// Draws FileChanger's original app icon (a black lizard whose tail curls into a spiral, with a dotted spine, on a
// lime squircle) and the same lizard as the menu-bar template. Writes Resources/AppIcon.icns and
// Resources/MenuBarIcon.png / MenuBarIcon@2x.png.   Run: swift scripts/make-icon.swift   (needs /usr/bin/iconutil)
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let lime = NSColor(srgbRed: 162 / 255, green: 201 / 255, blue: 35 / 255, alpha: 1)   // #A2C923, Brand.accent
let ink = NSColor(srgbRed: 0.07, green: 0.08, blue: 0.06, alpha: 1)

// MARK: - Lizard, in a unit square (y up)

func v(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func + (a: CGPoint, b: CGPoint) -> CGPoint { v(a.x + b.x, a.y + b.y) }
func - (a: CGPoint, b: CGPoint) -> CGPoint { v(a.x - b.x, a.y - b.y) }
func * (a: CGPoint, k: CGFloat) -> CGPoint { v(a.x * k, a.y * k) }
func unit(_ a: CGPoint) -> CGPoint { let l = max(1e-9, hypot(a.x, a.y)); return v(a.x / l, a.y / l) }
func rot(_ a: CGPoint, _ deg: CGFloat) -> CGPoint {
    let r = deg * .pi / 180
    return v(a.x * cos(r) - a.y * sin(r), a.x * sin(r) + a.y * cos(r))
}

// The spine runs from the neck (q = 0, upper right) clockwise once around the icon as a near-circular ring,
// then the tail tightens into a spiral in the middle (q = 1).
let centre = v(0.465, 0.49)
let theta0: CGFloat = 50 * .pi / 180
let sweep: CGFloat = 700 * .pi / 180
let r0: CGFloat = 0.335, r1: CGFloat = 0.026

func spine(_ q: CGFloat) -> CGPoint {
    let th = theta0 - sweep * q
    // Starts as a ring, then winds inward quickly enough to leave room for the inner legs; smooth at both ends.
    let s = max(0, (q - 0.05) / 0.95), smooth = s * s * (3 - 2 * s), fast = 1 - (1 - s) * (1 - s)
    let r = r1 + (r0 - r1) * (1 - ((1 - s) * smooth + s * fast))
    return v(centre.x + r * cos(th), centre.y + r * sin(th))
}
func tangent(_ q: CGFloat) -> CGPoint { unit(spine(min(1, q + 0.002)) - spine(max(0, q - 0.002))) }   // toward the tail
func outward(_ q: CGFloat) -> CGPoint { rot(tangent(q), 90) }   // clockwise travel: left of travel is away from the centre

/// Body width: slim neck, full chest and hips, then a long tapering tail.
func width(_ q: CGFloat) -> CGFloat {
    let keys: [(CGFloat, CGFloat)] = [(0, 0.064), (0.04, 0.1), (0.09, 0.118), (0.17, 0.12), (0.24, 0.108), (0.3, 0.08)]
    if q >= 0.3 { let s = (q - 0.3) / 0.7; return 0.01 + (0.08 - 0.01) * pow(1 - s, 1.2) }
    for i in 1..<keys.count where q <= keys[i].0 {
        let (q0, w0) = keys[i - 1], (q1, w1) = keys[i]
        let t = (q - q0) / (q1 - q0), s = t * t * (3 - 2 * t)
        return w0 + (w1 - w0) * s
    }
    return 0.08
}

func ellipse(_ c: CGPoint, along d: CGPoint, length: CGFloat, width w: CGFloat) -> CGPath {
    var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: atan2(d.y, d.x))
    return CGPath(ellipseIn: CGRect(x: -length / 2, y: -w / 2, width: length, height: w), transform: &t)
}

func stroke(_ pts: [CGPoint], _ w: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addLines(between: pts)
    return p.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 4)
}

func dot(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil) }

/// One leg: upper limb, lower limb and four splayed toes with round pads. `side` is +1 outward, -1 inward;
/// `upper`/`lower` are the limb angles in degrees from straight out, positive toward the head.
func leg(at q: CGFloat, side: CGFloat, upper ua: CGFloat, lower la: CGFloat, scale k: CGFloat) -> [CGPath] {
    let fwd = tangent(q) * -1, out = outward(q) * side
    func dir(_ a: CGFloat) -> CGPoint { unit(out * cos(a * .pi / 180) + fwd * sin(a * .pi / 180)) }
    let shoulder = spine(q) + out * (width(q) * 0.25)
    let elbow = shoulder + dir(ua) * (0.085 * k)
    let wrist = elbow + dir(la) * (0.055 * k)
    var parts = [stroke([shoulder, elbow], 0.036 * k), stroke([elbow, wrist], 0.027 * k), dot(elbow, 0.02 * k)]
    for a: CGFloat in [-62, -22, 22, 62] {
        let tip = wrist + rot(dir(la), a * side) * (0.036 * k)
        parts.append(stroke([wrist, tip], 0.012 * k))
        parts.append(dot(tip, 0.0115 * k))
    }
    return parts
}

