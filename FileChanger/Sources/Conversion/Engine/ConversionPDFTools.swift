import Foundation
import AppKit
import PDFKit
import CoreGraphics

/// PDF tools behind the Tools wheel (DOC-30..34): create, merge, split, organize, PDF/A.
enum ConversionPDFTools {
    typealias F = ConversionFormat

    static func write(_ doc: PDFDocument, to dest: URL, failure: String) async throws {
        try await OutputLocation.writeAtomically(to: dest) { temp in
            guard doc.write(to: temp) else { throw FileChangerError.failed(failure) }
        }
    }

    // MARK: Create PDF (DOC-30)

    /// One PDF from images, PDFs and text documents, in the given order.
    static func createPDF(_ files: [URL], progress: ProgressHandler) async throws -> URL {
        guard let first = files.first else { throw FileChangerError.failed("The source file could not be read.") }
        let out = PDFDocument()
        let scratch = try ConvTemp.make("FileChanger-pdf"); defer { try? FileManager.default.removeItem(at: scratch) }
        for (i, f) in files.enumerated() {
            if Task.isCancelled { throw FileChangerError.cancelled }
            let kind = FileKind.of(f)
            let part = scratch.appendingPathComponent("part-\(i).pdf")
            switch kind {
            case .pdf:
                guard let d = PDFDocument(url: f) else { throw FileChangerError.failed("The PDF cannot be read or is password-protected.") }
                for p in 0..<d.pageCount { if let pg = d.page(at: p)?.copy() as? PDFPage { out.insert(pg, at: out.pageCount) } }
                progress(Double(i + 1) / Double(files.count)); continue
            case .image:
                let fmt = Conversions.format(of: f) ?? .png
                try ConversionImageEngine.encode(try ConversionImageEngine.decode(f, format: fmt), as: .pdf, to: part)
            case .document, .ebook:
                guard let fmt = Conversions.format(of: f), fmt != .pages else { throw FileChangerError.unsupported("This file type is not supported.") }
                let c = try await ConversionDocumentEngine.load(f, as: fmt)
                try ConversionPDFEngine.makePDF(from: c.attributed, to: part)
            default: throw FileChangerError.unsupported("This file type is not supported.")
            }
            guard let d = PDFDocument(url: part) else { throw FileChangerError.failed("Could not create the PDF.") }
            for p in 0..<d.pageCount { if let pg = d.page(at: p) { out.insert(pg, at: out.pageCount) } }
            progress(Double(i + 1) / Double(files.count))
        }
        guard out.pageCount > 0 else { throw FileChangerError.failed("Could not create the PDF.") }
        let dest = Conversions.outputURL(for: first, ext: "pdf")
        try await write(out, to: dest, failure: "Could not create the PDF.")
        return dest
    }

    // MARK: Merge (DOC-31)

    static func merge(_ files: [URL], progress: ProgressHandler) async throws -> URL {
        guard let first = files.first else { throw FileChangerError.failed("The source file could not be read.") }
        let out = PDFDocument()
        for (i, f) in files.enumerated() {
            guard let d = PDFDocument(url: f), !d.isLocked else { throw FileChangerError.failed("The PDF cannot be read or is password-protected.") }
            for p in 0..<d.pageCount {
                // copy() keeps annotations and form fields with the page.
                if let pg = d.page(at: p)?.copy() as? PDFPage { out.insert(pg, at: out.pageCount) }
            }
            progress(Double(i + 1) / Double(files.count))
        }
        guard out.pageCount > 0 else { throw FileChangerError.failed("This PDF has no pages.") }
        let dest = OutputLocation.sibling(of: first, suffix: "-merged", ext: "pdf")
        try await write(out, to: dest, failure: "PDFKit could not write the combined PDF.")
        return dest
    }

    // MARK: Split (DOC-32)

    enum SplitMode: Equatable { case everyPage, everyN(Int), ranges(String) }

