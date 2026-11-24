import AppKit
import os
import SwiftUI

private let log = Logger(subsystem: "io.github.oscallen-creator.filechanger", category: "fan")

/// One petal on a wheel.
struct FanItem: Identifiable {
    let id: String
    let label: String
    let symbol: String?
    let group: String
    let detail: String          // centre label while hovered
    let run: @MainActor ([URL]) -> Void
}

@MainActor
final class FanModel: ObservableObject {
    @Published var wheel: ShellWheel = .conversion
    @Published var items: [FanItem] = []
    @Published var hovered: Int?
    @Published var centre: CGPoint = .zero      // view coordinates, y down
    @Published var size: CGSize = .zero
    @Published var appeared = false
    @Published var theme = UserDefaults.standard.string(forKey: ShellSettings.fanTheme) ?? "glass"
    @Published var emptyMessage = ""
    var layout = ShellWheelLayout(count: 0)
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: ShellSettings.fanThemeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.theme = UserDefaults.standard.string(forKey: ShellSettings.fanTheme) ?? "glass" }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func setItems(_ items: [FanItem]) {
        self.items = items
        layout = ShellWheelLayout(count: items.count)
        hovered = nil
    }

    func setHovered(_ i: Int?) {
        guard i != hovered else { return }
        hovered = i
        if i != nil { ShellFeedback.hover() }
    }

    func hover(at offset: CGPoint, source: String) {
        let i = layout.hit(offset)
        if i != hovered { log.debug("hovered \(i ?? -1) via \(source)") }
        setHovered(i)
    }

    var centreTitle: String { hovered.flatMap { items.indices.contains($0) ? items[$0].detail : nil } ?? wheel.title }
    var centrePrompt: String { hovered == nil ? (items.isEmpty ? emptyMessage : wheel.prompt) : "" }
}

// MARK: - Drawing

/// Annular sector. Angles are clockwise from 12 o'clock.
struct PetalShape: Shape {
    let inner: CGFloat, outer: CGFloat, start: CGFloat, end: CGFloat
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        func pt(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: c.x + sin(a) * r, y: c.y - cos(a) * r) }
        let pad: CGFloat = 0.018   // visible gap between petals
        let a0 = start + pad, a1 = end - pad
        let steps = max(4, Int((a1 - a0) / (.pi / 60)))
        var p = Path()
        p.move(to: pt(outer, a0))
        for s in 1...steps { p.addLine(to: pt(outer, a0 + (a1 - a0) * CGFloat(s) / CGFloat(steps))) }
        for s in (0...steps).reversed() { p.addLine(to: pt(inner, a0 + (a1 - a0) * CGFloat(s) / CGFloat(steps))) }
        p.closeSubpath()
        return p
    }
}

struct FanView: View {
    @ObservedObject var model: FanModel

    private var metallic: Bool { model.theme == "metallic" }

