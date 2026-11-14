import AppKit
import AVFoundation

/// Modal alert helper; the app is an accessory so it must activate first.
@MainActor
enum ShellAlert {
    static func show(_ title: String, _ message: String, style: NSAlert.Style = .warning) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }
}

/// Running shell-started jobs, for the "Active Tasks" menu section and the busy status icon (SHL-03, SHL-38).
@MainActor
enum ShellTasks {
    static let changed = Notification.Name("shellActiveTasksChanged")
    private(set) static var active: [UUID: String] = [:]

    /// Every job (conversions and tools alike) reports through `Operations`; subscribe once at launch.
    static func observeOperations() {
        Operations.onStart = { id, title in
            active[id] = title
            NotificationCenter.default.post(name: changed, object: nil)
        }
        Operations.onFinish = { id, outcomes in
            active[id] = nil
            NotificationCenter.default.post(name: changed, object: nil)
            ShellJobs.revealDesktopOutputs(outcomes.compactMap(\.output))
        }
    }

    static var titles: [String] { active.values.sorted() }
}

/// Starts jobs from the wheels and applies the Desktop reveal (SHL-32, SHL-35).
@MainActor
enum ShellJobs {
    /// Outputs put at the drop point; the Finder reveal skips them (its window would cover the icon).
    private static var placed: Set<URL> = []

    static func convert(_ files: [URL], to target: ConversionTarget) {
        // The cursor is still at the drop point; decide desktop-or-not once, here.
        let drop = ShellDropPlacement.desktopDropPoint(NSEvent.mouseLocation)
        Task { @MainActor in
            await Operations.run(title: "Converting to \(target.label)", files: files) { file, progress in
                let out = try await Conversions.convert(file, to: target, progress: progress)
                // Placement is best effort: if the move fails, the converted file stays beside the original.
                guard let drop, let dest = try? await ShellDropPlacement.place(out, at: drop, index: files.firstIndex(of: file) ?? 0)
                else { return out }
                await MainActor.run { _ = placed.insert(dest.standardizedFileURL) }
                return dest
            }
        }
    }

    /// After a job whose output lies on the Desktop, bring Finder forward on the results.
    static func revealDesktopOutputs(_ outputs: [URL]) {
        guard UserDefaults.standard.bool(forKey: ShellSettings.revealsDesktop) else { return }
        let onDesktop = outputs.filter { shellIsOnDesktop($0) && !placed.contains($0.standardizedFileURL) }
        if !onDesktop.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(onDesktop) }
    }
}

/// Hover tick: a short synthesized blip (own sound, nothing copied), plus a haptic tick.
@MainActor
enum ShellFeedback {
    private static let sound: NSSound? = NSSound(data: tickWAV())

    static func hover() {
        let d = UserDefaults.standard
        if d.bool(forKey: ShellSettings.soundsEnabled), let s = sound { s.stop(); s.volume = 0.35; s.play() }
        if d.bool(forKey: ShellSettings.hapticsEnabled) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    /// 35 ms 1.6 kHz sine with a fast exponential decay, 16-bit mono PCM.
    private static func tickWAV() -> Data {
        let rate = 44100, n = rate * 35 / 1000
        var pcm = Data()
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            let v = sin(2 * .pi * 1600 * t) * exp(-t * 110) * 0.8
            var s = Int16(max(-1, min(1, v)) * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
        }
        func u32(_ v: Int) -> Data { var x = UInt32(v).littleEndian; return Data(bytes: &x, count: 4) }
        func u16(_ v: Int) -> Data { var x = UInt16(v).littleEndian; return Data(bytes: &x, count: 2) }
        var d = Data("RIFF".utf8)
        d += u32(36 + pcm.count); d += Data("WAVEfmt ".utf8); d += u32(16); d += u16(1); d += u16(1)
        d += u32(rate); d += u32(rate * 2); d += u16(2); d += u16(16)
        d += Data("data".utf8); d += u32(pcm.count); d += pcm
        return d
    }
}

/// The six file actions of the Actions wheel (SHL-23..30).
@MainActor
enum ShellActionRunner {
    struct Spec: Identifiable {
        let id: String, label: String, symbol: String, detail: String
    }

    static let all: [Spec] = [
        Spec(id: "terminal", label: "Terminal", symbol: "terminal", detail: "Open terminal in folder"),
        Spec(id: "copyPaths", label: "Copy Paths", symbol: "doc.on.clipboard", detail: "Copy file and folder paths"),
        Spec(id: "move", label: "Move", symbol: "folder", detail: "Move files and folders to a chosen folder"),
        Spec(id: "copyFiles", label: "Copy Files", symbol: "doc.on.doc", detail: "Copy files and folders"),
        Spec(id: "float", label: "Float", symbol: "square.stack.3d.up", detail: "Float file or folder thumbnail"),
        Spec(id: "airdrop", label: "AirDrop", symbol: "dot.radiowaves.left.and.right", detail: "Share files and folders with AirDrop"),
    ]

    static func run(_ id: String, files: [URL]) {
        switch id {
        case "terminal": openTerminal(files)
        case "copyPaths": attempt { try ShellFileActions.copyPaths(files) }
        case "copyFiles": attempt { try ShellFileActions.copyFiles(files) }
        case "move": move(files)
        case "float": ShellFloat.shared.add(files)
        case "airdrop": airDrop(files)
        default: break
        }
    }

    private static func attempt(_ body: () throws -> Void) {
        do { try body() } catch let e as ShellFileActions.ActionError { ShellAlert.show(e.title, e.message) }
        catch { ShellAlert.show("Couldn't complete the action", error.localizedDescription) }
    }

    private static func openTerminal(_ files: [URL]) {
        let d = UserDefaults.standard
        let bundleID = d.string(forKey: ShellSettings.terminalApp) ?? ShellSettings.defaultTerminal
        let name = d.string(forKey: ShellSettings.terminalAppName) ?? (bundleID == "com.googlecode.iterm2" ? "iTerm2" : "Terminal")
        guard ShellFileActions.localURLs(files).count == files.count, !files.isEmpty else {
            ShellAlert.show("Couldn't open terminal", "Only local files and folders can open a terminal."); return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            ShellAlert.show("Couldn't open terminal", "\(name) isn't available. Choose it again in Settings > General > Terminal app."); return
        }
        NSWorkspace.shared.open(ShellFileActions.terminalFolders(for: files), withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Task { @MainActor in ShellAlert.show("Couldn't open terminal", error.localizedDescription) } }
        }
    }

    private static func move(_ files: [URL]) {
        guard ShellFileActions.localURLs(files).count == files.count else {
            ShellAlert.show("Couldn't move files", "No items were moved."); return
        }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Here"
        panel.message = "Choose a destination folder for " + (files.count == 1 ? files[0].lastPathComponent : "\(files.count) items")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let result = ShellFileActions.move(files, to: folder)
        if result.moved.isEmpty && !result.failures.isEmpty {
            ShellAlert.show("Couldn't move files", result.summary)
        } else if !result.failures.isEmpty {
            ShellAlert.show("Couldn't move files", "The move was not completed. " + result.failures.joined(separator: " "))
        } else if !result.moved.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(result.moved)
        }
    }

    private static func airDrop(_ files: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: files) else {
            ShellAlert.show("Couldn't AirDrop files", "AirDrop isn't available for these files on this Mac."); return
        }
        service.perform(withItems: files)
    }
}
