import AVFoundation
import Accelerate
import Foundation

// Audio plumbing and the audio tools: trim (+ silent ends), channels, normalize (BS.1770), bleep.
// Audio is decoded to float32 PCM, processed in chunks, and written back as the source's PCM format
// (wav/aiff/caf/flac) or AAC in .m4a for everything else (no mp3/ogg encoders ship with macOS).

/// An opened audio source. Video files (or anything AVAudioFile cannot read) are decoded to a temp CAF first.
final class AudioSource {
    let file: AVAudioFile
    private let temp: URL?
    init(file: AVAudioFile, temp: URL?) { self.file = file; self.temp = temp }
    deinit { if let temp { try? FileManager.default.removeItem(at: temp) } }

    var sampleRate: Double { file.processingFormat.sampleRate }
    var channels: Int { Int(file.processingFormat.channelCount) }
    var duration: Double { Double(file.length) / sampleRate }
    func frame(_ seconds: Double) -> AVAudioFramePosition { min(file.length, max(0, AVAudioFramePosition((seconds * sampleRate).rounded()))) }
}

enum AudioIO {
    static let pcmExtensions: Set<String> = ["wav", "aiff", "aif", "caf"]
    static let chunk: AVAudioFrameCount = 32768

    static func open(_ url: URL) async throws -> AudioSource {
        if FileKind.of(url) == .audio, let f = try? AVAudioFile(forReading: url), f.length > 0 { return AudioSource(file: f, temp: nil) }
        return try await decode(url)
    }

    /// Decodes the first audio track of any AVFoundation-readable file into a float32 CAF in the temp folder.
    static func decode(_ url: URL) async throws -> AudioSource {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw FileChangerError.failed("This file has no audio track.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        guard reader.startReading() else { throw FileChangerError.failed("This file has no playable audio.") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("filechanger-audio-\(UUID().uuidString).caf")
        var outFile: AVAudioFile?
        while let sb = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let desc = CMSampleBufferGetFormatDescription(sb) else { continue }
            let fmt = AVAudioFormat(cmAudioFormatDescription: desc)
            let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
            guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { continue }
            buf.frameLength = n
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList) == noErr else { continue }
            if outFile == nil {
                outFile = try AVAudioFile(forWriting: temp, settings: fmt.settings, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
            }
            try outFile?.write(from: buf)
        }
        outFile = nil
        if reader.status == .failed { throw FileChangerError.failed("This file has no playable audio.") }
        guard let f = try? AVAudioFile(forReading: temp), f.length > 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw FileChangerError.failed("This file has no playable audio.")
        }
        return AudioSource(file: f, temp: temp)
    }

    static func outputExtension(for url: URL) -> String {
        let e = url.pathExtension.lowercased()
        return pcmExtensions.contains(e) || e == "flac" ? e : "m4a"
    }

    /// AAC-LC only accepts bitrates in a window that depends on sample rate and channels (22.05 kHz mono tops out near 64 kbps).
    static func aacBitrate(sampleRate: Double, channels: Int) -> Int {
        // Checked against the encoder: each rate accepts only a window (8 kHz mono 8-24 kbps, 22.05 kHz stereo 32-128 kbps, ...).
        let stereo = channels > 1
        switch sampleRate {
        case ..<8_001: return stereo ? 32_000 : 16_000
        case ..<12_001: return stereo ? 48_000 : 24_000
        case ..<16_001: return stereo ? 64_000 : 32_000
        case ..<24_001: return stereo ? 64_000 : 48_000
        case ..<40_000: return stereo ? 96_000 : 64_000
        default: return stereo ? 192_000 : 128_000
        }
    }

    static func writeSettings(ext: String, sampleRate: Double, channels: Int, source: [String: Any]) -> [String: Any] {
        if ext == "m4a" {
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: aacBitrate(sampleRate: sampleRate, channels: channels)]
        }
        let depth = (source[AVLinearPCMBitDepthKey] as? Int) ?? 16
        if ext == "flac" {
            return [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: depth >= 24 ? 24 : 16]
        }
        let isFloat = (source[AVLinearPCMIsFloatKey] as? Bool) ?? false
        return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: depth, AVLinearPCMIsFloatKey: isFloat,
                AVLinearPCMIsBigEndianKey: ext == "aiff" || ext == "aif", AVLinearPCMIsNonInterleaved: false]
    }

    /// Reads `frames` of `src` in chunks, lets `process` fill an output buffer (same frame count, `outChannels` wide),
    /// and writes the result to `dest`.
    static func stream(_ src: AVAudioFile, frames: Range<AVAudioFramePosition>, to dest: URL, ext: String, outChannels: Int,
                       progress: ProgressHandler,
                       process: (_ input: AVAudioPCMBuffer, _ firstFrame: AVAudioFramePosition, _ output: AVAudioPCMBuffer) throws -> Void) throws {
        let inFmt = src.processingFormat
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFmt.sampleRate,
                                         channels: AVAudioChannelCount(outChannels), interleaved: false),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: chunk),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: chunk) else {
            throw FileChangerError.failed("This audio can't be processed.")
        }
        let settings = writeSettings(ext: ext, sampleRate: inFmt.sampleRate, channels: outChannels, source: src.fileFormat.settings)
        var out: AVAudioFile? = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        src.framePosition = frames.lowerBound
        var pos = frames.lowerBound
        while pos < frames.upperBound {
            try Task.checkCancellation()
            let n = AVAudioFrameCount(min(Int64(chunk), frames.upperBound - pos))
            try src.read(into: inBuf, frameCount: n)
            if inBuf.frameLength == 0 { break }
            outBuf.frameLength = inBuf.frameLength
            try process(inBuf, pos, outBuf)
            try out?.write(from: outBuf)
            pos += Int64(inBuf.frameLength)
            progress(Double(pos - frames.lowerBound) / Double(max(1, frames.count)))
        }
        out = nil   // closes the file
    }

    static func copyChannels(_ i: AVAudioPCMBuffer, _ o: AVAudioPCMBuffer) {
        guard let src = i.floatChannelData, let dst = o.floatChannelData else { return }
        for c in 0..<Int(o.format.channelCount) { memcpy(dst[c], src[min(c, Int(i.format.channelCount) - 1)], Int(i.frameLength) * 4) }
    }
}

