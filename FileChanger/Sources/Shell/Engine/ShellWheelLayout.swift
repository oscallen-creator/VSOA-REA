import AppKit
import CoreGraphics
import Foundation

/// Geometry of a wheel: petals laid in one ring (up to 10) or two rings, starting at 12 o'clock and
/// running clockwise. Pure maths so hit-testing and drawing share it. Angles are in radians,
/// measured clockwise from 12 o'clock; y grows downward (flip when feeding AppKit coordinates).
struct ShellWheelLayout {
    struct Petal: Equatable {
        let index: Int
        let innerRadius: CGFloat
        let outerRadius: CGFloat
        let startAngle: CGFloat   // clockwise from top
        let endAngle: CGFloat
        var midAngle: CGFloat { (startAngle + endAngle) / 2 }
        var midRadius: CGFloat { (innerRadius + outerRadius) / 2 }
    }

    static let hubRadius: CGFloat = 58
    static let ringWidth: CGFloat = 54
    static let ringGap: CGFloat = 4
    static let singleRingLimit = 10

    let count: Int
    let petals: [Petal]
    /// Outer edge of the whole wheel.
    let radius: CGFloat

    init(count: Int) {
        self.count = count
        guard count > 0 else { petals = []; radius = Self.hubRadius; return }
        var result: [Petal] = []
        var rings: [Int]
        if count <= Self.singleRingLimit { rings = [count] }
        else { let inner = count / 2; rings = [inner, count - inner] }
        var index = 0
        var r = Self.hubRadius + 6
        for n in rings {
            let width = Self.ringWidth
            for i in 0..<n {
                let a0 = 2 * .pi * CGFloat(i) / CGFloat(n)
                let a1 = 2 * .pi * CGFloat(i + 1) / CGFloat(n)
                result.append(Petal(index: index, innerRadius: r, outerRadius: r + width, startAngle: a0, endAngle: a1))
                index += 1
            }
            r += width + Self.ringGap
        }
        petals = result
        radius = r - Self.ringGap
    }

    /// Centre of a petal's label relative to the wheel centre (y down).
    func labelOffset(of petal: Petal) -> CGPoint {
        CGPoint(x: sin(petal.midAngle) * petal.midRadius, y: -cos(petal.midAngle) * petal.midRadius)
    }

    /// Petal under `offset` (relative to the wheel centre, y down), or nil in the hub / outside.
    func hit(_ offset: CGPoint) -> Int? {
        let d = hypot(offset.x, offset.y)
        guard d >= Self.hubRadius, d <= radius + 10 else { return nil }
        var a = atan2(offset.x, -offset.y)          // clockwise from top
        if a < 0 { a += 2 * .pi }
        // Gaps between rings count towards the nearest ring so the hover does not flicker.
        let candidates = petals.filter { d >= $0.innerRadius - Self.ringGap && d <= $0.outerRadius + Self.ringGap }
        return candidates.first { a >= $0.startAngle && a < $0.endAngle }?.index
    }

    /// Wheel frame size needed around the centre, including shadow margin.
    var diameter: CGFloat { (radius + 24) * 2 }
}

/// Orders items by group (first appearance of each group wins) and keeps order inside a group.
func shellGroupedOrder<T>(_ items: [T], group: (T) -> String) -> [T] {
    var order: [String] = []
    for i in items { let g = group(i); if !order.contains(g) { order.append(g) } }
    return order.flatMap { g in items.filter { group($0) == g } }
}

/// Title-cases an all-caps wheel label but keeps acronyms: "MERGE PDFS" -> "Merge PDFs", "READ QR CODES" -> "Read QR Codes".
func shellDisplayLabel(_ raw: String) -> String {
    let acronyms: Set<String> = ["PDF", "QR", "BG", "MP3", "MP4", "GIF", "OCR", "PNG", "JPG", "HEIC", "WEBP", "SRT", "PDFA", "PDF/A"]
    return raw.split(separator: " ").map { w -> String in
        let u = w.uppercased()
        if acronyms.contains(u) { return u }
        if u.hasSuffix("S"), acronyms.contains(String(u.dropLast())) { return String(u.dropLast()) + "s" }
        return u.prefix(1) + u.dropFirst().lowercased()
    }.joined(separator: " ")
}

/// The drag operation to answer a drag session with: one the source allows, preferring copy.
/// Finder with Command held offers only move, and answering .copy would make it refuse the drop.
func shellDragOperation(allowed: NSDragOperation) -> NSDragOperation {
    for op in [NSDragOperation.copy, .generic, .move, .link] where allowed.contains(op) { return op }
    return []
}