    var body: some View {
        ZStack {
            wheelBody
                .frame(width: model.size.width, height: model.size.height)
                .position(x: model.centre.x, y: model.centre.y)
                .scaleEffect(model.appeared ? 1 : 0.7, anchor: UnitPoint(x: model.centre.x / max(1, model.size.width),
                                                                          y: model.centre.y / max(1, model.size.height)))
                .opacity(model.appeared ? 1 : 0)
        }
        .frame(width: model.size.width, height: model.size.height)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: model.appeared)
        .animation(.easeOut(duration: 0.12), value: model.hovered)
    }

    private var wheelBody: some View {
        let layout = model.layout
        let groups = Array(NSOrderedSet(array: model.items.map(\.group))) as? [String] ?? []
        return ZStack {
            Circle()
                .fill(metallic ? AnyShapeStyle(LinearGradient(colors: [Color(white: 0.27), Color(white: 0.14)], startPoint: .top, endPoint: .bottom))
                               : AnyShapeStyle(.ultraThinMaterial))
                .frame(width: (layout.radius + 8) * 2, height: (layout.radius + 8) * 2)
                .overlay(Circle().strokeBorder(Brand.accent.opacity(0.55), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            ForEach(layout.petals, id: \.index) { p in
                let item = model.items[p.index]
                let hot = model.hovered == p.index
                let shape = PetalShape(inner: p.innerRadius, outer: p.outerRadius, start: p.startAngle, end: p.endAngle)
                shape.fill(petalFill(hot: hot, group: groups.firstIndex(of: item.group) ?? 0, groupCount: groups.count))
                    .overlay(shape.stroke(Color.white.opacity(hot ? 0.8 : 0.28), lineWidth: hot ? 1.5 : 0.8))
                    .shadow(color: hot ? Brand.accent.opacity(0.6) : .clear, radius: 8)
                    .scaleEffect(hot ? 1.04 : 1)
                petalLabel(item, hot: hot)
                    .position(x: model.size.width / 2 + layout.labelOffset(of: p).x,
                              y: model.size.height / 2 + layout.labelOffset(of: p).y)
            }
            hub
        }
    }

    private func petalFill(hot: Bool, group: Int, groupCount: Int) -> AnyShapeStyle {
        if hot { return AnyShapeStyle(Brand.accent) }
        if metallic {
            let w = 0.62 - 0.1 * Double(group % 3)
            return AnyShapeStyle(LinearGradient(colors: [Color(white: min(0.88, w + 0.22)), Color(white: w - 0.12)], startPoint: .top, endPoint: .bottom))
        }
        // Alternate groups get a slightly different strength of lime so grouped formats read as clusters.
        return AnyShapeStyle(Brand.accent.opacity(group % 2 == 0 ? 0.34 : 0.22))
    }

    private func petalLabel(_ item: FanItem, hot: Bool) -> some View {
        VStack(spacing: 2) {
            if let s = item.symbol { Image(systemName: s).font(.system(size: 15, weight: .medium)) }
            Text(item.label).font(.system(size: model.items.count > 10 ? 10.5 : 11.5, weight: .semibold)).lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(hot ? Brand.onAccent : (metallic ? Color.black.opacity(0.8) : Color.white))
        .shadow(color: .black.opacity(metallic || hot ? 0 : 0.35), radius: 1)
        .frame(width: 60)
        .allowsHitTesting(false)
    }

    private var hub: some View {
        let r = ShellWheelLayout.hubRadius
        return ZStack {
            Circle().fill(metallic ? AnyShapeStyle(Color(white: 0.12)) : AnyShapeStyle(.regularMaterial))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            VStack(spacing: 3) {
                Text(model.centreTitle)
                    .font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center).lineLimit(3)
                    .foregroundStyle(model.hovered == nil ? Color.white : Brand.accent)
                if !model.centrePrompt.isEmpty {
                    Text(model.centrePrompt).font(.system(size: 9.5)).multilineTextAlignment(.center)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(width: r * 2, height: r * 2)
        .allowsHitTesting(false)
    }
}

// MARK: - Panel and drop target

/// Transparent, non-activating, screen-saver-level panel. It is a real drag destination, so the drag
/// that started in Finder (or anywhere) continues over it and can be dropped on a petal.
final class FanPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FanDropView: NSView {
    let model: FanModel
    var onDrop: ((Int, [URL]) -> Void)?
    var onClickItem: ((Int) -> Void)?
    var onClickHub: (() -> Void)?
    var onDragExit: (() -> Void)?
    var onDragEnter: (() -> Void)?
    var onDragEnd: (() -> Void)?

    init(model: FanModel, frame: NSRect) {
        self.model = model
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        let host = NSHostingView(rootView: FanView(model: model))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { nil }

    /// Keep the hosting view out of drag/mouse routing, and let the transparent corners fall through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let d = hypot(p.x - model.centre.x, (bounds.height - p.y) - model.centre.y)
        return d <= model.layout.radius + 12 ? self : nil
    }
    override var acceptsFirstResponder: Bool { true }

    // model.centre is y-down; flip the NSView point (y-up) to y-down first.
    private func offsetFromWindow(_ p: NSPoint) -> CGPoint {
        let l = convert(p, from: nil)
        return CGPoint(x: l.x - model.centre.x, y: (bounds.height - l.y) - model.centre.y)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        log.debug("draggingEntered")
        onDragEnter?()
        model.hover(at: offsetFromWindow(sender.draggingLocation), source: "drag-destination")
        return shellDragOperation(allowed: sender.draggingSourceOperationMask)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        model.hover(at: offsetFromWindow(sender.draggingLocation), source: "drag-destination")
        return shellDragOperation(allowed: sender.draggingSourceOperationMask)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        log.debug("draggingExited")
        model.setHovered(nil)
        onDragExit?()
    }
    /// A rejected drop (hub, gap) or a cancelled drag still ends here: always close the wheel.
    override func draggingEnded(_ sender: NSDraggingInfo) { log.debug("draggingEnded"); onDragEnd?() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        model.layout.hit(offsetFromWindow(sender.draggingLocation)) != nil
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let i = model.layout.hit(offsetFromWindow(sender.draggingLocation)) else { return false }
        log.debug("performDragOperation \(i)")
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(i, urls)
        return true
    }

    // Click mode (files opened on the app icon): hover with the mouse, click a petal, click the hub to switch wheel.
    override func mouseMoved(with event: NSEvent) { model.hover(at: offsetFromWindow(event.locationInWindow), source: "mouse") }
    /// Click mode runs in an inactive accessory app: the first click must reach us, not just activate.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let o = offsetFromWindow(event.locationInWindow)
        if let i = model.layout.hit(o) { onClickItem?(i) }
        else if hypot(o.x, o.y) < ShellWheelLayout.hubRadius { onClickHub?() }
    }
}

// MARK: - Controller

@MainActor
final class ShellFan {
    static let shared = ShellFan()
    private var panel: FanPanel?
    private let model = FanModel()
    private var files: [URL] = []
    private var keyMonitors: [Any] = []
    private var exitWork: DispatchWorkItem?
    private(set) var clickMode = false

    var isVisible: Bool { panel?.isVisible ?? false }
    var currentWheel: ShellWheel? { isVisible ? model.wheel : nil }

    /// Tap on a wheel's modifier: open it, switch to it, or close it when it is already showing.
    func toggle(_ wheel: ShellWheel, files: [URL], at point: NSPoint) {
        if isVisible, model.wheel == wheel { dismiss(); return }
        show(wheel, files: files, at: point)
    }

    func show(_ wheel: ShellWheel, files: [URL], at cursor: NSPoint, clickMode: Bool = false) {
        self.files = files
        self.clickMode = clickMode
        log.debug("show \(wheel.title) how: \(clickMode ? "click" : "hold/tap")")
        model.wheel = wheel
        model.emptyMessage = wheel == .conversion ? "No formats for these files" : "No tools for these files"
        model.setItems(items(for: wheel, files: files))
        let side = max(300, model.layout.diameter)
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main ?? NSScreen.screens[0]
        // Keep the whole wheel on screen: near an edge the centre slides inward.
        let inset = model.layout.radius + 14
        let area = screen.frame.insetBy(dx: min(inset, screen.frame.width / 2), dy: min(inset, screen.frame.height / 2))
        let point = NSPoint(x: min(max(cursor.x, area.minX), area.maxX), y: min(max(cursor.y, area.minY), area.maxY))
        let frame = NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        model.size = frame.size
        model.centre = CGPoint(x: point.x - frame.origin.x, y: frame.height - (point.y - frame.origin.y))
        let wasVisible = isVisible
        exitWork?.cancel()

        let p: FanPanel
        if let existing = panel { p = existing }
        else {
            p = FanPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .screenSaver
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.acceptsMouseMovedEvents = true
            panel = p
        }
        p.setFrame(frame, display: false)
        let view = FanDropView(model: model, frame: NSRect(origin: .zero, size: frame.size))
        view.onDrop = { [weak self] i, urls in self?.drop(i, urls) }
        view.onClickItem = { [weak self] i in guard let self else { return }; self.drop(i, self.files) }
        view.onClickHub = { [weak self] in self?.cycleWheel() }
        view.onDragEnd = { [weak self] in
            // Let a successful drop's own dismissal run first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let self, !self.keepAsClickMenu(at: NSEvent.mouseLocation) else { return }
                self.dismiss()
            }
        }
        view.onDragEnter = { [weak self] in self?.exitWork?.cancel() }
        view.onDragExit = { [weak self] in self?.scheduleDismiss() }
        p.contentView = view
        if !wasVisible { model.appeared = false }
        p.orderFrontRegardless()
        DispatchQueue.main.async { [model] in model.appeared = true }
        installKeyMonitors()
    }

    /// Global drag events keep flowing during a drag even when the panel gets no dragging callbacks.
    /// `screen` is in AppKit screen coordinates (y up); the wheel offset is y down from the hub.
    func hover(atScreen screen: NSPoint) {
        guard let p = panel, p.isVisible else { return }
        model.hover(at: CGPoint(x: screen.x - p.frame.minX - model.centre.x,
                                y: (p.frame.maxY - screen.y) - model.centre.y), source: "monitor")
    }

    /// The drag ended without a drop. A release inside the wheel keeps it open as a click menu.
    /// Returns true when it did.
    @discardableResult
    func keepAsClickMenu(at screen: NSPoint) -> Bool {
        guard let p = panel, p.isVisible, model.appeared, !clickMode else { return clickMode }
        let d = hypot(screen.x - (p.frame.minX + model.centre.x), screen.y - (p.frame.maxY - model.centre.y))
        guard d <= model.layout.radius + 8 else { return false }
        log.debug("switch to click mode")
        clickMode = true
        exitWork?.cancel()
        return true
    }

    func dismiss() {
        exitWork?.cancel()
        clickMode = false
        guard let p = panel, p.isVisible else { return }
        model.appeared = false
        for m in keyMonitors { NSEvent.removeMonitor(m) }
        keyMonitors = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, !self.model.appeared else { return }
            p.orderOut(nil)
            p.contentView = nil
        }
    }

    /// Dragging away from the wheel (the cursor leaves the panel) dismisses it after a short grace period.
    private func scheduleDismiss() {
        exitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.dismiss() } }
        exitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func cycleWheel() {
        guard clickMode, let panel else { return }
        let all = ShellWheel.allCases
        let next = all[(all.firstIndex(of: model.wheel)! + 1) % all.count]
        show(next, files: files, at: NSPoint(x: panel.frame.minX + model.centre.x, y: panel.frame.maxY - model.centre.y), clickMode: true)
    }

    private func drop(_ index: Int, _ urls: [URL]) {
        guard model.items.indices.contains(index) else { dismiss(); return }
        let item = model.items[index]
        dismiss()
        DispatchQueue.main.async { item.run(urls) }
    }

    private func installKeyMonitors() {
        guard keyMonitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] e in
            MainActor.assumeIsolated {
                if e.keyCode == 53 { self?.dismiss() }                       // Escape
                else if e.keyCode == 43 { self?.dismiss(); ShellSettingsWindow.show() }   // comma opens Settings (SHL-80)
            }
        }
        keyMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) as Any)
        keyMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in handler(e); return e } as Any)
    }

    private func items(for wheel: ShellWheel, files: [URL]) -> [FanItem] {
        switch wheel {
        case .conversion:
            let targets = shellGroupedOrder(Conversions.targets(for: files), group: \.group)
            return targets.map { t in
                FanItem(id: t.id, label: t.label, symbol: nil, group: t.group, detail: "Convert to \(t.label)") { urls in
                    ShellJobs.convert(urls, to: t)
                }
            }
        case .tools:
            return Catalog.tools(for: files).map { spec in
                FanItem(id: spec.id, label: shellDisplayLabel(spec.wheelLabel), symbol: spec.symbol, group: "tools", detail: spec.title) { urls in
                    ToolPanel.present(spec, files: urls)
                }
            }
        case .actions:
            return ShellActionRunner.all.map { a in
                FanItem(id: a.id, label: a.label, symbol: a.symbol, group: "actions", detail: a.detail) { urls in
                    ShellActionRunner.run(a.id, files: urls)
                }
            }
        }
    }
}
