import Foundation
import CoreGraphics

/// IMG-15..18 and the arrow-key nudging of the crop fields. Rects are in image pixels, origin top-left.
enum CropHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

enum CropRatio: String, CaseIterable, Sendable {
    case free = "Free", original = "Original", square = "1:1", r43 = "4:3", r34 = "3:4", r32 = "3:2", r23 = "2:3", r169 = "16:9", r916 = "9:16"
    /// width / height; nil when the crop is unconstrained. `original` needs the image size.
    func value(imageSize: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return imageSize.width / max(1, imageSize.height)
        case .square: return 1
        case .r43: return 4.0 / 3
        case .r34: return 3.0 / 4
        case .r32: return 3.0 / 2
        case .r23: return 2.0 / 3
        case .r169: return 16.0 / 9
        case .r916: return 9.0 / 16
        }
    }
}

enum ImageCropEngine {
    static let outsideMessage = "Keep the crop inside the image."
    static let tinyMessage = "The crop must be at least 1 x 1 pixel."

    /// Arrow-key / scrub step: 5 px, Shift 25 px, Option 1 px (inventory: "Shift for bigger steps or Option for single pixels").
    static func nudgeStep(shift: Bool, option: Bool) -> CGFloat { option ? 1 : (shift ? 25 : 5) }

    static func validate(_ r: CGRect, in size: CGSize) throws {
        guard r.width >= 1, r.height >= 1 else { throw FileChangerError.failed(tinyMessage) }
        guard r.minX >= 0, r.minY >= 0, r.maxX <= size.width + 0.001, r.maxY <= size.height + 0.001 else {
            throw FileChangerError.failed(outsideMessage)
        }
    }

    /// Keeps `r` inside the image (moving it, then shrinking if it is bigger than the image).
    static func clamped(_ r: CGRect, in size: CGSize) -> CGRect {
        var o = r
        o.size.width = min(max(1, o.width), size.width); o.size.height = min(max(1, o.height), size.height)
        o.origin.x = min(max(0, o.minX), size.width - o.width); o.origin.y = min(max(0, o.minY), size.height - o.height)
        return o
    }

    /// Crop that covers `ratio` as much of the image as fits, centred.
    static func fitted(ratio: CGFloat, in size: CGSize) -> CGRect {
        var w = size.width, h = w / ratio
        if h > size.height { h = size.height; w = h * ratio }
        return CGRect(x: ((size.width - w) / 2).rounded(), y: ((size.height - h) / 2).rounded(), width: w.rounded(), height: h.rounded())
    }

    /// Drag a handle by `delta` (pixels). With a ratio, the dragged corner/edge keeps it.
    static func resize(_ r: CGRect, handle: CropHandle, delta: CGPoint, in size: CGSize, ratio: CGFloat? = nil) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch handle {
        case .left, .topLeft, .bottomLeft: minX += delta.x
        case .right, .topRight, .bottomRight: maxX += delta.x
        default: break
        }
        switch handle {
        case .top, .topLeft, .topRight: minY += delta.y
        case .bottom, .bottomLeft, .bottomRight: maxY += delta.y
        default: break
        }
        minX = min(max(0, minX), maxX - 1); maxX = min(max(minX + 1, maxX), size.width)
        minY = min(max(0, minY), maxY - 1); maxY = min(max(minY + 1, maxY), size.height)
        var out = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let ratio else { return out }
        // Re-derive the free side from the moved one, anchored at the opposite edge/corner.
        let horizontal = [.left, .right, .topLeft, .topRight, .bottomLeft, .bottomRight].contains(handle)
        var w = horizontal ? out.width : out.height * ratio
        var h = horizontal ? out.width / ratio : out.height
        let anchorLeft = ![.left, .topLeft, .bottomLeft].contains(handle)
        let anchorTop = ![.top, .topLeft, .topRight].contains(handle)
        let maxW = anchorLeft ? size.width - r.minX : r.maxX, maxH = anchorTop ? size.height - r.minY : r.maxY
        if w > maxW { w = maxW; h = w / ratio }
        if h > maxH { h = maxH; w = h * ratio }
        w = max(1, w); h = max(1, h)
        let x = (handle == .top || handle == .bottom) ? r.midX - w / 2 : (anchorLeft ? r.minX : r.maxX - w)
        let y = (handle == .left || handle == .right) ? r.midY - h / 2 : (anchorTop ? r.minY : r.maxY - h)
        out = clamped(CGRect(x: x, y: y, width: w, height: h), in: size)
        return out
    }

    /// The same share of another image (the "use this crop for every image" toggle).
    static func proportional(_ r: CGRect, from: CGSize, to: CGSize) -> CGRect {
        let sx = to.width / from.width, sy = to.height / from.height
        let x = (r.minX * sx).rounded(), y = (r.minY * sy).rounded()
        let w = max(1, (r.width * sx).rounded()), h = max(1, (r.height * sy).rounded())
        return clamped(CGRect(x: x, y: y, width: w, height: h), in: to)
    }

    static func cropped(_ image: CGImage, _ r: CGRect) throws -> CGImage {
        try validate(r, in: CGSize(width: image.width, height: image.height))
        guard let out = image.cropping(to: r.integral) else { throw FileChangerError.failed("Could not crop the image.") }
        return out
    }

    static func crop(_ url: URL, rect: CGRect, referenceSize: CGSize?, progress: ProgressHandler) async throws -> URL {
        let image = try ImageFiles.load(url)
        let size = CGSize(width: image.width, height: image.height)
        let r = (referenceSize != nil && referenceSize != size) ? proportional(rect, from: referenceSize!, to: size) : rect
        progress(0.5)
        return try await ImageFiles.save(try cropped(image, r), beside: url, suffix: "-cropped")
    }
}
