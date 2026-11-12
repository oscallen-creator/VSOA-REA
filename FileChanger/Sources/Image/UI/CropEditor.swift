import SwiftUI

/// IMG-15..18. Crop Image with a thumbnail strip, 8 handles, ratio presets, zoom and "apply to all".
struct CropEditor: View {
    let files: [URL]
    @State private var current: URL
    @State private var images: [URL: CGImage] = [:]      // only the selected image is held at full size
    @State private var sizes: [URL: CGSize] = [:]
    @State private var pinchBase: CGFloat?
    @State private var rects: [URL: CGRect] = [:]
    @State private var ratio: CropRatio = .free
    @State private var zoom: CGFloat = 1
    @State private var applyToAll = false
    @State private var dragStart: CGRect?
    @State private var activeHandle: CropHandle?
    @State private var thumbs: [URL: CGImage] = [:]
    @FocusState private var canvasFocused: Bool
    @Environment(\.toolPanel) private var panel

    init(files: [URL]) { self.files = files; _current = State(initialValue: files[0]) }

    private var size: CGSize? { sizes[current] }
    private var rect: CGRect { rects[current] ?? .zero }

    private func setRect(_ r: CGRect) { if let size { rects[current] = ImageCropEngine.clamped(r, in: size) } }

    private var problem: String? {
        guard let size else { return nil }
        do { try ImageCropEngine.validate(rect, in: size); return nil } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            ScrollView([.horizontal, .vertical]) {
                if let img = images[current] {
                    FittedImage(image: img, zoom: zoom) { frame, scale in cropOverlay(frame: frame, scale: scale) }
                        .frame(minWidth: 400, minHeight: 280)
                        .frame(width: zoom > 1 ? 560 * zoom : nil, height: zoom > 1 ? 340 * zoom : nil)
                } else { ProgressView().frame(maxWidth: .infinity, minHeight: 280) }
            }
            .focusable().focused($canvasFocused).focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                let step = ImageCropEngine.nudgeStep(shift: press.modifiers.contains(.shift), option: press.modifiers.contains(.option))
                var r = rect
                switch press.key {
                case .leftArrow: r.origin.x -= step
                case .rightArrow: r.origin.x += step
                case .upArrow: r.origin.y -= step
                default: r.origin.y += step
                }
                setRect(r); return .handled
            }
            .onTapGesture(count: 2) { zoom = 1 }
            .gesture(MagnificationGesture().onChanged { v in if pinchBase == nil { pinchBase = zoom }; zoom = min(6, max(1, (pinchBase ?? 1) * v)) }.onEnded { _ in pinchBase = nil })
            if files.count > 1 { Divider(); strip }
            Divider()
            ToolFooter(primary: "Crop", isEnabled: problem == nil && size != nil, message: problem, reset: resetCrop) { save() }
        }
        .task { await loadAll() }
        .task(id: current) {
            images = [:]
            if let img = await loadPreview(current, maxPixel: 32000) { images[current] = img }
        }
        .onAppear { canvasFocused = true }
    }

    // MARK: Pieces

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Ratio", selection: $ratio) { ForEach(CropRatio.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .frame(width: 150).onChange(of: ratio) { _, _ in applyRatio() }
            if let size {
                IntField(title: "Crop width in pixels", value: Binding(get: { Int(rect.width) }, set: { setSide(width: CGFloat($0), height: nil) }),
                         range: 1...Int(size.width))
                Text("x")
                IntField(title: "Crop height in pixels", value: Binding(get: { Int(rect.height) }, set: { setSide(width: nil, height: CGFloat($0)) }),
                         range: 1...Int(size.height))
                Text("px").foregroundStyle(.secondary)
            }
            Spacer()
            Button { zoom = max(1, zoom - 0.5) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out").buttonStyle(.borderless)
            Button { zoom = min(6, zoom + 0.5) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in").buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .bottomLeading) {
            if files.count > 1 {
                Toggle("Use this crop, as the same share of each image, for every image", isOn: $applyToAll)
                    .font(.caption).toggleStyle(.checkbox).offset(y: 18).padding(.leading, 12)
            }
        }
        .padding(.bottom, files.count > 1 ? 18 : 0)
    }

    private var strip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(files, id: \.self) { f in
                    Button { current = f; zoom = 1 } label: {
                        Group {
                            if let t = thumbs[f] { previewImage(t).resizable().scaledToFill() } else { Color.gray.opacity(0.2) }
                        }
                        .frame(width: 64, height: 48).clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(f == current ? Brand.accent : .clear, lineWidth: 2))
                    }.buttonStyle(.plain).help(f.lastPathComponent)
                }
            }.padding(8)
        }.frame(height: 66)
    }

    @ViewBuilder
    private func cropOverlay(frame: CGRect, scale: CGFloat) -> some View {
        let r = rect
        let box = CGRect(x: frame.minX + r.minX * scale, y: frame.minY + r.minY * scale, width: r.width * scale, height: r.height * scale)
        ZStack(alignment: .topLeading) {
            // Dim everything outside the selection.
            Path { p in p.addRect(frame); p.addRect(box) }.fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            Rectangle().stroke(Color.white, lineWidth: 1.5).frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
            Rectangle().fill(Color.white.opacity(0.001)).frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
                .accessibilityLabel("Crop selection. Drag to reposition.")
                .gesture(DragGesture().onChanged { g in
                    if dragStart == nil { dragStart = rect }
                    if let s = dragStart { setRect(s.offsetBy(dx: (g.translation.width / scale).rounded(), dy: (g.translation.height / scale).rounded())) }
                }.onEnded { _ in dragStart = nil })
            ForEach(CropHandle.allCases, id: \.self) { h in
                let p = handlePoint(h, box)
                Rectangle().fill(Color.white).overlay(Rectangle().stroke(Brand.accent, lineWidth: 1.5)).frame(width: 10, height: 10)
                    .position(p).accessibilityLabel("Crop handle")
                    .gesture(DragGesture().onChanged { g in
                        if dragStart == nil { dragStart = rect }
                        if let s = dragStart, let size {
                            setRect(ImageCropEngine.resize(s, handle: h, delta: CGPoint(x: g.translation.width / scale, y: g.translation.height / scale),
                                                           in: size, ratio: ratio.value(imageSize: size)))
                        }
                    }.onEnded { _ in dragStart = nil })
            }
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

    // MARK: Logic

    private func setSide(width: CGFloat?, height: CGFloat?) {
        guard let size else { return }
        var r = rect
        let ratioValue = ratio.value(imageSize: size)
        if let width { r.size.width = width; if let ratioValue { r.size.height = (width / ratioValue).rounded() } }
        if let height { r.size.height = height; if let ratioValue { r.size.width = (height * ratioValue).rounded() } }
        setRect(r)
    }

    private func applyRatio() {
        guard let size, let v = ratio.value(imageSize: size) else { return }
        setRect(ImageCropEngine.fitted(ratio: v, in: size))
    }

    private func resetCrop() {
        if let size { rects[current] = CGRect(origin: .zero, size: size) }
        ratio = .free
    }

    private func loadAll() async {
        for f in files {
            guard let sz = ImageFiles.displaySize(f) else { continue }
            sizes[f] = sz
            rects[f] = CGRect(origin: .zero, size: sz)
            thumbs[f] = await loadPreview(f, maxPixel: 160)
        }
    }

    private func save() {
        guard let size else { return }
        let all = applyToAll
        let mine = rects[current] ?? .zero
        let perFile = rects, allSizes = sizes
        let targets = files
        runImageJob(title: "Cropping image", files: targets, close: panel.close) { url, progress in
            if all { return try await ImageCropEngine.crop(url, rect: mine, referenceSize: size, progress: progress) }
            guard let r = perFile[url], let s = allSizes[url] else { throw FileChangerError.failed("Could not crop the image.") }
            return try await ImageCropEngine.crop(url, rect: r, referenceSize: s, progress: progress)
        }
    }
}
