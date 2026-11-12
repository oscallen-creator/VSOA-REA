import Foundation
import CoreGraphics
import CoreImage

/// IMG-30..32 "Add BG".
enum FrameCanvasRatio: String, CaseIterable, Sendable {
    case automatic = "Automatic", square = "Square 1:1", r43 = "Landscape 4:3", r169 = "Landscape 16:9", r34 = "Portrait 3:4", r916 = "Portrait 9:16"
    var ratio: CGFloat? {
        switch self {
        case .automatic: return nil; case .square: return 1; case .r43: return 4.0 / 3; case .r169: return 16.0 / 9
        case .r34: return 0.75; case .r916: return 9.0 / 16
        }
    }
}

/// A background preset: solid colour, or a base colour with two soft radial blobs ("mesh" look).
struct FrameBackgroundPreset: Identifiable, Hashable, Sendable {
    let name: String
    let base: UInt32
    let blobs: [UInt32]          // empty for solid presets
    var id: String { name }
    var isGradient: Bool { !blobs.isEmpty }

    private static func solid(_ n: String, _ hex: UInt32) -> FrameBackgroundPreset { .init(name: n, base: hex, blobs: []) }
    private static func mesh(_ n: String, _ base: UInt32, _ a: UInt32, _ b: UInt32) -> FrameBackgroundPreset { .init(name: n, base: base, blobs: [a, b]) }
    // Colour values are ours (inventory lists names only). Order follows the inventory.
    static let all: [FrameBackgroundPreset] = [
        mesh("citrus", 0xFFD93D, 0xFF8A1F, 0xB6E04A), mesh("mesh", 0x7B6CF6, 0xFF7AB8, 0x4CC9F0), mesh("meadow", 0xA8E063, 0x56AB2F, 0xF9F871),
        mesh("whisper", 0xF3EDE7, 0xE8D9F0, 0xD6ECF5), mesh("orchid", 0xC77DFF, 0xFF9ECD, 0x7B2CBF), mesh("oasis", 0x2BC4A8, 0xF8E08E, 0x1B7F8C),
        mesh("lagoon", 0x1FA2C7, 0x7AE7C7, 0x0B3C5D), solid("aqua", 0x00C2D1), mesh("dream", 0xFBC2EB, 0xA6C1EE, 0xFFE0A3),
        mesh("sorbet", 0xFF9A9E, 0xFAD0C4, 0xFFD6A5), mesh("frost", 0xCFE8F7, 0xE6F2FB, 0x9CC5E8), solid("emerald", 0x10B981),
        mesh("sunset", 0xFF7E5F, 0xFEB47B, 0x8E2DE2), solid("mint", 0x98F5C9), solid("violet", 0x8B5CF6), solid("graphite", 0x3A3F47),
        solid("yellow", 0xFACC15), solid("lime", 0xA3E635), solid("green", 0x22C55E), solid("teal", 0x14B8A6), solid("cyan", 0x22D3EE),
        solid("cobalt", 0x2457D6), solid("navy", 0x14213D), solid("purple", 0x9333EA), solid("lavender", 0xC4B5FD), solid("rose", 0xFB7185),
        solid("coral", 0xFF7F6B), solid("orange", 0xFF8A00), solid("brown", 0x8B5A2B), solid("gray", 0x9CA3AF), solid("black", 0x0B0B0C),
        solid("sky", 0x7DD3FC), solid("red", 0xEF4444),
    ]
}

enum FrameBackground: Hashable, Sendable {
    case preset(FrameBackgroundPreset)
    case custom(ImageRGBA)
    case blur
    case image(URL)
}

struct FrameOptions: Hashable, Sendable {
    var background: FrameBackground = .preset(FrameBackgroundPreset.all[0])
    var ratio: FrameCanvasRatio = .automatic
    var padding = 12.0     // % of the photo's shorter side, each edge
    var corners = 6.0      // % of the maximum radius is not used: percent of the shorter side
    var shadow = 30.0      // 0...100
    static let paddingRange = 0.0...50.0, cornerRange = 0.0...25.0, shadowRange = 0.0...100.0
    static let maxSide = 16000
}

enum ImageFrameEngine {
    static let tooLarge = "This frame would be too large. Use less padding or a closer output ratio."

    static func canvasSize(photo: CGSize, _ o: FrameOptions) throws -> CGSize {
        let pad = (min(photo.width, photo.height) * o.padding / 100).rounded()
        var w = photo.width + 2 * pad, h = photo.height + 2 * pad
        if let r = o.ratio.ratio {
            if w / h < r { w = (h * r).rounded() } else { h = (w / r).rounded() }
        }
        guard w <= CGFloat(FrameOptions.maxSide), h <= CGFloat(FrameOptions.maxSide) else { throw FileChangerError.failed(tooLarge) }
        return CGSize(width: w, height: h)
    }

