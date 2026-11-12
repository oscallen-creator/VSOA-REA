import AppKit
import SwiftUI

/// The options window a tool opens in (Tangerine: FileToolOptionsWindowController / FileToolOptionsPanel).
/// One panel per tool invocation; it floats above other apps so it works while Finder is in front.
@MainActor
final class ToolPanel: NSObject, NSWindowDelegate {
    private static var open: [ToolPanel] = []
    private let window: NSPanel
    let files: [URL]

    /// Runs the tool: opens its panel, or runs it directly when it has no options.
    static func present(_ spec: FileToolSpec, files: [URL]) {
        guard case .panel(let makePanel) = spec.action else {
            if case .run(let run) = spec.action { run(files) }
            return
        }
        let panel = ToolPanel(spec: spec, files: files, content: makePanel(files))
        open.append(panel)
        panel.window.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.window.makeKeyAndOrderFront(nil)
    }

    private init(spec: FileToolSpec, files: [URL], content: AnyView) {
        self.files = files
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        super.init()
        window.title = spec.title
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        let context = ToolPanelContext(close: { [weak self] in self?.window.close() })
        let root = VStack(spacing: 0) {
            CompactToolHeader(title: spec.title, symbol: spec.symbol, files: files)
            Divider()
            content
        }
        .environment(\.toolPanel, context)
        .frame(minWidth: 520, minHeight: 380)
        window.contentView = NSHostingView(rootView: root)
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}

/// What an editor can ask of the panel that hosts it.
struct ToolPanelContext {
    var close: @MainActor () -> Void = {}
}

private struct ToolPanelKey: EnvironmentKey { static let defaultValue = ToolPanelContext() }
extension EnvironmentValues {
    var toolPanel: ToolPanelContext {
        get { self[ToolPanelKey.self] }
        set { self[ToolPanelKey.self] = newValue }
    }
}

/// Title row: tool icon, title, and the file name (or "N files").
struct CompactToolHeader: View {
    let title: String
    let symbol: String
    let files: [URL]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Brand.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 10)
    }
}

/// Bottom bar every editor uses: optional Reset on the left, error text, primary save button on the right.
/// Return (or Enter) triggers the primary button; Escape closes the panel.
struct ToolFooter: View {
    let primary: String
    var isEnabled: Bool = true
    var message: String? = nil
    var reset: (() -> Void)? = nil
    let action: () -> Void
    @Environment(\.toolPanel) private var panel

    var body: some View {
        HStack {
            if let reset { Button("Reset", action: reset) }
            if let message { Text(message).font(.caption).foregroundStyle(.red).lineLimit(2) }
            Spacer()
            Button("Cancel") { panel.close() }.keyboardShortcut(.cancelAction)
            Button(primary, action: action)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).tint(Brand.accent)
                .disabled(!isEnabled)
        }
        .padding(12)
    }
}

/// Accent colour, the same orange Tangerine uses (#FF5200, SHL-100).
enum Brand {
    static let accent = Color(red: 1.0, green: 0.322, blue: 0.0)
    static let nsAccent = NSColor(srgbRed: 1.0, green: 0.322, blue: 0.0, alpha: 1)
}
