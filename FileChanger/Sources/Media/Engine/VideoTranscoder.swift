import AVFoundation
import Foundation

// Re-encode through AVAssetReader -> AVAssetWriter with an explicit bitrate. Crop, redact and compress share it.

struct VideoTranscodeJob {
    var asset: AVAsset
    var videoComposition: AVVideoComposition
    var codec: AVVideoCodecType = .h264
    var videoBitrate: Int
    var audioBitrate: Int = 128_000
    var info: MediaInfo
    var type: AVFileType
    var includeAudio = true
}

enum VideoTranscoder {
    static func run(_ job: VideoTranscodeJob, to url: URL, progress: @escaping ProgressHandler) async throws {
        let asset = job.asset
        let vTracks = try await asset.loadTracks(withMediaType: .video)
        let aTracks = job.includeAudio ? ((try? await asset.loadTracks(withMediaType: .audio)) ?? []) : []
        guard !vTracks.isEmpty else { throw FileChangerError.failed("This file has no playable video track.") }
        let duration = try await asset.load(.duration).seconds

        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: vTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        vOut.videoComposition = job.videoComposition
        reader.add(vOut)

        // AAC refuses stereo below ~64 kbps, so tiny audio budgets go mono.
        let channels = job.audioBitrate < 64_000 ? 1 : max(1, min(2, job.info.audioChannels))
        let audioBitrate = max(job.audioBitrate, channels == 1 ? 32_000 : 64_000)
        let rate = job.info.sampleRate > 0 ? job.info.sampleRate : 44100
        var aOut: AVAssetReaderAudioMixOutput?
        if !aTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false])
            o.audioTimePitchAlgorithm = .spectral
            reader.add(o)
            aOut = o
        }

        let size = job.videoComposition.renderSize
        var props: [String: Any] = [AVVideoAverageBitRateKey: max(50_000, job.videoBitrate)]
        if job.codec == .h264 { props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let writer = try AVAssetWriter(outputURL: url, fileType: job.type)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: job.codec, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: props])
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: audioBitrate])
            i.expectsMediaDataInRealTime = false
            writer.add(i)
            aIn = i
        }
        writer.shouldOptimizeForNetworkUse = true

        guard reader.startReading() else { throw FileChangerError.failed(reader.error?.localizedDescription ?? "The operation couldn't be completed.") }
        guard writer.startWriting() else { throw FileChangerError.failed(writer.error?.localizedDescription ?? "The operation couldn't be completed.") }
        writer.startSession(atSourceTime: .zero)

        var feeds = [MediaPump.Feed(input: vIn, step: {
            guard let sb = vOut.copyNextSampleBuffer() else { return false }
            progress(min(1, CMSampleBufferGetPresentationTimeStamp(sb).seconds / max(duration, 0.001)))
            return vIn.append(sb)
        })]
        if let aOut, let aIn {
            feeds.append(MediaPump.Feed(input: aIn, step: {
                guard let sb = aOut.copyNextSampleBuffer() else { return false }
                return aIn.append(sb)
            }))
        }
        let cancelled = await MediaPump.run(feeds)
        if cancelled || Task.isCancelled {
            reader.cancelReading(); writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw FileChangerError.failed(reader.error?.localizedDescription ?? "The operation couldn't be completed.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw FileChangerError.failed(writer.error?.localizedDescription ?? "The operation couldn't be completed.")
        }
        progress(1)
    }
}

// MARK: - Compress (VID-70...73)

enum VideoCompressMode: Sendable, Equatable {
    case preset(strong: Bool)
    /// Reduce the file by this many percent (1...99).
    case reduction(Int)
    case targetSize(bytes: Int64, accurate: Bool)
}

enum VideoCompressEngine {
    static let kilobyte: Int64 = 1000

