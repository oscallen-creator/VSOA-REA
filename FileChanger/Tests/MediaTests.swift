import AVFoundation
import CoreGraphics
import Foundation

// Fixtures are generated at test time: noisy H.264 clips and sine tones.
enum MediaFixtures {
    static func dir(_ name: String) throws -> URL {
        let d = Fixtures.scratch.appendingPathComponent("media-\(name)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Sine tone; `silenceBefore`/`silenceAfter` pad with zeros. Writes 16-bit PCM wav.
    @discardableResult
    static func tone(_ url: URL, seconds: Double, freq: Double = 1000, amplitude: Double = 0.5, channels: Int = 2,
                     rate: Double = 44100, silenceBefore: Double = 0, silenceAfter: Double = 0) throws -> URL {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let fmt = file!.processingFormat
        let total = Int((silenceBefore + seconds + silenceAfter) * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(total))!
        buf.frameLength = AVAudioFrameCount(total)
        let start = Int(silenceBefore * rate), end = start + Int(seconds * rate)
        for c in 0..<channels {
            for i in 0..<total {
                buf.floatChannelData![c][i] = (i >= start && i < end) ? Float(amplitude * sin(2 * .pi * freq * Double(i - start) / rate)) : 0
            }
        }
        try file!.write(from: buf)
        file = nil
        return url
    }

    /// Noisy colour-cycling H.264 mp4; optionally with a tone under it.
    @discardableResult
    static func video(_ url: URL, seconds: Double, fps: Int32 = 10, width: Int = 160, height: Int = 96, audio: Bool = false) async throws -> URL {
        let target = audio ? url.deletingPathExtension().appendingPathExtension("silent.mp4") : url
        let writer = try AVAssetWriter(outputURL: target, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pb)
            for y in 0..<height {
                for x in 0..<width {
                    let o = y * stride + x * 4
                    base[o] = UInt8.random(in: 90...255, using: &rng); base[o + 1] = UInt8.random(in: 90...255, using: &rng)
                    base[o + 2] = UInt8(truncatingIfNeeded: 120 + i * 9); base[o + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw FileChangerError.failed("fixture video failed: \(String(describing: writer.error))") }
        if audio {
            let wav = try tone(url.deletingPathExtension().appendingPathExtension("tone.wav"), seconds: seconds, freq: 440)
            try await VideoMux.replaceAudio(video: target, audio: wav, type: .mp4, to: url) { _ in }
        }
        return url
    }

    /// Two-level sine (loud then quiet) to give the file a wide loudness range.
    static func twoLevel(_ url: URL, seconds: Double, loud: Double, quiet: Double, rate: Double = 44100) throws -> URL {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = Int(seconds * 2 * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: file!.processingFormat, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { buf.floatChannelData![0][i] = Float((i < n / 2 ? loud : quiet) * sin(2 * .pi * 440 * Double(i) / rate)) }
        try file!.write(from: buf)
        file = nil
        return url
    }

    /// Low-rate mono AAC .m4a, the combination AVAudioFile only encodes at a small bitrate.
    static func lowRateM4A(_ url: URL, seconds: Double, rate: Double = 22050, channels: Int = 1) throws -> URL {
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                                 AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: AudioIO.aacBitrate(sampleRate: rate, channels: channels)], commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = Int(seconds * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: file!.processingFormat, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for c in 0..<channels { for i in 0..<n { buf.floatChannelData![c][i] = Float(0.3 * sin(2 * .pi * 440 * Double(i) / rate)) } }
        try file!.write(from: buf)
        file = nil
        return url
    }

    /// Peak |sample| between two times of an audio file.
    static func peak(_ url: URL, from: Double, to: Double) throws -> Float {
        let f = try AVAudioFile(forReading: url)
        let sr = f.processingFormat.sampleRate
        f.framePosition = AVAudioFramePosition(from * sr)
        let n = AVAudioFrameCount((to - from) * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n)!
        try f.read(into: buf, frameCount: n)
        var m: Float = 0
        for c in 0..<Int(buf.format.channelCount) { for i in 0..<Int(buf.frameLength) { m = max(m, abs(buf.floatChannelData![c][i])) } }
        return m
    }

    static func luma(_ image: CGImage, x: Int, y: Int) -> Double {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Double(px[0]) + Double(px[1]) + Double(px[2])) / 765
    }
}

extension TestSuites {
    static var mediaSuites: [Suite] {
        [Suite(name: "media-core", tests: [
            ("time formatting m:ss.cc", {
                try expectEqual(MediaTime.format(0), "0:00.00")
                try expectEqual(MediaTime.format(83.456), "1:23.46")
                try expectEqual(MediaTime.format(59.999), "1:00.00")
                try expectEqual(MediaTime.format(3725.5), "1:02:05.50")
                try expect(abs((MediaTime.parse("1:23.46") ?? 0) - 83.46) < 1e-9)
                try expectEqual(MediaTime.parse("12"), 12)
                try expect(MediaTime.parse("x") == nil)
            }),
            ("range validation messages", {
                func message(_ body: () throws -> Void) -> String { do { try body() } catch { return error.localizedDescription }; return "" }
                try expectEqual(message { try MediaRange.validateTrim(start: -1, end: 2, duration: 10) }, "Set a start and end within the file.")
                try expectEqual(message { try MediaRange.validateTrim(start: 3, end: 3, duration: 10) }, "Choose a positive time range within the file's duration.")
                try expectEqual(message { try MediaRange.validateSplits([0.01], duration: 10) },
                                "Add split points inside the video, at least 0.05 seconds from either end.")
                try expectEqual(message { try MediaRange.validateSplits([2, 2.02], duration: 10) }, "Split points must be at least 0.05 seconds apart.")
                try expectEqual(message { try MediaRange.validateSpeed(5) }, "Choose a speed between 0.25 and 4.")
                try expectEqual(message { try AudioSilence.validate(thresholdDB: -5) }, "Choose a silence threshold between -80 and -10 dB.")
                try expectEqual(message { try AudioNormalizeEngine.validate(target: 0, range: 11, truePeak: -1) },
                                "Choose a target from -70 to -5 LUFS, a loudness range from 1 to 50 LU, and a true peak from -9 to 0 dBTP.")
                try expectEqual(MediaRange.clips(splits: [1, 3], duration: 4).count, 3)
            }),
            ("compress validation and size parsing", {
                func message(_ body: () throws -> Void) -> String { do { try body() } catch { return error.localizedDescription }; return "" }
                try expectEqual(VideoCompressEngine.bytes(from: "1.5", unit: "MB"), 1_500_000)
                try expectEqual(message { _ = try VideoCompressEngine.validateTarget(5_000_000, original: 1_000_000) }, "Target size cannot exceed the original file size.")
                try expectEqual(message { _ = try VideoCompressEngine.validateTarget(10, original: 1_000_000) }, "Enter a target size between 1 KB and 1 TB.")
                try expectEqual(message { _ = try VideoCompressEngine.validateReduction(100, original: 1_000_000) },
                                "Choose a reduction from 1% to 99% that leaves at least 1 KB per file.")
                try expectEqual(try VideoCompressEngine.validateReduction(50, original: 1_000_000), 500_000)
            }),
        ]),
        Suite(name: "media-video", tests: [
            ("trim keeps the chosen range", {
                let dir = try MediaFixtures.dir("trim")
                let src = try await MediaFixtures.video(dir.appendingPathComponent("a.mp4"), seconds: 4)
                let out = try await VideoTrimEngine.trim(src, start: 1, end: 3) { _ in }
                try expectEqual(out.lastPathComponent, "a-edited.mp4")
                let info = try await MediaProbe.video(out)
                try expect(abs(info.duration - 2) < 0.35, "duration \(info.duration)")
            }),
            ("split into clips and merged export", {
                let dir = try MediaFixtures.dir("split")
                let src = try await MediaFixtures.video(dir.appendingPathComponent("a.mp4"), seconds: 4)
                let folder = try await VideoSplitEngine.split(src, splits: [1.5, 3], mode: .clips) { _ in }
                let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
                try expectEqual(files, ["Clip 001.mp4", "Clip 002.mp4", "Clip 003.mp4"])
                let merged = try await VideoSplitEngine.split(src, splits: [1.5, 3], removed: [1], mode: .merged) { _ in }
                let d = try await MediaProbe.video(merged).duration
                try expect(abs(d - 2.5) < 0.4, "merged duration \(d)")
                var failed = ""
                do { _ = try await VideoSplitEngine.split(src, splits: [2], removed: [0, 1], mode: .merged) { _ in } } catch { failed = error.localizedDescription }
                try expectEqual(failed, "Keep at least one clip.")
            }),
            ("join normalises sizes and sums durations", {
                let dir = try MediaFixtures.dir("join")
                let a = try await MediaFixtures.video(dir.appendingPathComponent("a.mp4"), seconds: 2, audio: true)
                let b = try await MediaFixtures.video(dir.appendingPathComponent("b.mp4"), seconds: 1, width: 96, height: 160)
                let out = try await VideoJoinEngine.join([a, b]) { _ in }
                let info = try await MediaProbe.video(out)
                try expect(abs(info.duration - 3) < 0.4, "duration \(info.duration)")
                try expectEqual(Int(info.displaySize.width), 160)
                try expect(info.hasAudio, "audio from first clip kept")
                try expectEqual(VideoJoinEngine.sortedByName([dir.appendingPathComponent("clip10.mp4"), dir.appendingPathComponent("clip2.mp4")]).map(\.lastPathComponent),
                                ["clip2.mp4", "clip10.mp4"])
            }),
            ("join of videos without audio and crop height cap", {
                let dir = try MediaFixtures.dir("joinsilent")
                let a = try await MediaFixtures.video(dir.appendingPathComponent("a.mp4"), seconds: 1)
                let b = try await MediaFixtures.video(dir.appendingPathComponent("b.mp4"), seconds: 1)
                let out = try await VideoJoinEngine.join([a, b]) { _ in }
                let info = try await MediaProbe.video(out)
                try expect(!info.hasAudio && abs(info.duration - 2) < 0.4, "joined \(info.duration)")
                let crop = try await VideoCropEngine.crop(a, rect: CGRect(x: 0, y: 0, width: 160, height: 96), maxHeight: 48) { _ in }
                let ci = try await MediaProbe.video(crop)
                try expectEqual(Int(ci.displaySize.height), 48)
            }),
            ("remove audio drops the audio track", {
                let dir = try MediaFixtures.dir("mute")
                let src = try await MediaFixtures.video(dir.appendingPathComponent("a.mp4"), seconds: 2, audio: true)
                let hadAudio = try await MediaProbe.info(src).hasAudio
                try expect(hadAudio, "fixture has audio")
                let out = try await VideoMuteEngine.mute(src) { _ in }
                let info = try await MediaProbe.info(out)
                try expect(info.hasVideo && !info.hasAudio, "video only")
                try expect(abs(info.duration - 2) < 0.3)
            }),
            ("speed changes duration and keeps audio", {
                let dir = try MediaFixtures.dir("speed")
                let src = try await MediaFixtures.video(dir.appendingPathComponent("a.mp4"), seconds: 4, audio: true)
                let fast = try await VideoSpeedEngine.changeSpeed(src, speed: 2) { _ in }
                let fi = try await MediaProbe.video(fast)
                try expect(abs(fi.duration - 2) < 0.35, "2x duration \(fi.duration)")
                try expect(fi.hasAudio, "audio kept")
                let slow = try await VideoSpeedEngine.changeSpeed(src, speed: 0.5) { _ in }
                let si = try await MediaProbe.video(slow).duration
                try expect(abs(si - 8) < 0.5, "0.5x duration \(si)")
            }),
            ("snapshots write named PNGs", {
                let dir = try MediaFixtures.dir("snap")
                let src = try await MediaFixtures.video(dir.appendingPathComponent("a.mp4"), seconds: 3)
                let folder = try await VideoSnapshotEngine.snapshots(src, times: [0, 1.25, 2.5]) { _ in }
                let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
                try expectEqual(files, ["Frame 001 - 0.000s.png", "Frame 002 - 1.250s.png", "Frame 003 - 2.500s.png"])
                var message = ""
                do { _ = try await VideoSnapshotEngine.snapshots(src, times: [99]) { _ in } } catch { message = error.localizedDescription }
                try expectEqual(message, "Select at least one frame within the video.")
            }),
            ("crop output has the cropped size", {
                let dir = try MediaFixtures.dir("crop")
                let src = try await MediaFixtures.video(dir.appendingPathComponent("a.mp4"), seconds: 2)
                let out = try await VideoCropEngine.crop(src, rect: CGRect(x: 16, y: 8, width: 81, height: 49)) { _ in }
                let info = try await MediaProbe.video(out)
                try expectEqual(Int(info.displaySize.width), 80)
                try expectEqual(Int(info.displaySize.height), 48)
                var message = ""
                do { _ = try await VideoCropEngine.crop(src, rect: CGRect(x: 100, y: 0, width: 100, height: 50)) { _ in } } catch { message = error.localizedDescription }
                try expectEqual(message, "Keep the crop inside the video frame.")
            }),
            ("redact paints only inside its time range", {
                let dir = try MediaFixtures.dir("redact")
                let src = try await MediaFixtures.video(dir.appendingPathComponent("a.mp4"), seconds: 2)
                let item = VideoRedaction(rect: CGRect(x: 40, y: 20, width: 80, height: 50), start: 0, end: 1)
                let out = try await VideoRedactEngine.redact(src, items: [item], style: .solid) { _ in }
                let during = try await MediaThumbnails.frame(url: out, at: 0.4)
                let after = try await MediaThumbnails.frame(url: out, at: 1.5)
                try expect(MediaFixtures.luma(during, x: 80, y: 45) < 0.12, "covered while active")
                try expect(MediaFixtures.luma(after, x: 80, y: 45) > 0.2, "visible after the range")
                let blurred = try await VideoRedactEngine.redact(src, items: [item], style: .blur) { _ in }
                let bd = try await MediaProbe.video(blurred).duration
                try expect(bd > 1.5)
            }),
            ("compress to a target size", {
                let dir = try MediaFixtures.dir("compress")
                let src = try await MediaFixtures.video(dir.appendingPathComponent("a.mp4"), seconds: 4, audio: true)
                let original = VideoCompressEngine.fileSize(src)
                let target = original * 6 / 10
                let out = try await VideoCompressEngine.compress(src, mode: .targetSize(bytes: target, accurate: true)) { _ in }
                try expect(VideoCompressEngine.fileSize(out) <= target, "size \(VideoCompressEngine.fileSize(out)) > \(target)")
                let info = try await MediaProbe.video(out)
                try expect(info.hasAudio && abs(info.duration - 4) < 0.5)
                let silent = try await MediaFixtures.video(dir.appendingPathComponent("b.mp4"), seconds: 4)
                // A 4-second noise clip is already near the encoder floor: smaller output, or the explicit refusal.
                do {
                    let preset = try await VideoCompressEngine.compress(silent, mode: .preset(strong: true)) { _ in }
                    try expect(VideoCompressEngine.fileSize(preset) < VideoCompressEngine.fileSize(silent))
                } catch let e as FileChangerError {
                    try expectEqual(e.localizedDescription, "Compressed output would exceed the original or target file size.")
                }
            }),
        ]),
        Suite(name: "media-audio", tests: [
            ("trim audio and silent ends", {
                let dir = try MediaFixtures.dir("atrim")
                let src = try MediaFixtures.tone(dir.appendingPathComponent("t.wav"), seconds: 3)
                let out = try await AudioTrimEngine.trim(src, start: 0.5, end: 2) { _ in }
                let f = try AVAudioFile(forReading: out)
                try expect(abs(Double(f.length) / f.processingFormat.sampleRate - 1.5) < 0.02)
                let padded = try MediaFixtures.tone(dir.appendingPathComponent("p.wav"), seconds: 1, silenceBefore: 1, silenceAfter: 1)
                let auto = try await AudioTrimEngine.trim(padded, start: 0, end: 3, autoTrimSilence: true, thresholdDB: -50) { _ in }
                let a = try AVAudioFile(forReading: auto)
                let d = Double(a.length) / a.processingFormat.sampleRate
                try expect(abs(d - 1) < 0.05, "auto-trimmed length \(d)")
                let quiet = try MediaFixtures.tone(dir.appendingPathComponent("q.wav"), seconds: 1, amplitude: 0)
                var message = ""
                do { _ = try await AudioTrimEngine.trim(quiet, start: 0, end: 1, autoTrimSilence: true) { _ in } } catch { message = error.localizedDescription }
                try expectEqual(message, "The selected range is silent at this threshold. Lower the threshold or turn off automatic trimming.")
            }),
            ("22.05 kHz mono m4a trims and normalizes", {
                let dir = try MediaFixtures.dir("lowrate")
                let src = try MediaFixtures.lowRateM4A(dir.appendingPathComponent("v.m4a"), seconds: 3)
                let trimmed = try await AudioTrimEngine.trim(src, start: 0.5, end: 2) { _ in }
                try expectEqual(trimmed.pathExtension, "m4a")
                let norm = try await AudioNormalizeEngine.normalize(src) { _ in }
                let m = try await LoudnessMeter.measure(url: norm)
                try expect(abs(m.integrated + 16) < 1, "normalized \(m.integrated)")
                try expectEqual(AudioIO.aacBitrate(sampleRate: 22050, channels: 1), 48000)
                for (rate, ch) in [(8000.0, 1), (16000.0, 2), (11025.0, 1)] {
                    let low = try MediaFixtures.lowRateM4A(dir.appendingPathComponent("r\(Int(rate)).m4a"), seconds: 1, rate: rate, channels: ch)
                    let t = try await AudioTrimEngine.trim(low, start: 0, end: 0.5) { _ in }
                    try expectEqual(t.pathExtension, "m4a")
                }
            }),
            ("loudness range target narrows wide material", {
                let dir = try MediaFixtures.dir("lra")
                let src = try MediaFixtures.twoLevel(dir.appendingPathComponent("w.wav"), seconds: 8, loud: 0.4, quiet: 0.1)
                let before = try await LoudnessMeter.measure(url: src)
                let lraBefore = LoudnessMeter.loudnessRange(before.subPowers)
                try expect(lraBefore > 8, "input range \(lraBefore)")
                let out = try await AudioNormalizeEngine.normalize(src, target: -16, range: 4, truePeak: -1.5) { _ in }
                let after = try await LoudnessMeter.measure(url: out)
                try expect(abs(after.integrated + 16) <= 0.3, "riding landed at \(after.integrated)")
                let mild = try await AudioNormalizeEngine.normalize(src, target: -16, range: 5, truePeak: -1.5) { _ in }
                let mildLUFS = try await LoudnessMeter.measure(url: mild).integrated
                try expect(abs(mildLUFS + 16) <= 0.3, "LRA 5 landed at \(mildLUFS)")
                try expect(LoudnessMeter.loudnessRange(after.subPowers) < lraBefore - 5, "output range \(LoudnessMeter.loudnessRange(after.subPowers))")
            }),
            ("channels: mono, stereo and balance", {
                let dir = try MediaFixtures.dir("chan")
                let stereo = try MediaFixtures.tone(dir.appendingPathComponent("s.wav"), seconds: 1, amplitude: 0.8)
                let mono = try await AudioChannelsEngine.convert(stereo, channels: 1) { _ in }
                try expectEqual(Int(try AVAudioFile(forReading: mono).processingFormat.channelCount), 1)
                let back = try await AudioChannelsEngine.convert(mono, channels: 2, left: 1, right: 0.5) { _ in }
                let f = try AVAudioFile(forReading: back)
                try expectEqual(Int(f.processingFormat.channelCount), 2)
                let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 44100)!
                try f.read(into: buf, frameCount: 44100)
                var l: Float = 0, r: Float = 0
                for i in 0..<Int(buf.frameLength) { l = max(l, abs(buf.floatChannelData![0][i])); r = max(r, abs(buf.floatChannelData![1][i])) }
                try expect(abs(r / l - 0.5) < 0.02, "balance \(r / l)")
            }),
            ("BS.1770 loudness of a -23 dBFS stereo sine is -23 LUFS", {
                let dir = try MediaFixtures.dir("loud")
                let src = try MediaFixtures.tone(dir.appendingPathComponent("t.wav"), seconds: 3, amplitude: pow(10, -23.0 / 20), rate: 48000)
                let m = try await LoudnessMeter.measure(url: src)
                try expect(abs(m.integrated + 23) < 0.2, "measured \(m.integrated)")
                let silent = try MediaFixtures.tone(dir.appendingPathComponent("z.wav"), seconds: 1, amplitude: 0)
                let sm = try await LoudnessMeter.measure(url: silent)
                try expect(sm.integrated == -.infinity)
            }),
            ("normalize reaches the target and respects the true-peak limit", {
                let dir = try MediaFixtures.dir("norm")
                let src = try MediaFixtures.tone(dir.appendingPathComponent("t.wav"), seconds: 4, freq: 997, amplitude: 0.03)
                let out = try await AudioNormalizeEngine.normalize(src, target: -16, truePeak: -1.5) { _ in }
                let m = try await LoudnessMeter.measure(url: out)
                try expect(abs(m.integrated + 16) < 0.5, "normalized to \(m.integrated)")
                // Loud peaky material: target -10 LUFS would clip without the limiter.
                let peaky = dir.appendingPathComponent("peaky.wav")
                try MediaFixtures.tone(peaky, seconds: 4, freq: 220, amplitude: 0.1)
                let spiky = try AVAudioFile(forReading: peaky)
                let buf = AVAudioPCMBuffer(pcmFormat: spiky.processingFormat, frameCapacity: AVAudioFrameCount(spiky.length))!
                try spiky.read(into: buf)
                for k in stride(from: 20000, to: Int(buf.frameLength), by: 40000) { for c in 0..<2 { buf.floatChannelData![c][k] = 0.9 } }
                let spikedURL = dir.appendingPathComponent("spiked.wav")
                var w: AVAudioFile? = try AVAudioFile(forWriting: spikedURL, settings: spiky.fileFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try w?.write(from: buf); w = nil
                let limited = try await AudioNormalizeEngine.normalize(spikedURL, target: -10, truePeak: -1.5) { _ in }
                let peak = try MediaFixtures.peak(limited, from: 0, to: 3.9)
                try expect(Double(peak) <= pow(10, -1.5 / 20) * 1.03, "peak \(peak)")
            }),
            ("bleep replaces the range with a 1 kHz tone at 0.18", {
                let dir = try MediaFixtures.dir("bleep")
                let src = try MediaFixtures.tone(dir.appendingPathComponent("t.wav"), seconds: 3, freq: 440, amplitude: 0.6)
                let out = try await AudioBleepEngine.bleep(src, ranges: [MediaSpan(start: 1, end: 2)]) { _ in }
                try expect(abs(Double(try MediaFixtures.peak(out, from: 1.1, to: 1.9)) - 0.18) < 0.01)
                try expect(abs(Double(try MediaFixtures.peak(out, from: 0.1, to: 0.9)) - 0.6) < 0.01)
                var message = ""
                do { _ = try await AudioBleepEngine.bleep(src, ranges: []) { _ in } } catch { message = error.localizedDescription }
                try expectEqual(message, "Add at least one bleep range.")
            }),
            ("waveform peaks follow the audio", {
                let dir = try MediaFixtures.dir("wave")
                let src = try MediaFixtures.tone(dir.appendingPathComponent("t.wav"), seconds: 2, amplitude: 0.5, silenceBefore: 1)
                let p = try await MediaWaveform.peaks(url: src, bins: 6)
                try expect(p[0] == 0 && p[5] > 0.4, "peaks \(p)")
            }),
            ("visualizer writes H.264 + AAC mp4", {
                let dir = try MediaFixtures.dir("viz")
                let src = try MediaFixtures.tone(dir.appendingPathComponent("t.wav"), seconds: 2, freq: 300)
                let out = try await AudioVisualizerEngine.create(src, style: .waveform, imageURL: nil, shape: .landscape,
                                                                 canvasOverride: CGSize(width: 192, height: 108)) { _ in }
                let info = try await MediaProbe.video(out)
                try expect(info.hasAudio && abs(info.duration - 2) < 0.3, "duration \(info.duration)")
                try expectEqual(Int(info.displaySize.width), 192)
                try expectEqual(AudioVisualizerEngine.canvas(.portrait, image: nil), CGSize(width: 1080, height: 1920))
                var message = ""
                do { _ = try await AudioVisualizerEngine.create(src, style: .staticImage, imageURL: nil, shape: .square) { _ in } } catch { message = error.localizedDescription }
                try expectEqual(message, "Choose an image for the visualization.")
            }),
        ])]
    }
}
