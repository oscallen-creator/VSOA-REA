import Foundation
import CoreGraphics
import ImageIO
import PDFKit

/// IMG-10..14. Compresses images (JPEG/HEIC by quality search, PNG/TIFF losslessly) and PDFs (Quartz filter).
enum ImageCompressionStrength: String, CaseIterable, Sendable {
    case balanced, strong        // UserDefaults `defaultImageCompressionStrength`, default "balanced"
    var label: String { self == .balanced ? "Balanced" : "Smaller File" }
    var quality: Double { self == .balanced ? 0.7 : 0.45 }
    static var saved: ImageCompressionStrength {
        ImageCompressionStrength(rawValue: UserDefaults.standard.string(forKey: "defaultImageCompressionStrength") ?? "") ?? .balanced
    }
}

enum ImageCompressionSize: String, CaseIterable, Sendable {
    case original, large, medium, small   // UserDefaults `defaultImageCompressionSize`, default "original"
    var label: String {
        switch self { case .original: return "Original size"; case .large: return "Up to 2560 px"
        case .medium: return "Up to 1600 px"; case .small: return "Up to 1024 px" }
    }
    var maxEdge: Int? {
        switch self { case .original: return nil; case .large: return 2560; case .medium: return 1600; case .small: return 1024 }
    }
    static var saved: ImageCompressionSize {
        ImageCompressionSize(rawValue: UserDefaults.standard.string(forKey: "defaultImageCompressionSize") ?? "") ?? .original
    }
}

enum ImageCompressionMode: Equatable, Sendable {
    case level(ImageCompressionStrength, ImageCompressionSize)
    case percentage(Int)        // reduction 1...99
    case targetBytes(Int)
}

enum ImageCompressEngine {
    static let minTarget = 1024
    static let maxTarget = 1 << 40

