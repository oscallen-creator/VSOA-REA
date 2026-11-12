import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// Shared ImageIO / CoreGraphics helpers for every image tool.
enum ImageFiles {
    /// Largest side any tool will produce (IMG-07: "Keep each side at most N pixels").
    static let maxSide = 20000

    // MARK: Loading

    /// Decodes the first frame with its EXIF orientation applied, at full resolution.
    static func load(_ url: URL, maxPixel: Int? = nil) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw FileChangerError.failed("\(url.lastPathComponent) could not be read as an image.")
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel ?? 32000,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw FileChangerError.failed("\(url.lastPathComponent) could not be read as an image.")
        }
        return img
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        return p
    }

    /// Pixel size as displayed (orientation applied) without decoding pixels.
    static func displaySize(_ url: URL) -> CGSize? {
        let p = properties(url)
        guard let w = p[kCGImagePropertyPixelWidth] as? Double, let h = p[kCGImagePropertyPixelHeight] as? Double else { return nil }
        let o = (p[kCGImagePropertyOrientation] as? Int) ?? 1
        return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    static func isAnimated(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(src) > 1
    }

    static func fileSize(_ url: URL) -> Int {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
    }

    // MARK: Drawing

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Colour space to draw in: the image's own when it is plain RGB, else sRGB.
    static func space(for image: CGImage) -> CGColorSpace {
        if let cs = image.colorSpace, cs.model == .rgb { return cs }
        return sRGB
    }

    static func context(_ w: Int, _ h: Int, space: CGColorSpace = sRGB) -> CGContext? {
        let ctx = CGContext(data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.interpolationQuality = .high
        return ctx
    }

    /// Draws with a top-left origin (y grows downward) and returns the bitmap.
    static func render(_ w: Int, _ h: Int, space: CGColorSpace = sRGB, _ body: (CGContext) -> Void) -> CGImage? {
        guard let ctx = context(w, h, space: space) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        body(ctx)
        return ctx.makeImage()
    }

    /// Draws an image into a top-left-origin context without it appearing upside down.
    static func draw(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    // MARK: Encoding

    struct Format {
        let type: UTType
        let ext: String
        var supportsQuality: Bool { type == .jpeg || type == .heic }
        var supportsAlpha: Bool { type != .jpeg && type != .bmp }
    }

    /// Format for a file extension, falling back to PNG when ImageIO cannot write it (WebP, AVIF...).
    static func format(forExtension ext: String) -> Format {
        let wanted: Format
        switch ext.lowercased() {
        case "jpg", "jpeg", "jpe": wanted = Format(type: .jpeg, ext: ext.lowercased())
        case "heic", "heif": wanted = Format(type: .heic, ext: ext.lowercased())
        case "tif", "tiff": wanted = Format(type: .tiff, ext: ext.lowercased())
        case "gif": wanted = Format(type: .gif, ext: "gif")
        case "bmp": wanted = Format(type: .bmp, ext: "bmp")
        default: wanted = Format(type: .png, ext: "png")
        }
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return writable.contains(wanted.type.identifier) ? wanted : Format(type: .png, ext: "png")
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// JPEG/BMP cannot hold alpha; flatten onto white first.
    static func flattened(_ image: CGImage) -> CGImage {
        guard hasAlpha(image) else { return image }
        return render(image.width, image.height, space: space(for: image)) { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), ctx)
        } ?? image
    }

    static func encode(_ image: CGImage, as format: Format, quality: Double = 0.9, properties: [CFString: Any] = [:]) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else {
            throw FileChangerError.failed("Could not create the \(format.ext.uppercased()) encoder.")
        }
        var props = properties
        if format.supportsQuality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        if format.type == .tiff { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] }
        CGImageDestinationAddImage(dest, format.supportsAlpha ? image : flattened(image), props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw FileChangerError.failed("Could not save the \(format.ext.uppercased()) image.")
        }
        return data as Data
    }

    /// Writes `image` to a new file beside `source` (atomic, collision-safe) in `source`'s format.
    static func save(_ image: CGImage, beside source: URL, suffix: String, format forced: Format? = nil,
                     quality: Double = 0.92) async throws -> URL {
        let fmt = forced ?? format(forExtension: source.pathExtension)
        let data = try encode(image, as: fmt, quality: quality)
        let dest = OutputLocation.sibling(of: source, suffix: suffix, ext: fmt.ext)
        try await OutputLocation.writeAtomically(to: dest) { try data.write(to: $0) }
        return dest
    }

    /// SHA-256 of the decoded RGBA pixels (orientation not applied), used to prove a metadata rewrite left pixels alone.
    static func pixelHash(_ url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var hasher = SHA256()
        let n = CGImageSourceGetCount(src)
        guard n > 0 else { return nil }
        for i in 0..<n {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil),
                  let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            guard let d = ctx.data else { return nil }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: d, count: img.width * img.height * 4))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// RGBA colour in 0...1 that the engines share with the SwiftUI layer.
struct ImageRGBA: Hashable, Sendable {
    var r: Double, g: Double, b: Double, a: Double = 1
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    static let white = ImageRGBA(r: 1, g: 1, b: 1)
    static let black = ImageRGBA(r: 0, g: 0, b: 0)
    static let clear = ImageRGBA(r: 0, g: 0, b: 0, a: 0)
    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(hex: UInt32) { self.init(r: Double((hex >> 16) & 255) / 255, g: Double((hex >> 8) & 255) / 255, b: Double(hex & 255) / 255) }
}
