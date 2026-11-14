// Renders the DMG window background: a misty pine forest at dusk in the app's lime green (ranks of pines fading into
// fog, light rays, framing trunks, ferns, fireflies), a dotted trail from FileChanger to Applications, and the two
// caption texts. Procedural CoreGraphics with a fixed seed, so every run gives the same picture.
// Writes dmg/background@2x.png (1440x920) and dmg/background.png (720x460).
// Run: swift scripts/make-dmg-background.swift     (DMG_OUT=dir writes elsewhere)
import AppKit
import CoreText
import ImageIO

let env = ProcessInfo.processInfo.environment
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let outDir = URL(fileURLWithPath: env["DMG_OUT"] ?? root.appendingPathComponent("dmg").path)

// Layout from scripts/make-dmg.sh, in 720 x 460 points, y down: icon centres and the 112 pt icons.
let appIcon = CGPoint(x: 170, y: 205), appsIcon = CGPoint(x: 550, y: 205), setupIcon = CGPoint(x: 360, y: 340)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
    let x = a.components!, y = b.components!
    return CGColor(srgbRed: x[0] + (y[0] - x[0]) * t, green: x[1] + (y[1] - x[1]) * t, blue: x[2] + (y[2] - x[2]) * t, alpha: 1)
}
let lime = rgb(0xA2C923), haze = rgb(0xB8D27A), pine = rgb(0x0C2214), skyTop = rgb(0x0B1F18)

/// Small deterministic generator (SplitMix64), so the picture is the same on every run.
struct RNG {
    var s: UInt64
    mutating func next() -> CGFloat {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return CGFloat((z ^ (z >> 31)) >> 11) / CGFloat(1 << 53)
    }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * next() }
}
var rng = RNG(s: 20261112)

func linear(_ ctx: CGContext, _ colors: [CGColor], _ locs: [CGFloat], from a: CGPoint, to b: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locs)!
    ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func glow(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: CGColor, _ alpha: CGFloat) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [color.copy(alpha: alpha)!, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
}

/// A pine: jagged tiers widening toward the base, with a little jitter so no two match.
func pineTree(_ ctx: CGContext, x: CGFloat, base: CGFloat, h: CGFloat, color: CGColor) {
    let tiers = max(4, Int(h / 9)), w = h * rng.range(0.2, 0.27)
    var right: [CGPoint] = [], left: [CGPoint] = []
    for k in 0..<tiers {
        let t = CGFloat(k + 1) / CGFloat(tiers)
        let y = base - h + h * 0.92 * t, half = w * pow(t, 0.9) * rng.range(0.85, 1.12)
        right.append(CGPoint(x: x + half, y: y)); left.append(CGPoint(x: x - half * rng.range(0.85, 1.12), y: y))
        if k < tiers - 1 {
            let notchY = y - h * 0.92 / CGFloat(tiers) * 0.15
            right.append(CGPoint(x: x + half * 0.5, y: notchY)); left.append(CGPoint(x: x - half * 0.5, y: notchY))
        }
    }
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x, y: base - h))
    p.addLines(between: [CGPoint(x: x, y: base - h)] + right + [CGPoint(x: x + w * 0.08, y: base), CGPoint(x: x - w * 0.08, y: base)] + left.reversed())
    p.closeSubpath()
    ctx.addPath(p); ctx.setFillColor(color); ctx.fillPath()
}

/// One rank of trees standing on a ground band of the same colour, so nearer ranks cover the ones behind.
func treeLine(_ ctx: CGContext, base: CGFloat, hRange: (CGFloat, CGFloat), spacing: CGFloat, color: CGColor) {
    ctx.setFillColor(color); ctx.fill(CGRect(x: 0, y: base - 2, width: 720, height: 460 - base + 2))
    var x: CGFloat = -20
    while x < 740 {
        pineTree(ctx, x: x, base: base + rng.range(-4, 4), h: rng.range(hRange.0, hRange.1), color: color)
        x += spacing * rng.range(0.55, 1.25)
    }
}

func fogBand(_ ctx: CGContext, y: CGFloat, height: CGFloat, alpha: CGFloat) {
    linear(ctx, [haze.copy(alpha: 0)!, haze.copy(alpha: alpha)!, haze.copy(alpha: 0)!], [0, 0.55, 1],
           from: CGPoint(x: 0, y: y - height), to: CGPoint(x: 0, y: y + height * 0.4))
}

