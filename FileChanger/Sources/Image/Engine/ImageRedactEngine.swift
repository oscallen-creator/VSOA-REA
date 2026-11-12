import Foundation
import CoreGraphics
import CoreImage
import Vision

/// IMG-33..35. Rectangles are image pixels, top-left origin.
enum RedactionStyle: String, CaseIterable, Sendable { case solid = "Solid", blur = "Blur" }

enum PhotoRedactionDetectionKind: String, CaseIterable, Sendable {
    case faces = "Faces", text = "Text"
    var noun: String { rawValue.lowercased() }
}

enum ImageRedactEngine {
    static func clamp(_ r: CGRect, to size: CGSize) -> CGRect {
        r.intersection(CGRect(origin: .zero, size: size))
    }

    static func render(_ image: CGImage, rects: [CGRect], style: RedactionStyle) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let rs = rects.map { clamp($0, to: size).integral }.filter { $0.width >= 1 && $0.height >= 1 }
        guard !rs.isEmpty else { throw FileChangerError.failed("Draw a rectangle over the area to hide.") }
        var blurred: CGImage?
        if style == .blur {
            let ci = CIImage(cgImage: image)
            let radius = max(12, CGFloat(min(image.width, image.height)) * 0.03)
            let b = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(radius)).cropped(to: ci.extent)
            guard let cg = ImageAdjustEngine.context.createCGImage(b, from: ci.extent, format: .RGBA8, colorSpace: ImageFiles.space(for: image)) else {
                throw FileChangerError.failed("Could not blur the selected area.")
            }
            blurred = cg
        }
        guard let out = ImageFiles.render(image.width, image.height, space: ImageFiles.space(for: image), { ctx in
            ImageFiles.draw(image, in: CGRect(origin: .zero, size: size), ctx)
            for r in rs {
                ctx.saveGState(); ctx.clip(to: r)
                if let blurred { ImageFiles.draw(blurred, in: CGRect(origin: .zero, size: size), ctx) }
                else { ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(r) }
                ctx.restoreGState()
            }
        }) else { throw FileChangerError.failed("Could not prepare the redacted image.") }
        return out
    }

    /// Vision boxes (normalised, bottom-left origin) -> pixel rects, grown slightly so edges are covered.
    static func pixelRect(fromVision box: CGRect, size: CGSize, grow: CGFloat = 0.12) -> CGRect {
        var r = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width, height: box.height * size.height)
        r = r.insetBy(dx: -r.width * grow, dy: -r.height * grow)
        return clamp(r, to: size)
    }

    static func detect(_ kind: PhotoRedactionDetectionKind, in image: CGImage) async throws -> [CGRect] {
        let size = CGSize(width: image.width, height: image.height)
        return try await Task.detached {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                switch kind {
                case .faces:
                    let req = VNDetectFaceRectanglesRequest()
                    try handler.perform([req])
                    return (req.results ?? []).map { pixelRect(fromVision: $0.boundingBox, size: size, grow: 0.15) }
                case .text:
                    let req = VNRecognizeTextRequest()
                    req.recognitionLevel = .accurate
                    try handler.perform([req])
                    return (req.results ?? []).map { pixelRect(fromVision: $0.boundingBox, size: size, grow: 0.08) }
                }
            } catch { throw FileChangerError.failed("Could not detect \(kind.noun).") }
        }.value
    }

    /// Detected rectangles not already (mostly) covered by existing ones.
    static func newRects(_ detected: [CGRect], existing: [CGRect]) -> [CGRect] {
        detected.filter { d in
            !existing.contains { e in
                let i = d.intersection(e)
                return !i.isNull && i.width * i.height >= 0.6 * d.width * d.height
            }
        }
    }

    static func redact(_ url: URL, rects: [CGRect], style: RedactionStyle, progress: ProgressHandler) async throws -> URL {
        let image = try ImageFiles.load(url)
        progress(0.3)
        let out = try render(image, rects: rects, style: style)
        progress(0.8)
        return try await ImageFiles.save(out, beside: url, suffix: "-redacted")
    }
}

/// IMG-36. Reads QR codes (Vision barcode detector).
struct QRResult: Identifiable, Equatable, Sendable {
    let id = UUID()
    let text: String
}

enum ImageQREngine {
    static func read(_ url: URL) throws -> [QRResult] {
        let image = try ImageFiles.load(url, maxPixel: 6000)
        let req = VNDetectBarcodesRequest()
        req.symbologies = [.qr, .microQR]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        var seen = Set<String>(), out: [QRResult] = []
        for ob in req.results ?? [] {
            guard let s = ob.payloadStringValue, !s.isEmpty, seen.insert(s).inserted else { continue }
            out.append(QRResult(text: s))
        }
        return out
    }
}
