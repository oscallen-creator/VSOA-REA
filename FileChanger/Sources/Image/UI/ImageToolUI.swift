import SwiftUI
import AppKit

/// Small shared pieces for the image tool editors.
@MainActor
func runImageJob(title: String, files: [URL], close: () -> Void,
                 job: @escaping @Sendable (URL, ProgressHandler) async throws -> URL) {
    close()
    Task { @MainActor in await Operations.run(title: title, files: files, job: job) }
}

func loadPreview(_ url: URL, maxPixel: Int = 1600) async -> CGImage? {
    await Task.detached(priority: .userInitiated) { try? ImageFiles.load(url, maxPixel: maxPixel) }.value
}

func previewImage(_ cg: CGImage) -> Image { Image(decorative: cg, scale: 1) }

/// Integer text field; arrow keys step by 1 (Option), 5, or 25 (Shift) like the crop nudging rules.
struct IntField: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 1...ImageFiles.maxSide
    var width: CGFloat = 64

    var body: some View {
        TextField(title, value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }), format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: width)
            .accessibilityLabel(title)
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                let step = Int(ImageCropEngine.nudgeStep(shift: press.modifiers.contains(.shift), option: press.modifiers.contains(.option)))
                value = min(max(value + (press.key == .upArrow ? step : -step), range.lowerBound), range.upperBound)
                return .handled
            }
    }
}

/// Slider row with a label, a formatted value and a per-slider Reset.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var neutral: Double = 0
    var format: (Double) -> String = { String(format: "%.0f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(format(value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Reset") { value = neutral }.buttonStyle(.borderless).font(.caption).disabled(value == neutral)
            }
            Slider(value: $value, in: range).tint(Brand.accent).accessibilityLabel(title)
        }
    }
}

extension Color {
    init(_ c: ImageRGBA) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }
    var imageRGBA: ImageRGBA {
        let n = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return ImageRGBA(r: Double(n.redComponent), g: Double(n.greenComponent), b: Double(n.blueComponent), a: Double(n.alphaComponent))
    }
}

/// Image fitted into the available space; reports where the picture sits so overlays can map coordinates.
struct FittedImage<Overlay: View>: View {
    let image: CGImage
    var zoom: CGFloat = 1
    @ViewBuilder let overlay: (_ frame: CGRect, _ scale: CGFloat) -> Overlay   // scale = view points per image pixel

    var body: some View {
        GeometryReader { geo in
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let fit = min(geo.size.width / iw, geo.size.height / ih) * zoom
            let w = iw * fit, h = ih * fit
            let frame = CGRect(x: max(0, (geo.size.width - w) / 2), y: max(0, (geo.size.height - h) / 2), width: w, height: h)
            ZStack(alignment: .topLeading) {
                previewImage(image).resizable().interpolation(.medium).frame(width: w, height: h).offset(x: frame.minX, y: frame.minY)
                overlay(frame, fit)
            }
            .frame(width: max(geo.size.width, w), height: max(geo.size.height, h), alignment: .topLeading)
        }
    }
}

/// Native open panel for choosing image files.
@MainActor
func chooseImages(multiple: Bool, message: String = "Choose images") -> [URL] {
    let p = NSOpenPanel()
    p.allowsMultipleSelection = multiple; p.canChooseDirectories = false; p.allowedContentTypes = [.image]; p.message = message
    p.level = .modalPanel
    return p.runModal() == .OK ? p.urls : []
}
