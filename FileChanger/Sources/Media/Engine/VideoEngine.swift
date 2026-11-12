import AVFoundation
import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Video tools that cut, join and retime with AVFoundation compositions (VID-01...50).
// Crop, redact and compress re-encode through VideoTranscoder (VideoTranscoder.swift).

enum MediaComposition {
    /// Back-to-back copy of `spans` of `url`. Audio/video tracks are optional so mute can drop audio.
    static func build(_ url: URL, spans: [MediaSpan], video: Bool = true, audio: Bool = true) async throws -> AVMutableComposition {
        let asset = AVURLAsset(url: url)
        let comp = AVMutableComposition()
        let vt = try? await asset.loadTracks(withMediaType: .video).first
        let at = try? await asset.loadTracks(withMediaType: .audio).first
        guard vt != nil else { throw FileChangerError.failed("This file has no playable video track.") }
        let cv = video ? comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let ca = audio && at != nil ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        var cursor = CMTime.zero
        for s in spans {
            let range = CMTimeRange(start: MediaTime.cm(s.start), duration: MediaTime.cm(s.length))
            if let vt, let cv { try cv.insertTimeRange(range, of: vt, at: cursor) }
            if let at, let ca { try ca.insertTimeRange(range, of: at, at: cursor) }
            cursor = cursor + range.duration
        }
        if let vt, let cv { cv.preferredTransform = try await vt.load(.preferredTransform) }
        return comp
    }
}

// MARK: - Trim (VID-01)

enum VideoTrimEngine {
    static func trim(_ url: URL, start: Double, end: Double, progress: @escaping ProgressHandler) async throws -> URL {
        let info = try await MediaProbe.video(url)
        try MediaRange.validateTrim(start: start, end: end, duration: info.duration)
        let (ext, type) = MediaOutput.videoContainer(url)
        let range = CMTimeRange(start: MediaTime.cm(start), end: MediaTime.cm(end))
        return try await MediaOutput.write(url, suffix: "-edited", ext: ext) { out in
            try await MediaExport.preferPassthrough(asset: AVURLAsset(url: url), type: type, to: out, timeRange: range, progress: progress)
        }
    }
}

// MARK: - Split (VID-10...13)

enum VideoSplitEngine {
    enum Mode: String, Sendable { case clips, merged }

    /// `removed` holds indexes into `MediaRange.clips(splits:duration:)`.
    static func kept(splits: [Double], removed: Set<Int>, duration: Double) throws -> [MediaSpan] {
        try MediaRange.validateSplits(splits, duration: duration)
        let all = MediaRange.clips(splits: splits, duration: duration)
        let kept = all.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        guard !kept.isEmpty else { throw FileChangerError.failed("Keep at least one clip.") }
        return kept
    }

