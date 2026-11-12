import Foundation
import AVFoundation
import ImageIO
import CoreGraphics
import CoreVideo

/// Audio/video/GIF conversions (CNV-20..22, CNV-50..68). AVFoundation first, ffmpeg for the rest.
enum ConversionMediaEngine {
    typealias F = ConversionFormat

    static func convert(_ file: URL, from s: F, to t: F, progress: ProgressHandler) async throws -> URL {
        let dest = Conversions.outputURL(for: file, ext: t.ext)
        let native = Conversions.route(from: s, to: t) == .native
        try await OutputLocation.writeAtomically(to: dest) { temp in
            if !native { try await ffmpegConvert(file, from: s, to: t, out: temp, progress: progress) }
            else if s.group == .audio { try convertAudio(file, to: t, out: temp, progress: progress) }
            else if s == .gif { try await gifToVideo(file, to: t, out: temp, progress: progress) }
            else if t == .gif { try await videoToGIF(file, out: temp, progress: progress) }
            else { try await exportVideo(file, to: t, out: temp, progress: progress) }
        }
        return dest
    }

    // MARK: Native audio (AVAudioFile -> AVAudioFile)

    static func audioSettings(for t: F, source: AVAudioFormat, sourceDepth: Int) throws -> [String: Any] {
        let rate = source.sampleRate, ch = Int(source.channelCount)
        let choice = ConversionProfile.string(t, .audioSampleDepth)
        func depth() throws -> (bits: Int, float: Bool) {
            switch choice {
            case "bit16": return (16, false)
            case "bit24": return (24, false)
            case "bit32": return (32, false)
            case "float32": return (32, true)
            default:
                if sourceDepth > 32 { throw FileChangerError.failed("This source uses more than 32-bit integer audio. Choose an output bit depth in settings.") }
                return (max(16, sourceDepth), false)
            }
        }
        switch t {
        case .m4a:
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: min(ch, 2),
                    AVEncoderBitRateKey: (ch == 1 ? min(ConversionProfile.int(t, .audioBitrate), 160) : ConversionProfile.int(t, .audioBitrate)) * 1000]
        case .wav:
            let d = try depth()
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: ch,
                    AVLinearPCMBitDepthKey: d.bits, AVLinearPCMIsFloatKey: d.float, AVLinearPCMIsBigEndianKey: false]
        case .aiff:
            var d = try depth(); if d.float { d = (32, false) }   // AIFF stores integers
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: ch,
                    AVLinearPCMBitDepthKey: d.bits, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true]
        case .flac:
            var d = try depth(); if d.bits == 32 { d = (24, false) }
            return [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: ch, AVLinearPCMBitDepthKey: d.bits]
        default: throw FileChangerError.unsupported("Converting to \(t.label) is not available.")
        }
    }

    static func convertAudio(_ file: URL, to t: F, out: URL, progress: ProgressHandler) throws {
        let src: AVAudioFile
        do { src = try AVAudioFile(forReading: file) } catch { throw FileChangerError.failed("The source file could not be read.") }
        let depth = (src.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int) ?? 16
        let settings = try audioSettings(for: t, source: src.processingFormat, sourceDepth: depth)
        let total = max(1, src.length)
        try autoreleasepool {
            let dst = try AVAudioFile(forWriting: out, settings: settings)
            guard let buf = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: 16384) else { throw FileChangerError.failed("The conversion process failed.") }
            while src.framePosition < src.length {
                if Task.isCancelled { throw FileChangerError.cancelled }
                try src.read(into: buf)
                if buf.frameLength == 0 { break }
                try dst.write(from: buf)
                progress(Double(src.framePosition) / Double(total))
            }
        }
    }

    // MARK: Native video (AVAssetExportSession)

    static func exportVideo(_ file: URL, to t: F, out: URL, progress: ProgressHandler) async throws {
        let asset = AVURLAsset(url: file)
        guard try await asset.load(.isReadable) else { throw FileChangerError.failed("The source file could not be read.") }
        let h = ConversionProfile.int(t, .videoMaxHeight)
        let preset: String
        switch h {
        case 2160: preset = ConversionProfile.quality(t) == .high ? AVAssetExportPresetHEVC3840x2160 : AVAssetExportPreset3840x2160
        case 1080: preset = ConversionProfile.quality(t) == .high ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPreset1920x1080
        case 720: preset = AVAssetExportPreset1280x720
        default:
            switch ConversionProfile.quality(t) {
            case .high: preset = AVAssetExportPresetHEVCHighestQuality
            case .balanced: preset = AVAssetExportPresetHighestQuality
            case .compact: preset = AVAssetExportPresetMediumQuality
            }
        }
        let compatible = AVAssetExportSession.exportPresets(compatibleWith: asset)
        guard let session = AVAssetExportSession(asset: asset, presetName: compatible.contains(preset) ? preset : AVAssetExportPresetHighestQuality) else {
            throw FileChangerError.failed("The converter finished without creating an output file.")
        }
        session.outputURL = out
        session.outputFileType = t == .mov ? .mov : .mp4
        session.shouldOptimizeForNetworkUse = t == .mp4
        if !ConversionProfile.bool(t, .preserveMetadata) { session.metadata = [] }
        nonisolated(unsafe) let box = session
        await withoutActuallyEscaping(progress) { esc in
            let poll = Task { while !Task.isCancelled { esc(Double(box.progress)); try? await Task.sleep(nanoseconds: 200_000_000) } }
            await withTaskCancellationHandler {
                await box.export()
            } onCancel: { box.cancelExport() }
            poll.cancel()
            _ = await poll.result   // the closure must not outlive this scope
        }
        if Task.isCancelled { throw FileChangerError.cancelled }
        if session.status != .completed { throw FileChangerError.failed(session.error?.localizedDescription ?? "The conversion process failed.") }
    }

    // MARK: GIF

    static func videoToGIF(_ file: URL, out: URL, progress: ProgressHandler) async throws {
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw FileChangerError.failed("The source file could not be read.") }
        let fps = max(1, ConversionProfile.int(.gif, .gifFrameRate))
        let maxW = ConversionProfile.int(.gif, .gifMaxWidth)
        let count = min(Int(duration * Double(fps)) + 1, 900)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: maxW, height: maxW * 4)   // width-bound; aspect kept
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "com.compuserve.gif" as CFString, count, nil) else {
            throw FileChangerError.failed("The conversion process failed.")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)]] as CFDictionary
        var written = 0
        for i in 0..<count {
            if Task.isCancelled { throw FileChangerError.cancelled }
            let time = CMTime(seconds: min(Double(i) / Double(fps), max(0, duration - 0.01)), preferredTimescale: 600)
            if let cg = try? gen.copyCGImage(at: time, actualTime: nil) { CGImageDestinationAddImage(dest, cg, frameProps); written += 1 }
            progress(Double(i + 1) / Double(count))
        }
        guard written > 0, CGImageDestinationFinalize(dest) else { throw FileChangerError.failed("The converter finished without creating an output file.") }
    }

    static func gifToVideo(_ file: URL, to t: F, out: URL, progress: ProgressHandler) async throws {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw FileChangerError.failed("The source file could not be read.")
        }
        let n = CGImageSourceGetCount(src)
        let first = CGImageSourceCreateImageAtIndex(src, 0, nil)
        guard let f0 = first else { throw FileChangerError.failed("The source file could not be read.") }
        var w = f0.width, h = f0.height
        let cap = ConversionProfile.int(t, .videoMaxHeight)
        if cap > 0 && h > cap { w = w * cap / h; h = cap }
        w = max(2, w / 2 * 2); h = max(2, h / 2 * 2)   // even dimensions (CNV-67)
        let writer = try AVAssetWriter(outputURL: out, fileType: t == .mov ? .mov : .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        guard writer.startWriting() else { throw FileChangerError.failed(writer.error?.localizedDescription ?? "The conversion process failed.") }
        writer.startSession(atSourceTime: .zero)
        var t0 = 0.0
        for i in 0..<n {
            if Task.isCancelled { writer.cancelWriting(); throw FileChangerError.cancelled }
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32ARGB, nil, &pb)
            guard let buf = pb else { continue }
            CVPixelBufferLockBaseAddress(buf, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            adaptor.append(buf, withPresentationTime: CMTime(seconds: t0, preferredTimescale: 600))
            t0 += max(0.02, delay)
            progress(Double(i + 1) / Double(n))
        }
        input.markAsFinished()
        // A last-frame hold gives the final frame its duration.
        writer.endSession(atSourceTime: CMTime(seconds: t0, preferredTimescale: 600))
        await writer.finishWriting()
        if writer.status != .completed { throw FileChangerError.failed(writer.error?.localizedDescription ?? "The conversion process failed.") }
    }

    // MARK: ffmpeg

    /// Argument list for ffmpeg (CNV-50..66); pure so it can be tested without ffmpeg installed.
    static func ffmpegArguments(input: URL, output: URL, from s: F, to t: F) -> [String] {
        var a = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-progress", "pipe:1", "-nostats", "-i", input.path]
        let kbps = "\(ConversionProfile.int(t, .audioBitrate))k"
        func depthCodec(be: Bool) -> String {
            switch ConversionProfile.string(t, .audioSampleDepth) {
            case "bit24": return be ? "pcm_s24be" : "pcm_s24le"
            case "bit32": return be ? "pcm_s32be" : "pcm_s32le"
            case "float32": return be ? "pcm_f32be" : "pcm_f32le"
            default: return be ? "pcm_s16be" : "pcm_s16le"
            }
        }
        switch t {
        case .m4a: a += ["-vn", "-c:a", "aac", "-b:a", kbps]
        case .mp3: a += ["-vn", "-c:a", "libmp3lame", "-b:a", kbps]
        case .wav: a += ["-vn", "-c:a", depthCodec(be: false)]
        case .aiff: a += ["-vn", "-c:a", depthCodec(be: true)]
        case .flac:
            a += ["-vn", "-c:a", "flac", "-compression_level", "8"]
            switch ConversionProfile.string(t, .audioSampleDepth) { case "bit24", "bit32", "float32": a += ["-sample_fmt", "s32"]; default: a += ["-sample_fmt", "s16"] }
        case .opus: a += ["-vn", "-c:a", "opus", "-strict", "experimental", "-b:a", kbps]
        case .ogg: a += ["-vn", "-c:a", "vorbis", "-strict", "experimental", "-ac", "2", "-b:a", kbps]
        case .wma: a += ["-vn", "-c:a", "wmav2", "-b:a", kbps]
        case .gif:
            let fps = ConversionProfile.int(.gif, .gifFrameRate), w = ConversionProfile.int(.gif, .gifMaxWidth)
            a += ["-an", "-vf", "fps=\(fps),scale='min(\(w),iw)':-2:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"]
        case .mp4, .mov, .mkv, .webm, .avi, .wmv:
            let h = ConversionProfile.int(t, .videoMaxHeight)
            var filter = h > 0 ? "scale=-2:'min(\(h),trunc(ih/2)*2)'" : "pad=ceil(iw/2)*2:ceil(ih/2)*2"
            if t == .webm { a += ["-c:v", "libvpx-vp9", "-c:a", "libopus"] }
            else if t == .avi { a += ["-c:v", "mpeg4", "-c:a", "libmp3lame"] }
            else if t == .wmv { a += ["-c:v", "wmv2", "-c:a", "wmav2"] }
            else {
                a += ["-c:v", "h264_videotoolbox", "-c:a", "aac", "-b:a", "192k"]
                if t != .mkv { a += ["-movflags", "+faststart"] }
            }
            switch ConversionProfile.quality(t) {   // VideoToolbox / vp9 quality knobs
            case .compact: a += t == .webm ? ["-crf", "40", "-b:v", "0"] : ["-q:v", "40"]
            case .balanced: a += t == .webm ? ["-crf", "32", "-b:v", "0"] : ["-q:v", "60"]
            case .high: a += t == .webm ? ["-crf", "24", "-b:v", "0"] : ["-q:v", "80"]
            }
            if h > 0 { filter += ",pad=ceil(iw/2)*2:ceil(ih/2)*2" }
            a += ["-vf", filter]
            if !ConversionProfile.bool(t, .preserveMetadata) { a += ["-map_metadata", "-1"] }
        default: break
        }
        a.append(output.path)
        return a
    }

    static func ffmpegConvert(_ file: URL, from s: F, to t: F, out: URL, progress: ProgressHandler) async throws {
        guard let ffmpeg = ExternalTool.ffmpeg.url else { throw FileChangerError.unsupported(ExternalTool.ffmpeg.missingMessage) }
        // Duration from ffmpeg's own banner (no ffprobe).
        let probe = try await ConvProcess.run(ffmpeg, ["-hide_banner", "-i", file.path], check: false)
        var total = 0.0
        if let r = probe.stderrText.range(of: #"Duration: (\d+):(\d+):(\d+\.?\d*)"#, options: .regularExpression) {
            let p = probe.stderrText[r].dropFirst(10).split(separator: ":").compactMap { Double($0) }
            if p.count == 3 { total = p[0] * 3600 + p[1] * 60 + p[2] }
        }
        // ffmpeg needs a known extension to pick the muxer; the temp name keeps ours.
        let args = ffmpegArguments(input: file, output: out, from: s, to: t)
        let duration = total
        try await withoutActuallyEscaping(progress) { esc in
            _ = try await ConvProcess.run(ffmpeg, args) { line in
                if duration > 0, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) { esc(min(1, us / 1_000_000 / duration)) }
            }
        }
    }
}
