import AppKit
import SwiftUI

/// Entry point. A menu-bar-only app (LSUIElement), like Tangerine. The shell builder owns
/// Sources/Shell/ (menu bar, drag monitor, fan/wheel overlay, Float shelf, settings, welcome) and
/// wires it up from `Shell.start()`.
@main
enum FileChangerMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        Shell.start()
    }

    /// A menu-bar-only app shows no menu bar, but key equivalents still route through the main menu.
    /// Without this, ⌘C/⌘V/⌘Z/⌘A/⌘W do nothing in tool panels and text fields.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [(String, Selector?, String, NSEvent.ModifierFlags)]) {
            let menu = NSMenu(title: title)
            for (t, action, key, mods) in items {
                if action == nil { menu.addItem(.separator()); continue }
                let item = NSMenuItem(title: t, action: action, keyEquivalent: key)
                item.keyEquivalentModifierMask = mods
                menu.addItem(item)
            }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
        }
        submenu("FileChanger", [("Hide FileChanger", #selector(NSApplication.hide(_:)), "h", .command),
                                ("", nil, "", []),
                                ("Quit FileChanger", #selector(NSApplication.terminate(_:)), "q", .command)])
        submenu("Edit", [("Undo", Selector(("undo:")), "z", .command),
                         ("Redo", Selector(("redo:")), "z", [.command, .shift]),
                         ("", nil, "", []),
                         ("Cut", #selector(NSText.cut(_:)), "x", .command),
                         ("Copy", #selector(NSText.copy(_:)), "c", .command),
                         ("Paste", #selector(NSText.paste(_:)), "v", .command),
                         ("Delete", #selector(NSText.delete(_:)), "", []),
                         ("Select All", #selector(NSText.selectAll(_:)), "a", .command)])
        submenu("Window", [("Close", #selector(NSWindow.performClose(_:)), "w", .command),
                           ("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", .command)])
        return main
    }

    /// Files opened on the app icon or via `open -a FileChanger file` go to the same picker the drop uses.
    func application(_ application: NSApplication, open urls: [URL]) {
        Shell.handleOpened(urls)
    }
}
