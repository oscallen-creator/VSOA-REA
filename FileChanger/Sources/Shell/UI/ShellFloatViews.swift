import AppKit
import QuickLookUI

/// The file area of a Float: grid, list or stack of thumbnails with selection, rubber band, drag out,
/// double-click open, Space for Quick Look, Delete to remove, and a context menu (SHL-52..64).
final class FloatFilesView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    unowned let controller: FloatController
    var selection = Set<URL>() { didSet { controller.refreshSummaryOnly() } }
    private var rects: [URL: NSRect] = [:]
    private var stackRect = NSRect.zero
    private var pressed: URL?
    private var pressPoint = NSPoint.zero
    private var extendedOnPress = false
    private var rubberStart: NSPoint?
    private var rubberRect = NSRect.zero
    private var baseSelection = Set<URL>()
    private var didDrag = false

    private let cellW: CGFloat = 96, cellH: CGFloat = 108, rowH: CGFloat = 30, pad: CGFloat = 10

    init(controller: FloatController) {
        self.controller = controller
        super.init(frame: .zero)
        setAccessibilityLabel("File selection area. Drag empty space to select multiple files.")
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var urls: [URL] { controller.urls }

    // MARK: Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        computeRects()
    }

    func relayout() {
        let visible = enclosingScrollView?.contentSize ?? NSSize(width: 300, height: 200)
        let needed = computeRects(width: visible.width)
        let h = max(needed, visible.height)
        if abs(frame.height - h) > 0.5 || abs(frame.width - visible.width) > 0.5 {
            super.setFrameSize(NSSize(width: visible.width, height: h))
        }
        computeRects()
        needsDisplay = true
    }

    private func computeRects() { computeRects(width: bounds.width) }

    @discardableResult
    private func computeRects(width: CGFloat) -> CGFloat {
        rects = [:]
        switch controller.mode {
        case .grid:
            let cols = max(1, Int((width - pad) / cellW))
            for (i, u) in urls.enumerated() {
                rects[u] = NSRect(x: pad + CGFloat(i % cols) * cellW, y: pad + CGFloat(i / cols) * cellH, width: cellW, height: cellH)
            }
            return pad * 2 + CGFloat((urls.count + cols - 1) / cols) * cellH
        case .list:
            for (i, u) in urls.enumerated() { rects[u] = NSRect(x: 6, y: 6 + CGFloat(i) * rowH, width: max(0, width - 12), height: rowH) }
            return 12 + CGFloat(urls.count) * rowH
        case .stack:
            let h = max(200, enclosingScrollView?.contentSize.height ?? 200)
            stackRect = NSRect(x: width / 2 - 70, y: h / 2 - 90, width: 140, height: 160)
            for u in urls { rects[u] = stackRect }
            return h
        }
    }

    private func url(at p: NSPoint) -> URL? {
        if controller.mode == .stack { return stackRect.contains(p) ? urls.first : nil }
        return urls.reversed().first { rects[$0]?.contains(p) == true }
    }

    // MARK: Drawing

    override func draw(_ dirty: NSRect) {
        switch controller.mode {
        case .stack: drawStack()
        case .grid, .list:
            for u in urls {
                guard let r = rects[u], r.intersects(dirty) else { continue }
                if selection.contains(u) {
                    Brand.nsAccent.withAlphaComponent(0.28).setFill()
                    NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
                }
                controller.mode == .grid ? drawCell(u, r) : drawRow(u, r)
            }
        }
        if rubberStart != nil {
            Brand.nsAccent.withAlphaComponent(0.15).setFill(); rubberRect.fill()
            Brand.nsAccent.setStroke(); NSBezierPath(rect: rubberRect).stroke()
        }
    }

    private func drawCell(_ u: URL, _ r: NSRect) {
        let thumb = controller.thumbnail(for: u)
        draw(image: thumb, in: NSRect(x: r.midX - 32, y: r.minY + 8, width: 64, height: 64))
        draw(name: u.lastPathComponent, in: NSRect(x: r.minX + 4, y: r.minY + 76, width: r.width - 8, height: 30), center: true, lines: 2, selected: selection.contains(u))
    }

    private func drawRow(_ u: URL, _ r: NSRect) {
        draw(image: controller.thumbnail(for: u), in: NSRect(x: r.minX + 8, y: r.minY + 4, width: 22, height: 22))
        draw(name: u.lastPathComponent, in: NSRect(x: r.minX + 38, y: r.minY + 7, width: r.width - 46, height: 18), center: false, lines: 1, selected: selection.contains(u))
    }

    private func drawStack() {
        guard !urls.isEmpty else { return }
        let r = stackRect
        let shown = Array(urls.prefix(4))
        for (i, u) in shown.enumerated().reversed() {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.saveGState()
            ctx.translateBy(x: r.midX, y: r.minY + 70)
            ctx.rotate(by: CGFloat(i) * 0.09 * (i % 2 == 0 ? 1 : -1))
            draw(image: controller.thumbnail(for: u), in: NSRect(x: -52, y: -52, width: 104, height: 104))
            ctx.restoreGState()
        }
        let label = "\(urls.count) file\(urls.count == 1 ? "" : "s")"
        draw(name: label, in: NSRect(x: r.minX, y: r.maxY - 28, width: r.width, height: 20), center: true, lines: 1, selected: !selection.isEmpty)
    }

    private func draw(image: NSImage, in rect: NSRect) {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return }
        let k = min(rect.width / s.width, rect.height / s.height)
        let target = NSRect(x: rect.midX - s.width * k / 2, y: rect.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func draw(name: String, in rect: NSRect, center: Bool, lines: Int, selected: Bool) {
        let p = NSMutableParagraphStyle()
        p.alignment = center ? .center : .left
        p.lineBreakMode = lines > 1 ? .byTruncatingTail : .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: p,
                                                    .foregroundColor: NSColor.labelColor]
        (name as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        didDrag = false
        pressPoint = p
        extendedOnPress = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
        if let u = url(at: p) {
            pressed = u
            if event.clickCount == 2 { urls.isEmpty ? () : open(controller.mode == .stack ? urls : [u]); return }
            if extendedOnPress {
                if selection.contains(u) { selection.remove(u) } else { selection.insert(u) }
            } else if !selection.contains(u) {
                selection = controller.mode == .stack ? Set(urls) : [u]
            }
        } else {
            pressed = nil
            if !extendedOnPress { selection = [] }
            baseSelection = selection
            rubberStart = p
            rubberRect = NSRect(origin: p, size: .zero)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let start = rubberStart {
            rubberRect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            let hit = Set(urls.filter { rects[$0]?.intersects(rubberRect) == true })
            selection = extendedOnPress ? baseSelection.union(hit) : hit
            autoscroll(with: event)
            needsDisplay = true
            return
        }
        guard !didDrag, let pressed, hypot(p.x - pressPoint.x, p.y - pressPoint.y) > 4 else { return }
        didDrag = true
        let carried: [URL]
        if controller.mode == .stack { carried = urls }
        else { carried = urls.filter { selection.contains($0) || $0 == pressed } }
        controller.beginDrag(carried, from: self, event: event, frames: rects)
    }

    override func mouseUp(with event: NSEvent) {
        if rubberStart != nil { rubberStart = nil; needsDisplay = true; return }
        // A plain click on one item of a multi-selection narrows to it.
        if !didDrag, !extendedOnPress, event.clickCount == 1, let pressed, controller.mode != .stack, selection.count > 1 {
            selection = [pressed]; needsDisplay = true
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: toggleQuickLook()                                  // Space
        case 51, 117: removeSelected()                              // Delete, Forward Delete
        case 36, 76: open(selection.isEmpty ? [] : Array(selection)) // Return
        case 0 where event.modifierFlags.contains(.command): selection = Set(urls); needsDisplay = true
        default: super.keyDown(with: event)
        }
    }

    override func selectAll(_ sender: Any?) { selection = Set(urls); needsDisplay = true }

    func removeSelected() {
        guard !selection.isEmpty else { return }
        controller.remove(selection)
    }

    private func open(_ list: [URL]) { for u in list { NSWorkspace.shared.open(u) } }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let u = url(at: p) else { return nil }
        if !selection.contains(u) { selection = [u]; needsDisplay = true }
        let targets = urls.filter { selection.contains($0) }
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self; m.addItem(mi)
        }
        add("Open", #selector(menuOpen))
        add("Quick Look", #selector(menuQuickLook))
        add("Show in Finder", #selector(menuReveal))
        m.addItem(.separator())
        add("Copy", #selector(menuCopy))
        add("Duplicate", #selector(menuDuplicate))
        add("Share", #selector(menuShare))
        m.addItem(.separator())
        add("Move to Trash", #selector(menuTrash))
        let withItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        withItem.submenu = openWithMenu(for: targets.first ?? u)
        m.addItem(withItem)
        m.addItem(.separator())
        add("Remove from Float", #selector(menuRemove))
        return m
    }

    private func openWithMenu(for url: URL) -> NSMenu {
        let sub = NSMenu()
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        if apps.isEmpty {
            let none = NSMenuItem(title: "No Applications Available", action: nil, keyEquivalent: ""); none.isEnabled = false
            sub.addItem(none)
        }
        for app in apps.prefix(20) {
            let mi = NSMenuItem(title: FileManager.default.displayName(atPath: app.path), action: #selector(menuOpenWith(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path); icon.size = NSSize(width: 16, height: 16)
            mi.image = icon
            sub.addItem(mi)
        }
        return sub
    }

    private var targets: [URL] { urls.filter { selection.contains($0) } }
    @objc private func menuOpen() { open(targets) }
    @objc private func menuQuickLook() { toggleQuickLook() }
    @objc private func menuReveal() { NSWorkspace.shared.activateFileViewerSelecting(targets) }
    @objc private func menuCopy() { try? ShellFileActions.copyFiles(targets) }
    @objc private func menuRemove() { removeSelected() }
    @objc private func menuShare() {
        guard let u = targets.first, let r = rects[u] else { return }
        NSSharingServicePicker(items: targets).show(relativeTo: r, of: self, preferredEdge: .minY)
    }
    @objc private func menuDuplicate() {
        var added: [URL] = []
        for u in targets {
            let ext = u.pathExtension
            var copy = u.deletingLastPathComponent().appendingPathComponent(u.deletingPathExtension().lastPathComponent + " copy")
            if !ext.isEmpty { copy.appendPathExtension(ext) }
            let dest = OutputLocation.unique(copy)
            if (try? FileManager.default.copyItem(at: u, to: dest)) != nil { added.append(dest) }
        }
        controller.add(added)
    }
    @objc private func menuTrash() {
        var gone = Set<URL>()
        for u in targets where (try? FileManager.default.trashItem(at: u, resultingItemURL: nil)) != nil { gone.insert(u) }
        if !gone.isEmpty { controller.remove(gone) }
    }
    @objc private func menuOpenWith(_ item: NSMenuItem) {
        guard let app = item.representedObject as? URL else { return }
        NSWorkspace.shared.open(targets, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Quick Look

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    private var previewURLs: [URL] { selection.isEmpty ? urls : urls.filter { selection.contains($0) } }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURLs.indices.contains(index) ? previewURLs[index] as NSURL : nil
    }
}

/// Collapsed edge tab: a stack of thumbnails clipped with a paper clip, plus the file count.
/// Click expands; dragging the body carries every file; the top grip moves/detaches the Float.
final class FloatTabView: NSView {
    unowned let controller: FloatController
    private var pressPoint = NSPoint.zero
    private var didDrag = false
    private let gripHeight: CGFloat = 16

    init(controller: FloatController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        let n = controller.urls.count
        setAccessibilityLabel("Expand Float, \(n) file\(n == 1 ? "" : "s"). Drag to move.")
        // grip
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 14, y: 6, width: 28, height: 4), xRadius: 2, yRadius: 2).fill()
        let stackCentre = NSPoint(x: bounds.midX, y: bounds.midY + 4)
        for (i, u) in controller.urls.prefix(3).enumerated().reversed() {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.saveGState()
            ctx.translateBy(x: stackCentre.x, y: stackCentre.y)
            ctx.rotate(by: CGFloat(i) * 0.12 * (i % 2 == 0 ? 1 : -1))
            let img = controller.thumbnail(for: u)
            img.draw(in: NSRect(x: -26, y: -26, width: 52, height: 52), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            ctx.restoreGState()
        }
        drawPaperClip(at: NSPoint(x: stackCentre.x + 14, y: stackCentre.y - 34))
        let label = "\(n)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attrs)
        let badge = NSRect(x: bounds.maxX - size.width - 20, y: bounds.maxY - 22, width: size.width + 12, height: 17)
        Brand.nsAccent.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 8.5, yRadius: 8.5).fill()
        label.draw(at: NSPoint(x: badge.minX + 6, y: badge.minY + 2), withAttributes: attrs)
    }

    /// Own vector paper clip (two nested open loops), drawn with strokes only.
    private func drawPaperClip(at o: NSPoint) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: o.x, y: o.y + 22))
        p.line(to: NSPoint(x: o.x, y: o.y + 4))
        p.appendArc(withCenter: NSPoint(x: o.x + 4, y: o.y + 4), radius: 4, startAngle: 180, endAngle: 360)
        p.line(to: NSPoint(x: o.x + 8, y: o.y + 18))
        p.appendArc(withCenter: NSPoint(x: o.x + 5, y: o.y + 18), radius: 3, startAngle: 0, endAngle: 180, clockwise: true)
        p.line(to: NSPoint(x: o.x + 2, y: o.y + 8))
        p.lineWidth = 1.6
        p.lineCapStyle = .round
        NSColor.systemGray.setStroke()
        p.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressPoint = p
        didDrag = false
        if p.y < gripHeight { controller.moveWindow(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard !didDrag, pressPoint.y >= gripHeight, hypot(p.x - pressPoint.x, p.y - pressPoint.y) > 4 else { return }
        didDrag = true
        let frames = Dictionary(uniqueKeysWithValues: controller.urls.map { ($0, NSRect(x: bounds.midX - 32, y: bounds.midY - 32, width: 64, height: 64)) })
        controller.beginDrag(controller.urls, from: self, event: event, frames: frames)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag, pressPoint.y >= gripHeight { controller.expand() }
    }
}