/// A big near trunk with a few needle-heavy boughs, used to frame the left and right edges.
func framingTree(_ ctx: CGContext, x: CGFloat, width: CGFloat, lean: CGFloat, side: CGFloat) {
    let bark = rgb(0x08140C)
    let trunk = CGMutablePath()
    trunk.move(to: CGPoint(x: x - width / 2, y: 470))
    trunk.addLine(to: CGPoint(x: x - width * 0.32 + lean, y: -10))
    trunk.addLine(to: CGPoint(x: x + width * 0.32 + lean, y: -10))
    trunk.addLine(to: CGPoint(x: x + width / 2, y: 470))
    trunk.closeSubpath()
    ctx.addPath(trunk); ctx.setFillColor(bark); ctx.fillPath()
    // Boughs reach inward (toward the middle) and droop; each is a spray of needle strokes.
    for (y0, len) in [(18.0, 120.0), (70.0, 95.0), (128.0, 70.0)] as [(CGFloat, CGFloat)] {
        let start = CGPoint(x: x + lean * (1 - y0 / 460), y: y0)
        let end = CGPoint(x: start.x + side * len, y: y0 + len * 0.28)
        ctx.setStrokeColor(bark); ctx.setLineWidth(5); ctx.setLineCap(.round)
        ctx.move(to: start); ctx.addQuadCurve(to: end, control: CGPoint(x: start.x + side * len * 0.5, y: y0 - 6)); ctx.strokePath()
        ctx.setLineWidth(1.6)
        for i in 0..<Int(len / 2.2) {
            let t = CGFloat(i) / (len / 2.2)
            let p = CGPoint(x: start.x + side * len * t, y: y0 + len * 0.28 * t * t - 6 * 4 * t * (1 - t) * 0.5)
            for s: CGFloat in [-1, 1] {
                let n = rng.range(9, 19) * (1 - t * 0.5)
                ctx.setStrokeColor(mix(bark, pine, rng.range(0, 0.6)))
                ctx.move(to: p); ctx.addLine(to: CGPoint(x: p.x + side * n * 0.55, y: p.y + s * n)); ctx.strokePath()
            }
        }
    }
}

func fern(_ ctx: CGContext, at p: CGPoint, length: CGFloat, angle: CGFloat, color: CGColor) {
    let dir = CGPoint(x: cos(angle), y: sin(angle)), nrm = CGPoint(x: -dir.y, y: dir.x)
    ctx.setStrokeColor(color); ctx.setLineCap(.round)
    ctx.setLineWidth(2); ctx.move(to: p); ctx.addLine(to: CGPoint(x: p.x + dir.x * length, y: p.y + dir.y * length)); ctx.strokePath()
    ctx.setLineWidth(1.4)
    let n = Int(length / 5)
    for i in 1..<n {
        let t = CGFloat(i) / CGFloat(n), q = CGPoint(x: p.x + dir.x * length * t, y: p.y + dir.y * length * t)
        let leaf = length * 0.32 * sin(.pi * min(1, t * 1.15)) + 2
        for s: CGFloat in [-1, 1] {
            ctx.move(to: q)
            ctx.addLine(to: CGPoint(x: q.x + (nrm.x * s + dir.x * 0.5) * leaf, y: q.y + (nrm.y * s + dir.y * 0.5) * leaf))
            ctx.strokePath()
        }
    }
}

/// Keep fireflies off the icons, their labels and the captions.
let busy: [CGRect] = [appIcon, appsIcon, setupIcon].map { CGRect(x: $0.x - 70, y: $0.y - 62, width: 140, height: 155) }
    + [CGRect(x: 150, y: 40, width: 420, height: 46), CGRect(x: 430, y: 315, width: 280, height: 50)]

