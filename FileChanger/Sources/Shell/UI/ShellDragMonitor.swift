import AppKit
import ApplicationServices

/// Watches for file drags anywhere on screen and opens a wheel when the user TAPS a wheel's
/// modifier combination mid-drag (SHL-08). Global monitors see other apps' events only, which is
/// exactly what we want: the practice wheel in Welcome uses its own local observer.
@MainActor
final class ShellDragMonitor {
    static let shared = ShellDragMonitor()

    private var monitors: [Any] = []
    private var tap = ShellTapDetector()
    private var pressChangeCount = 0
    private(set) var files: [URL] = []
    private var trustTimer: Timer?

    var isDraggingFiles: Bool { !files.isEmpty }

    func start() {
        install()
        if !AXIsProcessTrusted() {
            if UserDefaults.standard.bool(forKey: ShellSettings.completedWelcome) { promptForAccessOnce() }
            // Monitors created before the grant stay deaf until recreated; recreate as soon as trust appears.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    t.invalidate()
                    self?.trustTimer = nil
                    self?.install()
                }
            }
        }
    }

    private func install() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged, .keyDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(m) }
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            if ShellFan.shared.clickMode { ShellFan.shared.dismiss() }   // global monitors only see clicks outside our windows
            pressChangeCount = NSPasteboard(name: .drag).changeCount
            files = []
            tap.reset()
        case .leftMouseDragged:
            if files.isEmpty {
                files = fileDragContents()
                // Modifier already held when the drag began: no tap can happen, so open its wheel now.
                if !files.isEmpty, let wheel = ShellModifierStore.wheel(matching: ShellModifierMask(flags: e.modifierFlags)) {
                    ShellFan.shared.show(wheel, files: files, at: NSEvent.mouseLocation)
                }
            }
            // The panel may get no dragging callbacks from some sources, so drive the highlight from here too.
            if !files.isEmpty { ShellFan.shared.hover(atScreen: NSEvent.mouseLocation) }
        case .leftMouseUp:
            files = []
            tap.reset()
            // The release may be the drop onto a petal; give that a moment to land before cleaning up.
            if ShellFan.shared.isVisible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard !ShellDragMonitor.shared.isDraggingFiles else { return }
                    // Released on the wheel without a drop (or no dragging callbacks at all): keep it as a click menu.
                    if !ShellFan.shared.keepAsClickMenu(at: NSEvent.mouseLocation) { ShellFan.shared.dismiss() }
                }
            }
        case .flagsChanged:
            // leftMouseUp may never reach a global monitor for a drag session; the button state is the truth.
            if NSEvent.pressedMouseButtons & 1 == 0 { files = [] }
            guard isDraggingFiles else { tap.reset(); return }
            let mask = ShellModifierMask(flags: e.modifierFlags.intersection(.deviceIndependentFlagsMask))
            guard let tapped = tap.flagsChanged(mask, at: e.timestamp) else { return }
            if let wheel = ShellModifierStore.wheel(matching: tapped) {
                ShellFan.shared.toggle(wheel, files: files, at: NSEvent.mouseLocation)
            }
        case .keyDown:
            tap.otherInput()
        default: break
        }
    }

    /// File URLs on the drag pasteboard, only if a drag really started since the last mouse-down.
    private func fileDragContents() -> [URL] {
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != pressChangeCount else { return [] }
        return (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    // MARK: Permission

    /// Called when Welcome closes, so the permission alert never appears on top of it.
    func promptIfNeeded() { if !AXIsProcessTrusted() { promptForAccessOnce() } }

    private func promptForAccessOnce() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: ShellSettings.shownAccessibilityPrompt) else { return }
        d.set(true, forKey: ShellSettings.shownAccessibilityPrompt)
        DispatchQueue.main.async { Self.showAccessAlert() }
    }

    static func showAccessAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow FileChanger to watch for modifier taps"
        alert.informativeText = "FileChanger opens its wheels when you tap a modifier key (such as Shift) while dragging files. macOS only lets an app see keys pressed in other apps if you allow it in System Settings > Privacy & Security > Accessibility (and Input Monitoring). Without it, the wheels cannot open."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