    /// `clips` mode writes "Clip 001.<ext>"... into a new folder beside the video and returns the folder;
    /// `merged` joins the kept clips into one "-edited" video and returns it.
    static func split(_ url: URL, splits: [Double], removed: Set<Int> = [], mode: Mode,
                      progress: @escaping ProgressHandler) async throws -> URL {
        let info = try await MediaProbe.video(url)
        let spans = try kept(splits: splits, removed: removed, duration: info.duration)
        let (ext, type) = MediaOutput.videoContainer(url)
        switch mode {
        case .merged:
            let comp = try await MediaComposition.build(url, spans: spans)
            return try await MediaOutput.write(url, suffix: "-edited", ext: ext) { out in
                try await MediaExport.preferPassthrough(asset: comp, type: type, to: out, metadataFrom: url, progress: progress)
            }
        case .clips:
            let dir = try MediaOutput.folder(beside: url, suffix: " Clips")
            do {
                for (i, s) in spans.enumerated() {
                    let dest = dir.appendingPathComponent(String(format: "Clip %03d", i + 1)).appendingPathExtension(ext)
                    let range = CMTimeRange(start: MediaTime.cm(s.start), duration: MediaTime.cm(s.length))
                    try await OutputLocation.writeAtomically(to: dest) { out in
                        try await MediaExport.preferPassthrough(asset: AVURLAsset(url: url), type: type, to: out, timeRange: range) {
                            progress((Double(i) + $0) / Double(spans.count))
                        }
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: dir)
                throw error
            }
            return dir
        }
    }
}

// MARK: - Join (VID-20)

enum VideoJoinEngine {
    /// Finder-style name order.
    static func sortedByName(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Clips are scaled to fit the first clip's size (letterboxed), 30 fps; clips without audio stay silent.
    static func join(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> URL {
        guard urls.count >= 2 else { throw FileChangerError.failed("Select at least two videos to join.") }
        var infos: [MediaInfo] = []
        for u in urls {
            guard let i = try? await MediaProbe.info(u), i.hasVideo else { throw FileChangerError.failed("Every selected file must contain a video track.") }
            infos.append(i)
        }
        let size = CGSize(width: VideoGeometry.even(infos[0].displaySize.width), height: VideoGeometry.even(infos[0].displaySize.height))
        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw FileChangerError.failed("Every selected file must contain a video track.")
        }
        var ca: AVMutableCompositionTrack?   // created on the first clip that has audio: an empty track fails the export
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero
        for (u, info) in zip(urls, infos) {
            let asset = AVURLAsset(url: u)
            guard let vt = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = CMTimeRange(start: .zero, duration: MediaTime.cm(info.duration))
            try cv.insertTimeRange(range, of: vt, at: cursor)
            if info.hasAudio, let at = try await asset.loadTracks(withMediaType: .audio).first {
                if ca == nil { ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                try ca?.insertTimeRange(range, of: at, at: cursor)
            }
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: cv)
            layer.setTransform(VideoGeometry.fit(base: info.transform, size: info.displaySize, into: size), at: cursor)
            let ins = AVMutableVideoCompositionInstruction()
            ins.timeRange = CMTimeRange(start: cursor, duration: range.duration)
            ins.layerInstructions = [layer]
            instructions.append(ins)
            cursor = cursor + range.duration
        }
        let vc = AVMutableVideoComposition()
        vc.renderSize = size
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        vc.instructions = instructions
        let (ext, type) = MediaOutput.videoContainer(urls[0])
        return try await MediaOutput.write(urls[0], suffix: "-joined", ext: ext) { out in
            try await MediaExport.run(asset: comp, preset: AVAssetExportPresetHighestQuality, type: type, to: out,
                                      videoComposition: vc, metadataFrom: urls[0], progress: progress)
        }
    }
}

// MARK: - Mute (VID-30) and speed (VID-40)

enum VideoMuteEngine {
    static func mute(_ url: URL, progress: @escaping ProgressHandler) async throws -> URL {
        let info = try await MediaProbe.video(url)
        let comp = try await MediaComposition.build(url, spans: [MediaSpan(start: 0, end: info.duration)], audio: false)
        let (ext, type) = MediaOutput.videoContainer(url)
        return try await MediaOutput.write(url, suffix: "-edited", ext: ext) { out in
            try await MediaExport.preferPassthrough(asset: comp, type: type, to: out, metadataFrom: url, progress: progress)
        }
    }
}

enum VideoSpeedEngine {
    static func changeSpeed(_ url: URL, speed: Double, progress: @escaping ProgressHandler) async throws -> URL {
        try MediaRange.validateSpeed(speed)
        let info = try await MediaProbe.video(url)
        let comp = try await MediaComposition.build(url, spans: [MediaSpan(start: 0, end: info.duration)])
        comp.scaleTimeRange(CMTimeRange(start: .zero, duration: comp.duration), toDuration: MediaTime.cm(info.duration / speed))
        let (ext, type) = MediaOutput.videoContainer(url)
        return try await MediaOutput.write(url, suffix: "-edited", ext: ext) { out in
            try await MediaExport.run(asset: comp, preset: AVAssetExportPresetHighestQuality, type: type, to: out,
                                      pitch: .spectral, metadataFrom: url, progress: progress)   // pitch-preserving audio
        }
    }
}

// MARK: - Snapshots (VID-50)

enum VideoSnapshotEngine {
    static func fileName(index: Int, time: Double) -> String { String(format: "Frame %03d - %.3fs.png", index, time) }

