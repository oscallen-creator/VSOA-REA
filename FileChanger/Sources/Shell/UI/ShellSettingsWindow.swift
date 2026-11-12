import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum ShellSettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "FileChanger Settings"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 640, height: 420)
            w.contentView = NSHostingView(rootView: ShellSettingsView())
            w.center()
            w.setFrameAutosaveName("FileChangerSettings")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum ShellSettingsTab: String, CaseIterable, Identifiable {
    case general = "General", formats = "Formats", compatibility = "Compatibility", folders = "Folders", about = "About"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .formats: return "arrow.triangle.2.circlepath"
        case .compatibility: return "tablecells"
        case .folders: return "folder"
        case .about: return "info.circle"
        }
    }
}

struct ShellSettingsView: View {
    @State private var tab: ShellSettingsTab = .general

    var body: some View {
        NavigationSplitView {
            List(ShellSettingsTab.allCases, selection: $tab) { t in
                Label(t.rawValue, systemImage: t.symbol).tag(t)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 200)
        } detail: {
            Group {
                switch tab {
                case .general: GeneralSettingsPane()
                case .formats: FormatsSettingsPane()
                case .compatibility: FormatCompatibilityView().padding()
                case .folders: FoldersSettingsPane()
                case .about: AboutSettingsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .tint(Brand.accent)
    }
}

// MARK: - Launch at login

@MainActor
final class LoginItemModel: ObservableObject {
    @Published var enabled = false
    @Published var needsApproval = false
    @Published var error: String?

    init() { refresh() }

    func refresh() {
        let s = SMAppService.mainApp.status
        enabled = s == .enabled || s == .requiresApproval
        needsApproval = s == .requiresApproval
    }

    func set(_ on: Bool) {
        error = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = on ? "Couldn't update launch at login. You can try again, or set it up later in System Settings."
                            : "macOS couldn't change this setting. Try again in Login Items."
        }
        refresh()
    }
}

struct LoginItemRow: View {
    @StateObject private var model = LoginItemModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at login", isOn: Binding(get: { model.enabled }, set: { model.set($0) }))
            Text("Ready whenever you turn on your Mac.").font(.caption).foregroundStyle(.secondary)
            if model.needsApproval {
                HStack {
                    Text("One more step: allow FileChanger in macOS Login Items.").font(.caption)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
                }
            }
            if let e = model.error { Text(e).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { model.refresh() }
    }
}

// MARK: - Modifier recorder

@MainActor
final class ModifierRecorder: ObservableObject {
    @Published var recording: ShellWheel?
    @Published var message: String?
    @Published var masks = ShellModifierStore.masks()
    private var monitor: Any?
    private var peak: ShellModifierMask = []

    func toggle(_ wheel: ShellWheel) {
        if recording == wheel { stop(); return }
        stop()
        recording = wheel
        message = nil
        peak = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e, wheel) }
            return nil
        }
    }

    private func handle(_ e: NSEvent, _ wheel: ShellWheel) {
        if e.type == .keyDown { if e.keyCode == 53 { stop() }; return }
        let m = ShellModifierMask(flags: e.modifierFlags.intersection(.deviceIndependentFlagsMask))
        if m.isEmpty {
            if !peak.isEmpty { commit(peak, wheel) }
        } else if m.isSuperset(of: peak) { peak = m }
    }

    private func commit(_ mask: ShellModifierMask, _ wheel: ShellWheel) {
        if let other = ShellModifierStore.conflict(for: mask, assigning: wheel) {
            message = "\(mask.display) is already used by the \(other.settingsLabel)."
        } else {
            ShellModifierStore.set(mask, for: wheel)
        }
        masks = ShellModifierStore.masks()
        stop()
    }

    func reset(_ wheel: ShellWheel) {
        if !ShellModifierStore.set(wheel.defaultMask, for: wheel) {
            message = "\(wheel.defaultMask.display) is used by another wheel."
        } else { message = nil }
        masks = ShellModifierStore.masks()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}

struct ModifierKeyCaps: View {
    let mask: ShellModifierMask
    var body: some View {
        HStack(spacing: 4) {
            if mask.isEmpty { Text("Unset").foregroundStyle(.secondary) }
            ForEach(mask.glyphs, id: \.self) { g in
                Text(g).font(.system(size: 14, weight: .medium))
                    .frame(minWidth: 26, minHeight: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.2)))
            }
        }
    }
}

// MARK: - General

struct GeneralSettingsPane: View {
    @AppStorage(ShellSettings.showsMenuBarIcon) private var showsIcon = true
    @AppStorage(ShellSettings.revealsDesktop) private var revealsDesktop = true
    @AppStorage(ShellSettings.fanTheme) private var theme = "glass"
    @AppStorage(ShellSettings.soundsEnabled) private var sounds = true
    @AppStorage(ShellSettings.hapticsEnabled) private var haptics = true
    @AppStorage(ShellSettings.floatBehavior) private var floatBehavior = ShellFloatBehavior.addToExisting.rawValue
    @AppStorage(ShellSettings.terminalApp) private var terminalID = ShellSettings.defaultTerminal
    @AppStorage(ShellSettings.terminalAppName) private var terminalName = ""
    @StateObject private var recorder = ModifierRecorder()
    @State private var terminalError: String?

