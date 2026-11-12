import SwiftUI

/// IMG-33..35. Redact Photo (one still photo).
struct RedactEditor: View {
    let file: URL
    let count: Int
    @State private var image: CGImage?
    @State private var shown: CGImage?
    @State private var rects: [(id: UUID, rect: CGRect)] = []
    @State private var selected: UUID?
    @State private var style: RedactionStyle = .solid
    @State private var draft: CGRect?
    @State private var dragStart: CGRect?
    @State private var status: String?
    @State private var detecting = false
    @FocusState private var focused: Bool
    @Environment(\.toolPanel) private var panel

    init(files: [URL]) { file = files[0]; count = files.count }

    private var size: CGSize { image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }

    var body: some View {
        if count > 1 || ImageFiles.isAnimated(file) {
            VStack {
                Spacer()
                Text("Redact one still photo at a time. Export the frames or pages first.").foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                Spacer()
                ToolFooter(primary: "Save Redacted Copy", isEnabled: false) {}
            }
        } else { editor }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Style", selection: $style) { ForEach(RedactionStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 150).labelsHidden()
                Button("Faces") { detect(.faces) }.disabled(detecting).accessibilityIdentifier("detectPhotoFaces")
                Button("Text") { detect(.text) }.disabled(detecting).accessibilityIdentifier("detectPhotoText")
                Spacer()
                Button("Delete Redaction") { deleteSelected() }.disabled(selected == nil)
            }.padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            Group {
                if let shown = shown ?? image {
                    FittedImage(image: shown) { frame, fit in overlay(frame: frame, fit: fit * CGFloat(shown.width) / max(1, size.width)) }
                        .accessibilityLabel("Redaction preview. Draw rectangles to cover areas.")
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .frame(minHeight: 300).focusable().focused($focused).focusEffectDisabled()
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in deleteSelected(); return .handled }
            HStack {
                Text(status ?? (style == .blur ? "Blur softens details. Use Solid for sensitive information." : "Draw a rectangle over the area to hide."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 12).padding(.vertical, 4)
            ToolFooter(primary: "Save Redacted Copy", isEnabled: !rects.isEmpty, message: rects.isEmpty ? nil : nil,
                       reset: { rects = []; selected = nil; status = nil; refresh() }) { save() }
        }
        .task { image = await loadPreview(file, maxPixel: 32000); refresh(); focused = true }
        .onChange(of: style) { _, _ in refresh() }
    }

    @ViewBuilder
    private func overlay(frame: CGRect, fit: CGFloat) -> some View {
        let toView = { (r: CGRect) in CGRect(x: frame.minX + r.minX * fit, y: frame.minY + r.minY * fit, width: r.width * fit, height: r.height * fit) }
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        let a = CGPoint(x: (g.startLocation.x - frame.minX) / fit, y: (g.startLocation.y - frame.minY) / fit)
                        let b = CGPoint(x: (g.location.x - frame.minX) / fit, y: (g.location.y - frame.minY) / fit)
                        draft = ImageRedactEngine.clamp(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)), to: size)
                    }
                    .onEnded { _ in
                        if let d = draft, d.width >= 4, d.height >= 4 { let id = UUID(); rects.append((id, d)); selected = id; refresh() }
                        draft = nil
                    })
                .simultaneousGesture(TapGesture().onEnded { selected = nil })
            ForEach(rects, id: \.id) { item in
                let v = toView(item.rect)
                Rectangle().stroke(item.id == selected ? Brand.accent : Color.white, lineWidth: 2).background(Color.white.opacity(0.001))
                    .frame(width: v.width, height: v.height).offset(x: v.minX, y: v.minY).accessibilityLabel("Redaction rectangle")
                    .gesture(DragGesture().onChanged { g in
                        selected = item.id
                        if dragStart == nil { dragStart = item.rect }
                        if let s = dragStart, let i = rects.firstIndex(where: { $0.id == item.id }) {
                            rects[i].rect = ImageCropEngine.clamped(s.offsetBy(dx: g.translation.width / fit, dy: g.translation.height / fit), in: size)
                        }
                    }.onEnded { _ in dragStart = nil; refresh() })
                if item.id == selected {
                    ForEach(CropHandle.allCases, id: \.self) { h in
                        let p = handlePoint(h, v)
                        Circle().fill(Brand.accent).frame(width: 10, height: 10).position(p).accessibilityLabel("Resize redaction")
                            .gesture(DragGesture().onChanged { g in
                                if dragStart == nil { dragStart = item.rect }
                                if let s = dragStart, let i = rects.firstIndex(where: { $0.id == item.id }) {
                                    rects[i].rect = ImageCropEngine.resize(s, handle: h, delta: CGPoint(x: g.translation.width / fit, y: g.translation.height / fit), in: size)
                                }
                            }.onEnded { _ in dragStart = nil; refresh() })
                    }
                }
            }
            if let d = draft { let v = toView(d); Rectangle().stroke(Brand.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .frame(width: v.width, height: v.height).offset(x: v.minX, y: v.minY) }
        }
    }

    private func handlePoint(_ h: CropHandle, _ b: CGRect) -> CGPoint {
        switch h {
        case .topLeft: return CGPoint(x: b.minX, y: b.minY); case .top: return CGPoint(x: b.midX, y: b.minY)
        case .topRight: return CGPoint(x: b.maxX, y: b.minY); case .right: return CGPoint(x: b.maxX, y: b.midY)
        case .bottomRight: return CGPoint(x: b.maxX, y: b.maxY); case .bottom: return CGPoint(x: b.midX, y: b.maxY)
        case .bottomLeft: return CGPoint(x: b.minX, y: b.maxY); case .left: return CGPoint(x: b.minX, y: b.midY)
        }
    }

    private func refresh() {
        guard let image else { return }
        let rs = rects.map(\.rect), st = style
        if rs.isEmpty { shown = nil; return }
        // Preview at reduced size keeps dragging responsive.
        let k = min(1, 1200 / CGFloat(max(image.width, image.height)))
        Task {
            let out = await Task.detached { () -> CGImage? in
                guard let small = k < 1 ? ImageFiles.render(Int(CGFloat(image.width) * k), Int(CGFloat(image.height) * k), { c in
                    ImageFiles.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width) * k, height: CGFloat(image.height) * k), c) }) : image
                else { return nil }
                return try? ImageRedactEngine.render(small, rects: rs.map { CGRect(x: $0.minX * k, y: $0.minY * k, width: $0.width * k, height: $0.height * k) }, style: st)
            }.value
            // Preview image is smaller, but FittedImage scales it to the same frame, so rect coordinates stay in full-size pixels.
            shown = out
        }
    }

    private func deleteSelected() { guard let s = selected else { return }; rects.removeAll { $0.id == s }; selected = nil; refresh() }

    private func detect(_ kind: PhotoRedactionDetectionKind) {
        guard let image else { return }
        detecting = true
        Task {
            defer { detecting = false }
            do {
                let found = try await ImageRedactEngine.detect(kind, in: image)
                if found.isEmpty { status = "No \(kind.noun) found."; return }
                let fresh = ImageRedactEngine.newRects(found, existing: rects.map(\.rect))
                if fresh.isEmpty { status = "All detected \(kind.noun) are already selected."; return }
                rects += fresh.map { (UUID(), $0) }; status = nil; refresh()
            } catch { status = error.localizedDescription }
        }
    }

    private func save() {
        let rs = rects.map(\.rect), st = style
        runImageJob(title: "Redacting photo", files: [file], close: panel.close) { url, p in try await ImageRedactEngine.redact(url, rects: rs, style: st, progress: p) }
    }
}