    /// Writes one PNG per time into a new "<name> Snapshots" folder beside the video; returns the folder.
    static func snapshots(_ url: URL, times: [Double], progress: @escaping ProgressHandler) async throws -> URL {
        guard !times.isEmpty else { throw FileChangerError.failed("Add a frame to save.") }
        let info = try await MediaProbe.video(url)
        guard times.allSatisfy({ $0 >= 0 && $0 < info.duration }) else {
            throw FileChangerError.failed("Select at least one frame within the video.")
        }
        let dir = try MediaOutput.folder(beside: url, suffix: " Snapshots")
        do {
            for (i, t) in times.enumerated() {
                try Task.checkCancellation()
                let image = try await MediaThumbnails.frame(url: url, at: t)
                let dest = dir.appendingPathComponent(fileName(index: i + 1, time: t))
                guard let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw FileChangerError.failed("Could not save the frame.")
                }
                CGImageDestinationAddImage(d, image, nil)
                guard CGImageDestinationFinalize(d) else { throw FileChangerError.failed("Could not save the frame.") }
                progress(Double(i + 1) / Double(times.count))
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return dir
    }
}

// MARK: - Crop (VID-60)

enum VideoCropEngine {
    /// `rect` is in displayed pixels, origin top-left. Returns the even-sized rect that will be exported.
    static func validate(_ rect: CGRect, frame: CGSize) throws -> CGRect {
        guard rect.width >= 2, rect.height >= 2 else { throw FileChangerError.failed("The crop must be at least 2 x 2 pixels.") }
        guard rect.minX >= -0.5, rect.minY >= -0.5, rect.maxX <= frame.width + 0.5, rect.maxY <= frame.height + 0.5 else {
            throw FileChangerError.failed("Keep the crop inside the video frame.")
        }
        let x = max(0, rect.minX.rounded()), y = max(0, rect.minY.rounded())
        let w = VideoGeometry.even(min(rect.width, frame.width - x)), h = VideoGeometry.even(min(rect.height, frame.height - y))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func crop(_ url: URL, rect: CGRect, maxHeight: CGFloat? = nil, progress: @escaping ProgressHandler) async throws -> URL {
        let info = try await MediaProbe.video(url)
        let r = try validate(rect, frame: info.displaySize)
        guard info.videoBitrate > 0 else { throw FileChangerError.failed("Could not read the video bitrate for cropping.") }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw FileChangerError.failed("This file has no playable video track.") }
        // Optional height cap (VID-61): keep aspect, never upscale.
        let scale = min(1, (maxHeight ?? .infinity) / r.height)
        let outSize = CGSize(width: r.width * scale, height: r.height * scale)
        let t = info.transform.concatenating(CGAffineTransform(translationX: -r.minX, y: -r.minY)).concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let vc = VideoGeometry.composition(track: track, duration: MediaTime.cm(info.duration), transform: t, renderSize: outSize, fps: info.fps)
        let (ext, type) = MediaOutput.videoContainer(url)
        let bitrate = Int(max(300_000, info.videoBitrate * Double(vc.renderSize.width * vc.renderSize.height) / Double(info.displaySize.width * info.displaySize.height)))
        return try await MediaOutput.write(url, suffix: "-edited", ext: ext) { out in
            try await VideoTranscoder.run(VideoTranscodeJob(asset: asset, videoComposition: vc, codec: info.isHEVC ? .hevc : .h264,
                                                            videoBitrate: bitrate, info: info, type: type), to: out, progress: progress)
        }
    }
}

// MARK: - Redact (VID-80...82)

struct VideoRedaction: Sendable, Equatable {
    var rect: CGRect        // displayed pixels, origin top-left
    var start: Double
    var end: Double
}

enum VideoRedactionStyle: String, Sendable, CaseIterable { case solid, blur }

enum VideoRedactEngine {
    static func validate(_ items: [VideoRedaction], frame: CGSize, duration: Double) throws {
        guard !items.isEmpty else { throw FileChangerError.failed("Draw a rectangle over the area to hide.") }
        for r in items {
            guard r.rect.width >= 1, r.rect.height >= 1, r.rect.minX >= -0.5, r.rect.minY >= -0.5,
                  r.rect.maxX <= frame.width + 0.5, r.rect.maxY <= frame.height + 0.5 else {
                throw FileChangerError.failed("Keep each rectangle inside the preview.")
            }
            try MediaRange.validateTrim(start: r.start, end: r.end, duration: duration)
        }
    }

    /// Applies the redactions to one frame at time `t` (CoreImage space: origin bottom-left).
    static func apply(_ items: [VideoRedaction], style: VideoRedactionStyle, to image: CIImage, at t: Double) -> CIImage {
        let height = image.extent.height
        var out = image
        for r in items where t >= r.start && t < r.end {
            let box = CGRect(x: image.extent.minX + r.rect.minX, y: image.extent.minY + height - r.rect.maxY,
                             width: r.rect.width, height: r.rect.height)
            switch style {
            case .solid:
                out = CIImage(color: .black).cropped(to: box).composited(over: out)
            case .blur:
                let sigma = max(10, min(box.width, box.height) * 0.15)
                out = out.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: box).composited(over: out)
            }
        }
        return out
    }

    static func redact(_ url: URL, items: [VideoRedaction], style: VideoRedactionStyle, progress: @escaping ProgressHandler) async throws -> URL {
        let info = try await MediaProbe.video(url)
        try validate(items, frame: info.displaySize, duration: info.duration)
        let asset = AVURLAsset(url: url)
        let vc = AVMutableVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
            let t = request.compositionTime.seconds
            request.finish(with: apply(items, style: style, to: request.sourceImage, at: t), context: nil)
        })
        let (ext, type) = MediaOutput.videoContainer(url)
        let bitrate = Int(max(500_000, info.videoBitrate))
        return try await MediaOutput.write(url, suffix: "-redacted", ext: ext) { out in
            try await VideoTranscoder.run(VideoTranscodeJob(asset: asset, videoComposition: vc, codec: info.isHEVC ? .hevc : .h264,
                                                            videoBitrate: bitrate, info: info, type: type), to: out, progress: progress)
        }
    }
}
