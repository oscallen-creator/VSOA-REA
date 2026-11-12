import SwiftUI
import AppKit

/// IMG-23..27, SHL-90..92. Annotate Photo. Annotations are in full-size image pixels; the preview is the engine's own render.
struct AnnotateEditor: View {
    let file: URL
    @State private var full: CGSize = .zero
    @State private var preview: CGImage?
    @State private var shown: CGImage?
    @State private var scale: CGFloat = 1            // preview pixels per full pixel
    @State private var list: [Annotation] = []
    @State private var history: [[Annotation]] = []
    @State private var tool: AnnotationKind = .arrow
    @State private var color = Color(red: 1, green: 0.23, blue: 0.19)
    @State private var zoomLevel: CGFloat = 2
    @State private var selected: UUID?
    @State private var draft: Annotation?
    @State private var moving: (id: UUID, last: CGPoint)?
    @State private var message: String?
    @FocusState private var focused: Bool
    @Environment(\.toolPanel) private var panel

    init(files: [URL]) { file = files[0] }

    private var selectedIndex: Int? { list.firstIndex { $0.id == selected } }
    private var drawTools: [AnnotationKind] { [.arrow, .freehand, .rectangle, .ellipse, .highlighter, .number, .magnifier] }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                canvas
                if let i = selectedIndex, list[i].kind == .text || list[i].kind == .image { Divider(); inspector(i).frame(width: 200) }
            }
            Divider()
            HStack { Text(tool.hint).font(.caption).foregroundStyle(.secondary).lineLimit(2); Spacer() }.padding(.horizontal, 12).padding(.vertical, 4)
            ToolFooter(primary: "Save Annotated Copy", message: message, reset: nil) { save() }
        }
        .task {
            if let s = ImageFiles.displaySize(file) { full = s }
            preview = await loadPreview(file, maxPixel: 1400)
            if let p = preview, full.width > 0 { scale = CGFloat(p.width) / full.width }
            rerender()
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(drawTools, id: \.self) { k in
                Button { tool = k; selected = nil } label: { Image(systemName: k.symbol).frame(width: 22, height: 20) }
                    .buttonStyle(.bordered).tint(tool == k ? Brand.accent : nil).help(k.label)
            }
            Button { addText() } label: { Label("Text", systemImage: AnnotationKind.text.symbol) }.help(AnnotationKind.text.hint)
            Button { for u in chooseImages(multiple: true) { addImage(from: u) } } label: { Label("Image", systemImage: AnnotationKind.image.symbol) }
                .help(AnnotationKind.image.hint)
            Divider().frame(height: 18)
            ColorPicker("Annotation color", selection: $color).labelsHidden().help("Annotation color")
                .onChange(of: color) { _, c in if let i = selectedIndex { push(); list[i].color = c.imageRGBA; rerender() } }
            if tool == .magnifier {
                Picker("Magnifier zoom level", selection: $zoomLevel) { ForEach([2, 3, 4], id: \.self) { Text("\($0)x").tag(CGFloat($0)) } }
                    .labelsHidden().frame(width: 60).help("Magnifier zoom level")
            }
            Spacer()
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .help("Undo last annotation").disabled(history.isEmpty)
            Button { deleteSelected() } label: { Image(systemName: "trash") }.help("Delete selected annotation").disabled(selected == nil)
            Button { push(); list.removeAll { $0.kind == .freehand || $0.kind == .highlighter }; rerender() } label: { Image(systemName: "eraser") }
                .help("Remove all drawn strokes")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func inspector(_ i: Int) -> some View {
        Form {
            if list[i].kind == .text {
                TextField("Text", text: Binding(get: { list[i].text }, set: { list[i].text = $0; rerender() }), axis: .vertical).lineLimit(1...5)
                Picker("Font", selection: Binding(get: { list[i].font }, set: { list[i].font = $0; rerender() })) {
                    ForEach(AnnotationFont.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Stepper("\(Int(list[i].fontSize)) pt", value: Binding(get: { list[i].fontSize }, set: { list[i].fontSize = $0; rerender() }), in: 8...200, step: 2)
                Stepper("Width \(Int(list[i].width))", value: Binding(get: { list[i].width }, set: { list[i].width = $0; rerender() }), in: 40...1000, step: 20)
            } else {
                Text("Drag the image to move it.").font(.caption)
                Stepper("Size", value: Binding(get: { 0 }, set: { grow(i, $0 > 0 ? 1.1 : 0.9) }))
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }

    // MARK: Canvas

    private var canvas: some View {
        Group {
            if let img = shown ?? preview {
                FittedImage(image: img) { frame, fit in
                    ZStack(alignment: .topLeading) {
                        Color.clear.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { g in drag(to: toImage(g.location, frame, fit), start: toImage(g.startLocation, frame, fit), first: draft == nil && moving == nil) }
                                .onEnded { g in endDrag(toImage(g.location, frame, fit), start: toImage(g.startLocation, frame, fit)) })
                        if let i = selectedIndex {
                            let b = ImageAnnotateEngine.bounds(list[i], imageSize: full)
                            let ratio = fit * scale
                            Rectangle().stroke(Brand.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                .frame(width: b.width * ratio, height: b.height * ratio)
                                .offset(x: frame.minX + b.minX * ratio, y: frame.minY + b.minY * ratio).allowsHitTesting(false)
                            if list[i].kind == .text || list[i].kind == .image {
                                if list[i].kind == .text { handle(i, .right, x: frame.minX + b.maxX * ratio, y: frame.minY + b.midY * ratio, ratio)
                                    handle(i, .left, x: frame.minX + b.minX * ratio, y: frame.minY + b.midY * ratio, ratio) }
                                else { handle(i, .bottomRight, x: frame.minX + b.maxX * ratio, y: frame.minY + b.maxY * ratio, ratio) }
                            }
                        }
                    }
                }
                .accessibilityLabel("Annotation preview").accessibilityIdentifier("annotationCanvas")
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(minHeight: 300)
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in deleteSelected(); return .handled }
        .onPasteCommand(of: [.image, .fileURL]) { providers in pasteImage(providers) }
        .onCommand(Selector(("undo:"))) { undo() }
        .onAppear { focused = true }
    }

    /// View point -> full-size image pixel.
    private func toImage(_ p: CGPoint, _ frame: CGRect, _ fit: CGFloat) -> CGPoint {
        // `fit` is view points per preview pixel; full pixels per preview pixel is 1/scale.
        CGPoint(x: (p.x - frame.minX) / fit / scale, y: (p.y - frame.minY) / fit / scale)
    }

    private func drag(to p: CGPoint, start: CGPoint, first: Bool) {
        if first {
            if let hit = list.last(where: { $0.id == selected && ImageAnnotateEngine.hit($0, at: start, imageSize: full) }) {
                push(); moving = (hit.id, start); return
            }
            switch tool {
            case .number, .magnifier: return   // placed on release
            default:
                draft = Annotation(kind: tool, color: color.imageRGBA, points: [start], zoom: zoomLevel)
            }
        }
        if let m = moving, let i = list.firstIndex(where: { $0.id == m.id }) {
            list[i] = ImageAnnotateEngine.moved(list[i], by: CGSize(width: p.x - m.last.x, height: p.y - m.last.y))
            moving = (m.id, p); rerender(); return
        }
        guard var d = draft else { return }
        switch d.kind {
        case .freehand, .highlighter: d.points.append(p)
        default: d.points = [d.points[0], p]
        }
        draft = d; rerender()
    }

    private func endDrag(_ p: CGPoint, start: CGPoint) {
        defer { draft = nil; moving = nil; rerender() }
        if moving != nil { return }
        let isClick = hypot(p.x - start.x, p.y - start.y) <= 3 / max(scale, 0.01)
        if isClick, let hit = list.last(where: { ImageAnnotateEngine.hit($0, at: start, imageSize: full) }) { selected = hit.id; return }
        if isClick { selected = nil }
        if let d = draft {
            if !isClick { push(); list.append(d); selected = d.id; message = nil }
            return
        }
        guard tool == .number || tool == .magnifier else { return }
        push()
        var a = Annotation(kind: tool, color: color.imageRGBA, points: [start], zoom: zoomLevel)
        if tool == .number { a.number = (list.filter { $0.kind == .number }.map(\.number).max() ?? 0) + 1 }
        list.append(a); selected = a.id
    }

    @State private var resizeStart: Annotation?

    /// Side handles: text boxes change width only (left/right); images resize from the corner.
    private func handle(_ i: Int, _ h: CropHandle, x: CGFloat, y: CGFloat, _ ratio: CGFloat) -> some View {
        Capsule().fill(Brand.accent).frame(width: h == .bottomRight ? 10 : 6, height: h == .bottomRight ? 10 : 22)
            .position(x: x, y: y)
            .accessibilityLabel(h == .left ? "Resize text from left" : (h == .right && list[i].kind == .text ? "Resize text from right" : "Resize image"))
            .gesture(DragGesture().onChanged { g in
                if resizeStart == nil { push(); resizeStart = list[i] }
                guard let st = resizeStart, list.indices.contains(i) else { return }
                let dx = g.translation.width / ratio, dy = g.translation.height / ratio
                if st.kind == .text {
                    let u = ImageAnnotateEngine.unit(full)
                    let w = max(40, st.width + (h == .left ? -dx : dx) / u)
                    list[i].width = w
                    if h == .left { list[i].points[0].x = st.points[0].x + (st.width - w) * u }
                } else if st.points.count == 2 {
                    list[i].points[1] = CGPoint(x: max(st.points[0].x + 8, st.points[1].x + dx), y: max(st.points[0].y + 8, st.points[1].y + dy))
                }
                rerender()
            }.onEnded { _ in resizeStart = nil })
    }

    // MARK: Actions

    private func push() { history.append(list) }
    private func undo() { if let h = history.popLast() { list = h; selected = nil; rerender() } }
    private func deleteSelected() { guard let s = selected else { return }; push(); list.removeAll { $0.id == s }; selected = nil; rerender() }

    private func addText() {
        push()
        var a = Annotation(kind: .text, color: color.imageRGBA, points: [CGPoint(x: full.width * 0.1, y: full.height * 0.1 + CGFloat(list.count % 5) * full.height * 0.08)], text: "Text")
        a.width = 360
        list.append(a); selected = a.id; rerender()
    }

    private func addImage(from url: URL) {
        guard let img = try? ImageFiles.load(url, maxPixel: 2000) else { return }
        place(img)
    }

    private func place(_ img: CGImage) {
        push()
        let w = full.width * 0.3, h = w * CGFloat(img.height) / CGFloat(img.width)
        let o = CGPoint(x: full.width * 0.1, y: full.height * 0.1)
        var a = Annotation(kind: .image, points: [o, CGPoint(x: o.x + w, y: o.y + h)]); a.image = img
        list.append(a); selected = a.id; rerender()
    }

    private func grow(_ i: Int, _ k: CGFloat) {
        guard list[i].points.count == 2 else { return }
        push()
        let a = list[i].points[0], b = list[i].points[1]
        list[i].points[1] = CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k); rerender()
    }

    private func pasteImage(_ providers: [NSItemProvider]) {
        if let img = NSImage(pasteboard: .general), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { place(cg) }
    }

    private func rerender() {
        guard let preview else { return }
        var items = list
        if let d = draft { items.append(d) }
        let scaled = items.map { a -> Annotation in var b = a; b.points = a.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }; return b }
        // Preview rendering skips validation: it must show unfinished shapes.
        shown = (try? ImageAnnotateEngine.renderUnchecked(preview, scaled)) ?? preview
    }

    private func save() {
        if let problem = ImageAnnotateEngine.validate(list, imageSize: full) { message = problem; return }
        let annotations = list
        runImageJob(title: "Annotating photo", files: [file], close: panel.close) { url, p in
            let base = try ImageFiles.load(url)
            p(0.4)
            let out = try ImageAnnotateEngine.render(base, annotations)
            return try await ImageFiles.save(out, beside: url, suffix: "-annotated")
        }
    }
}