// MARK: - Waveform peaks (AUD-01 / AUD-12)

enum MediaWaveform {
    /// Peak amplitude (0...1) per bin; `channel` nil = loudest channel.
    static func peaks(url: URL, bins: Int, channel: Int? = nil) async throws -> [Float] {
        let source = try await AudioIO.open(url)
        return try peaks(source.file, bins: bins, channel: channel)
    }

    static func peaks(_ file: AVAudioFile, bins: Int, channel: Int? = nil) throws -> [Float] {
        let total = max(1, file.length)
        var result = [Float](repeating: 0, count: max(1, bins))
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AudioIO.chunk) else { return result }
        file.framePosition = 0
        var pos: Int64 = 0
        let channels = Int(file.processingFormat.channelCount)
        while pos < file.length {
            try Task.checkCancellation()
            try file.read(into: buf, frameCount: AudioIO.chunk)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let data = buf.floatChannelData else { break }
            let range = channel.map { min($0, channels - 1)...min($0, channels - 1) } ?? 0...(channels - 1)
            for i in 0..<n {
                var m: Float = 0
                for c in range { m = max(m, abs(data[c][i])) }
                let bin = min(result.count - 1, Int((pos + Int64(i)) * Int64(result.count) / total))
                if m > result[bin] { result[bin] = m }
            }
            pos += Int64(n)
        }
        return result
    }
}

// MARK: - Trim audio (AUD-01, AUD-02)

enum AudioSilence {
    static func validate(thresholdDB: Double) throws {
        guard thresholdDB >= -80, thresholdDB <= -10 else { throw FileChangerError.failed("Choose a silence threshold between -80 and -10 dB.") }
    }

