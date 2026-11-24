import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import ImageIO

// Audio Visualizer (AUD-50, AUD-51): audio -> H.264 + AAC mp4, either a live waveform in #FF5200 or a still image.

enum VisualizerStyle: String, Sendable, CaseIterable { case waveform, staticImage }

enum VisualizerShape: String, Sendable, CaseIterable {
    case automatic, square, landscape, portrait
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .square: return "Square"
        case .landscape: return "Landscape 16:9"
        case .portrait: return "Portrait 9:16"
        }
    }
}

enum AudioVisualizerEngine {
    static let lime = CGColor(srgbRed: 162 / 255, green: 201 / 255, blue: 35 / 255, alpha: 1)   // Brand.accent

    /// Even pixel size for a shape. Automatic follows the image when there is one, otherwise 1920x1080.
    static func canvas(_ shape: VisualizerShape, image: CGSize?) -> CGSize {
        switch shape {
        case .square: return CGSize(width: 1080, height: 1080)
        case .landscape: return CGSize(width: 1920, height: 1080)
        case .portrait: return CGSize(width: 1080, height: 1920)
        case .automatic:
            guard let image, image.width > 0, image.height > 0 else { return CGSize(width: 1920, height: 1080) }
            let s = min(1, 1920 / max(image.width, image.height))
            return CGSize(width: VideoGeometry.even(image.width * s), height: VideoGeometry.even(image.height * s))
        }
    }

    static func loadImage(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw FileChangerError.failed("Could not read the image.")
        }
        return img
    }

    /// Mono 8 kHz samples for drawing; memory is ~115 MB per hour of audio.
    static func envelopeSamples(_ asset: AVAsset, track: AVAssetTrack) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        guard reader.startReading() else { throw FileChangerError.failed("This file has no playable audio.") }
        var samples: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(block) / 4
            var chunk = [Float](repeating: 0, count: n)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: &chunk)
            samples.append(contentsOf: chunk)
        }
        return samples
    }

    /// The still behind everything: black canvas with the image fitted (static) or filled and dimmed (waveform backdrop).
    static func background(size: CGSize, image: CGImage?, fill: Bool) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: fill ? 0.06 : 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        if let image {
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let s = fill ? max(size.width / iw, size.height / ih) : min(size.width / iw, size.height / ih)
            let r = CGRect(x: (size.width - iw * s) / 2, y: (size.height - ih * s) / 2, width: iw * s, height: ih * s)
            ctx.draw(image, in: r)
            if fill { ctx.setFillColor(CGColor(gray: 0, alpha: 0.55)); ctx.fill(CGRect(origin: .zero, size: size)) }
        }
        return ctx.makeImage()
    }

    static func drawWaveform(_ ctx: CGContext, size: CGSize, samples: [Float], center: Double, window: Double = 0.12) {
        let columns = max(8, Int(size.width / 8))
        let lo = Int((center - window / 2) * 8000), span = max(1, Int(window * 8000))
        let cy = size.height / 2, maxHalf = size.height * 0.4
        ctx.setStrokeColor(lime)
        ctx.setLineWidth(max(2, size.width / 400))
        ctx.setLineCap(.round)
        for c in 0..<columns {
            let a = lo + c * span / columns, b = max(a + 1, lo + (c + 1) * span / columns)
            var peak: Float = 0
            if b > 0, a < samples.count { for i in max(0, a)..<min(samples.count, b) { peak = max(peak, abs(samples[i])) } }
            let h = CGFloat(max(0.004, min(1, peak.squareRoot()))) * maxHalf     // sqrt scale
            let x = (CGFloat(c) + 0.5) * size.width / CGFloat(columns)
            ctx.move(to: CGPoint(x: x, y: cy - h)); ctx.addLine(to: CGPoint(x: x, y: cy + h))
        }
        ctx.strokePath()
    }

    static func create(_ url: URL, style: VisualizerStyle, imageURL: URL?, shape: VisualizerShape,
                       canvasOverride: CGSize? = nil, progress: @escaping ProgressHandler) async throws -> URL {
        let info = try await MediaProbe.audio(url)
        var image: CGImage?
        if style == .staticImage {
            guard let imageURL else { throw FileChangerError.failed("Choose an image for the visualization.") }
            image = try loadImage(imageURL)
        } else if let imageURL {
            image = try loadImage(imageURL)
        }
        let size = canvasOverride ?? canvas(shape, image: image.map { CGSize(width: $0.width, height: $0.height) })
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw FileChangerError.failed("This file has no audio track.") }
        let samples = style == .waveform ? try envelopeSamples(asset, track: track) : []
        let backdrop = background(size: size, image: image, fill: style == .waveform)
        let fps: Int32 = style == .waveform ? 30 : 2
        let frames = max(1, Int((info.duration * Double(fps)).rounded(.up)))

        return try await MediaOutput.write(url, suffix: "-visualization", ext: "mp4") { out in
            let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(size.width * size.height * 2),
                                                  AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]])
            vIn.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
            writer.add(vIn)
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
            aIn.expectsMediaDataInRealTime = false
            writer.add(aIn)
            writer.shouldOptimizeForNetworkUse = true

            let reader = try AVAssetReader(asset: asset)
            let aOut = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            reader.add(aOut)
            guard reader.startReading(), writer.startWriting() else {
                throw FileChangerError.failed(writer.error?.localizedDescription ?? "The operation couldn't be completed.")
            }
            writer.startSession(atSourceTime: .zero)

            var index = 0
            var fixed: CVPixelBuffer?
            let draw: (CVPixelBuffer, Double) -> Void = { pb, t in
                CVPixelBufferLockBaseAddress(pb, [])
                defer { CVPixelBufferUnlockBaseAddress(pb, []) }
                guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height),
                                          bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
                if let backdrop { ctx.draw(backdrop, in: CGRect(origin: .zero, size: size)) }
                if style == .waveform { drawWaveform(ctx, size: size, samples: samples, center: t) }
            }
            let feeds = [
                MediaPump.Feed(input: vIn, step: {
                    guard index < frames, let pool = adaptor.pixelBufferPool else { return false }
                    var pb: CVPixelBuffer?
                    if style == .staticImage, let f = fixed { pb = f } else {
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                        if let pb { draw(pb, Double(index) / Double(fps)); if style == .staticImage { fixed = pb } }
                    }
                    guard let pb else { return false }
                    let ok = adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps))
                    index += 1
                    progress(Double(index) / Double(frames))
                    return ok
                }),
                MediaPump.Feed(input: aIn, step: {
                    guard let sb = aOut.copyNextSampleBuffer() else { return false }
                    return aIn.append(sb)
                }),
            ]
            if await MediaPump.run(feeds) || Task.isCancelled {
                reader.cancelReading(); writer.cancelWriting()
                throw CancellationError()
            }
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw FileChangerError.failed(writer.error?.localizedDescription ?? "The operation couldn't be completed.")
            }
        }
    }
}
