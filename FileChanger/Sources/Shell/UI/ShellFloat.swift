import AppKit
import QuickLookThumbnailing
import QuickLookUI

enum FloatViewMode: String, CaseIterable {
    case grid, list, stack
    var symbol: String { self == .grid ? "square.grid.2x2" : (self == .list ? "list.bullet" : "square.stack") }
    var label: String { rawValue.capitalized }
}

enum FloatMaterialKind: String, CaseIterable {
    case glass, frosted, dark, solid
    var label: String { rawValue.capitalized }
    var material: NSVisualEffectView.Material {
        switch self {
        case .glass: return .hudWindow
        case .frosted: return .sidebar
        case .dark: return .hudWindow
        case .solid: return .windowBackground
        }
    }
    var appearance: NSAppearance? { self == .dark ? NSAppearance(named: .darkAqua) : nil }
}

enum FloatEdge { case left, right, top, bottom }

/// Creates, finds and feeds Floats (SHL-30, SHL-50, SHL-65).
@MainActor
final class ShellFloat {
    static let shared = ShellFloat()
    private var floats: [FloatController] = []

    func add(_ urls: [URL]) {
        let behavior = ShellFloatBehavior(rawValue: UserDefaults.standard.string(forKey: ShellSettings.floatBehavior) ?? "") ?? .addToExisting
        if behavior == .addToExisting, let existing = floats.last {
            existing.add(urls)
            existing.show()
            return
        }
        let c = FloatController(urls: urls, near: NSEvent.mouseLocation)
        c.onClose = { [weak self, weak c] in self?.floats.removeAll { $0 === c } }
        floats.append(c)
        c.show()
    }
}

final class FloatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Root of a Float: the material, a drop target for adding files, and the "Drop to add" hint.
final class FloatRootView: NSVisualEffectView {
    weak var controller: FloatController?
    private let hint = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        state = .active
        blendingMode = .behindWindow
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        registerForDraggedTypes([.fileURL])
        hint.font = .systemFont(ofSize: 13, weight: .semibold)
        hint.alignment = .center
        hint.textColor = .white
        hint.wantsLayer = true
        hint.drawsBackground = false
        hint.isHidden = true
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        hint.frame = NSRect(x: 8, y: bounds.midY - 16, width: bounds.width - 16, height: 32)
    }

    func setHint(_ text: String?) {
        if hint.superview == nil { addSubview(hint) }
        if let text {
            hint.stringValue = text
            hint.isHidden = false
            layer?.borderWidth = 2
            layer?.borderColor = Brand.nsAccent.cgColor
        } else {
            hint.isHidden = true
            layer?.borderWidth = 0
        }
    }

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    private func isInternal(_ info: NSDraggingInfo) -> Bool { info.draggingSource as AnyObject === controller }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isInternal(sender) else { return [] }
        let n = droppedURLs(sender).count
        setHint(n == 1 ? "Drop to add 1 item to it" : "Drop to add \(n) items to it")
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { setHint(nil) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setHint(nil) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHint(nil)
        guard !isInternal(sender) else { return false }
        let urls = droppedURLs(sender)
        guard !urls.isEmpty else { return false }
        controller?.add(urls)
        return true
    }
}

/// Header strip: the grab handle that moves the Float (drag near an edge to attach, away to detach).
final class FloatHeaderView: NSView {
    weak var controller: FloatController?
    override func mouseDown(with event: NSEvent) { controller?.moveWindow(with: event) }
    override var mouseDownCanMoveWindow: Bool { false }
}

final class FloatController: NSObject, NSDraggingSource, NSWindowDelegate {
    var urls: [URL]
    var onClose: () -> Void = {}
    private(set) var thumbs: [URL: NSImage] = [:]
    private var requested: Set<URL> = []

    let panel: FloatPanel
    private let root: FloatRootView
    private let header = FloatHeaderView()
    private let grip = FloatResizeGrip()
    private let summary = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private(set) var filesView: FloatFilesView!
    private var tabView: FloatTabView!
    private var modeControl: NSSegmentedControl!
    private var collapseButton: NSButton!

    private var edge: FloatEdge?
    private var expanded = true
    private var expandedSize = NSSize(width: 360, height: 320)