    /// "1-3, 5, 8-" -> [1...3, 5...5, 8...pageCount]; 1-based, validated against the page count.
    static func parseRanges(_ text: String, pageCount: Int) throws -> [ClosedRange<Int>] {
        let bad = FileChangerError.failed("Enter page ranges like 1-3, 5, 8-.")
        var out: [ClosedRange<Int>] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            let ends = p.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            var lo: Int, hi: Int
            if ends.count == 1, let n = Int(ends[0]) { lo = n; hi = n }
            else if ends.count == 2 {
                guard let a = ends[0].isEmpty ? 1 : Int(ends[0]), let b = ends[1].isEmpty ? pageCount : Int(ends[1]) else { throw bad }
                lo = a; hi = b
            } else { throw bad }
            guard lo >= 1, hi >= lo, hi <= pageCount else { throw FileChangerError.failed("Page ranges must be between 1 and \(pageCount).") }
            out.append(lo...hi)
        }
        guard !out.isEmpty else { throw bad }
        return out
    }

    static func splitRanges(_ mode: SplitMode, pageCount: Int) throws -> [ClosedRange<Int>] {
        switch mode {
        case .everyPage: return (1...max(1, pageCount)).map { $0...$0 }
        case .everyN(let n):
            let step = max(1, n)
            return stride(from: 1, through: pageCount, by: step).map { $0...min(pageCount, $0 + step - 1) }
        case .ranges(let s): return try parseRanges(s, pageCount: pageCount)
        }
    }

    /// Writes `Page 001.pdf` ... (single pages) or `Pages 001-003.pdf` (ranges) into a folder beside the original.
    static func split(_ file: URL, mode: SplitMode, progress: ProgressHandler) async throws -> URL {
        guard let doc = PDFDocument(url: file), !doc.isLocked else { throw FileChangerError.failed("The PDF cannot be read or is password-protected.") }
        guard doc.pageCount > 0 else { throw FileChangerError.failed("This PDF has no pages.") }
        let ranges = try splitRanges(mode, pageCount: doc.pageCount)
        let folder = Conversions.outputFolder(for: file)
        let work = folder.deletingLastPathComponent().appendingPathComponent(".filechanger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            for (i, r) in ranges.enumerated() {
                if Task.isCancelled { throw FileChangerError.cancelled }
                let part = PDFDocument()
                for p in r { if let pg = doc.page(at: p - 1)?.copy() as? PDFPage { part.insert(pg, at: part.pageCount) } }
                let name = r.count == 1 ? String(format: "Page %03d.pdf", r.lowerBound) : String(format: "Pages %03d-%03d.pdf", r.lowerBound, r.upperBound)
                guard part.write(to: work.appendingPathComponent(name)) else { throw FileChangerError.failed("Could not write page \(r.lowerBound)") }
                progress(Double(i + 1) / Double(ranges.count))
            }
            try FileManager.default.moveItem(at: work, to: folder)
        } catch { try? FileManager.default.removeItem(at: work); throw error }
        return folder
    }

    // MARK: Organize (DOC-33)

    struct PageEdit: Equatable { var original: Int; var rotation: Int = 0 }   // 0-based source index, extra clockwise degrees

    static func organize(_ file: URL, pages: [PageEdit], equalWidths: Bool, progress: ProgressHandler) async throws -> URL {
        guard let doc = PDFDocument(url: file), !doc.isLocked else { throw FileChangerError.failed("The PDF cannot be read or is password-protected.") }
        guard doc.pageCount > 0 else { throw FileChangerError.failed("This PDF has no pages.") }
        guard !pages.isEmpty, pages.allSatisfy({ $0.original >= 0 && $0.original < doc.pageCount }) else {
            throw FileChangerError.failed("The page order must include every page exactly once.")
        }
        guard pages.allSatisfy({ $0.rotation % 90 == 0 }) else { throw FileChangerError.failed("Page rotations must be 90-degree turns for pages in this PDF.") }
        let out = PDFDocument()
        for (i, e) in pages.enumerated() {
            guard let pg = doc.page(at: e.original)?.copy() as? PDFPage else { throw FileChangerError.failed("Could not write page \(e.original + 1)") }
            pg.rotation = ((pg.rotation + e.rotation) % 360 + 360) % 360
            out.insert(pg, at: i)
            progress(0.5 * Double(i + 1) / Double(pages.count))
        }
        if equalWidths { try scaleToNarrowest(out) }
        let dest = OutputLocation.sibling(of: file, suffix: "-organized", ext: "pdf")
        try await write(out, to: dest, failure: "PDFKit could not write the organized PDF.")
        return dest
    }

    /// Pages are scaled proportionally to the narrowest page's width (heights may differ).
    static func scaleToNarrowest(_ doc: PDFDocument) throws {
        func size(_ p: PDFPage) -> CGSize {
            let b = p.bounds(for: .mediaBox); return p.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
        }
        let widths = (0..<doc.pageCount).compactMap { doc.page(at: $0).map { size($0).width } }
        guard let narrow = widths.min(), narrow > 0 else { return }
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            let s = size(p)
            guard abs(s.width - narrow) > 0.5 else { continue }
            let k = narrow / s.width
            // Shrinking the crop/media box scale: re-render the page into a smaller PDF page.
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: narrow, height: s.height * k)
            guard let c = CGDataConsumer(data: data), let ctx = CGContext(consumer: c, mediaBox: &box, nil) else { continue }
            ctx.beginPDFPage(nil)
            ctx.scaleBy(x: k, y: k)
            p.draw(with: .mediaBox, to: ctx)
            ctx.endPDFPage(); ctx.closePDF()
            if let np = PDFDocument(data: data as Data)?.page(at: 0) { doc.removePage(at: i); doc.insert(np, at: i) }
        }
    }

    // MARK: PDF/A-2b (DOC-34)

    /// Features PDF/A forbids; any of these in the raw bytes aborts with the original's message.
    static let forbidden = ["/Encrypt", "/JavaScript", "/JS", "/OpenAction", "/Launch", "/XFA", "/Movie", "/Sound", "/Screen",
                            "/Rendition", "/RichMedia", "/3D", "/EmbeddedFile", "/LZWDecode", "/Crypt"]

    static func scanForbidden(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)   // lossy decode is fine for name tokens
        for key in forbidden {
            var from = text.startIndex
            while let r = text.range(of: key, range: from..<text.endIndex) {
                // Whole-token match: "/JS" must not be the start of "/JSFoo".
                let next = r.upperBound < text.endIndex ? text[r.upperBound] : " "
                if !(next.isLetter || next.isNumber) { return String(key.dropFirst()) }
                from = r.upperBound
            }
        }
        return nil
    }

    /// Best native approximation: pages are redrawn through CGPDFContext with PDF/A output enabled (CoreGraphics adds the
    /// XMP/pdfaid identification), sRGB output intent, and fonts as embedded in the source. Not run through a validator.
    static func convertPDFA(_ file: URL, progress: ProgressHandler) async throws -> URL {
        let raw = try Data(contentsOf: file, options: .mappedIfSafe)
        guard let src = CGPDFDocument(file as CFURL), src.numberOfPages > 0 else { throw FileChangerError.failed("The PDF cannot be read or is password-protected.") }
        if src.isEncrypted && !src.isUnlocked { throw FileChangerError.failed("The PDF cannot be read or is password-protected.") }
        if let bad = scanForbidden(raw) { throw FileChangerError.failed("This PDF could not be made PDF/A: it still contains the unsupported feature \(bad)") }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { throw FileChangerError.failed("The sRGB color profile is unavailable.") }
        let title = file.deletingPathExtension().lastPathComponent
        let dest = OutputLocation.sibling(of: file, suffix: "-PDFA", ext: "pdf")
        try await OutputLocation.writeAtomically(to: dest) { temp in
            let info: [CFString: Any] = [
                kCGPDFContextCreatePDFA: true, kCGPDFContextTitle: title, kCGPDFContextCreator: "FileChanger",
                kCGPDFContextOutputIntent: [kCGPDFXOutputIntentSubtype: "GTS_PDFX", kCGPDFXOutputConditionIdentifier: "sRGB IEC61966-2.1",
                                            kCGPDFXInfo: "sRGB IEC61966-2.1", kCGPDFXDestinationOutputProfile: srgb] as [CFString: Any]]
            var first = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let ctx = CGContext(temp as CFURL, mediaBox: &first, info as CFDictionary) else { throw FileChangerError.failed("Could not create the PDF.") }
            for n in 1...src.numberOfPages {
                guard let page = src.page(at: n) else { continue }
                var box = page.getBoxRect(.mediaBox)
                if box.width < 3 || box.height < 3 || box.width > 14400 || box.height > 14400 {
                    throw FileChangerError.failed("\(Int(max(box.width, box.height))) is outside the page sizes PDF/A allows (3 to 14,400 points per side).")
                }
                ctx.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
                ctx.drawPDFPage(page)
                ctx.endPDFPage()
                progress(Double(n) / Double(src.numberOfPages))
            }
            ctx.closePDF()
        }
        return dest
    }
}
