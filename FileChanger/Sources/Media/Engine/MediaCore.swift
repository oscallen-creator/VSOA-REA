import AVFoundation
import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Shared pieces of the media tools (MED-*): time formatting, range validation, probing, export plumbing,
// thumbnails and waveform peaks. Editors reuse these; nothing here knows about SwiftUI.

// MARK: - Time

enum MediaTime {
    /// "m:ss.cc" (MED-09), "h:mm:ss.cc" past an hour.
    static func format(_ seconds: Double) -> String {
        let cs = Int(((seconds.isFinite ? max(0, seconds) : 0) * 100).rounded())
        let h = cs / 360_000, m = (cs / 6000) % 60, s = Double(cs % 6000) / 100
        return h > 0 ? String(format: "%d:%02d:%05.2f", h, m, s) : String(format: "%d:%05.2f", m, s)
    }

    /// Accepts "83.2", "1:23.2", "1:02:03.5".
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }

    static func cm(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 6000) }
}

struct MediaSpan: Equatable, Sendable {
    var start: Double
    var end: Double
    var length: Double { end - start }
}

// MARK: - Validation (messages come from the inventory)

enum MediaRange {
    static let minSplitGap = 0.05

    static func validateTrim(start: Double, end: Double, duration: Double) throws {
        guard start.isFinite, end.isFinite, start >= 0, end <= duration + 0.001 else {
            throw FileChangerError.failed("Set a start and end within the file.")
        }
        guard end > start else { throw FileChangerError.failed("Choose a positive time range within the file's duration.") }
    }

    /// Split points must lie inside the video, 0.05 s from either end and from each other.
    static func validateSplits(_ times: [Double], duration: Double) throws {
        let t = times.sorted()
        guard t.allSatisfy({ $0 >= minSplitGap - 1e-9 && $0 <= duration - minSplitGap + 1e-9 }) else {
            throw FileChangerError.failed("Add split points inside the video, at least 0.05 seconds from either end.")
        }
        for (a, b) in zip(t, t.dropFirst()) where b - a < minSplitGap - 1e-9 {
            throw FileChangerError.failed("Split points must be at least 0.05 seconds apart.")
        }
    }

    /// Clips are the segments between split points.
    static func clips(splits: [Double], duration: Double) -> [MediaSpan] {
        let edges = [0.0] + splits.sorted() + [duration]
        return zip(edges, edges.dropFirst()).map { MediaSpan(start: $0, end: $1) }
    }

    static func validateSpeed(_ speed: Double) throws {
        guard speed.isFinite, speed >= 0.25, speed <= 4 else { throw FileChangerError.failed("Choose a speed between 0.25 and 4.") }
    }

    static func validateRanges(_ ranges: [MediaSpan], duration: Double, emptyMessage: String) throws {
        guard !ranges.isEmpty else { throw FileChangerError.failed(emptyMessage) }
        for r in ranges { try validateTrim(start: r.start, end: r.end, duration: duration) }
    }
}

// MARK: - Probe (MED-07)

struct MediaInfo: Sendable {
    var duration: Double
    var hasVideo: Bool
    var hasAudio: Bool
    var displaySize: CGSize = .zero      // honours rotation
    var transform: CGAffineTransform = .identity
    var naturalSize: CGSize = .zero
    var fps: Double = 30
    var videoBitrate: Double = 0
    var audioBitrate: Double = 0
    var audioChannels: Int = 0
    var sampleRate: Double = 44100
    var isHEVC = false
    var isHDR = false
}