    /// First and last non-silent point inside `within` (10 ms RMS windows; leading/trailing silence under 0.1 s is kept).
    /// nil when everything in the range is below the threshold.
    static func nonSilentSpan(_ file: AVAudioFile, thresholdDB: Double, within: MediaSpan? = nil) throws -> MediaSpan? {
        try validate(thresholdDB: thresholdDB)
        let sr = file.processingFormat.sampleRate
        let startFrame = Int64((within?.start ?? 0) * sr), endFrame = min(file.length, Int64((within?.end ?? Double.infinity) * sr))
        let win = max(1, Int(sr * 0.01))
        let limit = pow(10, Float(thresholdDB) / 10)     // mean-square threshold
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(win * 64)) else { return nil }
        file.framePosition = startFrame
        var pos = startFrame
        var first: Int64?, last: Int64 = 0
        let channels = Int(file.processingFormat.channelCount)
        while pos < endFrame {
            try Task.checkCancellation()
            try file.read(into: buf, frameCount: AVAudioFrameCount(min(Int64(buf.frameCapacity), endFrame - pos)))
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let data = buf.floatChannelData else { break }
            var w = 0
            while w < n {
                let len = min(win, n - w)
                var sum: Float = 0
                for c in 0..<channels {
                    var ms: Float = 0
                    vDSP_measqv(data[c] + w, 1, &ms, vDSP_Length(len))
                    sum += ms
                }
                if sum / Float(channels) > limit {
                    if first == nil { first = pos + Int64(w) }
                    last = pos + Int64(w + len)
                }
                w += len
            }
            pos += Int64(n)
        }
        guard let first else { return nil }
        var start = Double(first) / sr, end = Double(last) / sr
        let lo = within?.start ?? 0, hi = min(within?.end ?? .infinity, Double(file.length) / sr)
        if start - lo < 0.1 { start = lo }
        if hi - end < 0.1 { end = hi }
        return MediaSpan(start: start, end: end)
    }
}

enum AudioTrimEngine {
    static func trim(_ url: URL, start: Double, end: Double, autoTrimSilence: Bool = false, thresholdDB: Double = -50,
                     progress: @escaping ProgressHandler) async throws -> URL {
        let source = try await AudioIO.open(url)
        var span = MediaSpan(start: start, end: end)
        try MediaRange.validateTrim(start: start, end: end, duration: source.duration)
        if autoTrimSilence {
            guard let s = try AudioSilence.nonSilentSpan(source.file, thresholdDB: thresholdDB, within: span) else {
                throw FileChangerError.failed("The selected range is silent at this threshold. Lower the threshold or turn off automatic trimming.")
            }
            span = s
        }
        let frames = source.frame(span.start)..<source.frame(span.end)
        guard !frames.isEmpty else { throw FileChangerError.failed("Choose a positive time range within the file's duration.") }
        let ext = AudioIO.outputExtension(for: url)
        return try await MediaOutput.write(url, suffix: "-edited", ext: ext) { out in
            try AudioIO.stream(source.file, frames: frames, to: out, ext: ext, outChannels: source.channels, progress: progress) {
                AudioIO.copyChannels($0, $2)
            }
        }
    }
}

// MARK: - Channels (AUD-10..12)

enum AudioChannelsEngine {
    static func validate(channels: Int, left: Double, right: Double) throws {
        guard (1...2).contains(channels), (0...1).contains(left), (0...1).contains(right) else {
            throw FileChangerError.failed("Choose valid audio channel settings.")
        }
    }

    /// Mix `input` into `output` (1 or 2 channels). Volumes are 0...1. `solo` plays one source channel on its own.
    static func mix(_ input: AVAudioPCMBuffer, into output: AVAudioPCMBuffer, left: Float, right: Float, solo: Int? = nil) {
        guard let x = input.floatChannelData, let y = output.floatChannelData else { return }
        let inCh = Int(input.format.channelCount), outCh = Int(output.format.channelCount), n = Int(input.frameLength)
        if let solo {
            for c in 0..<outCh { memcpy(y[c], x[min(solo, inCh - 1)], n * 4) }
            return
        }
        let mid = (left + right) / 2
        let v: [Float] = (0..<inCh).map { inCh == 1 ? mid : ($0 == 0 ? left : $0 == 1 ? right : mid) }
        if outCh == 2 {
            for i in 0..<n {
                y[0][i] = x[0][i] * left
                y[1][i] = x[inCh > 1 ? 1 : 0][i] * right
            }
        } else {
            for i in 0..<n {
                var m: Float = 0
                for c in 0..<inCh { m += x[c][i] * v[c] }
                y[0][i] = m / Float(inCh)
            }
        }
    }

