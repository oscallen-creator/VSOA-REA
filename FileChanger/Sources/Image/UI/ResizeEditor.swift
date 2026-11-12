import SwiftUI

/// IMG-01..09. Resize Images.
struct ResizeEditor: View {
    let files: [URL]
    @State private var s = ImageResizeSettings()
    @AppStorage("imageResizeKeepsProportions") private var keepProportions = true
    @State private var sizes: [URL: CGSize] = [:]
    @State private var thumbs: [URL: CGImage] = [:]
    @Environment(\.toolPanel) private var panel

    private func result(for url: URL) -> (text: String, ok: Bool) {
        guard let src = sizes[url] else { return ("Reading...", false) }
        if ImageFiles.isAnimated(url) && s.mode != .original { return (ImageResizeEngine.animationMessage, false) }
        var t = s; t.keepProportions = keepProportions
        do {
            let r = try ImageResizeEngine.targetSize(for: src, t)
            let bigger = r.width > Int(src.width) || r.height > Int(src.height)
            return ("\(r.width) x \(r.height)" + (bigger ? " (Upscale)" : " (Downscale)"), true)
        } catch { return (error.localizedDescription, false) }
    }

    private var firstProblem: String? {
        files.compactMap { u -> String? in let r = result(for: u); return r.ok ? nil : r.text }.first
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Resize by", selection: $s.mode) {
                    ForEach(ImageResizeMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }.accessibilityIdentifier("imageResizeMode")
                switch s.mode {
                case .percentage:
                    HStack {
                        Text("Resize percentage")
                        Spacer()
                        TextField("Resize percentage", value: $s.percentage, format: .number.precision(.fractionLength(0...1)))
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 70)
                        Text("%")
                        Menu {
                            ForEach(ImageResizeSettings.percentagePresets, id: \.self) { p in Button("\(Int(p))%") { s.percentage = p } }
                        } label: { Image(systemName: "chevron.up.chevron.down") }
                        .menuStyle(.borderlessButton).fixedSize().help("Common percentages").accessibilityLabel("Percentage presets")
                    }
                case .preset:
                    Picker("Common sizes", selection: $s.preset) {
                        ForEach(ImageResizePreset.all, id: \.self) { Text($0.name).tag($0) }
                    }.accessibilityLabel("Size presets")
                    Text("Each image is sized to the preset.").font(.caption).foregroundStyle(.secondary)
                    proportionsControls
                case .longEdge:
                    HStack {
                        IntField(title: "Long edge in pixels", value: $s.longEdge, width: 80)
                        Text("px long edge")
                        Menu {
                            ForEach(ImageResizeSettings.longEdgePresets, id: \.self) { p in Button("\(p) px") { s.longEdge = p } }
                        } label: { Image(systemName: "chevron.up.chevron.down") }.menuStyle(.borderlessButton).fixedSize()
                    }
                case .fit:
                    HStack {
                        IntField(title: "Width in pixels", value: $s.width, width: 80)
                        Text("x")
                        IntField(title: "Height in pixels", value: $s.height, width: 80)
                        Picker("Unit", selection: $s.unitPercent) { Text("px").tag(false); Text("%").tag(true) }
                            .labelsHidden().frame(width: 60)
                        Spacer()
                        Button { keepProportions.toggle() } label: {
                            Label(keepProportions ? "Keep proportions on" : "Keep proportions off", systemImage: keepProportions ? "lock.fill" : "lock.open")
                        }
                        .help(keepProportions ? "Proportions are kept. Click to stretch width and height separately."
                                              : "Width and height stretch separately. Click to keep proportions.")
                        .accessibilityIdentifier("imageResizeProportions")
                    }
                    Text(keepProportions ? "Lock on: images fit inside the size." : "Lock off: images stretch to the size.")
                        .font(.caption).foregroundStyle(.secondary)
                    if keepProportions && files.count > 1 { priorityPicker }
                case .original:
                    Text("Keep original dimensions").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden).frame(maxHeight: 280)
            Divider()
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(files, id: \.self) { f in
                        let r = result(for: f)
                        HStack {
                            Group {
                                if let t = thumbs[f] { previewImage(t).resizable().scaledToFill() } else { Image(systemName: "photo").foregroundStyle(.secondary) }
                            }.frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading) {
                                Text(f.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                if let sz = sizes[f] { Text("\(Int(sz.width)) x \(Int(sz.height))").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(r.text).font(.callout).foregroundStyle(r.ok ? Color.primary : Color.red).lineLimit(2).multilineTextAlignment(.trailing)
                        }
                        .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(12)
            }
            Divider()
            ToolFooter(primary: "Resize", isEnabled: files.contains { result(for: $0).ok },
                       message: firstProblem) { save() }
        }
        .task { for f in files { sizes[f] = ImageFiles.displaySize(f); thumbs[f] = await loadPreview(f, maxPixel: 96) } }
    }

    private var proportionsControls: some View {
        Group { if files.count > 1 { priorityPicker } }
    }

    private var priorityPicker: some View {
        Picker("Priority", selection: $s.priority) {
            ForEach(ImageResizePriority.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .help(s.priority.help).accessibilityIdentifier("imageResizePriority")
    }

    private func save() {
        var settings = s; settings.keepProportions = keepProportions
        runImageJob(title: "Resizing images", files: files, close: panel.close) { url, progress in
            try await ImageResizeEngine.resize(url, settings, progress: progress)
        }
    }
}
