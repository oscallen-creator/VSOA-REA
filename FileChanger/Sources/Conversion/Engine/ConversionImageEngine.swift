import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Image conversions (CNV-10..18, CNV-70..77): ImageIO read/write, NSImage for SVG, cwebp/ffmpeg for webp/avif.
enum ConversionImageEngine {
    typealias F = ConversionFormat

    struct Decoded { let image: CGImage; let properties: [CFString: Any] }

    /// Decodes the first frame, oriented upright. RAW goes through ImageIO's camera decoders.
    static func decode(_ url: URL, format: F) throws -> Decoded {
        if format == .svg { return try decodeSVG(url) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw FileChangerError.failed("The source file could not be read.")
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0, h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max(w, h, 64),
                                     kCGImageSourceShouldCacheImmediately: true]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) ?? CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return Decoded(image: cg, properties: props)
        }
        throw FileChangerError.failed("The source file could not be read.")
    }

    static func decodeSVG(_ url: URL) throws -> Decoded {
        var data = try Data(contentsOf: url)
        if data.starts(with: [0x1f, 0x8b]) {   // svgz
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            p.arguments = ["-dc", url.path]
            let pipe = Pipe(); p.standardOutput = pipe
            try p.run(); data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        }
        guard data.count < 64 * 1024 * 1024, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
              !text.contains("<!ENTITY") else {
            throw FileChangerError.failed("Vector artwork is too large or contains entity declarations.")
        }
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw FileChangerError.failed("Vector artwork has invalid dimensions.")
        }
        // Rasterise so the long side is at least 1024 px, at most 4096.
        let long = max(image.size.width, image.size.height)
        let scale = min(4096 / long, max(1, 1024 / long))
        let pw = max(1, Int((image.size.width * scale).rounded())), ph = max(1, Int((image.size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FileChangerError.failed("Vector artwork could not be rasterized.")
        }
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gc
        image.draw(in: NSRect(x: 0, y: 0, width: pw, height: ph), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { throw FileChangerError.failed("Vector artwork could not be rasterized.") }
        return Decoded(image: cg, properties: [:])
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo { case .none, .noneSkipFirst, .noneSkipLast: return false; default: return true }
    }

    /// Composites over white for formats without transparency.
    static func flattened(_ image: CGImage) -> CGImage {
        guard hasAlpha(image),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    static func utType(_ f: F) -> CFString? {
        switch f {
        case .jpg: return "public.jpeg" as CFString
        case .png: return "public.png" as CFString
        case .heic: return "public.heic" as CFString
        case .tiff: return "public.tiff" as CFString
        case .bmp: return "com.microsoft.bmp" as CFString
        default: return nil
        }
    }

    /// Metadata to carry over: orientation is already applied to the pixels, so it resets to 1.
    static func metadata(from props: [CFString: Any]) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let v = props[key] { out[key] = v }
        }
        if var tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = out[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil; exif[kCGImagePropertyExifPixelYDimension] = nil
            out[kCGImagePropertyExifDictionary] = exif
        }
        out[kCGImagePropertyOrientation] = 1
        return out
    }

    static func encode(_ d: Decoded, as f: F, to dest: URL) throws {
        let preserve = ConversionProfile.bool(f, .preserveMetadata)
        var image = d.image
        if f == .jpg || f == .bmp { image = flattened(image) }
        if f == .pdf { try writePDF(image, dpi: (d.properties[kCGImagePropertyDPIWidth] as? Double) ?? 72, to: dest); return }
        guard let type = utType(f), let out = CGImageDestinationCreateWithURL(dest as CFURL, type, 1, nil) else {
            throw FileChangerError.unsupported("Converting to \(f.label) is not available.")
        }
        var props: [CFString: Any] = preserve ? metadata(from: d.properties) : [:]
        if f == .jpg || f == .heic { props[kCGImageDestinationLossyCompressionQuality] = ConversionProfile.imageQuality(f) }
        CGImageDestinationAddImage(out, image, props as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw FileChangerError.failed("The image could not be verified. No output was saved.") }
    }

    static func writePDF(_ image: CGImage, dpi: Double, to dest: URL) throws {
        let scale = 72 / (dpi > 1 ? dpi : 72)
        var box = CGRect(x: 0, y: 0, width: max(3, min(14400, Double(image.width) * scale)), height: max(3, min(14400, Double(image.height) * scale)))
        guard let ctx = CGContext(dest as CFURL, mediaBox: &box, nil) else { throw FileChangerError.failed("Could not create the PDF.") }
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: box)
        ctx.endPDFPage(); ctx.closePDF()
    }

    // MARK: Entry point

    static func convert(_ file: URL, from s: F, to t: F, progress: ProgressHandler) async throws -> URL {
        let decoded = try decode(file, format: s)
        progress(0.3)
        let dest = Conversions.outputURL(for: file, ext: t.ext)
        try await OutputLocation.writeAtomically(to: dest) { temp in
            switch t {
            case .webp, .avif: try await encodeExternal(decoded, as: t, to: temp)
            default: try encode(decoded, as: t, to: temp)
            }
        }
        return dest
    }

    /// webp via cwebp (preferred, keeps metadata flags) or ffmpeg's libwebp; avif via ffmpeg.
    static func encodeExternal(_ d: Decoded, as t: F, to dest: URL) async throws {
        let scratch = try ConvTemp.make(); defer { try? FileManager.default.removeItem(at: scratch) }
        let png = scratch.appendingPathComponent("in.png")
        try encode(d, as: .png, to: png)
        let q = Int((ConversionProfile.imageQuality(t) * 100).rounded())
        if t == .webp, let cwebp = ExternalTool.cwebp.url {
            var args = ["-quiet", "-mt", "-q", "\(q)"]
            if ConversionProfile.bool(t, .preserveMetadata) { args += ["-metadata", "all"] }
            _ = try await ConvProcess.run(cwebp, args + [png.path, "-o", dest.path])
        } else if let ffmpeg = ExternalTool.ffmpeg.url {
            let common = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", png.path, "-frames:v", "1"]
            let codec = t == .webp ? ["-c:v", "libwebp", "-quality", "\(q)"] : ["-c:v", "libaom-av1", "-still-picture", "1", "-crf", "\(max(10, 63 - q * 53 / 100))"]
            _ = try await ConvProcess.run(ffmpeg, common + codec + [dest.path])
        } else {
            throw FileChangerError.unsupported((t == .webp ? ExternalTool.cwebp : ExternalTool.ffmpeg).missingMessage)
        }
    }
}