    /// Writes the converted audio (`limit` frames at most, for previews) to `dest`.
    static func render(_ source: AudioSource, channels: Int, left: Double, right: Double, solo: Int? = nil,
                       maxSeconds: Double? = nil, to dest: URL, ext: String, progress: ProgressHandler) throws {
        let total = maxSeconds.map { min(source.file.length, source.frame($0)) } ?? source.file.length
        try AudioIO.stream(source.file, frames: 0..<total, to: dest, ext: ext, outChannels: channels, progress: progress) { i, _, o in
            mix(i, into: o, left: Float(left), right: Float(right), solo: solo)
        }
    }

    static func convert(_ url: URL, channels: Int, left: Double = 1, right: Double = 1,
                        progress: @escaping ProgressHandler) async throws -> URL {
        try validate(channels: channels, left: left, right: right)
        let info = try await MediaProbe.info(url)
        guard info.hasAudio else { throw FileChangerError.failed("This file has no audio track.") }
        let source = try await AudioIO.open(url)
        if info.hasVideo {
            // Re-mix the audio into a temp m4a, then lay it under the untouched video.
            let (ext, type) = MediaOutput.videoContainer(url)
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("filechanger-channels-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: temp) }
            try render(source, channels: channels, left: left, right: right, to: temp, ext: "m4a") { progress($0 * 0.5) }
            return try await MediaOutput.write(url, suffix: "-edited", ext: ext) { out in
                try await VideoMux.replaceAudio(video: url, audio: temp, type: type, to: out) { progress(0.5 + $0 * 0.5) }
            }
        }
        let ext = AudioIO.outputExtension(for: url)
        return try await MediaOutput.write(url, suffix: "-edited", ext: ext) { out in
            try render(source, channels: channels, left: left, right: right, to: out, ext: ext, progress: progress)
        }
    }
}

// MARK: - Loudness (AUD-20): ITU-R BS.1770-4 integrated loudness

enum LoudnessMeter {
    struct Result {
        var integrated: Double      // LUFS; -infinity when the audio is silent or shorter than 400 ms
        var truePeak: Double        // linear, 4x interpolated estimate
        var subPowers: [Double] = []  // weighted mean-square per 100 ms step (for short-term loudness / range)
    }

    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    /// Stage 1 (head-related high shelf) and stage 2 (revised low-frequency B-curve high-pass), any sample rate.
    private static func kWeighting(_ fs: Double) -> [Biquad] {
        var k = tan(.pi * 1681.974450955533 / fs)
        let q1 = 0.7071752369554196, vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q1 + k * k
        let shelf = Biquad(b0: (vh + vb * k / q1 + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q1 + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0, a2: (1 - k / q1 + k * k) / a0)
        k = tan(.pi * 38.13547087602444 / fs)
        let q2 = 0.5003270373238773
        a0 = 1 + k / q2 + k * k
        let hp = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q2 + k * k) / a0)
        return [shelf, hp]
    }

    static func channelWeights(_ n: Int) -> [Double] { n == 6 ? [1, 1, 1, 0, 1.41, 1.41] : [Double](repeating: 1, count: n) }

