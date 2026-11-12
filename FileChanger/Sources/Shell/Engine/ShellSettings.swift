import Foundation

/// UserDefaults keys and defaults of the shell (SHL-78 and friends).
enum ShellSettings {
    static let showsMenuBarIcon = "showsMenuBarIcon"
    static let revealsDesktop = "revealsDesktopOutputsInFinder"
    static let terminalApp = "fileActionsTerminalApplication"
    static let terminalAppName = "fileActionsTerminalApplicationName"
    static let terminalAppBookmark = "fileActionsTerminalApplicationBookmark"
    static let fanTheme = "conversionFanTheme"
    static let soundsEnabled = "soundsEnabled"
    static let hapticsEnabled = "hapticsEnabled"
    static let floatBehavior = "floatWheelBehavior"
    static let floatViewMode = "floatViewMode"
    static let floatMaterial = "floatMaterial"
    static let completedWelcome = "hasCompletedWelcome"
    static let shownAccessibilityPrompt = "shownAccessibilityPrompt"
    static let videoStrength = "defaultVideoCompressionStrength"
    static let imageStrength = "defaultImageCompressionStrength"
    static let imageSize = "defaultImageCompressionSize"

    static let defaultTerminal = "com.apple.Terminal"

    static let fanThemeChanged = Notification.Name("conversionFanThemeDidChange")
    static let menuBarVisibilityChanged = Notification.Name("menuBarIconVisibilityDidChange")

    static func register(_ d: UserDefaults = .standard) {
        d.register(defaults: [
            showsMenuBarIcon: true, revealsDesktop: true, terminalApp: defaultTerminal,
            fanTheme: "glass", soundsEnabled: true, hapticsEnabled: true,
            floatBehavior: ShellFloatBehavior.addToExisting.rawValue,
            floatViewMode: "grid", floatMaterial: "glass",
            videoStrength: "balanced", imageStrength: "balanced", imageSize: "original",
        ])
    }

    /// Restores the compression keys the Settings > Formats pane edits (SHL-81).
    static func restoreCompressionDefaults(_ d: UserDefaults = .standard) {
        d.set("balanced", forKey: videoStrength)
        d.set("balanced", forKey: imageStrength)
        d.set("original", forKey: imageSize)
    }
}
