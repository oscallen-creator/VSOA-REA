import AppKit
import SwiftUI

/// Menu-bar shell: status item and menu, drag monitor, wheels, Float, Welcome and Settings.
/// `FileChangerApp.swift` calls `start()` and `handleOpened(_:)`.
@MainActor
enum Shell {
    private static var menuBar: ShellMenuBar?

    static func start() {
        ShellSettings.register()
        ShellModifierStore.migrate()
        ShellTasks.observeOperations()
        let bar = ShellMenuBar()
        bar.install()
        menuBar = bar
        ShellDragMonitor.shared.start()
        installReopenHandler()
        if !UserDefaults.standard.bool(forKey: ShellSettings.completedWelcome) {
            DispatchQueue.main.async { ShellWelcomeWindow.show() }
        }
    }

    /// Files opened on the app icon or via `open -a FileChanger file` get a wheel at the cursor (click a petal).
    static func handleOpened(_ urls: [URL]) {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return }
        ShellFan.shared.show(.conversion, files: files, at: NSEvent.mouseLocation, clickMode: true)
    }

    /// Launching the app again (Dock/Finder/`open`) opens Settings: the way back in when the menu-bar icon is hidden.
    private static func installReopenHandler() {
        NSAppleEventManager.shared().setEventHandler(ShellReopenHandler.shared, andSelector: #selector(ShellReopenHandler.reopen),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEReopenApplication))
    }
}

final class ShellReopenHandler: NSObject {
    static let shared = ShellReopenHandler()
    @objc func reopen() { DispatchQueue.main.async { ShellSettingsWindow.show() } }
}

/// The status item and its menu (SHL-02..07, SHL-38).
@MainActor
final class ShellMenuBar: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let menu = NSMenu()

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.menu = menu
        menu.delegate = self
        self.item = item
        refreshIcon()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(refreshIcon), name: ShellTasks.changed, object: nil)
        nc.addObserver(self, selector: #selector(refreshIcon), name: ShellSettings.menuBarVisibilityChanged, object: nil)
    }

    @objc private func refreshIcon() {
        guard let item else { return }
        item.isVisible = UserDefaults.standard.bool(forKey: ShellSettings.showsMenuBarIcon)
        let busy = !ShellTasks.active.isEmpty
        let image = busy ? NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "FileChanger is working")
                         : Self.wheelIcon()
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = busy ? "FileChanger is working" : "FileChanger is ready"
        item.button?.setAccessibilityLabel(busy ? "FileChanger is working" : "FileChanger is ready")
    }

    /// Template icon: a ring of six petals, drawn here (no borrowed artwork).
    static func wheelIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            NSColor.black.setFill()
            for i in 0..<6 {
                let a0 = CGFloat(i) * 60 + 4, a1 = CGFloat(i + 1) * 60 - 4
                let p = NSBezierPath()
                p.appendArc(withCenter: c, radius: 8.4, startAngle: a0, endAngle: a1)
                p.appendArc(withCenter: c, radius: 3.6, startAngle: a1, endAngle: a0, clockwise: true)
                p.close()
                p.fill()
            }
            return true
        }
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !ShellTasks.active.isEmpty {
            let header = NSMenuItem(title: "Active Tasks", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for t in ShellTasks.titles {
                let row = NSMenuItem(title: t + "…", action: nil, keyEquivalent: "")
                row.isEnabled = false
                row.indentationLevel = 1
                menu.addItem(row)
            }
            menu.addItem(.separator())
        }
        if !AXIsProcessTrusted() {
            add("Allow Wheel Shortcuts…", symbol: "hand.raised", #selector(grantAccess))
            menu.addItem(.separator())
        }
        add("Settings…", symbol: "gearshape", #selector(openSettings), key: ",")
        add("Getting Started", symbol: "sparkle", #selector(openWelcome))
        add("About FileChanger", symbol: nil, #selector(openAbout))
        menu.addItem(.separator())
        add("Quit FileChanger", symbol: nil, #selector(quit), key: "q")
    }

    private func add(_ title: String, symbol: String?, _ action: Selector, key: String = "") {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        if let symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(mi)
    }

    @objc private func openSettings() { ShellSettingsWindow.show() }
    @objc private func openWelcome() { ShellWelcomeWindow.show() }
    @objc private func grantAccess() { ShellDragMonitor.showAccessAlert() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
