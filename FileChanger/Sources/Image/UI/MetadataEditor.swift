import SwiftUI

/// META-01..08. Metadata viewer/editor with per-field removal and Remove All.
struct MetadataEditor: View {
    let files: [URL]
    @State private var current: URL
    @State private var fields: [URL: [MetadataField]] = [:]
    @State private var removed: [URL: Set<String>] = [:]
    @State private var edits: [URL: [String: String]] = [:]
    @State private var search = ""
    @State private var error: String?
    @Environment(\.toolPanel) private var panel

    init(files: [URL]) { self.files = files; _current = State(initialValue: files[0]) }

    private var shown: [MetadataField] {
        let all = fields[current] ?? []
        guard !search.isEmpty else { return all }
        return all.filter { $0.key.localizedCaseInsensitiveContains(search) || $0.value.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search) }
    }
    private var groups: [String] { Array(Set(shown.map(\.group))).sorted() }
    private var dirty: Bool { files.contains { !(removed[$0] ?? []).isEmpty || !(edits[$0] ?? [:]).isEmpty } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if files.count > 1 {
                    Picker("File", selection: $current) { ForEach(files, id: \.self) { Text($0.lastPathComponent).tag($0) } }.frame(maxWidth: 240)
                }
                TextField("Search metadata", text: $search).textFieldStyle(.roundedBorder)
                Button("Remove All") { removeAll() }
                    .help("Remove metadata now and save a new file. Photo cleanup includes private blocks that cannot be removed individually. The original stays unchanged.")
            }.padding(12)
            Text("For photos, Remove All also clears hidden camera and processing data. HDR and portrait effects may change.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 6)
            Divider()
            if (fields[current] ?? []).isEmpty {
                Text("No readable metadata found.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.self) { g in
                        Section(g) { ForEach(shown.filter { $0.group == g }) { row($0) } }
                    }
                }
            }
            Divider()
            ToolFooter(primary: "Save", isEnabled: dirty, message: error, reset: { removed[current] = []; edits[current] = [:]; error = nil }) { save() }
        }
        .task { for f in files { fields[f] = (try? MetadataEngine.read(f)) ?? [] } }
    }

    private func row(_ f: MetadataField) -> some View {
        let isRemoved = removed[current]?.contains(f.id) ?? false
        return HStack {
            Text(f.copy.map { "\(f.key) (copy \($0))" } ?? f.key).frame(width: 150, alignment: .leading).lineLimit(1)
            if f.isEditable && !isRemoved {
                if f.kind == .list {
                    TextField("", text: Binding(get: { edits[current]?[f.id] ?? f.value }, set: { edits[current, default: [:]][f.id] = $0 }), axis: .vertical).lineLimit(1...4)
                } else {
                    TextField("", text: Binding(get: { edits[current]?[f.id] ?? f.value }, set: { edits[current, default: [:]][f.id] = $0 }))
                }
            } else {
                VStack(alignment: .leading) {
                    Text(f.value).foregroundStyle(isRemoved ? .secondary : .primary).strikethrough(isRemoved).lineLimit(2)
                    if let n = f.note { Text(n).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            if !f.isRemovable { EmptyView() }
            else if isRemoved { Button("Restore") { removed[current]?.remove(f.id) }.buttonStyle(.borderless) }
            else { Button { removed[current, default: []].insert(f.id); edits[current]?[f.id] = nil } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("Remove this field") }
        }
    }

    private func save() {
        let targets = files.filter { !(removed[$0] ?? []).isEmpty || !(edits[$0] ?? [:]).isEmpty }
        let rem = removed, ed = edits
        runImageJob(title: "Saving metadata", files: targets, close: panel.close) { url, p in
            try await MetadataEngine.save(url, removing: rem[url] ?? [], editing: ed[url] ?? [:], progress: p)
        }
    }

    private func removeAll() {
        runImageJob(title: "Saving metadata", files: files, close: panel.close) { url, p in try await MetadataEngine.removeAll(url, progress: p) }
    }
}
