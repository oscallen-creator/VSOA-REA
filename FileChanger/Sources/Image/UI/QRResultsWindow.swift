import SwiftUI
import AppKit

/// IMG-36. "QR Code Results" window; scans each file off the main thread.
@MainActor
final class QRResultsModel: ObservableObject {
    struct Entry: Identifiable { let id = UUID(); let file: URL; var results: [QRResult] = []; var done = false; var error: String? }
    @Published var entries: [Entry]
    @Published var copiedID: UUID?
    init(files: [URL]) { entries = files.map { Entry(file: $0) } }

    func scan() async {
        for i in entries.indices {
            let f = entries[i].file
            let r = await Task.detached { Result { try ImageQREngine.read(f) } }.value
            switch r {
            case .success(let list): entries[i].results = list
            case .failure(let e): entries[i].error = e.localizedDescription
            }
            entries[i].done = true
        }
    }

    func copy(_ text: String, id: UUID) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        copiedID = id
        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); if copiedID == id { copiedID = nil } }
    }
    func copyAll() {
        let all = entries.flatMap(\.results).map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(all, forType: .string)
        copiedID = entries.first?.id
        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); copiedID = nil }
    }
}

struct QRResultsView: View {
    @ObservedObject var model: QRResultsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "qrcode.viewfinder").foregroundStyle(Brand.accent)
                Text("QR Code Results").font(.headline)
                Spacer()
                Button(model.copiedID != nil ? "Copied" : "Copy All") { model.copyAll() }.disabled(model.entries.flatMap(\.results).isEmpty)
            }.padding(12)
            Divider()
            List {
                ForEach(model.entries) { e in
                    Section {
                        if !e.done { Text("Scanning \(e.file.lastPathComponent) (\(e.results.count))...").foregroundStyle(.secondary) }
                        else if let err = e.error { Text(err).foregroundStyle(.red) }
                        else if e.results.isEmpty { Text("No QR codes found").foregroundStyle(.secondary) }
                        ForEach(e.results) { r in
                            HStack {
                                Text(r.text).textSelection(.enabled).lineLimit(4)
                                Spacer()
                                Button(model.copiedID == r.id ? "Copied" : "Copy") { model.copy(r.text, id: r.id) }
                                    .accessibilityLabel("Copy QR code text from \(e.file.lastPathComponent)")
                            }
                        }
                    } header: { Text(e.file.lastPathComponent) }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 240)
    }
}

@MainActor
enum QRResultsWindow {
    private static var windows: [NSWindow] = []
    static func show(_ files: [URL]) {
        let model = QRResultsModel(files: files)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 340), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "QR Code Results"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: QRResultsView(model: model))
        w.center(); w.level = .floating
        windows.append(w)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        Task { await model.scan() }
    }
}