    static func measure(_ file: AVAudioFile, progress: ProgressHandler = { _ in }) throws -> Result {
        let fmt = file.processingFormat
        let sr = fmt.sampleRate, ch = Int(fmt.channelCount)
        var filters = (0..<ch).map { _ in kWeighting(sr) }
        let weights = channelWeights(ch)
        let sub = max(1, Int((sr * 0.1).rounded()))
        var subSum = 0.0, subCount = 0
        var subs: [Double] = [], powers: [Double] = []
        var peak = 0.0
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AudioIO.chunk) else { return Result(integrated: -.infinity, truePeak: 0) }
        file.framePosition = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buf, frameCount: AudioIO.chunk)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let data = buf.floatChannelData else { break }
            for c in 0..<ch { peak = max(peak, AudioMath.truePeak(data[c], count: n, floor: peak * 0.5)) }
            for i in 0..<n {
                for c in 0..<ch {
                    let y = filters[c][1].run(filters[c][0].run(Double(data[c][i])))
                    subSum += weights[c] * y * y
                }
                subCount += 1
                if subCount == sub {
                    subs.append(subSum); subSum = 0; subCount = 0
                    if subs.count >= 4 { powers.append(subs.suffix(4).reduce(0, +) / Double(4 * sub)) }
                }
            }
            progress(Double(file.framePosition) / Double(max(1, file.length)))
        }
        return Result(integrated: integrated(powers), truePeak: peak, subPowers: subs.map { $0 / Double(sub) })
    }

    /// Absolute gate at -70 LUFS, then relative gate 10 LU below the gated mean.
    static func integrated(_ powers: [Double]) -> Double {
        func lufs(_ p: Double) -> Double { -0.691 + 10 * log10(p) }
        let abs70 = powers.filter { $0 > 0 && lufs($0) > -70 }
        guard !abs70.isEmpty else { return -.infinity }
        let gate = lufs(abs70.reduce(0, +) / Double(abs70.count)) - 10
        let kept = abs70.filter { lufs($0) > gate }
        guard !kept.isEmpty else { return -.infinity }
        return lufs(kept.reduce(0, +) / Double(kept.count))
    }

    static func lufs(_ p: Double) -> Double { -0.691 + 10 * log10(max(p, 1e-12)) }

    /// EBU Tech 3342 style range: 3 s short-term windows, -70 LUFS absolute and -20 LU relative gates, 10th..95th percentile.
    static func loudnessRange(_ subs: [Double]) -> Double {
        guard subs.count >= 30 else { return 0 }
        var window = subs[0..<30].reduce(0, +)
        var values = [window / 30]
        for i in 30..<subs.count { window += subs[i] - subs[i - 30]; values.append(window / 30) }
        let abs70 = values.filter { lufs($0) > -70 }
        guard !abs70.isEmpty else { return 0 }
        let gate = lufs(abs70.reduce(0, +) / Double(abs70.count)) - 20
        let l = abs70.map(lufs).filter { $0 > gate }.sorted()
        guard l.count > 1 else { return 0 }
        func pct(_ q: Double) -> Double { l[min(l.count - 1, Int(q * Double(l.count - 1)))] }
        return pct(0.95) - pct(0.10)
    }

    static func measure(url: URL) async throws -> Result {
        try measure(try await AudioIO.open(url).file)
    }
}

enum AudioMath {
    /// Largest |sample| including a Catmull-Rom estimate of the inter-sample peaks. Only samples above `floor` are interpolated.
    static func truePeak(_ p: UnsafePointer<Float>, count n: Int, floor: Double = 0) -> Double {
        var peak: Float = 0
        vDSP_maxmgv(p, 1, &peak, vDSP_Length(n))
        var best = Double(peak)
        let threshold = Float(max(floor, 0.0))
        guard n > 3 else { return best }
        for i in 1..<(n - 2) where abs(p[i]) >= threshold || abs(p[i + 1]) >= threshold {
            best = max(best, interpolatedPeak(p, i))
        }
        return best
    }

    /// Max |value| at t = 0.25, 0.5, 0.75 between samples i and i+1.
    static func interpolatedPeak(_ p: UnsafePointer<Float>, _ i: Int) -> Double {
        let p0 = Double(p[i - 1]), p1 = Double(p[i]), p2 = Double(p[i + 1]), p3 = Double(p[i + 2])
        var m = 0.0
        for t in [0.25, 0.5, 0.75] {
            let v = 0.5 * (2 * p1 + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t)
            m = max(m, abs(v))
        }
        return m
    }
}

enum AudioNormalizeEngine {
    static let defaultTarget = -16.0, defaultRange = 11.0, defaultTruePeak = -1.5

    static func validate(target: Double, range: Double, truePeak: Double) throws {
        guard (-70.0 ... -5.0).contains(target), (1.0 ... 50.0).contains(range), (-9.0 ... 0.0).contains(truePeak) else {
            throw FileChangerError.failed("Choose a target from -70 to -5 LUFS, a loudness range from 1 to 50 LU, and a true peak from -9 to 0 dBTP.")
        }
    }

