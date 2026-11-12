import Foundation
import AppKit
import PDFKit
import CoreText

/// Text-ish documents: docx rtf rtfd textClipping txt md epub -> docx pdf txt md html epub png jpg (DOC-01..17).
/// Everything pivots on two views of the content: an attributed string (for docx/pdf/plain text) and Markdown
/// (for md/html/epub), built once by `load`.
enum ConversionDocumentEngine {
    typealias F = ConversionFormat

    struct Content { var attributed: NSAttributedString; var markdown: String; var title: String; var isMarkdown = false }

    static let textLimit = 32 * 1024 * 1024, docLimit = 128 * 1024 * 1024

    static func plainAttributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)])
    }

    // MARK: Loading

    @MainActor
    static func attributed(url: URL, type: NSAttributedString.DocumentType) throws -> NSAttributedString {
        do {
            return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
        } catch {
            switch type {
            case .rtf: throw FileChangerError.failed("The file is not valid RTF.")
            case .rtfd: throw FileChangerError.failed("An RTFD attachment is missing or unreadable.")
            default: throw FileChangerError.failed("The document is empty or exceeds the 128 MB import limit.")
            }
        }
    }

    @MainActor
    static func attributed(html: String, baseURL: URL? = nil) throws -> NSAttributedString {
        var opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.html,
                                                                       .characterEncoding: String.Encoding.utf8.rawValue]
        if let baseURL { opts[.baseURL] = baseURL }
        return try NSAttributedString(data: Data(html.utf8), options: opts, documentAttributes: nil)
    }

    static func fileSize(_ url: URL) -> Int {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
            var n = 0
            while let u = e?.nextObject() as? URL { n += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
            return n
        }
        return ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
    }

    static func load(_ file: URL, as s: F) async throws -> Content {
        let size = fileSize(file)
        let title = file.deletingPathExtension().lastPathComponent
        if size == 0 && s != .rtfd { throw FileChangerError.failed(s == .txt || s == .md ? "The text file is unreadable or exceeds the 32 MB import limit." : "The document is empty or exceeds the 128 MB import limit.") }
        switch s {
        case .txt, .md:
            guard size <= textLimit, let text = ConvText.decode(try Data(contentsOf: file)) else {
                throw FileChangerError.failed("The file has invalid text encoding or too much text. Save it as UTF-8 in TextEdit and try again.")
            }
            if s == .txt { return Content(attributed: plainAttributed(text), markdown: text, title: title) }
            let a = try await MainActor.run { try attributed(html: ConversionMarkdown.page(title: title, body: ConversionMarkdown.body(text))) }
            return Content(attributed: a, markdown: text, title: title, isMarkdown: true)
        case .docx, .rtf, .rtfd:
            guard size <= docLimit else { throw FileChangerError.failed("The document is empty or exceeds the 128 MB import limit.") }
            let type: NSAttributedString.DocumentType = s == .docx ? .officeOpenXML : (s == .rtf ? .rtf : .rtfd)
            if s == .rtf, let head = try? FileHandle(forReadingFrom: file).read(upToCount: 5), String(decoding: head, as: UTF8.self) != "{\\rtf" {
                throw FileChangerError.failed("The file is not valid RTF.")
            }
            let a = try await MainActor.run { try attributed(url: file, type: type) }
            return Content(attributed: a, markdown: ConversionMarkdown.markdown(from: a), title: title)
        case .textClipping:
            guard let text = readClipping(file) else { throw FileChangerError.failed("The clipping contains no supported text.") }
            return Content(attributed: plainAttributed(text), markdown: text, title: title)
        case .epub:
            let a = try await readEPUB(file)
            return Content(attributed: a, markdown: ConversionMarkdown.markdown(from: a), title: title)
        default:
            throw FileChangerError.unsupported("Conversion from \(s.label) is unavailable.")
        }
    }

    /// `.textClipping`: modern clippings are a plist in the data fork; older ones keep `utxt`/`TEXT` resources in the resource fork (DOC-05).
    static func readClipping(_ url: URL) -> String? {
        if let data = try? Data(contentsOf: url), !data.isEmpty,
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let items = plist["UTI-Data"] as? [String: Any] {
            for key in ["public.utf8-plain-text", "public.utf16-external-plain-text", "public.plain-text"] {
                if let d = items[key] as? Data, let s = ConvText.decode(d) { return s }
                if let s = items[key] as? String { return s }
            }
            if let d = items["com.apple.flat-rtfd"] as? Data, let a = NSAttributedString(rtfd: d, documentAttributes: nil) { return a.string }
        }
        let size = getxattr(url.path, "com.apple.ResourceFork", nil, 0, 0, 0)
        guard size > 16 else { return nil }
        var rf = Data(count: size)
        let got = rf.withUnsafeMutableBytes { getxattr(url.path, "com.apple.ResourceFork", $0.baseAddress, size, 0, 0) }
        guard got == size else { return nil }
        func u32(_ o: Int) -> Int { o + 4 <= rf.count ? Int(rf[o]) << 24 | Int(rf[o + 1]) << 16 | Int(rf[o + 2]) << 8 | Int(rf[o + 3]) : 0 }
        func u16(_ o: Int) -> Int { o + 2 <= rf.count ? Int(rf[o]) << 8 | Int(rf[o + 1]) : 0 }
        let dataOff = u32(0), mapOff = u32(4)
        let typeList = mapOff + u16(mapOff + 24)
        let count = u16(typeList) + 1
        for i in 0..<min(count, 64) {
            let e = typeList + 2 + i * 8
            guard e + 8 <= rf.count else { break }
            let type = String(decoding: rf[e..<(e + 4)], as: UTF8.self)
            guard type == "utxt" || type == "TEXT" else { continue }
            let refList = typeList + u16(e + 6)
            let off = u32(refList + 4) & 0x00FFFFFF
            let start = dataOff + off
            let len = u32(start)
            guard len > 0, start + 4 + len <= rf.count else { continue }
            let bytes = rf.subdata(in: (start + 4)..<(start + 4 + len))
            return type == "utxt" ? String(data: bytes, encoding: .utf16BigEndian) : String(data: bytes, encoding: .macOSRoman)
        }
        return nil
    }

    // MARK: EPUB reading (DOC-09)

    static func readEPUB(_ url: URL) async throws -> NSAttributedString {
        let entries = try ConvZip.read(url)
        guard ConvZip.entry(entries, "mimetype") != nil || ConvZip.entry(entries, "META-INF/container.xml") != nil else {
            throw FileChangerError.failed("The EPUB container is invalid.")
        }
        if ConvZip.entry(entries, "META-INF/encryption.xml") != nil { throw FileChangerError.failed("This EPUB is encrypted and cannot be converted.") }
        guard let c = ConvZip.entry(entries, "META-INF/container.xml").flatMap(XMLNode.parse),
              let rootPath = c.descendants("rootfile").first?.attr("full-path"),
              let opf = ConvZip.entry(entries, rootPath).flatMap(XMLNode.parse) else {
            throw FileChangerError.failed("The EPUB package document could not be read.")
        }
        var manifest: [String: String] = [:]
        for item in opf.first("manifest")?.all("item") ?? [] { if let id = item.attr("id"), let h = item.attr("href") { manifest[id] = h } }
        let spine = (opf.first("spine")?.all("itemref") ?? []).compactMap { $0.attr("idref") }.compactMap { manifest[$0] }
        guard !spine.isEmpty else { throw FileChangerError.failed("The EPUB has no readable chapters.") }
        let scratch = try ConvTemp.make("FileChanger-epub"); defer { try? FileManager.default.removeItem(at: scratch) }
        for e in entries {
            try Task.checkCancellation()
            let dest = scratch.appendingPathComponent(e.name)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try e.data.write(to: dest)
        }
        let rootDir = (rootPath as NSString).deletingLastPathComponent
        let result = NSMutableAttributedString()
        for href in spine {
            try Task.checkCancellation()
            let rel = (href.removingPercentEncoding ?? href)
            let path = rootDir.isEmpty ? rel : rootDir + "/" + rel
            let chapter = scratch.appendingPathComponent(path).standardizedFileURL
            guard chapter.path.hasPrefix(scratch.standardizedFileURL.path), let data = try? Data(contentsOf: chapter) else { continue }
            let a = try await MainActor.run {
                try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .baseURL: chapter,
                                                             .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
            }
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(a)
        }
        guard result.length > 0 else { throw FileChangerError.failed("The EPUB has no readable chapters.") }
        return result
    }

    // MARK: Conversion

    static func convert(_ file: URL, from s: F, to t: F, progress: ProgressHandler) async throws -> URL {
        switch s {
        case .pdf: return try await ConversionPDFEngine.convert(file, to: t, progress: progress)
        case .ppt, .pptx: return try await ConversionOfficeEngine.convert(file, from: s, to: t, progress: progress)
        default: break
        }
        let content = try await load(file, as: s)
        progress(0.4)
        return try await write(content, source: file, to: t, progress: progress)
    }

    static func write(_ c: Content, source: URL, to t: F, progress: ProgressHandler) async throws -> URL {
        let dest = Conversions.outputURL(for: source, ext: t.ext)
        switch t {
        case .png, .jpg:
            let scratch = try ConvTemp.make("FileChanger-document-images"); defer { try? FileManager.default.removeItem(at: scratch) }
            let pdf = scratch.appendingPathComponent("doc.pdf")
            try ConversionPDFEngine.makePDF(from: c.attributed, to: pdf)
            guard let doc = PDFDocument(url: pdf) else { throw FileChangerError.failed("Could not create the PDF.") }
            return try ConversionPDFEngine.writePageImages(doc, source: source, format: t, progress: progress)
        default: break
        }
        try await OutputLocation.writeAtomically(to: dest) { temp in
            switch t {
            case .txt: try Data(c.attributed.string.utf8).write(to: temp)
            case .md: try Data(c.markdown.utf8).write(to: temp)
            case .html: try Data(ConversionMarkdown.page(title: c.title, body: ConversionMarkdown.body(c.markdown)).utf8).write(to: temp)
            case .docx:
                var attr = c.attributed
                var tables: [[[String]]] = []
                if c.isMarkdown {
                    let split = ConversionMarkdown.extractTables(c.markdown)
                    if !split.tables.isEmpty {
                        tables = split.tables
                        attr = try await MainActor.run { try attributed(html: ConversionMarkdown.page(title: c.title, body: ConversionMarkdown.body(split.markdown))) }
                    }
                }
                let data = try await MainActor.run { [attr, tables] in try ConversionDocx.export(attr, tables: tables) }
                try data.write(to: temp)
            case .pdf: try ConversionPDFEngine.makePDF(from: c.attributed, to: temp)
            case .epub: try ConversionPDFEngine.writeEPUB(markdown: c.markdown, title: c.title, to: temp)
            default: throw FileChangerError.unsupported("Conversion to \(t.label) is unavailable.")
            }
        }
        return dest
    }
}
