import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// Merge PDFs: ordered source list with a sort-by-name action (DOC-31).
struct MergePDFPanel: View {
    @State var files: [URL]
    @Environment(\.toolPanel) private var panel

    init(files: [URL]) { _files = State(initialValue: files) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Files are merged in this order. Drag to reorder.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { files.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } } label: {
                    Label("Sort by Name", systemImage: "textformat.abc")
                }.help("Order the files by name, as Finder lists them").accessibilityIdentifier("sortSourcesByName")
            }.padding(.horizontal, 16).padding(.vertical, 8)
            List {
                ForEach(files, id: \.self) { f in
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                        Image(systemName: "doc.richtext")
                        Text(f.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(PDFDocument(url: f)?.pageCount ?? 0) pages").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onMove { files.move(fromOffsets: $0, toOffset: $1) }
            }
            .accessibilityIdentifier("orderedSourceList")
            Divider()
            ToolFooter(primary: "Merge PDFs") {
                let order = files
                panel.close()
                Task { @MainActor in
                    await Operations.runCombined(title: "Merging", files: order) { urls, p in try await ConversionPDFTools.merge(urls, progress: p) }
                }
            }
        }
    }
}

/// Split PDF: every page, every N pages, or page ranges (DOC-32).
struct SplitPDFPanel: View {
    let file: URL
    @State private var mode = 0
    @State private var every = 2
    @State private var ranges = ""
    @Environment(\.toolPanel) private var panel
    private var pageCount: Int { PDFDocument(url: file)?.pageCount ?? 0 }

    private var splitMode: ConversionPDFTools.SplitMode {
        mode == 0 ? .everyPage : (mode == 1 ? .everyN(every) : .ranges(ranges))
    }
    private var error: String? {
        if mode == 2 { do { _ = try ConversionPDFTools.parseRanges(ranges, pageCount: pageCount) } catch { return ranges.isEmpty ? nil : error.localizedDescription } }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This PDF has \(pageCount) pages. Pages are saved in a new folder beside it.").foregroundStyle(.secondary)
            Picker("Split", selection: $mode) {
                Text("Every page").tag(0); Text("Every N pages").tag(1); Text("Page ranges").tag(2)
            }.pickerStyle(.segmented)
            if mode == 1 { Stepper("Pages per file: \(every)", value: $every, in: 1...max(1, pageCount)) }
            if mode == 2 {
                TextField("1-3, 5, 8-", text: $ranges).textFieldStyle(.roundedBorder)
                Text("Each range becomes one file; a lone page is named Page 005.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ToolFooter(primary: "Split PDF", isEnabled: pageCount > 0 && (mode != 2 || (error == nil && !ranges.isEmpty)), message: error) {
                let m = splitMode
                panel.close()
                Task { @MainActor in
                    await Operations.run(title: "Splitting PDF", files: [file]) { f, p in try await ConversionPDFTools.split(f, mode: m, progress: p) }
                }
            }
        }
        .padding(.top, 12).padding(.horizontal, 16)
    }
}

/// Organize PDF: thumbnail grid with drag-to-reorder, rotate, remove and equal widths (DOC-33).
struct OrganizePDFPanel: View {
    let file: URL
    @State private var pages: [ConversionPDFTools.PageEdit] = []
    @State private var thumbs: [Int: NSImage] = [:]
    @State private var equalWidths = false
    @State private var dragging: Int?
    @Environment(\.toolPanel) private var panel

    private func load() {
        guard pages.isEmpty, let doc = PDFDocument(url: file) else { return }
        pages = (0..<doc.pageCount).map { .init(original: $0) }
        for i in 0..<doc.pageCount { if let p = doc.page(at: i) { thumbs[i] = p.thumbnail(of: CGSize(width: 150, height: 200), for: .mediaBox) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                    ForEach(Array(pages.enumerated()), id: \.element.original) { index, e in
                        VStack(spacing: 4) {
                            Image(nsImage: thumbs[e.original] ?? NSImage())
                                .resizable().scaledToFit().rotationEffect(.degrees(Double(e.rotation))).frame(height: 130)
                                .shadow(radius: 1)
                            Text("\(index + 1)" + (e.original != index ? ", originally page \(e.original + 1)" : "")).font(.caption).lineLimit(1)
                            HStack(spacing: 8) {
                                Button { pages[index].rotation = (pages[index].rotation + 90) % 360 } label: { Image(systemName: "rotate.right") }
                                    .help("Rotate 90 degrees clockwise").accessibilityIdentifier("pdfOrganizerRotatePage")
                                Button { if pages.count > 1 { pages.remove(at: index) } } label: { Image(systemName: "trash") }
                                    .help("Remove this page").disabled(pages.count < 2)
                            }.buttonStyle(.borderless)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(dragging == e.original ? Brand.accent.opacity(0.15) : Color.clear))
                        .accessibilityLabel("Page \(index + 1). Drag to change its position, or use Rotate to turn it clockwise")
                        .onDrag { dragging = e.original; return NSItemProvider(object: "\(e.original)" as NSString) }
                        .onDrop(of: [.text], delegate: PageDrop(target: e.original, pages: $pages, dragging: $dragging))
                    }
                }.padding(16)
            }
            .accessibilityIdentifier("pdfOrganizerGrid")
            Divider()
            HStack {
                Toggle("Make all pages the same width", isOn: $equalWidths).accessibilityIdentifier("pdfOrganizerEqualWidths")
                Text("Pages are scaled proportionally to match the narrowest page; their heights may still differ.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 16).padding(.vertical, 8)
            ToolFooter(primary: "Save Organized PDF", isEnabled: !pages.isEmpty, reset: {
                pages = (0..<thumbs.count).map { .init(original: $0) }
            }) {
                let edits = pages, eq = equalWidths
                panel.close()
                Task { @MainActor in
                    await Operations.run(title: "Organizing PDF", files: [file]) { f, p in try await ConversionPDFTools.organize(f, pages: edits, equalWidths: eq, progress: p) }
                }
            }
        }
        .onAppear(perform: load)
    }
}

private struct PageDrop: DropDelegate {
    let target: Int
    @Binding var pages: [ConversionPDFTools.PageEdit]
    @Binding var dragging: Int?

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != target,
              let a = pages.firstIndex(where: { $0.original == from }), let b = pages.firstIndex(where: { $0.original == target }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { pages.move(fromOffsets: IndexSet(integer: a), toOffset: b > a ? b + 1 : b) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

/// Convert to PDF/A-2b: a caption about what is written, then the conversion (DOC-34).
struct PDFAPanel: View {
    let files: [URL]
    @Environment(\.toolPanel) private var panel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Writes PDF/A-2b identification, an sRGB output intent and embedded fonts. Validate with a PDF/A checker if an archive requires certified files.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Copies are saved beside the originals with -PDFA added to the name.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            ToolFooter(primary: "Convert to PDF/A-2b") {
                let list = files
                panel.close()
                Task { @MainActor in
                    await Operations.run(title: "Converting to PDF/A-2b", files: list) { f, p in try await ConversionPDFTools.convertPDFA(f, progress: p) }
                }
            }
        }
        .padding(.top, 12).padding(.horizontal, 16)
    }
}