    /// Static gain to reach `target`, a slow gain-riding curve (dB per 100 ms step) when the material is wider than `range` LU,
    /// and whether the true-peak ceiling needs the limiter.
    static func plan(measured: LoudnessMeter.Result, target: Double, range: Double = .infinity, truePeak: Double)
        throws -> (gain: Double, limit: Bool, ride: [Float]) {
        guard measured.integrated.isFinite else {
            throw FileChangerError.failed("This audio is too quiet or too short to measure its loudness.")
        }
        var gain = pow(10, (target - measured.integrated) / 20)
        var ride: [Float] = []
        let lra = LoudnessMeter.loudnessRange(measured.subPowers)
        if lra > range {
            // Squeeze short-term loudness toward the programme level by range/lra, at most 10 dB either way.
            let keep = range / lra, subs = measured.subPowers
            ride = (0..<subs.count).map { j -> Float in
                let w = subs[max(0, j - 15)..<min(subs.count, j + 15)]
                let l = LoudnessMeter.lufs(w.reduce(0, +) / Double(w.count))
                return l < -70 ? 0 : Float(min(10, max(-10, (measured.integrated - l) * (1 - keep))))
            }
        }
        if !ride.isEmpty {
            // Riding moves the programme loudness; re-aim the static gain from the post-ride gated blocks.
            let adjusted = zip(measured.subPowers, ride).map { $0 * pow(10, Double($1) / 10) }
            let blocks = adjusted.indices.dropFirst(3).map { (adjusted[$0 - 3...$0].reduce(0, +)) / 4 }
            let post = LoudnessMeter.integrated(blocks)
            if post.isFinite { gain = pow(10, (target - post) / 20) }
        }
        return (gain, !ride.isEmpty || measured.truePeak * gain > pow(10, truePeak / 20), ride)
    }

    /// Applies `gain` (and the riding curve); when `ceiling` (linear) would be exceeded a look-ahead limiter pulls the gain
    /// down around each peak. The limiter reads a ±lookahead window straight from the file, so memory stays bounded.
    static func render(_ source: AudioSource, gain: Double, ceiling: Double, limit: Bool, ride: [Float] = [], maxSeconds: Double? = nil,
                       to dest: URL, ext: String, progress: ProgressHandler) throws {
        let file = source.file
        let total = maxSeconds.map { min(file.length, source.frame($0)) } ?? file.length
        let look = Int(source.sampleRate * 0.004)
        let subLen = Double(max(1, Int((source.sampleRate * 0.1).rounded())))
        let aux = try AVAudioFile(forReading: file.url)
        let auxBuf = AVAudioPCMBuffer(pcmFormat: aux.processingFormat, frameCapacity: AudioIO.chunk + AVAudioFrameCount(2 * look + 8))
        func gainAt(_ f: Int) -> Double {
            guard !ride.isEmpty else { return gain }
            let pos = Double(f) / subLen - 0.5, base = pos.rounded(.down)
            let i0 = min(max(0, Int(base)), ride.count - 1), i1 = min(i0 + 1, ride.count - 1)
            let frac = Float(min(1, max(0, pos - base)))
            return gain * pow(10, Double(ride[i0] * (1 - frac) + ride[i1] * frac) / 20)
        }
        try AudioIO.stream(file, frames: 0..<total, to: dest, ext: ext, outChannels: source.channels, progress: progress) { input, first, output in
            guard let x = input.floatChannelData, let y = output.floatChannelData else { return }
            let n = Int(input.frameLength), channels = source.channels
            var curve: [Float]?
            var offset = 0
            if limit, let auxBuf, let a = auxBuf.floatChannelData {
                let lo = max(0, Int(first) - look), hi = min(Int(file.length), Int(first) + n + look)
                aux.framePosition = AVAudioFramePosition(lo)
                try aux.read(into: auxBuf, frameCount: AVAudioFrameCount(hi - lo))
                let len = Int(auxBuf.frameLength)
                var c = [Float](repeating: 1, count: len)
                for k in 0..<len {
                    var pk = 0.0
                    for ch in 0..<channels { pk = max(pk, Double(abs(a[ch][k]))) }
                    let g = gainAt(lo + k)
                    pk *= g
                    if len > 3, k >= 1, k < len - 2, pk > ceiling * 0.5 {
                        for ch in 0..<channels { pk = max(pk, AudioMath.interpolatedPeak(a[ch], k) * g) }
                    }
                    guard pk > ceiling else { continue }
                    let t = Float(ceiling / pk)
                    for m in max(0, k - look)...min(len - 1, k + look) {
                        c[m] = min(c[m], t + (1 - t) * Float(abs(m - k)) / Float(max(look, 1)))
                    }
                }
                curve = c
                offset = Int(first) - lo
            }
            for i in 0..<n {
                let g = Float(gainAt(Int(first) + i)) * (curve?[offset + i] ?? 1)
                for c in 0..<channels { y[c][i] = x[c][i] * g }
            }
        }
    }