enum MediaProbe {
    static func info(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do { duration = try await asset.load(.duration) } catch {
            throw FileChangerError.failed("Could not read the duration of \(url.lastPathComponent).")
        }
        guard duration.isNumeric, duration.seconds > 0 else { throw FileChangerError.failed("This file has no playable duration.") }
        var info = MediaInfo(duration: duration.seconds, hasVideo: false, hasAudio: false)
        if let v = try? await asset.loadTracks(withMediaType: .video).first {
            info.hasVideo = true
            let (size, t, fps, rate, formats) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate,
                                                                 .estimatedDataRate, .formatDescriptions)
            let r = CGRect(origin: .zero, size: size).applying(t)
            info.naturalSize = size
            info.transform = t
            info.displaySize = CGSize(width: abs(r.width), height: abs(r.height))
            info.fps = fps > 1 ? Double(fps) : 30
            info.videoBitrate = Double(rate)
            if let f = formats.first {
                info.isHEVC = CMFormatDescriptionGetMediaSubType(f) == kCMVideoCodecType_HEVC
                if let tf = CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
                    info.isHDR = tf.contains("2084") || tf.contains("HLG") || tf.contains("2100")
                }
            }
        }
        if let a = try? await asset.loadTracks(withMediaType: .audio).first {
            info.hasAudio = true
            let (rate, formats) = try await a.load(.estimatedDataRate, .formatDescriptions)
            info.audioBitrate = Double(rate)
            if let f = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                info.audioChannels = Int(asbd.mChannelsPerFrame)
                if asbd.mSampleRate > 0 { info.sampleRate = asbd.mSampleRate }
            }
        }
        return info
    }

    static func video(_ url: URL) async throws -> MediaInfo {
        let i = try await info(url)
        guard i.hasVideo else { throw FileChangerError.failed("This file has no playable video track.") }
        return i
    }

    static func audio(_ url: URL) async throws -> MediaInfo {
        let i = try await info(url)
        guard i.hasAudio else { throw FileChangerError.failed("This file has no playable audio.") }
        return i
    }
}

// MARK: - Output + export plumbing

enum MediaOutput {
    /// Video containers AVFoundation writes; anything else is written as mp4.
    static func videoContainer(_ url: URL) -> (ext: String, type: AVFileType) {
        switch url.pathExtension.lowercased() {
        case "mov": return ("mov", .mov)
        case "m4v": return ("m4v", .m4v)
        default: return ("mp4", .mp4)
        }
    }

    @discardableResult
    static func write(_ source: URL, suffix: String, ext: String, _ body: (URL) async throws -> Void) async throws -> URL {
        let dest = OutputLocation.sibling(of: source, suffix: suffix, ext: ext)
        try await OutputLocation.writeAtomically(to: dest, body)
        return dest
    }

    /// Fresh unique folder beside `source`, e.g. "clip Clips".
    static func folder(beside source: URL, suffix: String) throws -> URL {
        let base = source.deletingPathExtension().lastPathComponent + suffix
        let dir = OutputLocation.unique(source.deletingLastPathComponent().appendingPathComponent(base, isDirectory: true))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Stops a pump/loop from another thread when the Swift task is cancelled.
final class MediaCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

enum MediaExport {
    static func run(asset: AVAsset, preset: String, type: AVFileType, to url: URL, timeRange: CMTimeRange? = nil,
                    videoComposition: AVVideoComposition? = nil, pitch: AVAudioTimePitchAlgorithm? = nil, metadataFrom: URL? = nil,
                    progress: @escaping ProgressHandler) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw FileChangerError.failed("This file can't be exported.")
        }
        session.outputURL = url
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        if let timeRange { session.timeRange = timeRange }
        if let videoComposition { session.videoComposition = videoComposition }
        if let pitch { session.audioTimePitchAlgorithm = pitch }
        // VID-90: carry the source's metadata into compositions (AVFoundation cannot write chapter tracks from one).
        if let src = metadataFrom, let items = try? await AVURLAsset(url: src).load(.metadata), !items.isEmpty { session.metadata = items }
        let poll = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in session.exportAsynchronously { c.resume() } }
        } onCancel: { session.cancelExport() }
        poll.cancel()
        switch session.status {
        case .completed: progress(1)
        case .cancelled: throw CancellationError()
        default: throw FileChangerError.failed(session.error?.localizedDescription ?? "The operation couldn't be completed.")
        }
    }

    /// Lossless copy when the asset allows it (trim, split, mute), otherwise re-encode at the highest quality.
    static func preferPassthrough(asset: AVAsset, type: AVFileType, to url: URL, timeRange: CMTimeRange? = nil,
                                  videoComposition: AVVideoComposition? = nil, metadataFrom: URL? = nil,
                                  progress: @escaping ProgressHandler) async throws {
        if videoComposition == nil, AVAssetExportSession.exportPresets(compatibleWith: asset).contains(AVAssetExportPresetPassthrough) {
            do {
                try await run(asset: asset, preset: AVAssetExportPresetPassthrough, type: type, to: url, timeRange: timeRange, metadataFrom: metadataFrom, progress: progress)
                return
            } catch is CancellationError { throw CancellationError() } catch { try? FileManager.default.removeItem(at: url) }
        }
        try await run(asset: asset, preset: AVAssetExportPresetHighestQuality, type: type, to: url, timeRange: timeRange,
                      videoComposition: videoComposition, metadataFrom: metadataFrom, progress: progress)
    }
}

