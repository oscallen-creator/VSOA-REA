// Draws FileChanger's original app icon (an orange squircle with a document and a circular "change" arrow)
// and writes Resources/AppIcon.icns.  Run: swift scripts/make-icon.swift   (needs /usr/bin/iconutil)
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("FileChanger.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: 824/1024 body with soft shadow margin.
    let inset = s * 0.098, body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 1, green: 0.55, blue: 0.16, alpha: 1),
                        NSColor(srgbRed: 1, green: 0.322, blue: 0, alpha: 1)])!.draw(in: squircle, angle: -90)

    // Document sheet with folded corner.
    let w = body.width * 0.42, h = body.width * 0.52
    let doc = NSRect(x: body.midX - w / 2, y: body.midY - h / 2, width: w, height: h)
    let fold = w * 0.28
    let sheet = NSBezierPath()
    sheet.move(to: NSPoint(x: doc.minX, y: doc.minY))
    sheet.line(to: NSPoint(x: doc.maxX, y: doc.minY))
    sheet.line(to: NSPoint(x: doc.maxX, y: doc.maxY - fold))
    sheet.line(to: NSPoint(x: doc.maxX - fold, y: doc.maxY))
    sheet.line(to: NSPoint(x: doc.minX, y: doc.maxY))
    sheet.close()
    NSColor.white.setFill(); sheet.fill()

    // Circular arrow ("change") inside the sheet.
    let c = NSPoint(x: doc.midX, y: doc.midY - h * 0.04), r = w * 0.26
    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: r, startAngle: 120, endAngle: 420)
    arc.lineWidth = w * 0.09
    arc.lineCapStyle = .round
    NSColor(srgbRed: 1, green: 0.322, blue: 0, alpha: 1).setStroke(); arc.stroke()
    let tip = NSPoint(x: c.x + r * cos(.pi * 60 / 180), y: c.y + r * sin(.pi * 60 / 180))
    let head = NSBezierPath()
    let a = w * 0.13
    head.move(to: NSPoint(x: tip.x + a * 0.9, y: tip.y + a * 0.2))
    head.line(to: NSPoint(x: tip.x - a * 0.5, y: tip.y + a * 0.75))
    head.line(to: NSPoint(x: tip.x - a * 0.25, y: tip.y - a * 0.75))
    head.close()
    NSColor(srgbRed: 1, green: 0.322, blue: 0, alpha: 1).setFill(); head.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