    var mode: FloatViewMode {
        get { FloatViewMode(rawValue: UserDefaults.standard.string(forKey: ShellSettings.floatViewMode) ?? "") ?? .grid }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: ShellSettings.floatViewMode) }
    }
    var material: FloatMaterialKind {
        FloatMaterialKind(rawValue: UserDefaults.standard.string(forKey: ShellSettings.floatMaterial) ?? "") ?? .glass
    }

    init(urls: [URL], near point: NSPoint) {
        self.urls = []
        let size = NSSize(width: 360, height: 320)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame
        let origin = NSPoint(x: min(max(point.x - size.width / 2, vis.minX + 8), vis.maxX - size.width - 8),
                             y: min(max(point.y - size.height / 2, vis.minY + 8), vis.maxY - size.height - 8))
        panel = FloatPanel(contentRect: NSRect(origin: origin, size: size),
                           styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        root = FloatRootView(frame: NSRect(origin: .zero, size: size))
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 240, height: 200)
        panel.contentView = root
        root.controller = self
        buildUI()
        applyMaterial()
        add(urls)
    }

    // MARK: UI

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        return b
    }

    private func buildUI() {
        header.controller = self
        header.toolTip = "Move Float; drag near an edge to attach, or away to detach"
        header.setAccessibilityIdentifier("float.summaryMove")
        summary.font = .systemFont(ofSize: 12, weight: .medium)
        summary.textColor = .secondaryLabelColor
        summary.setAccessibilityIdentifier("float.selection")

        modeControl = NSSegmentedControl(images: FloatViewMode.allCases.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.label) ?? NSImage() },
                                         trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        modeControl.controlSize = .small
        modeControl.selectedSegment = FloatViewMode.allCases.firstIndex(of: mode) ?? 0
        let sort = button("arrow.up.arrow.down", "Sort by Name", #selector(sortByName))
        let more = button("ellipsis.circle", "Float options", #selector(showOptions(_:)))
        let close = button("xmark.circle.fill", "Close Float without deleting files", #selector(closeFloat))
        collapseButton = button("chevron.compact.left", "Collapse Float", #selector(collapse))
        collapseButton.isHidden = true

        let row = NSStackView(views: [summary, NSView(), modeControl, sort, more, collapseButton, close])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])

        filesView = FloatFilesView(controller: self)
        scroll.documentView = filesView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        filesView.autoresizingMask = [.width]

        tabView = FloatTabView(controller: self)
        tabView.isHidden = true

        for v in [header, scroll, tabView!] { root.addSubview(v) }
        grip.panel = panel
        grip.frame = NSRect(x: root.bounds.width - 18, y: 0, width: 18, height: 18)
        grip.autoresizingMask = [.minXMargin, .maxYMargin]
        root.addSubview(grip)
        layoutPieces()
    }

    private func layoutPieces() {
        let b = root.bounds
        header.frame = NSRect(x: 0, y: b.height - 36, width: b.width, height: 36)
        scroll.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height - 36)
        tabView.frame = b
        header.autoresizingMask = [.width, .minYMargin]
        scroll.autoresizingMask = [.width, .height]
        tabView.autoresizingMask = [.width, .height]
        let showFull = edge == nil || expanded
        header.isHidden = !showFull
        scroll.isHidden = !showFull
        tabView.isHidden = showFull
        collapseButton.isHidden = edge == nil
        grip.isHidden = !showFull
        filesView.relayout()
        tabView.needsDisplay = true
    }

    private func applyMaterial() {
        root.material = material.material
        root.appearance = material.appearance
    }

    func refreshSummaryOnly() {
        let sel = filesView?.selection.count ?? 0
        summary.stringValue = sel > 0 ? "\(sel) selected" : "\(urls.count) file\(urls.count == 1 ? "" : "s")"
    }

    func refresh() {
        refreshSummaryOnly()
        tabView.needsDisplay = true
        filesView.relayout()
        filesView.needsDisplay = true
    }

    func show() { panel.orderFrontRegardless() }

    // MARK: Files

    func add(_ new: [URL]) {
        let have = Set(urls.map { $0.standardizedFileURL })
        for u in new where !have.contains(u.standardizedFileURL) && !urls.contains(u) { urls.append(u) }
        refresh()
    }

    func remove(_ gone: Set<URL>) {
        urls.removeAll { gone.contains($0) }
        filesView.selection.subtract(gone)
        if urls.isEmpty { closeFloat() } else { refresh() }
    }

    func thumbnail(for url: URL) -> NSImage {
        if let t = thumbs[url] { return t }
        if requested.insert(url).inserted {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 128),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
                guard let image = rep?.nsImage else { return }
                DispatchQueue.main.async { self?.thumbs[url] = image; self?.filesView.needsDisplay = true; self?.tabView.needsDisplay = true }
            }
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: Actions

    @objc private func modeChanged(_ s: NSSegmentedControl) {
        mode = FloatViewMode.allCases[max(0, s.selectedSegment)]
        filesView.relayout(); filesView.needsDisplay = true
    }
    @objc func sortByName() { urls = shellSortedByName(urls); refresh() }
    @objc func closeFloat() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        panel.orderOut(nil)
        onClose()
    }
    @objc private func collapse() { expanded = false; applyAttachment(animated: true) }
    func expand() { expanded = true; applyAttachment(animated: true) }

    @objc private func showOptions(_ sender: NSButton) {
        let menu = NSMenu()
        let viewMenu = NSMenu()
        for m in FloatViewMode.allCases {
            let mi = NSMenuItem(title: m.label, action: #selector(pickMode(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = m.rawValue; mi.state = m == mode ? .on : .off
            viewMenu.addItem(mi)
        }
        let matMenu = NSMenu()
        for m in FloatMaterialKind.allCases {
            let mi = NSMenuItem(title: m.label, action: #selector(pickMaterial(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = m.rawValue; mi.state = m == material ? .on : .off
            matMenu.addItem(mi)
        }
        let v = NSMenuItem(title: "View", action: nil, keyEquivalent: ""); v.submenu = viewMenu
        let m = NSMenuItem(title: "Material", action: nil, keyEquivalent: ""); m.submenu = matMenu
        menu.addItem(v); menu.addItem(m)
        menu.addItem(withTitle: "Sort by Name", action: #selector(sortByName), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
    @objc private func pickMode(_ s: NSMenuItem) {
        if let raw = s.representedObject as? String, let m = FloatViewMode(rawValue: raw) {
            mode = m; modeControl.selectedSegment = FloatViewMode.allCases.firstIndex(of: m) ?? 0
            filesView.relayout(); filesView.needsDisplay = true
        }
    }
    @objc private func pickMaterial(_ s: NSMenuItem) {
        if let raw = s.representedObject as? String { UserDefaults.standard.set(raw, forKey: ShellSettings.floatMaterial); applyMaterial() }
    }

    // MARK: Moving, edge attach/detach

    /// Drags the window with the mouse; on release, snaps to a nearby edge or detaches from one.
    func moveWindow(with event: NSEvent) {
        panel.performDrag(with: event)
        let screen = panel.screen ?? NSScreen.main
        guard let vis = screen?.visibleFrame else { return }
        let f = panel.frame
        let dist: [(FloatEdge, CGFloat)] = [(.left, f.minX - vis.minX), (.right, vis.maxX - f.maxX),
                                            (.top, vis.maxY - f.maxY), (.bottom, f.minY - vis.minY)]
        let nearest = dist.min { $0.1 < $1.1 }!
        if let current = edge {
            if (dist.first { $0.0 == current }?.1 ?? 0) > 60 { edge = nil; expanded = true; applyAttachment(animated: true) }
        } else if nearest.1 <= 36 {
            edge = nearest.0; expanded = false
            applyAttachment(animated: true)
        }
    }

    private func applyAttachment(animated: Bool) {
        guard let vis = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = panel.frame
        if edge == nil || expanded {
            let size = expandedSize
            f.size = size
        } else {
            f.size = (edge == .left || edge == .right) ? NSSize(width: 86, height: 104) : NSSize(width: 104, height: 86)
        }
        if let edge {
            switch edge {
            case .left: f.origin.x = vis.minX
            case .right: f.origin.x = vis.maxX - f.width
            case .top: f.origin.y = vis.maxY - f.height
            case .bottom: f.origin.y = vis.minY
            }
        }
        f.origin.x = min(max(f.origin.x, vis.minX), vis.maxX - f.width)
        f.origin.y = min(max(f.origin.y, vis.minY), vis.maxY - f.height)
        panel.setFrame(f, display: true, animate: animated)
        collapseButton.image = NSImage(systemSymbolName: edge == .right ? "chevron.compact.right" : "chevron.compact.left", accessibilityDescription: "Collapse Float")
        layoutPieces()
    }

    func windowDidResize(_ notification: Notification) {
        if edge == nil || expanded { expandedSize = panel.frame.size }
        filesView?.relayout()
    }

    // MARK: Drag out

    /// Starts a file drag from `view` carrying `carried` (all selected, or all files from the stack/tab).
    func beginDrag(_ carried: [URL], from view: NSView, event: NSEvent, frames: [URL: NSRect]) {
        let items = carried.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let frame = frames[url] ?? NSRect(x: 0, y: 0, width: 64, height: 64)
            let thumb = thumbnail(for: url)
            item.setDraggingFrame(NSRect(x: frame.midX - 32, y: frame.midY - 32, width: 64, height: 64), contents: thumb)
            return item
        }
        view.beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard operation.contains(.move) else { return }
        let gone = Set(urls.filter { !FileManager.default.fileExists(atPath: $0.path) })
        if !gone.isEmpty { remove(gone) }
    }
}

/// Corner grip: a borderless panel has no resize edge, so this drags the window's size.
final class FloatResizeGrip: NSView {
    weak var panel: NSPanel?
    private var startFrame = NSRect.zero
    private var startMouse = NSPoint.zero
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func draw(_ dirty: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
        for i in 0..<3 {
            let o = CGFloat(4 + i * 4)
            let p = NSBezierPath(); p.move(to: NSPoint(x: bounds.maxX - 2, y: o)); p.line(to: NSPoint(x: bounds.maxX - o - 2, y: 2)); p.stroke()
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) { startFrame = panel?.frame ?? .zero; startMouse = NSEvent.mouseLocation }
    override func mouseDragged(with event: NSEvent) {
        guard let panel else { return }
        let m = NSEvent.mouseLocation
        let w = max(panel.minSize.width, startFrame.width + (m.x - startMouse.x))
        let h = max(panel.minSize.height, startFrame.height - (m.y - startMouse.y))
        panel.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - h, width: w, height: h), display: true)
    }
}
