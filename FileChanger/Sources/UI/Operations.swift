import AppKit
import SwiftUI

/// Runs a job over files with the shared progress window (Tangerine: OperationProgressPanel).
/// Every tool's Save button and every conversion goes through here, so progress, per-file
/// "saved"/"failed" rows, cancellation and "reveal in Finder" behave the same everywhere.
@MainActor
enum Operations {
    struct Outcome: Identifiable {
        let id = UUID()
        let source: URL
        let output: URL?
        let error: String?
    }

    /// Set once by the shell: every job reports here, for the Active Tasks menu, busy icon and Desktop reveal.
    static var onStart: (UUID, String) -> Void = { _, _ in }
    static var onFinish: (UUID, [Outcome]) -> Void = { _, _ in }

    /// `title` is the progress verb, e.g. "Trimming", "Converting to PNG".
    /// `job` returns the written file (or the folder it wrote into).
    @discardableResult
    static func run(title: String, files: [URL],
                    job: @escaping @Sendable (URL, ProgressHandler) async throws -> URL) async -> [Outcome] {
        let token = UUID()
        onStart(token, title)
        let model = OperationModel(title: title, total: files.count)
        let window = OperationWindow(model: model)
        window.show()
        let task = Task { @MainActor () -> [Outcome] in
            var outcomes: [Outcome] = []
            for (i, file) in files.enumerated() {
                if Task.isCancelled { break }
                model.current = file.lastPathComponent
                model.index = i
                model.fraction = 0
                do {
                    let out = try await job(file) { f in Task { @MainActor in model.fraction = f } }
                    outcomes.append(Outcome(source: file, output: out, error: nil))
                } catch {
                    outcomes.append(Outcome(source: file, output: nil, error: error.localizedDescription))
                }
                model.outcomes = outcomes
            }
            return outcomes
        }
        model.cancel = { task.cancel() }
        let outcomes = await task.value
        model.stopped = task.isCancelled && outcomes.isEmpty
        model.finished = true
        onFinish(token, outcomes)
        if !outcomes.isEmpty && outcomes.allSatisfy({ $0.error == nil }) {
            NSSound(named: "Glass")?.play()
            window.close(after: 1.2)
        }
        return outcomes
    }

    /// Convenience for tools that write exactly one output from several inputs (join, collage, merge PDF).
    @discardableResult
    static func runCombined(title: String, files: [URL],
                            job: @escaping @Sendable ([URL], ProgressHandler) async throws -> URL) async -> Outcome {
        let first = files.first ?? URL(fileURLWithPath: "/")
        let results = await run(title: title, files: [first]) { _, progress in try await job(files, progress) }
        return results.first ?? Outcome(source: first, output: nil, error: "Cancelled.")
    }
}

@MainActor
final class OperationModel: ObservableObject {
    let title: String
    let total: Int
    @Published var index = 0
    @Published var current = ""
    @Published var fraction = 0.0
    @Published var outcomes: [Operations.Outcome] = []
    @Published var finished = false
    @Published var stopped = false
    var cancel: () -> Void = {}

    init(title: String, total: Int) { self.title = title; self.total = total }

    var failed: Int { outcomes.filter { $0.error != nil }.count }
}

@MainActor
private final class OperationWindow {
    private let panel: NSPanel
    static var open: [NSPanel] = []

    init(model: OperationModel) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                        styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "Operation in progress"
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: OperationProgressView(model: model) { [weak panel] in panel?.close() })
    }

    func show() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let step = CGFloat(OperationWindow.open.count % 8) * 28     // cascade concurrent windows
            panel.setFrameOrigin(NSPoint(x: f.maxX - panel.frame.width - 20 - step, y: f.maxY - panel.frame.height - 20 - step))
        }
        Self.open.append(panel)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [panel] _ in
            MainActor.assumeIsolated { OperationWindow.open.removeAll { $0 === panel } }
        }
        panel.orderFrontRegardless()
    }

    func close(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [panel] in panel.close() }
    }
}

struct OperationProgressView: View {
    @ObservedObject var model: OperationModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.finished ? (model.stopped ? "Stopped" : model.failed == 0 ? "Done" : (model.failed == model.total ? "Couldn't finish" : "Finished with errors")) : model.title)
                .font(.headline)
            if !model.finished {
                Text(model.total > 1 ? "\(model.current) (\(model.index + 1) of \(model.total))" : model.current)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                ProgressView(value: model.fraction).tint(Brand.accent)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.outcomes) { o in
                        HStack(spacing: 6) {
                            Image(systemName: o.error == nil ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(o.error == nil ? .green : .red)
                            Text(o.error == nil ? "\((o.output ?? o.source).lastPathComponent) saved"
                                                : "\(o.source.lastPathComponent) failed: \(o.error ?? "")")
                                .font(.caption).lineLimit(2)
                            Spacer()
                            if let out = o.output {
                                Button { NSWorkspace.shared.activateFileViewerSelecting([out]) } label: {
                                    Image(systemName: "magnifyingglass")
                                }.buttonStyle(.borderless).help("Show in Finder")
                            }
                        }
                    }
                }
            }.frame(maxHeight: 90)
            HStack {
                Spacer()
                if model.finished { Button("Close", action: dismiss).keyboardShortcut(.defaultAction) }
                else { Button("Stop") { model.cancel() }.keyboardShortcut(.cancelAction) }
            }
        }
        .padding(EdgeInsets(top: 28, leading: 16, bottom: 12, trailing: 16))
        .frame(width: 380)
    }
}