    /// "1.5 MB" style text.
    static func sizeText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// Parses a size field + unit ("KB", "MB", "GB", "TB").
    static func bytes(from text: String, unit: String) -> Int64? {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")), v > 0 else { return nil }
        let mult: [String: Double] = ["KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12]
        guard let m = mult[unit.uppercased()] else { return nil }
        return Int64(v * m)
    }

    static func validateTarget(_ bytes: Int64?, original: Int64) throws -> Int64 {
        guard let bytes else { throw FileChangerError.failed("Enter a target size of at least 1 KB.") }
        guard bytes >= kilobyte, bytes <= 1_000_000_000_000 else { throw FileChangerError.failed("Enter a target size between 1 KB and 1 TB.") }
        guard bytes <= original else { throw FileChangerError.failed("Target size cannot exceed the original file size.") }
        return bytes
    }

    static func validateReduction(_ percent: Int, original: Int64) throws -> Int64 {
        guard original >= kilobyte else { throw FileChangerError.failed("This file is already smaller than 1 KB.") }
        let target = original * Int64(100 - percent) / 100
        guard (1...99).contains(percent), target >= kilobyte else {
            throw FileChangerError.failed("Choose a reduction from 1% to 99% that leaves at least 1 KB per file.")
        }
        return target
    }

    struct Plan {
        var codec: AVVideoCodecType
        var videoBitrate: Int
        var audioBitrate: Int
        var height: CGFloat     // output height (display), never above the source
    }

    /// Bitrate budget for a target size: file bits minus container overhead and audio, spread over the duration.
    static func targetPlan(bytes: Int64, info: MediaInfo) throws -> Plan {
        let budget = Double(bytes) * 8 * 0.97 - 16 * 1024 * 8
        var audio = 0.0
        if info.hasAudio {
            audio = min(128_000, max(32_000, budget * 0.12 / info.duration))
            guard budget > audio * info.duration * 1.05 else {
                throw FileChangerError.failed("The target is too small after audio and container overhead. Choose a larger size.")
            }
        } else {
            guard budget > 0 else { throw FileChangerError.failed("The target is too small for this duration. Choose a larger size.") }
        }
        let video = (budget - audio * info.duration) / info.duration
        guard video >= 8_000 else { throw FileChangerError.failed("The target leaves too little space for video.") }
        return Plan(codec: .h264, videoBitrate: Int(video), audioBitrate: Int(audio),
                    height: height(bitrate: video, info: info, bitsPerPixel: 0.035))
    }

    /// Largest standard height (<= source) that still gets `bitsPerPixel` per pixel per frame.
    static func height(bitrate: Double, info: MediaInfo, bitsPerPixel: Double) -> CGFloat {
        let aspect = info.displaySize.width / max(1, info.displaySize.height)
        for h in [info.displaySize.height, 2160, 1440, 1080, 720, 480, 360, 240] where h <= info.displaySize.height {
            if bitrate / (Double(h) * Double(h) * Double(aspect) * info.fps) >= bitsPerPixel { return h }
        }
        return min(info.displaySize.height, 240)
    }

    static func presetPlan(strong: Bool, info: MediaInfo) -> Plan {
        let pixels = Double(info.displaySize.width * info.displaySize.height) * info.fps
        let source = info.videoBitrate > 0 ? info.videoBitrate : pixels * 0.1
        if strong {
            let v = max(120_000, min(source * 0.3, pixels * 0.04))
            return Plan(codec: .hevc, videoBitrate: Int(v), audioBitrate: 96_000, height: min(info.displaySize.height, 1080))
        }
        let v = max(200_000, min(source * 0.6, pixels * 0.09))
        return Plan(codec: .h264, videoBitrate: Int(v), audioBitrate: 128_000, height: info.displaySize.height)
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    private static func encode(_ url: URL, info: MediaInfo, plan: Plan, to out: URL, progress: @escaping ProgressHandler) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw FileChangerError.failed("This file has no playable video track.") }
        let scale = min(1, plan.height / info.displaySize.height)
        let size = CGSize(width: info.displaySize.width * scale, height: info.displaySize.height * scale)
        let t = info.transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let vc = VideoGeometry.composition(track: track, duration: MediaTime.cm(info.duration), transform: t, renderSize: size, fps: info.fps)
        let (_, type) = MediaOutput.videoContainer(url)
        try await VideoTranscoder.run(VideoTranscodeJob(asset: asset, videoComposition: vc, codec: plan.codec, videoBitrate: plan.videoBitrate,
                                                        audioBitrate: plan.audioBitrate, info: info, type: type), to: out, progress: progress)
    }

    /// The result must keep its duration and tracks (VID-72).
    private static func verify(_ out: URL, info: MediaInfo) async throws {
        guard let o = try? await MediaProbe.info(out), o.hasVideo, o.hasAudio == info.hasAudio,
              abs(o.duration - info.duration) <= max(0.6, info.duration * 0.03) else {
            throw FileChangerError.failed("The compressed video's duration or tracks could not be verified.")
        }
    }

    static func compress(_ url: URL, mode: VideoCompressMode, progress: @escaping ProgressHandler) async throws -> URL {
        let info = try await MediaProbe.video(url)
        let original = fileSize(url)
        let (ext, _) = MediaOutput.videoContainer(url)
        return try await MediaOutput.write(url, suffix: "-compressed", ext: ext) { out in
            switch mode {
            case .preset(let strong):
                try await encode(url, info: info, plan: presetPlan(strong: strong, info: info), to: out, progress: progress)
                guard fileSize(out) < original else { throw FileChangerError.failed("Compressed output would exceed the original or target file size.") }
            case .reduction(let percent):
                let target = try validateReduction(percent, original: original)
                try await fit(url, info: info, target: target, accurate: true, to: out, progress: progress)
            case .targetSize(let bytes, let accurate):
                let target = try validateTarget(bytes, original: original)
                try await fit(url, info: info, target: target, accurate: accurate, to: out, progress: progress)
            }
            try await verify(out, info: info)
        }
    }

    /// Fast = one encode; accurate = re-encode at a corrected bitrate (up to three more times) until it fits.
    private static func fit(_ url: URL, info: MediaInfo, target: Int64, accurate: Bool, to out: URL,
                            progress: @escaping ProgressHandler) async throws {
        var plan = try targetPlan(bytes: target, info: info)
        let attempts = accurate ? 4 : 1
        var size: Int64 = 0, previous = Int64.max
        for attempt in 0..<attempts {
            try? FileManager.default.removeItem(at: out)
            try await encode(url, info: info, plan: plan, to: out) { progress((Double(attempt) + $0) / Double(attempts)) }
            size = fileSize(out);
            if size <= target { return }
            let ratio = Double(target) / Double(max(size, 1))
            plan.videoBitrate = max(8_000, Int(Double(plan.videoBitrate) * ratio * 0.93))
            plan.height = height(bitrate: Double(plan.videoBitrate), info: info, bitsPerPixel: 0.03)
            // The encoder has a quality floor: when a lower bitrate stopped helping, shrink the picture too.
            if Double(size) > Double(previous) * 0.98 { plan.height = max(96, (plan.height * 0.8).rounded()) }
            previous = size
        }
        throw FileChangerError.failed(accurate
            ? "The encoder could not fit this video within the target. Choose a larger size."
            : "The encoder produced \(sizeText(size)), above the target. Try a larger target or Accurate mode")
    }
}
