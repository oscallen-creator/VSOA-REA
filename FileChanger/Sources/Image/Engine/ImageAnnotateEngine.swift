import Foundation
import CoreGraphics
import AppKit

/// IMG-23..27. Annotations live in image pixels (top-left origin); sizes scale with the image so the
/// output is rendered at full source resolution and number/magnifier badges keep a fixed size relative to it.
enum AnnotationKind: String, CaseIterable, Sendable {
    case arrow, freehand, rectangle, ellipse, highlighter, number, magnifier, text, image
    var label: String {
        switch self {
        case .arrow: return "Arrow"; case .freehand: return "Draw"; case .rectangle: return "Rectangle"; case .ellipse: return "Ellipse"
        case .highlighter: return "Highlighter"; case .number: return "Number"; case .magnifier: return "Magnifier"
        case .text: return "Text"; case .image: return "Image"
        }
    }
    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"; case .freehand: return "scribble"; case .rectangle: return "rectangle"
        case .ellipse: return "circle"; case .highlighter: return "highlighter"; case .number: return "1.circle"
        case .magnifier: return "plus.magnifyingglass"; case .text: return "textformat"; case .image: return "photo.badge.plus"
        }
    }
    var hint: String {
        switch self {
        case .arrow: return "Drag from the tail toward the arrowhead. Drag an annotation to move it."
        case .rectangle, .ellipse: return "Drag on the image to draw. Drag an annotation to move it."
        case .highlighter: return "Drag over the image to highlight."
        case .freehand: return "Drag to draw. Use Clear Drawing to remove all drawn strokes."
        case .number: return "Click to add numbered callouts; drag to move them. Their size stays fixed."
        case .magnifier: return "Choose a zoom level, then click the detail to place a magnifier bubble."
        case .text: return "Press Text to add another box. Drag its border to move it and its side handles to change width."
        case .image: return "Press Image to choose files, or press \u{2318}V to paste an image. Drag to move or resize it."
        }
    }
}

enum AnnotationFont: String, CaseIterable, Sendable {
    case system = "System", rounded = "Rounded", serif = "Serif", mono = "Mono"
    func nsFont(size: CGFloat, bold: Bool = false) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .semibold)
        switch self {
        case .system: return base
        case .rounded: return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case .serif: return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case .mono: return NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .semibold)
        }
    }
}

struct Annotation: Identifiable {
    var id = UUID()
    var kind: AnnotationKind
    var color: ImageRGBA = ImageRGBA(r: 1, g: 0.23, b: 0.19)
    /// arrow/rectangle/ellipse/image: [start, end]; freehand/highlighter: the path; number/magnifier: [centre]; text: [top-left].
    var points: [CGPoint] = []
    var text = ""
    var font: AnnotationFont = .system
    var fontSize: CGFloat = 28          // "N pt" on a 1000-unit-wide image
    var width: CGFloat = 320            // text box width, image pixels at unit scale
    var number = 1
    var zoom: CGFloat = 2
    var image: CGImage?
}

enum ImageAnnotateEngine {
    static func unit(_ size: CGSize) -> CGFloat { max(size.width, size.height) / 1000 }
    static let magnifierRadius: CGFloat = 70, badgeRadius: CGFloat = 15, lineWidth: CGFloat = 4, highlightWidth: CGFloat = 18