    var body: some View {
        Form {
            Section {
                LoginItemRow()
                Toggle("Show FileChanger in menu bar", isOn: $showsIcon)
                    .onChange(of: showsIcon) { _, on in
                        NotificationCenter.default.post(name: ShellSettings.menuBarVisibilityChanged, object: nil)
                        if !on {
                            ShellAlert.show("Menu Bar Icon Hidden",
                                            "The wheels still open when you tap their modifier while dragging files. To open Settings again, press comma (,) while a wheel is open, or open FileChanger again from Finder.",
                                            style: .informational)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Show Desktop results in Finder", isOn: $revealsDesktop)
                    Text("Open Finder after converting files on the Desktop").font(.caption).foregroundStyle(.secondary)
                }
                terminalPicker
            }
            Section("Drag Modifiers") {
                ForEach(ShellWheel.allCases) { wheel in
                    HStack {
                        Text(wheel.settingsLabel)
                        Spacer()
                        if recorder.recording == wheel {
                            Text("Press modifier keys…").foregroundStyle(Brand.accent)
                        } else {
                            ModifierKeyCaps(mask: recorder.masks[wheel] ?? wheel.defaultMask)
                        }
                        Button(recorder.recording == wheel ? "Cancel" : "Record") { recorder.toggle(wheel) }
                        Button("Reset") { recorder.reset(wheel) }.disabled(recorder.masks[wheel] == wheel.defaultMask)
                    }
                }
                Text("Tap the chosen modifier combination while dragging files.").font(.caption).foregroundStyle(.secondary)
                if let m = recorder.message { Text(m).font(.caption).foregroundStyle(.red) }
            }
            Section {
                Picker("Appearance", selection: $theme) {
                    Text("Glass").tag("glass")
                    Text("Metallic").tag("metallic")
                }
                .pickerStyle(.segmented)
                .onChange(of: theme) { _, _ in NotificationCenter.default.post(name: ShellSettings.fanThemeChanged, object: nil) }
                Toggle("Sound feedback", isOn: $sounds)
                Toggle("Haptic feedback", isOn: $haptics)
                Picker("Float Behaviour", selection: $floatBehavior) {
                    ForEach(ShellFloatBehavior.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            Section {
                Text("To open FileChanger Settings, press comma (,) while a wheel is open. To quit, use the Quit FileChanger button below.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Quit FileChanger") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .onDisappear { recorder.stop() }
    }

    private var terminalPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker("Terminal app", selection: Binding(get: { terminalID }, set: { selectTerminal($0) })) {
                Text("Terminal").tag("com.apple.Terminal")
                Text("iTerm2").tag("com.googlecode.iterm2")
                if terminalID != "com.apple.Terminal" && terminalID != "com.googlecode.iterm2" {
                    Text(terminalName.isEmpty ? terminalID : terminalName).tag(terminalID)
                }
                Divider()
                Text("Choose Terminal App…").tag("__choose__")
            }
            Text("Use the default Terminal app").font(.caption).foregroundStyle(.secondary)
            if let e = terminalError { Text(e).font(.caption).foregroundStyle(.red) }
        }
    }

    private func selectTerminal(_ id: String) {
        terminalError = nil
        if id != "__choose__" {
            terminalID = id
            terminalName = id == "com.googlecode.iterm2" ? "iTerm2" : (id == "com.apple.Terminal" ? "Terminal" : terminalName)
            UserDefaults.standard.removeObject(forKey: ShellSettings.terminalAppBookmark)
            return
        }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose the terminal app to open folders in."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension == "app", let bundleID = Bundle(url: url)?.bundleIdentifier else {
            terminalError = "Choose a macOS application (.app)."; return
        }
        terminalID = bundleID
        terminalName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        if let bookmark = try? url.bookmarkData() { UserDefaults.standard.set(bookmark, forKey: ShellSettings.terminalAppBookmark) }
        else { terminalError = "Couldn't save the terminal app. Choose it again to retry." }
    }
}

// MARK: - Formats

struct FormatsSettingsPane: View {
    @AppStorage(ShellSettings.videoStrength) private var videoStrength = "balanced"
    @AppStorage(ShellSettings.imageStrength) private var imageStrength = "balanced"
    @AppStorage(ShellSettings.imageSize) private var imageSize = "original"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Conversion formats").font(.title3.bold())
                Text("Conversion defaults are configured on the output format you choose.").foregroundStyle(.secondary)
                ConversionFormatsSettingsView()
                Divider()
                Text("Compression Settings").font(.title3.bold())
                VStack(alignment: .leading, spacing: 6) {
                    Text("Video Compression").font(.headline)
                    Picker("Strength", selection: $videoStrength) {
                        Text("Balanced").tag("balanced")
                        Text("Strong").tag("strong")
                    }.pickerStyle(.segmented).labelsHidden()
                    Text(videoStrength == "strong" ? "Much smaller files with more visible quality loss."
                                                    : "Better visual quality with moderate file-size savings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Image Compression").font(.headline)
                    Picker("Strength", selection: $imageStrength) {
                        Text("Balanced").tag("balanced")
                        Text("Strong").tag("strong")
                    }.pickerStyle(.segmented)
                    Picker("Size", selection: $imageSize) {
                        Text("Original").tag("original")
                        Text("Large").tag("large")
                        Text("Medium").tag("medium")
                        Text("Small").tag("small")
                    }
                }
                Button("Restore Compression Defaults") { ShellSettings.restoreCompressionDefaults() }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Folders, About

struct FoldersSettingsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Folder Access").font(.title3.bold())
            Label("No folder access is needed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            Text("FileChanger isn't sandboxed, so it saves results beside the originals without asking you to allow each folder. macOS may still ask once the first time it touches Desktop, Documents, Downloads or a removable drive; allow it there. Originals are never modified.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AboutSettingsPane: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.hexagongrid.fill").font(.system(size: 54)).foregroundStyle(Brand.accent)
            Text("FileChanger").font(.title.bold())
            Text("Version \(version) (\(build))").foregroundStyle(.secondary)
            Text("Drag files, tap a modifier, drop them on a wheel.").multilineTextAlignment(.center)
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}