    private static func paintBackground(_ o: FrameOptions, photo: CGImage, picked: CGImage?, canvas: CGSize, _ ctx: CGContext) {
        let full = CGRect(origin: .zero, size: canvas)
        switch o.background {
        case .custom(let c): ctx.setFillColor(c.cg); ctx.fill(full)
        case .preset(let p):
            ctx.setFillColor(ImageRGBA(hex: p.base).cg); ctx.fill(full)
            let spots: [(CGPoint, CGFloat)] = [(CGPoint(x: 0.15, y: 0.1), 0.9), (CGPoint(x: 0.9, y: 0.95), 0.85)]
            for (hex, spot) in zip(p.blobs, spots) {
                let c = ImageRGBA(hex: hex)
                let g = CGGradient(colorsSpace: ImageFiles.sRGB, colors: [c.cg, ImageRGBA(r: c.r, g: c.g, b: c.b, a: 0).cg] as CFArray, locations: [0, 1])!
                let center = CGPoint(x: spot.0.x * canvas.width, y: spot.0.y * canvas.height)
                ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: spot.1 * max(canvas.width, canvas.height), options: [])
            }
        case .blur, .image:
            let source = picked ?? photo
            let k = max(canvas.width / CGFloat(source.width), canvas.height / CGFloat(source.height))
            let r = CGRect(x: (canvas.width - CGFloat(source.width) * k) / 2, y: (canvas.height - CGFloat(source.height) * k) / 2,
                           width: CGFloat(source.width) * k, height: CGFloat(source.height) * k)
            if case .blur = o.background {
                // Blur at reduced size (cheap) then scale up.
                let small = 256.0, s = small / max(r.width, r.height)
                guard let tiny = ImageFiles.render(max(1, Int(r.width * s)), max(1, Int(r.height * s)), { c in
                    ImageFiles.draw(source, in: CGRect(x: 0, y: 0, width: r.width * s, height: r.height * s), c)
                }) else { return }
                let ci = CIImage(cgImage: tiny)
                let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: 10).cropped(to: ci.extent)
                if let cg = ImageAdjustEngine.context.createCGImage(blurred, from: ci.extent) { ImageFiles.draw(cg, in: r, ctx) }
            } else { ImageFiles.draw(source, in: r, ctx) }
        }
    }

    static func render(_ photo: CGImage, _ o: FrameOptions) throws -> CGImage {
        let ps = CGSize(width: photo.width, height: photo.height)
        let canvas = try canvasSize(photo: ps, o)
        var picked: CGImage?
        if case .image(let url) = o.background {
            guard FileManager.default.fileExists(atPath: url.path) else { throw FileChangerError.failed("Choose a background image.") }
            guard let img = try? ImageFiles.load(url, maxPixel: 4096) else { throw FileChangerError.failed("Could not prepare the image background.") }
            picked = img
        }
        guard let out = ImageFiles.render(Int(canvas.width), Int(canvas.height), { ctx in
            paintBackground(o, photo: photo, picked: picked, canvas: canvas, ctx)
            let rect = CGRect(x: (canvas.width - ps.width) / 2, y: (canvas.height - ps.height) / 2, width: ps.width, height: ps.height)
            let radius = min(ps.width, ps.height) * o.corners / 100
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            if o.shadow > 0 {
                ctx.saveGState()
                let m = min(ps.width, ps.height)
                ctx.setShadow(offset: CGSize(width: 0, height: -m * 0.012 * o.shadow / 100 * 3), blur: m * 0.06 * o.shadow / 100 + 1,
                              color: CGColor(gray: 0, alpha: 0.45))
                ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.addPath(path); ctx.fillPath()
                ctx.restoreGState()
            }
            ctx.saveGState(); ctx.addPath(path); ctx.clip()
            ImageFiles.draw(photo, in: rect, ctx)
            ctx.restoreGState()
        }) else { throw FileChangerError.failed("Could not finish adding the background.") }
        return out
    }

    static func addBackground(_ url: URL, _ o: FrameOptions, progress: ProgressHandler) async throws -> URL {
        let photo = try ImageFiles.load(url)
        progress(0.3)
        let out = try render(photo, o)
        progress(0.8)
        // A solid/gradient frame is opaque; keep JPEG for JPEGs, PNG otherwise.
        let fmt = ImageFiles.format(forExtension: url.pathExtension)
        return try await ImageFiles.save(out, beside: url, suffix: "-framed", format: fmt)
    }
}
