import AppKit
import SwiftUI

@MainActor
enum ShellWelcomeWindow {
    private static var window: NSWindow?
    private static let closer = WelcomeCloseObserver()

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Welcome to FileChanger"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: WelcomeView(finish: { finish() }))
            w.center()
            w.delegate = closer
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func finish() { window?.close() }
}

/// Any way of closing Welcome (red button, Finish setup) completes it; then the permission alert may show.
final class WelcomeCloseObserver: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: ShellSettings.completedWelcome)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ShellDragMonitor.shared.promptIfNeeded() }
    }
}

private enum WelcomePage: Int, CaseIterable {
    case intro, photo, conversion, tools, actions, practice, login
}

struct WelcomeView: View {
    let finish: () -> Void
    @State private var page = WelcomePage.intro

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case .intro: intro
                case .photo: wheelPage(icon: "photo.on.rectangle.angled", title: "Drag files anywhere",
                                       text: "Drag files from Finder, your desktop or any app. While you hold them, tap a modifier key and a wheel opens at your cursor.",
                                       wheel: .conversion, demo: false)
                case .conversion: wheelPage(icon: "arrow.triangle.2.circlepath", title: "Conversion wheel",
                                            text: "Keep dragging and tap \(ShellModifierStore.mask(for: .conversion).display) to open the Conversion wheel. Drop on a format. The new copy is saved next to the original.",
                                            wheel: .conversion, keys: ShellModifierStore.mask(for: .conversion))
                case .tools: wheelPage(icon: "wrench.and.screwdriver", title: "Tools wheel",
                                       text: "Tap \(ShellModifierStore.mask(for: .tools).display) while dragging to open the Tools wheel: compress, trim, resize, merge and more.",
                                       wheel: .tools, keys: ShellModifierStore.mask(for: .tools))
                case .actions: wheelPage(icon: "square.stack.3d.up", title: "Actions wheel",
                                         text: "Tap \(ShellModifierStore.mask(for: .actions).display) for quick actions: open your terminal in the file's folder, copy paths, move, copy files, float them in a stack, or AirDrop.",
                                         wheel: .actions, keys: ShellModifierStore.mask(for: .actions))
                case .practice: WelcomePractice()
                case .login: login
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            Divider()
            nav
        }
        .tint(Brand.accent)
        .frame(width: 640, height: 520)
    }

    private var nav: some View {
        HStack {
            if page != .intro { Button { go(-1) } label: { Label("Back", systemImage: "arrow.left") } }
            Spacer()
            HStack(spacing: 6) {
                ForEach(WelcomePage.allCases, id: \.rawValue) { p in
                    Circle().fill(p == page ? Brand.accent : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                }
            }
            Spacer()
            if page == .login {
                Button("Finish setup") { finish() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                if page == .practice { Button("Skip") { go(1) } }
                Button("Continue") { go(1) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func go(_ d: Int) {
        withAnimation { page = WelcomePage(rawValue: max(0, min(WelcomePage.allCases.count - 1, page.rawValue + d))) ?? page }
    }

    private var intro: some View {
        VStack(spacing: 14) {
            Image(systemName: "circle.hexagongrid.fill").font(.system(size: 64)).foregroundStyle(Brand.accent)
            Text("Welcome to FileChanger").font(.largeTitle.bold())
            Text("Convert files, use quick tools and run file actions without opening an app.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Label("Find the FileChanger icon near the clock in your menu bar", systemImage: "arrow.up.right")
                .padding(.top, 10)
        }
        .padding(40)
    }

    private func wheelPage(icon: String, title: String, text: String, wheel: ShellWheel,
                           keys: ShellModifierMask? = nil, demo: Bool = true) -> some View {
        VStack(spacing: 12) {
            WelcomeWheelDemo(wheel: wheel).frame(width: 300, height: 300)
            Label(title, systemImage: icon).font(.title2.bold())
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 50)
            if let keys {
                HStack(spacing: 8) {
                    Text("Tap").foregroundStyle(.secondary)
                    ModifierKeyCaps(mask: keys)
                }
            }
            Text("It works the same with files in Finder and on your desktop.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var login: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose whether FileChanger launches at login. You can change these options and your shortcuts in Settings.")
                .foregroundStyle(.secondary)
            LoginItemRow()
        }
        .padding(50)
    }
}

/// A static wheel that cycles a highlight through its petals.
struct WelcomeWheelDemo: View {
    let wheel: ShellWheel
    @StateObject private var model = FanModel()
    private let timer = Timer.publish(every: 1.1, on: .main, in: .common).autoconnect()

    var body: some View {
        FanView(model: model)
            .scaleEffect(0.78)
            .onAppear {
                let labels: [(String, String?)]
                switch wheel {
                case .conversion: labels = ["PNG", "JPG", "WEBP", "HEIC", "PDF", "TIFF"].map { ($0, nil) }
                case .tools: labels = [("Compress", "arrow.down.right.and.arrow.up.left"), ("Resize", "arrow.up.left.and.arrow.down.right"),
                                       ("Trim", "scissors"), ("Merge", "doc.on.doc"), ("Metadata", "eye.slash"), ("Collage", "square.grid.2x2")]
                case .actions: labels = ShellActionRunner.all.map { ($0.label, $0.symbol) }
                }
                model.wheel = wheel
                model.setItems(labels.map { FanItem(id: $0.0, label: $0.0, symbol: $0.1, group: "demo", detail: $0.0, run: { _ in }) })
                model.size = CGSize(width: 380, height: 380)
                model.centre = CGPoint(x: 190, y: 190)
                model.appeared = true
            }
            .onReceive(timer) { _ in
                guard !model.items.isEmpty else { return }
                model.hovered = ((model.hovered ?? -1) + 1) % model.items.count
            }
    }
}

/// Practice step: drag the sample file, tap the modifier, drop on a petal. Works without real files.
struct WelcomePractice: View {
    @State private var dragging = false
    @State private var showWheel = false
    @State private var saved = false
    @State private var monitor: Any?
    @State private var tap = ShellTapDetector()
    private let sampleURL: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Sample photo.png")
        if !FileManager.default.fileExists(atPath: url.path) {
            let img = NSImage(size: NSSize(width: 96, height: 64), flipped: false) { r in
                NSGradient(colors: [NSColor.systemOrange, NSColor.systemPink])?.draw(in: r, angle: 20); return true
            }
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
        }
        return url
    }()

    var body: some View {
        VStack(spacing: 12) {
            Text("Try it").font(.title2.bold())
            if saved {
                Label("Saved next to the original", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
                Text("The original stays unchanged.").foregroundStyle(.secondary)
                Button("Try again") { saved = false; showWheel = false }
            } else {
                HStack(spacing: 6) {
                    Text("Step 1. Drag files.")
                    Text("Step 2. While dragging, tap").foregroundStyle(.secondary)
                    ModifierKeyCaps(mask: ShellModifierStore.mask(for: .conversion))
                }
                .font(.callout)
                ZStack {
                    sample
                    if showWheel { practiceWheel.transition(.scale.combined(with: .opacity)) }
                }
                .frame(width: 330, height: 330)
                Text(showWheel ? "Move onto an option in the wheel and let go." : "Drag the sample file.")
                    .foregroundStyle(.secondary)
                Button(showWheel ? "Hide wheel" : "Show the wheel") { withAnimation { showWheel.toggle() } }
                    .controlSize(.small)
            }
        }
        .padding(.top, 20)
        .onAppear(perform: observe)
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }

    private var sample: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 96, height: 64)
            Text("Sample photo.png").font(.caption)
            Text("2.4 MB").font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityLabel("Sample file, landscape")
        .onDrag {
            dragging = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { dragging = false }
            return NSItemProvider(contentsOf: sampleURL) ?? NSItemProvider()
        }
    }

    private var practiceWheel: some View {
        let items = ["PNG", "JPG", "WEBP", "HEIC", "PDF", "TIFF"]
        let layout = ShellWheelLayout(count: items.count)
        return ZStack {
            ForEach(layout.petals, id: \.index) { p in
                PracticePetal(petal: p, label: items[p.index]) { withAnimation { saved = true } }
                    .frame(width: 330, height: 330)
            }
        }
    }

    /// Practice taps of the real modifier combination (local monitor: this is our own window's drag).
    private func observe() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { e in
            if e.type == .keyDown { tap.otherInput(); return e }
            let mask = ShellModifierMask(flags: e.modifierFlags.intersection(.deviceIndependentFlagsMask))
            if let tapped = tap.flagsChanged(mask, at: e.timestamp), tapped == ShellModifierStore.mask(for: .conversion) {
                withAnimation { showWheel = true }
            }
            return e
        }
    }
}

private struct PracticePetal: View {
    let petal: ShellWheelLayout.Petal
    let label: String
    let done: () -> Void
    @State private var hot = false

    var body: some View {
        let shape = PetalShape(inner: petal.innerRadius, outer: petal.outerRadius, start: petal.startAngle, end: petal.endAngle)
        let offset = ShellWheelLayout(count: 6).labelOffset(of: petal)
        ZStack {
            shape.fill(hot ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.regularMaterial))
                .overlay(shape.stroke(Color.primary.opacity(0.25)))
                .contentShape(shape)
                .onTapGesture(perform: done)
                .onDrop(of: [.fileURL, .item], isTargeted: $hot) { _ in done(); return true }
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(hot ? .white : .primary)
                .offset(x: offset.x, y: offset.y).allowsHitTesting(false)
        }
    }
}