/// The silhouette as separate filled parts: filling each one keeps overlaps solid whatever their winding.
func lizard() -> [CGPath] {
    let n = 700
    var left: [CGPoint] = [], right: [CGPoint] = []
    for i in 0...n {
        let q = CGFloat(i) / CGFloat(n), c = spine(q), o = outward(q), w = width(q) / 2
        left.append(c + o * w); right.append(c - o * w)
    }
    let body = CGMutablePath()
    body.addLines(between: left + right.reversed()); body.closeSubpath()
    var parts: [CGPath] = [body, dot(spine(1), 0.005)]

    // The neck turns the head up and out toward the corner.
    let neck = spine(0), headDir = rot(tangent(0) * -1, -30)
    let headC = neck + headDir * 0.05
    parts.append(stroke([spine(0.04), neck, headC], 0.07))
    parts.append(ellipse(headC, along: headDir, length: 0.11, width: 0.1))
    parts.append(ellipse(headC + headDir * 0.04, along: headDir, length: 0.085, width: 0.068))   // snout

    parts += leg(at: 0.07, side: 1, upper: 25, lower: 70, scale: 1)
    parts += leg(at: 0.075, side: -1, upper: 40, lower: 78, scale: 0.7)
    parts += leg(at: 0.255, side: 1, upper: -30, lower: -75, scale: 1)
    parts += leg(at: 0.255, side: -1, upper: -35, lower: -70, scale: 0.8)
    return parts
}

/// Dots along the spine, from the shoulders to near the tail tip, spaced evenly along the curve.
func spineDots() -> [CGRect] {
    var out: [CGRect] = [], travelled: CGFloat = 0, prev = spine(0.02)
    let step: CGFloat = 0.024
    var q: CGFloat = 0.02
    while q < 0.93 {
        q += 0.0005
        let c = spine(q)
        travelled += hypot(c.x - prev.x, c.y - prev.y); prev = c
        guard travelled >= step else { continue }
        travelled = 0
        let r = max(0.0028, 0.0058 * sqrt(width(q) / 0.13))
        out.append(CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }
    return out
}

// MARK: - Rendering

func bitmap(_ px: Int, _ body: (CGContext, CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    body(g.cgContext, CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func appIcon(_ px: Int) -> Data {
    bitmap(px) { ctx, s in
        // macOS icon grid: 824/1024 body with a soft shadow margin.
        let inset = s * 0.098, body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.shadowBlurRadius = s * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008); shadow.set()
        lime.setFill(); squircle.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        NSGradient(colors: [NSColor(srgbRed: 0.75, green: 0.88, blue: 0.3, alpha: 1), lime,
                            NSColor(srgbRed: 0.52, green: 0.7, blue: 0.08, alpha: 1)])!.draw(in: squircle, angle: -90)

        let m = body.width * 0.04
        ctx.saveGState()
        ctx.translateBy(x: body.minX + m, y: body.minY + m)
        ctx.scaleBy(x: body.width - 2 * m, y: body.height - 2 * m)
        ctx.setShadow(offset: CGSize(width: 0, height: -0.006 * s), blur: 0.012 * s, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(ink.cgColor)
        for part in lizard() { ctx.addPath(part); ctx.fillPath() }
        ctx.endTransparencyLayer()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.setFillColor(lime.cgColor)
        if s >= 64 { for d in spineDots() { ctx.fillEllipse(in: d) } }   // dots are noise at tiny sizes
        ctx.restoreGState()
    }
}

/// Black silhouette on clear (no dots: at 18 pt they would only blur the shape); the app marks it as a template so macOS tints it for the menu bar.
func menuBarIcon(_ px: Int) -> Data {
    bitmap(px) { ctx, s in
        ctx.scaleBy(x: s, y: s)
        ctx.setFillColor(NSColor.black.cgColor)
        for part in lizard() { ctx.addPath(part); ctx.fillPath() }
    }
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("FileChanger.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! appIcon(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! appIcon(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let res = root.appendingPathComponent("Resources")
try! menuBarIcon(18).write(to: res.appendingPathComponent("MenuBarIcon.png"))
try! menuBarIcon(36).write(to: res.appendingPathComponent("MenuBarIcon@2x.png"))
let out = res.appendingPathComponent("AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out.path) and MenuBarIcon(@2x).png\npreview: \(iconset.path)/icon_512x512@2x.png" : "iconutil failed")