    static func normalize(_ url: URL, target: Double = defaultTarget, range: Double = defaultRange, truePeak: Double = defaultTruePeak,
                          progress: @escaping ProgressHandler) async throws -> URL {
        try validate(target: target, range: range, truePeak: truePeak)
        let source = try await AudioIO.open(url)
        let measured = try LoudnessMeter.measure(source.file) { progress($0 * 0.4) }
        let plan = try plan(measured: measured, target: target, range: range, truePeak: truePeak)
        let ext = AudioIO.outputExtension(for: url)
        return try await MediaOutput.write(url, suffix: "-edited", ext: ext) { out in
            try render(source, gain: plan.gain, ceiling: pow(10, truePeak / 20) * 0.995, limit: plan.limit, ride: plan.ride,
                       to: out, ext: ext) { progress(0.4 + $0 * 0.6) }
        }
    }
}

// MARK: - Bleep (AUD-40, AUD-41)

enum AudioBleepEngine {
    static let frequency = 1000.0, amplitude: Float = 0.18

    /// Replaces the samples inside `ranges` (all channels) with a 1 kHz tone.
    static func render(_ source: AudioSource, ranges: [MediaSpan], maxSeconds: Double? = nil, to dest: URL, ext: String,
                       progress: ProgressHandler) throws {
        let sr = source.sampleRate
        let frames = ranges.map { (source.frame($0.start), source.frame($0.end)) }
        let total = maxSeconds.map { min(source.file.length, source.frame($0)) } ?? source.file.length
        try AudioIO.stream(source.file, frames: 0..<total, to: dest, ext: ext, outChannels: source.channels, progress: progress) { input, first, output in
            AudioIO.copyChannels(input, output)
            guard let y = output.floatChannelData else { return }
            let n = Int(input.frameLength)
            for (a, b) in frames {
                let lo = max(a, first), hi = min(b, first + Int64(n))
                guard lo < hi else { continue }
                for f in lo..<hi {
                    let v = amplitude * Float(sin(2 * .pi * frequency * Double(f - a) / sr))
                    for c in 0..<Int(output.format.channelCount) { y[c][Int(f - first)] = v }
                }
            }
        }
    }

    static func bleep(_ url: URL, ranges: [MediaSpan], progress: @escaping ProgressHandler) async throws -> URL {
        let source = try await AudioIO.open(url)
        try MediaRange.validateRanges(ranges, duration: source.duration, emptyMessage: "Add at least one bleep range.")
        let ext = AudioIO.outputExtension(for: url)
        return try await MediaOutput.write(url, suffix: "-bleeped", ext: ext) { out in
            try render(source, ranges: ranges, to: out, ext: ext, progress: progress)
        }
    }
}

// MARK: - Audio under video

enum VideoMux {
    /// Video track of `video` + audio of `audio` -> `out` (no re-encode where the container allows it).
    static func replaceAudio(video: URL, audio: URL, type: AVFileType, to out: URL, progress: @escaping ProgressHandler) async throws {
        let v = AVURLAsset(url: video), a = AVURLAsset(url: audio)
        let comp = AVMutableComposition()
        guard let vt = try await v.loadTracks(withMediaType: .video).first,
              let at = try await a.loadTracks(withMediaType: .audio).first,
              let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw FileChangerError.failed("This file has no playable video track.")
        }
        let vd = try await v.load(.duration), ad = try await a.load(.duration)
        try cv.insertTimeRange(CMTimeRange(start: .zero, duration: vd), of: vt, at: .zero)
        try ca.insertTimeRange(CMTimeRange(start: .zero, duration: min(ad, vd)), of: at, at: .zero)
        cv.preferredTransform = try await vt.load(.preferredTransform)
        try await MediaExport.preferPassthrough(asset: comp, type: type, to: out, progress: progress)
    }
}