/// Appends sample/frame producers to writer inputs on one serial queue until each runs dry.
enum MediaPump {
    struct Feed {
        let input: AVAssetWriterInput
        /// Appends one item when the input is ready; false when there is nothing left.
        let step: () -> Bool
    }

    /// Returns true when it stopped because the task was cancelled.
    @discardableResult
    static func run(_ feeds: [Feed]) async -> Bool {
        let cancel = MediaCancelFlag()
        let queue = DispatchQueue(label: "filechanger.media.pump")
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let group = DispatchGroup()
                for feed in feeds {
                    group.enter()
                    var finished = false
                    feed.input.requestMediaDataWhenReady(on: queue) {
                        if finished { return }
                        while feed.input.isReadyForMoreMediaData {
                            if cancel.isSet || !feed.step() {
                                feed.input.markAsFinished()
                                finished = true
                                group.leave()
                                return
                            }
                        }
                    }
                }
                if feeds.isEmpty { cont.resume() } else { group.notify(queue: queue) { cont.resume() } }
            }
        } onCancel: { cancel.set() }
        return cancel.isSet
    }
}

// MARK: - Video geometry

enum VideoGeometry {
    static func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded(.down) * 2) }

    /// One-instruction composition drawing `track` through `transform` (display space, top-left origin).
    static func composition(track: AVAssetTrack, duration: CMTime, transform: CGAffineTransform,
                            renderSize: CGSize, fps: Double) -> AVMutableVideoComposition {
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let vc = AVMutableVideoComposition()
        vc.renderSize = CGSize(width: even(renderSize.width), height: even(renderSize.height))
        vc.frameDuration = CMTime(seconds: 1 / max(1, min(120, fps)), preferredTimescale: 90000)
        vc.instructions = [instruction]
        return vc
    }

    /// Fit `size` into `target` keeping aspect, centred (letterbox), after applying `base` (the track's preferredTransform).
    static func fit(base: CGAffineTransform, size: CGSize, into target: CGSize) -> CGAffineTransform {
        let s = min(target.width / size.width, target.height / size.height)
        let w = size.width * s, h = size.height * s
        return base.concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: (target.width - w) / 2, y: (target.height - h) / 2))
    }
}

// MARK: - Thumbnails + frames (VID-07)

enum MediaThumbnails {
    /// `count` evenly spaced frames across the duration; nil where one could not be decoded.
    static func strip(url: URL, duration: Double, count: Int, height: CGFloat = 64) async -> [CGImage?] {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: height * 4, height: height * 2)
        gen.requestedTimeToleranceBefore = CMTime(seconds: duration / Double(max(count, 1)), preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = gen.requestedTimeToleranceBefore
        var out: [CGImage?] = []
        for i in 0..<max(count, 1) {
            let t = duration * (Double(i) + 0.5) / Double(max(count, 1))
            out.append(try? await gen.image(at: MediaTime.cm(t)).image)
        }
        return out
    }

    /// Exact frame (zero tolerance), as used by snapshots, crop and redact previews.
    static func frame(url: URL, at seconds: Double, maxSize: CGSize = .zero, exact: Bool = true) async throws -> CGImage {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        if exact { gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero }
        if maxSize != .zero { gen.maximumSize = maxSize }
        do { return try await gen.image(at: MediaTime.cm(seconds)).image } catch {
            throw FileChangerError.failed("No frame is available at this time. Choose an earlier frame.")
        }
    }
}