func drawScene(_ ctx: CGContext) {
    // Sky: deep green-black overhead, a lime glow low on the horizon.
    linear(ctx, [skyTop, rgb(0x1D4229), rgb(0x6F9A3A), rgb(0xD3E68E)], [0, 0.35, 0.72, 1],
           from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: 255))
    glow(ctx, CGPoint(x: 360, y: 250), 300, rgb(0xEAF6B0), 0.55)

    // Light rays fanning down from above the horizon glow.
    ctx.saveGState(); ctx.setBlendMode(.screen)
    for i in 0..<9 {
        let a = -0.95 + CGFloat(i) * 0.24 + rng.range(-0.05, 0.05), spread = rng.range(0.035, 0.08)
        let o = CGPoint(x: 360, y: -60), len: CGFloat = 640
        ctx.move(to: o)
        ctx.addLine(to: CGPoint(x: o.x + sin(a - spread) * len, y: o.y + cos(a - spread) * len))
        ctx.addLine(to: CGPoint(x: o.x + sin(a + spread) * len, y: o.y + cos(a + spread) * len))
        ctx.closePath()
        ctx.setFillColor(rgb(0xDDF2A0, rng.range(0.035, 0.075))); ctx.fillPath()
    }
    ctx.restoreGState()

    // Ranks of pines, far to near, each darker and with fog between.
    let ranks: [(base: CGFloat, h: (CGFloat, CGFloat), spacing: CGFloat, fog: CGFloat)] = [
        (238, (22, 40), 9, 0.78), (262, (34, 60), 13, 0.62), (290, (52, 90), 19, 0.46),
        (330, (80, 130), 30, 0.3), (378, (110, 175), 46, 0.16)]
    for (i, r) in ranks.enumerated() {
        treeLine(ctx, base: r.base, hRange: r.h, spacing: r.spacing, color: mix(pine, haze, r.fog))
        if i < ranks.count - 1 { fogBand(ctx, y: r.base + 6, height: 46, alpha: 0.38 - CGFloat(i) * 0.05) }
    }

    // Forest floor, darkening toward the bottom edge, with moss flecks.
    linear(ctx, [mix(pine, haze, 0.16).copy(alpha: 0)!, rgb(0x0A1A10, 0.9), rgb(0x061009)], [0, 0.45, 1],
           from: CGPoint(x: 0, y: 345), to: CGPoint(x: 0, y: 460))
    for _ in 0..<500 {
        let p = CGPoint(x: rng.range(0, 720), y: rng.range(395, 460))
        ctx.setFillColor(mix(rgb(0x1F3B1A), lime, rng.range(0, 0.35)).copy(alpha: rng.range(0.25, 0.6))!)
        ctx.fillEllipse(in: CGRect(x: p.x, y: p.y, width: rng.range(0.8, 2.2), height: rng.range(0.6, 1.4)))
    }

    // Low ground mist and a pale clearing keep Finder's icon labels on a mid tone (about 115 luma, like the
    // previous background), readable whether Finder draws them black or white.
    fogBand(ctx, y: 286, height: 40, alpha: 0.5)
    ctx.saveGState(); ctx.translateBy(x: 360, y: 412); ctx.scaleBy(x: 1.9, y: 0.5)
    glow(ctx, .zero, 120, haze, 0.65); ctx.restoreGState()

    framingTree(ctx, x: 18, width: 46, lean: 6, side: 1)
    framingTree(ctx, x: 706, width: 40, lean: -5, side: -1)

    // Ferns and grass along the bottom, thickest at the corners.
    for _ in 0..<26 {
        let corner = rng.next() < 0.5
        let x = corner ? rng.range(0, 150) : rng.range(570, 720)
        let up = -CGFloat.pi / 2 + (corner ? 1 : -1) * rng.range(0.15, 0.9)
        fern(ctx, at: CGPoint(x: x, y: 468), length: rng.range(40, 85), angle: up, color: mix(rgb(0x0E2614), lime, rng.range(0, 0.25)))
    }
    ctx.setLineWidth(1.1)
    for _ in 0..<260 {
        let x = rng.range(0, 720), h = rng.range(6, 20), lean = rng.range(-5, 5)
        ctx.setStrokeColor(mix(rgb(0x0B1E10), lime, rng.range(0, 0.3)))
        ctx.move(to: CGPoint(x: x, y: 461)); ctx.addQuadCurve(to: CGPoint(x: x + lean, y: 461 - h), control: CGPoint(x: x, y: 461 - h * 0.6)); ctx.strokePath()
    }

    // Fireflies.
    var placed = 0
    while placed < 46 {
        let p = CGPoint(x: rng.range(40, 680), y: rng.range(110, 445))
        guard !busy.contains(where: { $0.contains(p) }) else { continue }
        glow(ctx, p, rng.range(5, 11), rgb(0xDFF58A), rng.range(0.35, 0.7))
        ctx.setFillColor(rgb(0xF4FFD0, 0.95)); ctx.fillEllipse(in: CGRect(x: p.x - 0.9, y: p.y - 0.9, width: 1.8, height: 1.8))
        placed += 1
    }

    // Dotted trail from FileChanger to Applications, like the lizard's spine, ending in an arrowhead.
    let a = CGPoint(x: appIcon.x + 74, y: appIcon.y + 4), b = CGPoint(x: appsIcon.x - 82, y: appsIcon.y + 4)
    let ctl = CGPoint(x: 360, y: appIcon.y - 34)
    func bez(_ t: CGFloat) -> CGPoint {
        CGPoint(x: (1 - t) * (1 - t) * a.x + 2 * (1 - t) * t * ctl.x + t * t * b.x,
                y: (1 - t) * (1 - t) * a.y + 2 * (1 - t) * t * ctl.y + t * t * b.y)
    }
    for i in 0...26 {
        let p = bez(CGFloat(i) / 26), r: CGFloat = 2.6 + CGFloat(i) / 26 * 1.2
        glow(ctx, p, r * 3.2, rgb(0xC8EC5A), 0.45)
        ctx.setFillColor(rgb(0xE3F79A)); ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }
    let tip = CGPoint(x: b.x + 12, y: b.y + 3), back = bez(0.94)
    let d = CGPoint(x: tip.x - back.x, y: tip.y - back.y), l = hypot(d.x, d.y), u = CGPoint(x: d.x / l, y: d.y / l)
    ctx.move(to: tip)
    ctx.addLine(to: CGPoint(x: tip.x - u.x * 14 - u.y * 9, y: tip.y - u.y * 14 + u.x * 9))
    ctx.addLine(to: CGPoint(x: tip.x - u.x * 14 + u.y * 9, y: tip.y - u.y * 14 - u.x * 9))
    ctx.closePath(); ctx.setFillColor(rgb(0xE3F79A)); ctx.fillPath()
}

