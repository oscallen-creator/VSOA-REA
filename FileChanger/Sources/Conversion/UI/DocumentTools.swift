import SwiftUI

/// Document, PDF and archive tools on the wheel (DOC-30..34, ARC-07).
enum DocumentTools {
    @MainActor static var all: [FileToolSpec] { [
        FileToolSpec(id: "createPDF", wheelLabel: "CREATE PDF", title: "Create PDF", symbol: "doc.badge.plus",
                     kinds: [.image, .document, .ebook, .pdf], minFiles: 1, maxFiles: .max,
                     action: .run { files in
                         Task { @MainActor in
                             await Operations.runCombined(title: "Creating PDF", files: files) { urls, p in try await ConversionPDFTools.createPDF(urls, progress: p) }
                         }
                     }),
        FileToolSpec(id: "mergePDF", wheelLabel: "MERGE", title: "Merge PDFs", symbol: "doc.on.doc",
                     kinds: [.pdf], minFiles: 2, maxFiles: .max,
                     action: .panel { files in AnyView(MergePDFPanel(files: files)) }),
        FileToolSpec(id: "splitPDF", wheelLabel: "SPLIT", title: "Split PDF", symbol: "rectangle.split.2x1",
                     kinds: [.pdf], minFiles: 1, maxFiles: 1,
                     action: .panel { files in AnyView(SplitPDFPanel(file: files[0])) }),
        FileToolSpec(id: "organizePDF", wheelLabel: "ORGANIZE", title: "Organize PDF", symbol: "square.grid.2x2",
                     kinds: [.pdf], minFiles: 1, maxFiles: 1,
                     action: .panel { files in AnyView(OrganizePDFPanel(file: files[0])) }),
        FileToolSpec(id: "convertPDFA", wheelLabel: "PDF/A", title: "Convert to PDF/A-2b", symbol: "checkmark.seal",
                     kinds: [.pdf], minFiles: 1, maxFiles: .max,
                     action: .panel { files in AnyView(PDFAPanel(files: files)) }),
        FileToolSpec(id: "extractArchive", wheelLabel: "EXTRACT", title: "Extract Archive", symbol: "archivebox",
                     kinds: [.archive], minFiles: 1, maxFiles: .max,
                     action: .run { files in
                         Task { @MainActor in
                             await Operations.run(title: "Extracting archive", files: files) { f, p in try await ConversionArchiveEngine.extractBeside(f, progress: p) }
                         }
                     }),
    ] }
}
