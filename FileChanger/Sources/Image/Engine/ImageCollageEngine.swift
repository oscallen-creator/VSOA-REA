import Foundation
import CoreGraphics

/// IMG-28/29.
enum CollageStyle: String, CaseIterable, Sendable {
    case grid = "Grid", horizontal = "Horizontal", vertical = "Vertical", featured = "Featured"
}

enum CollageCanvas: String, CaseIterable, Sendable {
    case auto = "Auto", square = "1:1", r43 = "4:3", r32 = "3:2", r169 = "16:9", r34 = "3:4", r916 = "9:16"
    var ratio: CGFloat? {
        switch self {
        case .auto: return nil; case .square: return 1; case .r43: return 4.0 / 3; case .r32: return 1.5
        case .r169: return 16.0 / 9; case .r34: return 0.75; case .r916: return 9.0 / 16
        }
    }
}

enum CollageBackground: Hashable, Sendable {
    case white, transparent, color(ImageRGBA)
    var rgba: ImageRGBA { switch self { case .white: return .white; case .transparent: return .clear; case .color(let c): return c } }
}

struct CollageOptions: Hashable, Sendable {
    var style: CollageStyle = .grid
    var columns = 2                 // "Width": images across a grid
    var fillImage = true            // "Fill cells (crop edges)" vs "Fit whole images"
    var canvas: CollageCanvas = .auto
    var imageWidth = 600            // "Image width px": width of one cell
    var spacing = 16
    var padding = 24
    var cornerRadius = 12
    var background: CollageBackground = .white

    static let maxCanvas = 8192, minCell = 8
    static let imageWidthRange = 64...2048, spacingRange = 0...100, paddingRange = 0...200, cornerRange = 0...100, columnRange = 1...8
}

enum ImageCollageEngine {
    static let sizeMessage = "Choose a canvas and spacing that leave at least 8 x 8 pixels for each image (maximum canvas: 8192 x 8192)."

    /// Canvas size and one frame per image (top-left origin). `aspects` are width/height of the sources.
    static func layout(aspects: [CGFloat], _ o: CollageOptions) throws -> (canvas: CGSize, frames: [CGRect]) {
        let n = aspects.count
        guard n > 0 else { throw FileChangerError.failed("Add images to create a collage.") }
        let cw = CGFloat(o.imageWidth), sp = CGFloat(o.spacing), pad = CGFloat(o.padding)
        var frames: [CGRect] = []
        var size: CGSize
        switch o.style {
        case .grid:
            let cols = min(max(1, o.columns), n), rows = (n + cols - 1) / cols
            let width = pad * 2 + CGFloat(cols) * cw + CGFloat(cols - 1) * sp
            let cellH: CGFloat
            if let ratio = o.canvas.ratio {
                cellH = ((width / ratio) - pad * 2 - CGFloat(rows - 1) * sp) / CGFloat(rows)
            } else { cellH = cw }
            for i in 0..<n {
                frames.append(CGRect(x: pad + CGFloat(i % cols) * (cw + sp), y: pad + CGFloat(i / cols) * (cellH + sp), width: cw, height: cellH))
            }
            size = CGSize(width: width, height: pad * 2 + CGFloat(rows) * cellH + CGFloat(rows - 1) * sp)
        case .horizontal:
            let h = cw   // row height
            var x = pad
            for a in aspects { frames.append(CGRect(x: x, y: pad, width: h * a, height: h)); x += h * a + sp }
            size = CGSize(width: x - sp + pad, height: h + pad * 2)
        case .vertical:
            var y = pad
            for a in aspects { frames.append(CGRect(x: pad, y: y, width: cw, height: cw / a)); y += cw / a + sp }
            size = CGSize(width: cw + pad * 2, height: y - sp + pad)
        case .featured:
            let ch = cw, big = 2 * cw, bigH = 2 * ch + sp, m = n - 1
            if m == 0 { frames = [CGRect(x: pad, y: pad, width: big, height: bigH)] }
            else {
                frames.append(CGRect(x: pad, y: pad, width: big, height: bigH))
                let h = (bigH - CGFloat(m - 1) * sp) / CGFloat(m)
                for i in 0..<m { frames.append(CGRect(x: pad + big + sp, y: pad + CGFloat(i) * (h + sp), width: cw, height: h)) }
            }
            size = CGSize(width: pad * 2 + big + (m > 0 ? sp + cw : 0), height: bigH + pad * 2)
        }
        if size.width > CGFloat(CollageOptions.maxCanvas) || size.height > CGFloat(CollageOptions.maxCanvas)
            || frames.contains(where: { $0.width < CGFloat(CollageOptions.minCell) || $0.height < CGFloat(CollageOptions.minCell) }) {
            throw FileChangerError.failed(sizeMessage)
        }
        return (CGSize(width: size.width.rounded(), height: size.height.rounded()), frames)
    }

    static func render(_ images: [CGImage], _ o: CollageOptions) throws -> CGImage {
        let (canvas, frames) = try layout(aspects: images.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) }, o)
        guard let out = ImageFiles.render(Int(canvas.width), Int(canvas.height), { ctx in
            let bg = o.background.rgba
            if bg.a > 0 { ctx.setFillColor(bg.cg); ctx.fill(CGRect(origin: .zero, size: canvas)) }
            for (img, f) in zip(images, frames) {
                ctx.saveGState()
                let radius = min(CGFloat(o.cornerRadius), min(f.width, f.height) / 2)
                ctx.addPath(CGPath(roundedRect: f, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.clip()
                let iw = CGFloat(img.width), ih = CGFloat(img.height)
                let k = o.fillImage ? max(f.width / iw, f.height / ih) : min(f.width / iw, f.height / ih)
                let r = CGRect(x: f.midX - iw * k / 2, y: f.midY - ih * k / 2, width: iw * k, height: ih * k)
                ImageFiles.draw(img, in: r, ctx)
                ctx.restoreGState()
            }
        }) else { throw FileChangerError.failed("Could not create the collage canvas.") }
        return out
    }

    static func create(_ urls: [URL], _ o: CollageOptions, progress: ProgressHandler) async throws -> URL {
        var images: [CGImage] = []
        for (i, u) in urls.enumerated() { images.append(try ImageFiles.load(u, maxPixel: 4096)); progress(Double(i) / Double(urls.count) * 0.6) }
        let out = try render(images, o)
        progress(0.8)
        guard let first = urls.first else { throw FileChangerError.failed("Add images to create a collage.") }
        let png = ImageFiles.format(forExtension: "png")
        let dest = OutputLocation.unique(first.deletingLastPathComponent().appendingPathComponent("Collage.png"))
        let data = try ImageFiles.encode(out, as: png)
        try await OutputLocation.writeAtomically(to: dest) { try data.write(to: $0) }
        return dest
    }
}