func drawText(_ ctx: CGContext) {
    let ph: CGFloat = 460
    ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 6, color: CGColor(gray: 0, alpha: 0.7))
    func attr(_ size: CGFloat, _ w: NSFont.Weight, _ a: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: w), .foregroundColor: NSColor(white: 1, alpha: a)]
    }
    let title = NSAttributedString(string: "Drag FileChanger onto Applications", attributes: attr(24, .semibold, 1))
    let line = CTLineCreateWithAttributedString(title)
    let tb = CTLineGetBoundsWithOptions(line, [])
    ctx.textPosition = CGPoint(x: 360 - tb.width / 2 - tb.minX, y: ph - 62 - (tb.height / 2 + tb.minY))
    CTLineDraw(line, ctx)
    let cap = NSAttributedString(string: "Or double-click Setup & Test to install it and run the self-test.", attributes: attr(13, .regular, 0.9))
    let fs = CTFramesetterCreateWithAttributedString(cap)
    let sz = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil, CGSize(width: 255, height: 200), nil)
    let rect = CGRect(x: 440, y: ph - 340 - sz.height / 2, width: 260, height: sz.height + 2)
    CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil), ctx)
}

func render(scale s: CGFloat) -> CGImage {
    let w = Int(720 * s), h = Int(460 * s)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    rng = RNG(s: 20261112)   // same scene at both sizes
    ctx.saveGState(); ctx.translateBy(x: 0, y: 460); ctx.scaleBy(x: 1, y: -1)   // scene is laid out y down
    drawScene(ctx)
    ctx.restoreGState()
    drawText(ctx)
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ name: String) {
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let url = outDir.appendingPathComponent(name)
    let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
    print("wrote \(url.path)  \(img.width)x\(img.height)")
}
writePNG(render(scale: 2), "background@2x.png")
let small = render(scale: 1)
writePNG(small, "background.png")

// Mean luma (0-255) under Finder's icon labels and the captions, to check the text stays readable.
let data = small.dataProvider!.data! as Data, bpr = small.bytesPerRow
func band(_ name: String, _ r: CGRect) {
    var sum = 0.0, n = 0.0
    for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) {
        let i = y * bpr + x * 4
        sum += 0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2]); n += 1
    } }
    print(String(format: "  %@ luma %.0f", name, sum / n))
}
band("app label  ", CGRect(x: 110, y: 265, width: 120, height: 25))
band("apps label ", CGRect(x: 490, y: 265, width: 120, height: 25))
band("setup label", CGRect(x: 290, y: 400, width: 140, height: 22))
band("title band ", CGRect(x: 160, y: 45, width: 400, height: 35))
band("caption    ", CGRect(x: 440, y: 325, width: 260, height: 30))
