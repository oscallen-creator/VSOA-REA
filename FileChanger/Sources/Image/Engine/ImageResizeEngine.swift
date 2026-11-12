import Foundation
import CoreGraphics

/// IMG-01..09. Pure size math plus the render/save step.
enum ImageResizeMode: String, CaseIterable, Sendable {
    case percentage, preset, longEdge, fit, original
    var label: String {
        switch self {
        case .percentage: return "Percentage"
        case .preset: return "Common sizes"
        case .longEdge: return "Long edge"
        case .fit: return "Width x height"
        case .original: return "Keep original dimensions"
        }
    }
}

/// Which side is shared by every image of a batch when proportions are kept.
enum ImageResizePriority: String, CaseIterable, Sendable {
    case fitInside, height, width
    var label: String {
        switch self { case .fitInside: return "Fit inside"; case .height: return "Same height"; case .width: return "Same width" }
    }
    var help: String {
        switch self {
        case .fitInside: return "Lock on: images fit inside the size."
        case .height: return "Every image gets the same height; widths follow each image's proportions."
        case .width: return "Every image gets the same width; heights follow each image's proportions."
        }
    }
}

struct ImageResizePreset: Hashable, Sendable {
    let name: String
    let width: Int
    let height: Int
    // ponytail: fixed list chosen by us (inventory marks it unknown); user-editable presets if asked.
    static let all: [ImageResizePreset] = [
        .init(name: "Icon 256", width: 256, height: 256), .init(name: "Thumbnail 640 x 480", width: 640, height: 480),
        .init(name: "SVGA 800 x 600", width: 800, height: 600), .init(name: "XGA 1024 x 768", width: 1024, height: 768),
        .init(name: "HD 1280 x 720", width: 1280, height: 720), .init(name: "Full HD 1920 x 1080", width: 1920, height: 1080),
        .init(name: "QHD 2560 x 1440", width: 2560, height: 1440), .init(name: "4K 3840 x 2160", width: 3840, height: 2160),
        .init(name: "Square 1080", width: 1080, height: 1080),
    ]
}

struct ImageResizeSettings: Equatable, Sendable {
    var mode: ImageResizeMode = .percentage
    var percentage: Double = 50
    var preset: ImageResizePreset = ImageResizePreset.all[4]
    var longEdge: Int = 1600
    var width: Int = 1920
    var height: Int = 1080
    var keepProportions = true
    var unitPercent = false      // fit mode: width/height are % of each original
    var priority: ImageResizePriority = .fitInside

    static let percentagePresets: [Double] = [10, 25, 50, 75, 150, 200, 300]
    static let percentageRange: ClosedRange<Double> = 1...1000
    static let longEdgePresets = [480, 800, 1080, 1280, 1600, 2048, 2560, 3840]
}

enum ImageResizeEngine {
    static let animationMessage = "Choose original dimensions to preserve this image's animation."

    /// Output size for one source image (IMG-02..07).
    static func targetSize(for src: CGSize, _ s: ImageResizeSettings) throws -> (width: Int, height: Int) {
        let sw = Double(src.width), sh = Double(src.height)
        guard sw >= 1, sh >= 1 else { throw FileChangerError.failed("Could not create the resized image.") }
        var w = sw, h = sh
        switch s.mode {
        case .original: break
        case .percentage:
            guard ImageResizeSettings.percentageRange.contains(s.percentage) else {
                throw FileChangerError.failed("Choose a percentage from 1% to 1000%.")
            }
            w = sw * s.percentage / 100; h = sh * s.percentage / 100
        case .longEdge:
            guard s.longEdge >= 1 else { throw FileChangerError.failed("Enter a size of at least 1 pixel.") }
            let k = Double(s.longEdge) / max(sw, sh)
            w = sw * k; h = sh * k
        case .preset, .fit:
            let pct = s.mode == .fit && s.unitPercent
            let tw = pct ? sw * Double(s.width) / 100 : Double(s.mode == .preset ? s.preset.width : s.width)
            let th = pct ? sh * Double(s.height) / 100 : Double(s.mode == .preset ? s.preset.height : s.height)
            guard tw >= 1, th >= 1 else { throw FileChangerError.failed("Enter a size of at least 1 pixel.") }
            if !s.keepProportions && s.mode == .fit { w = tw; h = th; break }
            switch s.priority {
            case .fitInside: let k = min(tw / sw, th / sh); w = sw * k; h = sh * k
            case .height: h = th; w = sw * th / sh
            case .width: w = tw; h = sh * tw / sw
            }
        }
        let rw = max(1, Int(w.rounded())), rh = max(1, Int(h.rounded()))
        if rw > ImageFiles.maxSide || rh > ImageFiles.maxSide {
            throw FileChangerError.failed("Keep each side at most \(ImageFiles.maxSide) pixels.")
        }
        if rw == Int(sw) && rh == Int(sh) { throw FileChangerError.failed("Change the size to resize.") }
        return (rw, rh)
    }

    static func resized(_ image: CGImage, to size: (width: Int, height: Int)) throws -> CGImage {
        guard let out = ImageFiles.render(size.width, size.height, space: ImageFiles.space(for: image), { ctx in
            ctx.interpolationQuality = .high
            ImageFiles.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height), ctx)
        }) else { throw FileChangerError.failed("Could not create the resized image.") }
        return out
    }

    static func resize(_ url: URL, _ settings: ImageResizeSettings, progress: ProgressHandler) async throws -> URL {
        if ImageFiles.isAnimated(url) {
            guard settings.mode == .original else { throw FileChangerError.unsupported(animationMessage) }
            let dest = OutputLocation.sibling(of: url, suffix: "-resized")
            try await OutputLocation.writeAtomically(to: dest) { try FileManager.default.copyItem(at: url, to: $0) }
            return dest
        }
        let image = try ImageFiles.load(url)
        progress(0.2)
        let size = try targetSize(for: CGSize(width: image.width, height: image.height), settings)
        let out = try resized(image, to: size)
        progress(0.7)
        let fmt = ImageFiles.format(forExtension: url.pathExtension)
        if fmt.type == .png {
            do { return try await ImageFiles.save(out, beside: url, suffix: "-resized", format: fmt) }
            catch { throw FileChangerError.failed("Could not save the resized PNG.") }
        }
        return try await ImageFiles.save(out, beside: url, suffix: "-resized", format: fmt)
    }
}
