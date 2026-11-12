import SwiftUI

/// Settings > Formats pane (SHL-81): per-output-format conversion defaults. The shell embeds it in the Settings window.
struct ConversionFormatsSettingsView: View {
    @State private var query = ""
    @State private var selected: ConversionFormat = .jpg
    @State private var refresh = 0
    @AppStorage("defaultVideoCompressionStrength") private var videoStrength = "balanced"
    @AppStorage("defaultImageCompressionStrength") private var imageStrength = "balanced"
    @AppStorage("defaultImageCompressionSize") private var imageSize = "original"

    private var formats: [ConversionFormat] {
        let outputs = ConversionFormat.allCases.filter { !$0.isInputOnly }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? outputs : outputs.filter { $0.label.lowercased().contains(q) || $0.rawValue.contains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conversion formats").font(.title3.bold())
                    Text("Conversion defaults are configured on the output format you choose.").font(.callout).foregroundStyle(.secondary)
                }
                TextField("Search", text: $query).textFieldStyle(.roundedBorder)
                HStack(alignment: .top, spacing: 14) {
                    list.frame(width: 230, height: 300)
                    detail.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Divider()
                compression
            }
            .padding(20)
        }
    }

    private var list: some View {
        List(selection: Binding(get: { selected }, set: { if let v = $0 { selected = v } })) {
            if formats.isEmpty { Text("No results").foregroundStyle(.secondary) }
            ForEach(formats, id: \.self) { f in
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.label)
                    Text(Conversions.caption(for: f)).font(.caption2).foregroundStyle(.secondary)
                }.tag(f)
            }
        }
        .listStyle(.bordered)
    }

    private var detail: some View {
        let params = ConversionProfile.params(for: selected)
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(selected.label) Settings").font(.headline)
            Text(Conversions.caption(for: selected)).font(.caption).foregroundStyle(.secondary)
            if let hint = Conversions.unavailableHint(selected) { Text(hint).font(.caption).foregroundStyle(.orange) }
            if params.isEmpty {
                Text("This output format has no adjustable conversion defaults.").foregroundStyle(.secondary)
            } else {
                Text("Conversion Settings").font(.subheadline.bold())
                ForEach(params, id: \.self) { control(for: $0) }
                Button("Restore Defaults") { ConversionProfile.restoreDefaults(selected); refresh += 1 }
            }
        }
        .id("\(selected.rawValue)-\(refresh)")
    }

    @ViewBuilder private func control(for p: ConversionParam) -> some View {
        let binding = Binding<String>(get: { ConversionProfile.string(selected, p) },
                                      set: { ConversionProfile.set($0, selected, p); refresh += 1 })
        if p == .preserveMetadata {
            Toggle(p.title, isOn: Binding(get: { binding.wrappedValue == "true" }, set: { binding.wrappedValue = $0 ? "true" : "false" }))
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(p.title)
                    Spacer()
                    Picker("", selection: binding) { ForEach(p.choices, id: \.value) { Text($0.caption).tag($0.value) } }
                        .labelsHidden().frame(maxWidth: 200)
                }
                if let d = p.choices.first(where: { $0.value == binding.wrappedValue })?.detail {
                    Text(d).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var compression: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compression Settings").font(.headline)
            Picker("Video compression", selection: $videoStrength) {
                Text("Balanced").tag("balanced"); Text("Strong").tag("strong")
            }.pickerStyle(.segmented)
            Text(videoStrength == "strong" ? "Much smaller files with more visible quality loss." : "Better visual quality with moderate file-size savings.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Image Compression").font(.subheadline.bold())
            Picker("Strength", selection: $imageStrength) { Text("Balanced").tag("balanced"); Text("Strong").tag("strong") }.pickerStyle(.segmented)
            Picker("Size", selection: $imageSize) {
                Text("Original").tag("original"); Text("Large").tag("large"); Text("Medium").tag("medium"); Text("Small").tag("small")
            }.pickerStyle(.segmented)
            Button("Restore Compression Defaults") {
                videoStrength = "balanced"; imageStrength = "balanced"; imageSize = "original"
            }
        }
    }
}

/// Settings > Compatibility pane (SHL-82): the format compatibility matrix.
struct FormatCompatibilityView: View {
    enum Mode: String, CaseIterable { case both = "Input to output", input = "Input", output = "Output" }
    @State private var mode: Mode = .both
    @State private var categories: Set<ConversionFormat.Group> = []
    @State private var query = ""

    private var rows: [ConversionFormat] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return ConversionFormat.allCases.filter { f in
            if !categories.isEmpty && !categories.contains(f.group) { return false }
            switch mode {
            case .both, .input: if f.isOutputOnly && mode == .both { return false }
            case .output: if f.isInputOnly { return false }
            }
            if mode == .input && f.isOutputOnly { return false }
            return q.isEmpty || f.label.lowercased().contains(q) || f.rawValue.contains(q)
        }
    }

    private func text(for f: ConversionFormat) -> String {
        switch mode {
        case .both:
            let t = ConversionMatrix.targets(from: f).filter { Conversions.route(from: f, to: $0).isAvailable }
            return t.isEmpty ? "\(f.label) unavailable" : "\(f.label) converts to \(t.map(\.label).joined(separator: ", "))"
        case .input: return Conversions.isInputAvailable(f) ? "\(f.label) supported" : "\(f.label) unavailable"
        case .output: return Conversions.isOutputAvailable(f) ? "\(f.label) supported" : "\(f.label) unavailable"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Format Compatibility").font(.title3.bold())
            HStack(spacing: 6) {
                ForEach(ConversionFormat.Group.allCases, id: \.self) { g in
                    Button(g.rawValue) { if categories.contains(g) { categories.remove(g) } else { categories.insert(g) } }
                        .buttonStyle(.bordered).tint(categories.contains(g) ? Brand.accent : nil)
                }
            }
            HStack {
                Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
                TextField("Search", text: $query).textFieldStyle(.roundedBorder)
            }
            List {
                if rows.isEmpty { Text("No results").foregroundStyle(.secondary) }
                ForEach(rows, id: \.self) { f in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(text(for: f)).font(.callout)
                        Text(Conversions.caption(for: f)).font(.caption2).foregroundStyle(.secondary)
                        if let hint = Conversions.unavailableHint(f) { Text(hint).font(.caption2).foregroundStyle(.orange) }
                    }
                }
            }
            .listStyle(.bordered)
        }
        .padding(20)
    }
}
