import SwiftUI

/// IMG-19..22. Edit Photo.
struct AdjustEditor: View {
    let files: [URL]
    @State private var base: CGImage?
    @State private var shown: CGImage?
    @State private var a = ImageAdjustments()
    @Environment(\.toolPanel) private var panel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading) {
                    Text("Photo preview").font(.caption).foregroundStyle(.secondary).padding([.top, .leading], 10)
                    if let img = shown ?? base {
                        previewImage(img).resizable().scaledToFit().padding(10).accessibilityLabel("Photo preview")
                    } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.frame(maxWidth: .infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(ImageAdjustControl.sections, id: \.self) { section in
                            Text(section).font(.headline).padding(.top, 4)
                            ForEach(ImageAdjustControl.all.filter { $0.section == section }) { c in
                                ValueSlider(title: c.label, value: Binding(get: { a[c.id] }, set: { a[c.id] = $0 }), range: c.range, format: c.display)
                            }
                        }
                    }.padding(12)
                }.frame(width: 250)
            }
            Divider()
            ToolFooter(primary: "Save Edited Copy", reset: { a = ImageAdjustments() }) { save() }
        }
        .task { base = await loadPreview(files[0], maxPixel: 1000) }
        .task(id: a) {
            guard let base else { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
            if Task.isCancelled { return }
            let adj = a
            shown = await Task.detached { try? ImageAdjustEngine.render(adj, base) }.value
        }
        .onChange(of: base == nil) { _, _ in shown = nil }
    }

    private func save() {
        let adj = a
        runImageJob(title: "Saving", files: files, close: panel.close) { url, p in try await ImageAdjustEngine.adjust(url, adj, progress: p) }
    }
}
