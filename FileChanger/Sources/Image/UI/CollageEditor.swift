import SwiftUI

/// IMG-28/29. Create Collage.
struct CollageEditor: View {
    @State private var files: [URL]
    private let dropOrder: [URL]
    @State private var o = CollageOptions()
    @State private var color = Color.white
    @State private var bgKind = 0   // 0 white, 1 transparent, 2 colour
    @State private var sources: [URL: CGImage] = [:]
    @State private var shown: CGImage?
    @State private var problem: String?
    @Environment(\.toolPanel) private var panel

    init(files: [URL]) { _files = State(initialValue: files); dropOrder = files }

    private func effective() -> CollageOptions {
        var f = o
        f.background = bgKind == 0 ? .white : (bgKind == 1 ? .transparent : .color(color.imageRGBA))
        return f
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Group {
                    if let s = shown { previewImage(s).resizable().scaledToFit().padding(10).background(Checker()) }
                    else { Text(problem ?? "").foregroundStyle(.secondary).padding() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("Image order").font(.headline); Spacer()
                            Button("Add images") { files += chooseImages(multiple: true) }.controlSize(.small) }
                        List {
                            ForEach(files, id: \.self) { f in
                                HStack { Text(f.lastPathComponent).lineLimit(1).truncationMode(.middle); Spacer()
                                    Button { files.removeAll { $0 == f } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless) }
                            }.onMove { files.move(fromOffsets: $0, toOffset: $1) }
                        }.frame(height: 110)
                        Button("Reset Layout") { o = CollageOptions(); bgKind = 0; files = dropOrder }.controlSize(.small)
                        Picker("Style", selection: $o.style) { ForEach(CollageStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        if o.style == .grid { Stepper("Width: \(o.columns) across", value: $o.columns, in: CollageOptions.columnRange) }
                        Picker("Image fit", selection: $o.fillImage) { Text("Fill cells (crop edges)").tag(true); Text("Fit whole images").tag(false) }
                        Picker("Canvas", selection: $o.canvas) { ForEach(CollageCanvas.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                            .disabled(o.style != .grid)
                        Text("Spacing & background").font(.headline)
                        ValueSlider(title: "Image width px", value: Binding(get: { Double(o.imageWidth) }, set: { o.imageWidth = Int($0) }),
                                    range: Double(CollageOptions.imageWidthRange.lowerBound)...Double(CollageOptions.imageWidthRange.upperBound), neutral: 600)
                        ValueSlider(title: "Spacing", value: Binding(get: { Double(o.spacing) }, set: { o.spacing = Int($0) }),
                                    range: Double(CollageOptions.spacingRange.lowerBound)...Double(CollageOptions.spacingRange.upperBound), neutral: 16)
                        ValueSlider(title: "Padding", value: Binding(get: { Double(o.padding) }, set: { o.padding = Int($0) }),
                                    range: Double(CollageOptions.paddingRange.lowerBound)...Double(CollageOptions.paddingRange.upperBound), neutral: 24)
                        ValueSlider(title: "Corners", value: Binding(get: { Double(o.cornerRadius) }, set: { o.cornerRadius = Int($0) }),
                                    range: Double(CollageOptions.cornerRange.lowerBound)...Double(CollageOptions.cornerRange.upperBound), neutral: 12)
                        Picker("Background", selection: $bgKind) { Text("White").tag(0); Text("Transparent").tag(1); Text("Color").tag(2) }
                        if bgKind == 2 { ColorPicker("Background color", selection: $color) }
                    }.padding(12)
                }.frame(width: 270)
            }
            Divider()
            ToolFooter(primary: "Create Collage", isEnabled: files.count >= 2 && problem == nil, message: problem) { save() }
        }
        .task(id: files) {
            for f in files where sources[f] == nil { sources[f] = await loadPreview(f, maxPixel: 700) }
        }
        .task(id: [AnyHashable(effective()), AnyHashable(files), AnyHashable(sources.count)]) { await refresh() }
    }

    private func refresh() async {
        let imgs = files.compactMap { sources[$0] }
        guard imgs.count == files.count, !imgs.isEmpty else { return }
        let opts = effective()
        do {
            let (canvas, _) = try ImageCollageEngine.layout(aspects: imgs.map { CGFloat($0.width) / CGFloat($0.height) }, opts)
            let k = min(1, 700 / max(canvas.width, canvas.height))
            var p = opts
            p.imageWidth = max(8, Int(Double(opts.imageWidth) * k)); p.spacing = Int(Double(opts.spacing) * k)
            p.padding = Int(Double(opts.padding) * k); p.cornerRadius = Int(Double(opts.cornerRadius) * k)
            shown = try await Task.detached { try ImageCollageEngine.render(imgs, p) }.value
            problem = nil
        } catch { problem = error.localizedDescription; shown = nil }
    }

    private func save() {
        let opts = effective(), list = files
        close(); Task { @MainActor in
            await Operations.runCombined(title: "Creating collage", files: list) { urls, p in try await ImageCollageEngine.create(urls, opts, progress: p) }
        }
    }
    private func close() { panel.close() }
}

/// Checkerboard behind transparent previews.
struct Checker: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 10
            for y in 0..<Int(size.height / s) + 1 { for x in 0..<Int(size.width / s) + 1 where (x + y) % 2 == 0 {
                ctx.fill(Path(CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: s, height: s)), with: .color(.gray.opacity(0.15)))
            } }
        }
    }
}