    static func textSize(_ a: Annotation, unit u: CGFloat) -> CGSize {
        let s = NSAttributedString(string: a.text.isEmpty ? " " : a.text, attributes: [.font: a.font.nsFont(size: a.fontSize * u)])
        let r = s.boundingRect(with: CGSize(width: a.width * u, height: 100000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: a.width * u, height: ceil(r.height) + 8 * u)
    }

    static func normalized(_ p: [CGPoint]) -> CGRect {
        guard let f = p.first, let l = p.last else { return .zero }
        return CGRect(x: min(f.x, l.x), y: min(f.y, l.y), width: abs(f.x - l.x), height: abs(f.y - l.y))
    }

    /// Bounding box (image pixels) used for hit-testing, selection outlines and validation.
    static func bounds(_ a: Annotation, imageSize: CGSize) -> CGRect {
        let u = unit(imageSize)
        guard let first = a.points.first else { return .zero }
        switch a.kind {
        case .arrow, .rectangle, .ellipse, .image: return normalized(a.points)
        case .freehand, .highlighter:
            let xs = a.points.map(\.x), ys = a.points.map(\.y)
            return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        case .number: return CGRect(x: first.x - badgeRadius * u, y: first.y - badgeRadius * u, width: 2 * badgeRadius * u, height: 2 * badgeRadius * u)
        case .magnifier: return CGRect(x: first.x - magnifierRadius * u, y: first.y - magnifierRadius * u, width: 2 * magnifierRadius * u, height: 2 * magnifierRadius * u)
        case .text: return CGRect(origin: first, size: textSize(a, unit: u))
        }
    }

    static func moved(_ a: Annotation, by d: CGSize) -> Annotation {
        var o = a
        o.points = a.points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
        return o
    }

    static func hit(_ a: Annotation, at p: CGPoint, imageSize: CGSize) -> Bool {
        bounds(a, imageSize: imageSize).insetBy(dx: -8 * unit(imageSize), dy: -8 * unit(imageSize)).contains(p)
    }

    static func pathLength(_ pts: [CGPoint]) -> CGFloat {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// First problem with the annotation set, as the inventory's user-facing sentence (IMG-27).
    static func validate(_ list: [Annotation], imageSize: CGSize) -> String? {
        guard !list.isEmpty else { return "Add at least one annotation." }
        let u = unit(imageSize), canvas = CGRect(origin: .zero, size: imageSize)
        for a in list {
            if a.kind == .image && a.image == nil { return "Choose an image to place on the canvas." }
            if a.kind == .text && a.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter text for the text box." }
            if !bounds(a, imageSize: imageSize).intersects(canvas) && !a.points.isEmpty { return "Keep annotations inside the image." }
            let b = bounds(a, imageSize: imageSize)
            switch a.kind {
            case .freehand where pathLength(a.points) < 12 * u: return "Draw a slightly longer freehand line."
            case .arrow where hypot(b.width, b.height) < 10 * u: return "Make drawn annotations a little larger."
            case .rectangle where b.width < 6 * u || b.height < 6 * u,
                 .ellipse where b.width < 6 * u || b.height < 6 * u,
                 .image where b.width < 6 * u || b.height < 6 * u,
                 .highlighter where pathLength(a.points) < 12 * u: return "Make drawn annotations a little larger."
            default: break
            }
        }
        return nil
    }

    static func render(_ base: CGImage, _ list: [Annotation]) throws -> CGImage {
        if let problem = validate(list, imageSize: CGSize(width: base.width, height: base.height)) { throw FileChangerError.failed(problem) }
        return try renderUnchecked(base, list)
    }

    /// Same drawing without the validation pass (live preview shows half-drawn shapes).
    static func renderUnchecked(_ base: CGImage, _ list: [Annotation]) throws -> CGImage {
        let size = CGSize(width: base.width, height: base.height)
        let u = unit(size)
        guard let out = ImageFiles.render(base.width, base.height, space: ImageFiles.space(for: base), { ctx in
            ImageFiles.draw(base, in: CGRect(origin: .zero, size: size), ctx)
            for a in list { draw(a, base: base, u: u, size: size, ctx) }
        }) else { throw FileChangerError.failed("Could not prepare the annotated image.") }
        return out
    }

    private static func drawText(_ s: String, font: NSFont, color: NSColor, in rect: CGRect, centered: Bool = false, _ ctx: CGContext) {
        let style = NSMutableParagraphStyle(); style.alignment = centered ? .center : .left
        let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gc
        attr.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func draw(_ a: Annotation, base: CGImage, u: CGFloat, size: CGSize, _ ctx: CGContext) {
        guard let p0 = a.points.first else { return }
        let lw = lineWidth * u
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setStrokeColor(a.color.cg); ctx.setFillColor(a.color.cg); ctx.setLineWidth(lw)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let box = normalized(a.points)
        switch a.kind {
        case .arrow:
            guard let p1 = a.points.last else { return }
            let angle = atan2(p1.y - p0.y, p1.x - p0.x), head = max(16 * u, lw * 4)
            let tip = p1, back = CGPoint(x: tip.x - cos(angle) * head * 0.8, y: tip.y - sin(angle) * head * 0.8)
            ctx.move(to: p0); ctx.addLine(to: back); ctx.strokePath()
            ctx.move(to: tip)
            ctx.addLine(to: CGPoint(x: tip.x - cos(angle - 0.45) * head, y: tip.y - sin(angle - 0.45) * head))
            ctx.addLine(to: CGPoint(x: tip.x - cos(angle + 0.45) * head, y: tip.y - sin(angle + 0.45) * head))
            ctx.closePath(); ctx.fillPath()
        case .freehand, .highlighter:
            if a.kind == .highlighter {
                ctx.setBlendMode(.multiply); ctx.setStrokeColor(ImageRGBA(r: a.color.r, g: a.color.g, b: a.color.b, a: 0.55).cg)
                ctx.setLineWidth(highlightWidth * u)
            }
            ctx.move(to: p0); a.points.dropFirst().forEach { ctx.addLine(to: $0) }
            if a.points.count == 1 { ctx.addLine(to: p0) }
            ctx.strokePath()
        case .rectangle: ctx.stroke(box)
        case .ellipse: ctx.strokeEllipse(in: box)
        case .number:
            let r = badgeRadius * u
            ctx.fillEllipse(in: CGRect(x: p0.x - r, y: p0.y - r, width: 2 * r, height: 2 * r))
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(1.5 * u)
            ctx.strokeEllipse(in: CGRect(x: p0.x - r, y: p0.y - r, width: 2 * r, height: 2 * r))
            let f = AnnotationFont.system.nsFont(size: r * 1.15, bold: true)
            drawText("\(a.number)", font: f, color: .white, in: CGRect(x: p0.x - r, y: p0.y - f.pointSize * 0.62, width: 2 * r, height: f.pointSize * 1.3), centered: true, ctx)
        case .magnifier:
            let r = magnifierRadius * u, circle = CGRect(x: p0.x - r, y: p0.y - r, width: 2 * r, height: 2 * r)
            ctx.saveGState()
            ctx.addEllipse(in: circle); ctx.clip()
            ctx.translateBy(x: p0.x, y: p0.y); ctx.scaleBy(x: a.zoom, y: a.zoom); ctx.translateBy(x: -p0.x, y: -p0.y)
            ImageFiles.draw(base, in: CGRect(origin: .zero, size: size), ctx)
            ctx.restoreGState()
            ctx.setLineWidth(3 * u); ctx.strokeEllipse(in: circle)
        case .text:
            let ts = textSize(a, unit: u)
            drawText(a.text, font: a.font.nsFont(size: a.fontSize * u), color: NSColor(cgColor: a.color.cg) ?? .red,
                     in: CGRect(origin: p0, size: ts).insetBy(dx: 0, dy: 4 * u), ctx)
        case .image:
            if let img = a.image { ImageFiles.draw(img, in: box, ctx) }
        }
    }
}