    static func formatted(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Target in bytes for the size-based modes (nil for presets); throws the inventory's validation messages.
    static func target(for mode: ImageCompressionMode, originalBytes: Int) throws -> Int? {
        switch mode {
        case .level: return nil
        case .percentage(let reduction):
            let t = Int(Double(originalBytes) * Double(100 - reduction) / 100)
            guard (1...99).contains(reduction), t >= minTarget else {
                throw FileChangerError.failed("Choose a reduction from 1% to 99% that leaves at least 1 KB per file.")
            }
            return t
        case .targetBytes(let t):
            guard t >= minTarget else { throw FileChangerError.failed("Enter a target size of at least 1 KB.") }
            guard t <= maxTarget else { throw FileChangerError.failed("Enter a target size between 1 KB and 1 TB.") }
            guard t < originalBytes else { throw FileChangerError.failed("Target size cannot exceed the original file size.") }
            return t
        }
    }

    /// Properties worth carrying over (EXIF, GPS, ICC...) minus anything that describes pixel layout.
    private static func carried(_ url: URL) -> [CFString: Any] {
        var p = ImageFiles.properties(url)
        for k in [kCGImagePropertyOrientation, kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                  kCGImagePropertyHasAlpha, kCGImagePropertyIsFloat, kCGImagePropertyIsIndexed, kCGImagePropertyColorModel,
                  kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight, kCGImagePropertyFileSize, kCGImagePropertyProfileName] { p[k] = nil }
        if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil; p[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil; exif[kCGImagePropertyExifPixelYDimension] = nil
            p[kCGImagePropertyExifDictionary] = exif
        }
        return p
    }

    /// Best quality whose output fits `limit` bytes (10-step bisection), or throws with the smallest attempt.
    static func fit(_ image: CGImage, format: ImageFiles.Format, props: [CFString: Any], limit: Int) throws -> Data {
        var lo = 0.02, hi = 1.0
        var best: Data?
        let smallest = try ImageFiles.encode(image, as: format, quality: lo, properties: props)
        if smallest.count > limit {
            throw FileChangerError.failed("Could not reach the target size. Smallest attempt was \(formatted(smallest.count)). Try a larger target.")
        }
        best = smallest
        for _ in 0..<10 {
            let mid = (lo + hi) / 2
            let d = try ImageFiles.encode(image, as: format, quality: mid, properties: props)
            if d.count <= limit { best = d; lo = mid } else { hi = mid }
        }
        return best ?? smallest
    }

    /// Encoded bytes and the format for one image under `mode` (no file written).
    static func produce(_ url: URL, _ mode: ImageCompressionMode) throws -> (data: Data, format: ImageFiles.Format) {
        let original = ImageFiles.fileSize(url)
        let target = try target(for: mode, originalBytes: original)
        let ext = url.pathExtension.lowercased()
        if ImageFiles.isAnimated(url) {
            guard case .level = mode else {
                throw FileChangerError.unsupported("Target size compression cannot preserve this animation. Choose Level, which keeps the original dimensions.")
            }
            return (try animatedRewrite(url, original: original), ImageFiles.format(forExtension: ext))
        }
        if ext == "avif" { throw FileChangerError.unsupported("AVIF images cannot be compressed natively.") }
        if ext == "webp" { return (try webpData(url, mode, target: target), ImageFiles.Format(type: .webP, ext: "webp")) }
        var image = try ImageFiles.load(url)
        let fmt = ImageFiles.format(forExtension: ext)
        if case .level(_, let size) = mode, let edge = size.maxEdge, max(image.width, image.height) > edge {
            let k = Double(edge) / Double(max(image.width, image.height))
            image = try ImageResizeEngine.resized(image, to: (max(1, Int(Double(image.width) * k)), max(1, Int(Double(image.height) * k))))
        }
        let props = carried(url)
        let data: Data
        if fmt.supportsQuality {
            if let target { data = try fit(image, format: fmt, props: props, limit: target) }
            else if case .level(let s, _) = mode { data = try ImageFiles.encode(image, as: fmt, quality: s.quality, properties: props) }
            else { data = Data() }
        } else {
            data = try ImageFiles.encode(image, as: fmt, properties: props)   // lossless re-encode
            if let target, data.count > target {
                throw FileChangerError.failed("Could not reach the target size. Smallest attempt was \(formatted(data.count)). Try a larger target.")
            }
        }
        if data.count >= original && target == nil || data.isEmpty {
            throw FileChangerError.failed("Compressed output would exceed the original or target file size.")
        }
        return (data, fmt)
    }

    /// Animations keep their original dimensions: frames and delays are re-encoded as they are.
    static func animatedRewrite(_ url: URL, original: Int) throws -> Data {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else {
            throw FileChangerError.failed("Could not create the compressed image.")
        }
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(type as String) else {
            throw FileChangerError.unsupported("Animated \(url.pathExtension.uppercased()) images cannot be compressed natively.")
        }
        let data = NSMutableData()
        let n = CGImageSourceGetCount(src)
        guard let dest = CGImageDestinationCreateWithData(data, type, n, nil) else { throw FileChangerError.failed("Could not create the compressed image.") }
        if let fp = CGImageSourceCopyProperties(src, nil) { CGImageDestinationSetProperties(dest, fp) }
        for i in 0..<n {
            guard let f = CGImageSourceCreateImageAtIndex(src, i, nil) else { throw FileChangerError.failed("Could not create the compressed image.") }
            CGImageDestinationAddImage(dest, f, CGImageSourceCopyPropertiesAtIndex(src, i, nil))
        }
        guard CGImageDestinationFinalize(dest), data.length < original else {
            throw FileChangerError.failed("Compressed output would exceed the original or target file size.")
        }
        return data as Data
    }

    /// Still WebP needs cwebp (ImageIO cannot write WebP).
    static func webpData(_ url: URL, _ mode: ImageCompressionMode, target: Int?) throws -> Data {
        guard let cwebp = ExternalTool.cwebp.url else { throw FileChangerError.unsupported(ExternalTool.cwebp.missingMessage) }
        let image = try ImageFiles.load(url)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("filechanger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let png = tmp.appendingPathComponent("in.png"), out = tmp.appendingPathComponent("out.webp")
        try ImageFiles.encode(image, as: ImageFiles.Format(type: .png, ext: "png")).write(to: png)
        func run(_ q: Int) throws -> Data {
            let sem = DispatchSemaphore(value: 0)
            var failure: Error?
            Task.detached {
                do { try await ProcessRunner.run(cwebp, ["-quiet", "-q", String(q), png.path, "-o", out.path]) } catch { failure = error }
                sem.signal()
            }
            sem.wait()
            if let failure { throw failure }
            return try Data(contentsOf: out)
        }
        var data: Data
        if let target {
            var lo = 1, hi = 100
            data = try run(1)
            if data.count > target { throw FileChangerError.failed("Could not reach the target size. Smallest attempt was \(formatted(data.count)). Try a larger target.") }
            while lo < hi { let mid = (lo + hi + 1) / 2; let d = try run(mid); if d.count <= target { data = d; lo = mid } else { hi = mid - 1 } }
        } else if case .level(let st, _) = mode { data = try run(Int(st.quality * 100)) } else { data = Data() }
        guard !data.isEmpty, data.count < ImageFiles.fileSize(url) || target != nil else {
            throw FileChangerError.failed("Compressed output would exceed the original or target file size.")
        }
        return data
    }

    static func compress(_ url: URL, _ mode: ImageCompressionMode, progress: ProgressHandler) async throws -> URL {
        if FileKind.of(url) == .pdf { return try await compressPDF(url, mode, progress: progress) }
        progress(0.1)
        let (data, fmt) = try produce(url, mode)
        progress(0.9)
        let dest = OutputLocation.sibling(of: url, suffix: fmt.type == .png ? "-optimized" : "-compressed", ext: fmt.ext)
        try await OutputLocation.writeAtomically(to: dest) { try data.write(to: $0) }
        return dest
    }

    /// Size of the result without saving, for the "estimated compressed size" label; nil when it cannot be estimated.
    static func estimate(_ url: URL, _ mode: ImageCompressionMode) -> Int? {
        if FileKind.of(url) == .pdf { return nil }
        return try? produce(url, mode).data.count
    }

    // MARK: PDF

    /// Rewrites the document through macOS's "Reduce File Size" Quartz filter (keeps pages as vector where possible).
    static func quartzCompressed(_ source: URL, to dest: URL) throws {
        _ = dlopen("/System/Library/Frameworks/Quartz.framework/Quartz", RTLD_LAZY)
        let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
        guard let cls = NSClassFromString("QuartzFilter") as? NSObject.Type,
              FileManager.default.fileExists(atPath: filterURL.path),
              let filter = cls.perform(NSSelectorFromString("quartzFilterWithURL:"), with: filterURL)?.takeUnretainedValue() as? NSObject
        else { throw FileChangerError.unsupported("The macOS PDF compression filter is unavailable.") }
        guard let doc = CGPDFDocument(source as CFURL), doc.numberOfPages > 0,
              let ctx = CGContext(dest as CFURL, mediaBox: nil, nil) else {
            throw FileChangerError.failed("Could not create the compressed PDF.")
        }
        _ = filter.perform(NSSelectorFromString("applyToContext:"), with: ctx as AnyObject)
        for i in 1...doc.numberOfPages {
            guard let page = doc.page(at: i) else { continue }
            var box = page.getBoxRect(.mediaBox)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.drawPDFPage(page)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    static func compressPDF(_ url: URL, _ mode: ImageCompressionMode, progress: ProgressHandler) async throws -> URL {
        let original = ImageFiles.fileSize(url)
        let target = try target(for: mode, originalBytes: original)
        progress(0.1)
        let dest = OutputLocation.sibling(of: url, suffix: "-compressed")
        try await OutputLocation.writeAtomically(to: dest) { tmp in
            try quartzCompressed(url, to: tmp)
            let size = ImageFiles.fileSize(tmp)
            if size == 0 { throw FileChangerError.failed("Could not create the compressed PDF.") }
            if size >= original || (target.map { size > $0 } ?? false) {
                if let target, size < original, size > target {
                    throw FileChangerError.failed("Could not reach the target size. Smallest attempt was \(formatted(size)). Try a larger target.")
                }
                throw FileChangerError.failed("Compressed output would exceed the original or target file size.")
            }
        }
        progress(1)
        return dest
    }
}
