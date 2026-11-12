import SwiftUI

/// IMG-30..32. Add BG.
struct FrameEditor: View {
    enum Kind: String, CaseIterable { case solid = "Solid", gradient = "Gradient", custom = "Custom", image = "Image", blur = "Blur" }
    let files: [URL]
    @State private var photo: CGImage?
    @State private var shown: CGImage?
    @State private var o = FrameOptions()
    @State private var kind: Kind = .gradient
    @State private var custom = Color.white
    @State private var imageURL: URL?
    @State private var problem: String?
    @Environment(\.toolPanel) private var panel

    private func effective() -> FrameOptions {
        var f = o
        switch kind {
        case .custom: f.background = .custom(custom.imageRGBA)
        case .blur: f.background = .blur
        case .image: f.background = .image(imageURL ?? URL(fileURLWithPath: "/nonexistent"))
        default: break
        }
        return f
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Group {
                    if let s = shown ?? photo { previewImage(s).resizable().scaledToFit().padding(10) } else { ProgressView() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("frameImagePreview")
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Background", selection: $kind) { ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        if kind == .solid || kind == .gradient {
                            let items = FrameBackgroundPreset.all.filter { $0.isGradient == (kind == .gradient) }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 6)], spacing: 6) {
                                ForEach(items) { p in
                                    Button { o.background = .preset(p) } label: {
                                        RoundedRectangle(cornerRadius: 6).fill(swatch(p)).frame(width: 30, height: 30)
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(o.background == .preset(p) ? Brand.accent : .gray.opacity(0.3), lineWidth: 2))
                                    }.buttonStyle(.plain).help(p.name.capitalized)
                                }
                            }.accessibilityIdentifier(kind == .solid ? "frameSolidColorStrip" : "frameGradientStrip")
                        }
                        if kind == .custom { ColorPicker("Custom background", selection: $custom).help("Choose a custom background color") }
                        if kind == .image {
                            Button(imageURL == nil ? "Choose image background" : "Change image background") {
                                if let u = chooseImages(multiple: false, message: "Choose an image background").first { imageURL = u }
                            }
                            if let u = imageURL { Text(u.lastPathComponent).font(.caption).foregroundStyle(.secondary) }
                        }
                        Picker("Ratio", selection: $o.ratio) { ForEach(FrameCanvasRatio.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                            .accessibilityIdentifier("frameImageRatio")
                        ValueSlider(title: "Padding", value: $o.padding, range: FrameOptions.paddingRange, format: { String(format: "%.0f%%", $0) })
                        ValueSlider(title: "Corners", value: $o.corners, range: FrameOptions.cornerRange, format: { String(format: "%.0f%%", $0) })
                        ValueSlider(title: "Shadow", value: $o.shadow, range: FrameOptions.shadowRange)
                    }.padding(12)
                }.frame(width: 250)
            }
            Divider()
            ToolFooter(primary: "Save with Background", message: problem, reset: { o = FrameOptions(); kind = .gradient }) { save() }
        }
        .onChange(of: kind) { _, k in
            if k == .solid || k == .gradient, case .preset(let p) = o.background, p.isGradient == (k == .gradient) { return }
            if k == .solid || k == .gradient, let first = FrameBackgroundPreset.all.first(where: { $0.isGradient == (k == .gradient) }) { o.background = .preset(first) }
        }
        .task { photo = await loadPreview(files[0], maxPixel: 900) }
        .task(id: [AnyHashable(effective()), AnyHashable(photo?.width ?? 0)]) {
            guard let photo else { return }
            let opts = effective()
            do { shown = try await Task.detached { try ImageFrameEngine.render(photo, opts) }.value; problem = nil }
            catch { problem = error.localizedDescription }
        }
    }

    private func swatch(_ p: FrameBackgroundPreset) -> AnyShapeStyle {
        if p.isGradient {
            return AnyShapeStyle(LinearGradient(colors: ([p.base] + p.blobs).map { Color(ImageRGBA(hex: $0)) }, startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        return AnyShapeStyle(Color(ImageRGBA(hex: p.base)))
    }

    private func save() {
        let opts = effective()
        runImageJob(title: "Adding background", files: files, close: panel.close) { url, p in try await ImageFrameEngine.addBackground(url, opts, progress: p) }
    }
}
