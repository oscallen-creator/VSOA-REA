import Foundation
import AppKit
import PDFKit
import Vision
import CoreText
import ImageIO

/// PDF-sourced conversions (DOC-20..29) and the shared PDF/EPUB/image writers other document paths use.
enum ConversionPDFEngine {
    typealias F = ConversionFormat

    // MARK: Reading

    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0, !doc.isLocked else {
            throw FileChangerError.failed("The PDF cannot be read, is empty, or is password-protected.")
        }
        if !doc.allowsCopying && doc.string?.isEmpty != false && false { throw FileChangerError.failed("This PDF does not allow copying its content.") }
        return doc
    }

    static func render(_ page: PDFPage, scale: CGFloat = 2, maxEdge: CGFloat = 4000) throws -> CGImage {
        try Task.checkCancellation()
        let b = page.bounds(for: .mediaBox)
        guard b.width > 0, b.height > 0, b.width < 14400, b.height < 14400 else { throw FileChangerError.failed("A PDF page has invalid dimensions.") }
        let rotated = page.rotation % 180 != 0
        let w = rotated ? b.height : b.width, h = rotated ? b.width : b.height
        let k = min(scale, maxEdge / max(w, h))
        let size = CGSize(width: max(1, (w * k).rounded()), height: max(1, (h * k).rounded()))
        let img = page.thumbnail(of: size, for: .mediaBox)
        var rect = CGRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw FileChangerError.failed("A PDF page could not be rendered.") }
        return ConversionImageEngine.flattened(cg)
    }

    static func ocr(_ image: CGImage) throws -> [String] {
        try Task.checkCancellation()
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    // MARK: Structured blocks from PDF text (heading/list/paragraph heuristics, DOC-21)

    struct Block { enum Kind { case heading(Int), paragraph, listItem, image(CGImage) }; var kind: Kind; var text = "" }

    static func isBold(_ f: NSFont?) -> Bool {
        guard let f else { return false }
        return f.fontDescriptor.symbolicTraits.contains(.bold) || f.fontName.lowercased().contains("bold")
    }

    static func blocks(_ doc: PDFDocument, useOCR: Bool, progress: ProgressHandler = { _ in }) throws -> [Block] {
        var sizes: [CGFloat: Int] = [:]
        for i in 0..<doc.pageCount {
            guard let a = doc.page(at: i)?.attributedString else { continue }
            a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { v, r, _ in
                if let f = v as? NSFont { sizes[(f.pointSize * 2).rounded() / 2, default: 0] += r.length }
            }
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 12
        var out: [Block] = []
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { continue }
            var lines: [(text: String, size: CGFloat, bold: Bool)] = []
            if let a = page.attributedString, !a.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let ns = a.string as NSString
                ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { str, r, _, _ in
                    guard let str, !str.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    let f = a.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
                    lines.append((str.trimmingCharacters(in: .whitespaces), f?.pointSize ?? body, isBold(f)))
                }
            } else if useOCR {
                do { lines = try ocr(try render(page)).map { ($0, body, false) } }
                catch { throw FileChangerError.failed("Text recognition could not read a scanned PDF page: \(i + 1)") }
            }
            // Drop a lone page number at the page edges.
            for edge in [0, lines.count - 1] where lines.indices.contains(edge) && lines.count > 2 {
                if lines[edge].text.count <= 4, lines[edge].text.allSatisfy({ $0.isNumber }) { lines[edge].text = "" }
            }
            for l in lines where !l.text.isEmpty {
                let ratio = l.size / body
                let level = ratio >= 1.5 ? 1 : (ratio >= 1.25 ? 2 : ((ratio >= 1.1 && l.bold) || (l.bold && l.text.count < 60 && l.size >= body && !l.text.hasSuffix(".")) ? 3 : 0))
                if level > 0 { out.append(Block(kind: .heading(level), text: l.text)); continue }
                if l.text.range(of: #"^([•◦▪\-–]|\d+[.)])\s+"#, options: .regularExpression) != nil {
                    let t = l.text.replacingOccurrences(of: #"^([•◦▪\-–]|\d+[.)])\s+"#, with: "", options: .regularExpression)
                    out.append(Block(kind: .listItem, text: t)); continue
                }
                if let last = out.last, case .paragraph = last.kind, let end = last.text.last, !".:?!".contains(end) {
                    // Continuation line: de-hyphenate or join with a space.
                    if end == "-", let first = l.text.first, first.isLowercase { out[out.count - 1].text.removeLast(); out[out.count - 1].text += l.text }
                    else { out[out.count - 1].text += " " + l.text }
                } else { out.append(Block(kind: .paragraph, text: l.text)) }
            }
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        guard !out.isEmpty else { throw FileChangerError.failed("The PDF contains no text or page artwork that can be exported.") }
        return out
    }

    static func markdown(_ blocks: [Block]) -> String {
        var out: [String] = []
        for b in blocks {
            switch b.kind {
            case .heading(let n): out.append(String(repeating: "#", count: n) + " " + b.text)
            case .paragraph: out.append(b.text)
            case .listItem: out.append("- " + b.text)
            case .image: break
            }
        }
        var result = ""
        for (i, l) in out.enumerated() { result += l + (i + 1 < out.count && !(l.hasPrefix("- ") && out[i + 1].hasPrefix("- ")) ? "\n\n" : "\n") }
        return result
    }

    @MainActor
    static func attributed(_ blocks: [Block]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let bodyFont = NSFont(name: "Helvetica", size: 11) ?? .systemFont(ofSize: 11)
        let para = NSMutableParagraphStyle(); para.paragraphSpacing = 8; para.lineSpacing = 1.5
        for b in blocks {
            switch b.kind {
            case .heading(let n):
                let size: CGFloat = n == 1 ? 22 : (n == 2 ? 17 : 13)
                out.append(NSAttributedString(string: b.text + "\n", attributes: [.font: NSFont(name: "Helvetica-Bold", size: size) ?? .boldSystemFont(ofSize: size), .paragraphStyle: para]))
            case .paragraph: out.append(NSAttributedString(string: b.text + "\n", attributes: [.font: bodyFont, .paragraphStyle: para]))
            case .listItem: out.append(NSAttributedString(string: "•\t" + b.text + "\n", attributes: [.font: bodyFont, .paragraphStyle: para]))
            case .image(let cg):
                let rep = NSBitmapImageRep(cgImage: cg)
                if let png = rep.representation(using: .png, properties: [:]) {
                    let att = NSTextAttachment(data: png, ofType: "public.png")
                    let w: CGFloat = 468
                    att.bounds = CGRect(x: 0, y: 0, width: w, height: w * CGFloat(cg.height) / CGFloat(cg.width))
                    out.append(NSAttributedString(attachment: att)); out.append(NSAttributedString(string: "\n"))
                }
            }
        }
        return out
    }

    // MARK: PDF writing from attributed text (DOC-15)

    /// CoreText ignores some AppKit attribute keys; mirror colour and underline into the CT keys.
    static func coreTextReady(_ a: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: a)
        let full = NSRange(location: 0, length: m.length)
        m.enumerateAttribute(.foregroundColor, in: full) { v, r, _ in
            if let c = v as? NSColor { m.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: c.usingColorSpace(.sRGB)?.cgColor ?? c.cgColor, range: r) }
        }
        m.enumerateAttribute(.underlineStyle, in: full) { v, r, _ in
            if let n = v as? Int, n != 0 { m.addAttribute(NSAttributedString.Key(kCTUnderlineStyleAttributeName as String), value: CTUnderlineStyle.single.rawValue, range: r) }
        }
        m.enumerateAttribute(.attachment, in: full) { v, r, _ in if v != nil { m.replaceCharacters(in: r, with: "") } }
        return m
    }

    static func makePDF(from attr: NSAttributedString, to url: URL, pageSize: CGSize = CGSize(width: 612, height: 792), margin: CGFloat = 54) throws {
        let text = coreTextReady(attr)
        let fs = CTFramesetterCreateWithAttributedString(text)
        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextCreator: "FileChanger"] as CFDictionary) else {
            throw FileChangerError.failed("Could not create the PDF.")
        }
        var loc = 0
        repeat {
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(fs, CFRange(location: loc, length: 0), CGPath(rect: box.insetBy(dx: margin, dy: margin), transform: nil), nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            if visible.length == 0 && text.length > 0 { throw FileChangerError.failed("The text could not be laid out on a PDF page.") }
            loc += visible.length
        } while loc < text.length
        ctx.closePDF()
    }

    // MARK: Page images

    /// One page -> `name.ext`; several -> a folder `name` holding `Page 001.ext` ... (DOC-29).
    static func writePageImages(_ doc: PDFDocument, source: URL, format t: F, progress: ProgressHandler) throws -> URL {
        let decoded: (CGImage) -> ConversionImageEngine.Decoded = { .init(image: $0, properties: [:]) }
        if doc.pageCount == 1, let p = doc.page(at: 0) {
            let dest = Conversions.outputURL(for: source, ext: t.ext)
            let temp = dest.deletingLastPathComponent().appendingPathComponent(".filechanger-\(UUID().uuidString).\(t.ext)")
            defer { try? FileManager.default.removeItem(at: temp) }
            try ConversionImageEngine.encode(decoded(try render(p)), as: t, to: temp)
            try FileManager.default.moveItem(at: temp, to: dest)
            return dest
        }
        let folder = Conversions.outputFolder(for: source)
        let work = folder.deletingLastPathComponent().appendingPathComponent(".filechanger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            for i in 0..<doc.pageCount {
                if Task.isCancelled { throw FileChangerError.cancelled }
                guard let p = doc.page(at: i) else { continue }
                try autoreleasepool {
                    try ConversionImageEngine.encode(decoded(try render(p)), as: t, to: work.appendingPathComponent(String(format: "Page %03d.%@", i + 1, t.ext)))
                }
                progress(0.4 + 0.6 * Double(i + 1) / Double(doc.pageCount))
            }
            try FileManager.default.moveItem(at: work, to: folder)
        } catch { try? FileManager.default.removeItem(at: work); throw error }
        return folder
    }

    // MARK: EPUB writer (DOC-10)

    static func xhtmlFix(_ html: String) -> String {
        html.replacingOccurrences(of: "<hr>", with: "<hr/>")
            .replacingOccurrences(of: #"<img([^>]*[^/>])>"#, with: "<img$1/>", options: .regularExpression)
    }

    static func epubPackage(chapters: [(title: String, body: String)], images: [(name: String, data: Data, mime: String)], title: String,
                            fixed: Bool, cover: Data?, to url: URL) throws {
        let x = ConvText.escapeXML
        let xhtml = { (t: String, body: String, fixedPage: Bool) in
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><meta charset=\"utf-8\"/><title>\(x(t))</title><link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/>"
            + (fixedPage ? "<meta name=\"viewport\" content=\"width=1000, height=1400\"/>" : "") + "</head><body>\(body)</body></html>"
        }
        var entries: [ConvZip.Entry] = [
            .init(name: "mimetype", data: Data("application/epub+zip".utf8), store: true),
            .init(name: "META-INF/container.xml", data: Data("<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"EPUB/package.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8)),
            .init(name: "EPUB/style.css", data: Data((fixed ? "body{margin:0}img.source-page{display:block;width:100%;height:auto}" : "body{line-height:1.5;max-width:42em;margin:auto}h1,h2,h3{break-after:avoid}img{max-width:100%}table{border-collapse:collapse}td,th{border:1px solid #aaa;padding:3px}").utf8))]
        var manifest = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>"
        var spine = ""
        var toc = ""
        for (i, c) in chapters.enumerated() {
            let name = String(format: "chapter-%04d.xhtml", i + 1)
            entries.append(.init(name: "EPUB/\(name)", data: Data(xhtml(c.title, c.body, fixed).utf8)))
            manifest += "<item id=\"c\(i + 1)\" href=\"\(name)\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"c\(i + 1)\"/>"
            toc += "<li><a href=\"\(name)\">\(x(c.title))</a></li>"
        }
        for (i, im) in images.enumerated() {
            entries.append(.init(name: "EPUB/images/\(im.name)", data: im.data, store: true))
            manifest += "<item id=\"i\(i + 1)\" href=\"images/\(im.name)\" media-type=\"\(im.mime)\"/>"
        }
        var landmarks = ""
        if let cover {
            entries.append(.init(name: "EPUB/images/cover.jpg", data: cover, store: true))
            manifest += "<item id=\"cover\" href=\"images/cover.jpg\" media-type=\"image/jpeg\" properties=\"cover-image\"/>"
            landmarks = "<nav epub:type=\"landmarks\" hidden=\"hidden\"><ol><li><a epub:type=\"cover\" href=\"chapter-0001.xhtml\">Cover</a></li></ol></nav>"
        }
        entries.append(.init(name: "EPUB/nav.xhtml", data: Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><meta charset=\"utf-8\"/><title>\(x(title))</title></head><body><nav epub:type=\"toc\"><ol>\(toc)</ol></nav>\(landmarks)</body></html>".utf8)))
        let stamp = ISO8601DateFormatter().string(from: Date())
        let opf = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"uid\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"uid\">urn:uuid:\(UUID().uuidString)</dc:identifier><dc:title>\(x(title))</dc:title><dc:language>und</dc:language><meta property=\"dcterms:modified\">\(stamp)</meta><meta property=\"rendition:layout\">\(fixed ? "pre-paginated" : "reflowable")</meta><meta property=\"rendition:spread\">none</meta></metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>"
        entries.insert(.init(name: "EPUB/package.opf", data: Data(opf.utf8)), at: 2)
        try ConvZip.write(entries, to: url)
    }

    /// Markdown -> reflowable EPUB, one chapter per top-level heading.
    static func writeEPUB(markdown: String, title: String, to url: URL) throws {
        var chapters: [(String, [String])] = [(title, [])]
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("# ") { chapters.append((String(line.dropFirst(2)), [line])) } else { chapters[chapters.count - 1].1.append(line) }
        }
        if chapters.count > 1, chapters[0].1.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { chapters.removeFirst() }
        let built = chapters.map { (title: $0.0, body: xhtmlFix(ConversionMarkdown.body($0.1.joined(separator: "\n")))) }
        try epubPackage(chapters: built, images: [], title: title, fixed: false, cover: nil, to: url)
    }

    static func jpegData(_ cg: CGImage, quality: Double = 0.85) -> Data? {
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, ConversionImageEngine.flattened(cg), [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? d as Data : nil
    }

    static func pngData(_ cg: CGImage) -> Data? {
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? d as Data : nil
    }

    // MARK: pptx writer (one picture per slide, DOC-19 fallback)

    static func writePPTX(images: [CGImage], to url: URL) throws {
        guard !images.isEmpty else { throw FileChangerError.failed("The PDF contains no text or page artwork that can be exported.") }
        let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let hdr = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        // Slide size follows the first page, long side 12192000 EMU (13.33 in).
        let a0 = Double(images[0].width) / Double(images[0].height)
        let cx = a0 >= 1 ? 12192000 : Int(6858000 * a0), cy = a0 >= 1 ? Int(12192000 / a0) : 6858000
        var e: [ConvZip.Entry] = []
        var ct = "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/><Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/><Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/><Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
        var sldIds = "", presRels = "<Relationship Id=\"rId1\" Type=\"\(rel)/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>"
        for (i, img) in images.enumerated() {
            guard let jpg = jpegData(img, quality: 0.9) else { throw FileChangerError.failed("A PDF page could not be rendered.") }
            let n = i + 1
            ct += "<Override PartName=\"/ppt/slides/slide\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            sldIds += "<p:sldId id=\"\(255 + n)\" r:id=\"rId\(n + 1)\"/>"
            presRels += "<Relationship Id=\"rId\(n + 1)\" Type=\"\(rel)/slide\" Target=\"slides/slide\(n).xml\"/>"
            e.append(.init(name: "ppt/media/image\(n).jpeg", data: jpg, store: true))
            e.append(.init(name: "ppt/slides/_rels/slide\(n).xml.rels", data: Data("\(hdr)<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/><Relationship Id=\"rId2\" Type=\"\(rel)/image\" Target=\"../media/image\(n).jpeg\"/></Relationships>".utf8)))
            e.append(.init(name: "ppt/slides/slide\(n).xml", data: Data("\(hdr)<p:sld \(ns)><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"Page \(n)\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"rId2\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>".utf8)))
        }
        e.insert(.init(name: "[Content_Types].xml", data: Data("\(hdr)\(ct)</Types>".utf8)), at: 0)
        e.append(.init(name: "_rels/.rels", data: Data("\(hdr)<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>".utf8)))
        e.append(.init(name: "ppt/presentation.xml", data: Data("\(hdr)<p:presentation \(ns)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>\(sldIds)</p:sldIdLst><p:sldSz cx=\"\(cx)\" cy=\"\(cy)\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>".utf8)))
        e.append(.init(name: "ppt/_rels/presentation.xml.rels", data: Data("\(hdr)<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(presRels)</Relationships>".utf8)))
        e.append(.init(name: "ppt/slideMasters/slideMaster1.xml", data: Data("\(hdr)<p:sldMaster \(ns)><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld><p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst></p:sldMaster>".utf8)))
        e.append(.init(name: "ppt/slideMasters/_rels/slideMaster1.xml.rels", data: Data("\(hdr)<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/><Relationship Id=\"rId2\" Type=\"\(rel)/theme\" Target=\"../theme/theme1.xml\"/></Relationships>".utf8)))
        e.append(.init(name: "ppt/slideLayouts/slideLayout1.xml", data: Data("\(hdr)<p:sldLayout \(ns) type=\"blank\"><p:cSld name=\"Blank\"><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>".utf8)))
        e.append(.init(name: "ppt/slideLayouts/_rels/slideLayout1.xml.rels", data: Data("\(hdr)<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>".utf8)))
        let clr = { (n: String, v: String) in "<a:\(n)><a:srgbClr val=\"\(v)\"/></a:\(n)>" }
        let fonts = "<a:fontScheme name=\"F\"><a:majorFont><a:latin typeface=\"Helvetica\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont><a:minorFont><a:latin typeface=\"Helvetica\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme>"
        let fill = "<a:fillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:fillStyleLst>"
        let ln = "<a:lnStyleLst><a:ln w=\"6350\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln><a:ln w=\"12700\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln><a:ln w=\"19050\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln></a:lnStyleLst>"
        let fx = "<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>"
        let bg = "<a:bgFillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:bgFillStyleLst>"
        let scheme = "<a:clrScheme name=\"C\">" + clr("dk1", "000000") + clr("lt1", "FFFFFF") + clr("dk2", "44546A") + clr("lt2", "E7E6E6") + clr("accent1", "FF5200") + clr("accent2", "ED7D31") + clr("accent3", "A5A5A5") + clr("accent4", "FFC000") + clr("accent5", "5B9BD5") + clr("accent6", "70AD47") + clr("hlink", "0563C1") + clr("folHlink", "954F72") + "</a:clrScheme>"
        e.append(.init(name: "ppt/theme/theme1.xml", data: Data("\(hdr)<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"FileChanger\"><a:themeElements>\(scheme)\(fonts)<a:fmtScheme name=\"F\">\(fill)\(ln)\(fx)\(bg)</a:fmtScheme></a:themeElements></a:theme>".utf8)))
        try ConvZip.write(e, to: url)
    }

    // MARK: Entry point

    static func convert(_ file: URL, to t: F, progress: ProgressHandler) async throws -> URL {
        let doc = try open(file)
        progress(0.1)
        let dest = Conversions.outputURL(for: file, ext: t.ext)
        let layout = ConversionProfile.string(t, .pdfOfficeLayout)
        switch t {
        case .jpg, .png:
            return try writePageImages(doc, source: file, format: t, progress: progress)
        case .svg:
            return try writeSVG(doc, source: file, progress: progress)
        case .txt:
            let text = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !text.isEmpty else { throw FileChangerError.failed("This PDF has no selectable text. Scanned pages need OCR before text can be exported.") }
            try await OutputLocation.writeAtomically(to: dest) { try Data(text.joined(separator: "\n\n").utf8).write(to: $0) }
        case .md:
            let md = markdown(try blocks(doc, useOCR: true) { progress(0.1 + 0.8 * $0) })
            try await OutputLocation.writeAtomically(to: dest) { try Data(md.utf8).write(to: $0) }
        case .docx:
            let attr: NSAttributedString
            if layout == "preservePages" {
                let imgs = try (0..<doc.pageCount).compactMap { try doc.page(at: $0).map { try render($0, scale: 1.5) } }
                attr = await MainActor.run { attributed(imgs.map { Block(kind: .image($0)) }) }
            } else {
                let b = try blocks(doc, useOCR: true) { progress(0.1 + 0.8 * $0) }
                attr = await MainActor.run { attributed(b) }
            }
            let data = try await MainActor.run { try ConversionDocx.export(attr) }
            try await OutputLocation.writeAtomically(to: dest) { try data.write(to: $0) }
        case .epub:
            let title = file.deletingPathExtension().lastPathComponent
            try await OutputLocation.writeAtomically(to: dest) { temp in
                if ConversionProfile.string(.epub, .epubLayout) == "fixed" {
                    var pages: [(title: String, body: String)] = [], images: [(name: String, data: Data, mime: String)] = []
                    var cover: Data?
                    for i in 0..<doc.pageCount {
                        guard let p = doc.page(at: i), let jpg = jpegData(try render(p, scale: 1.5)) else { continue }
                        if i == 0 { cover = jpg }
                        let name = String(format: "page-%04d.jpg", i + 1)
                        images.append((name, jpg, "image/jpeg"))
                        pages.append(("Page \(i + 1)", "<img class=\"source-page\" src=\"images/\(name)\" alt=\"Page \(i + 1)\"/>"))
                    }
                    try epubPackage(chapters: pages, images: images, title: title, fixed: true, cover: cover, to: temp)
                } else {
                    try writeEPUB(markdown: markdown(try blocks(doc, useOCR: true)), title: title, to: temp)
                }
            }
        case .pptx:
            let imgs = try (0..<doc.pageCount).compactMap { try doc.page(at: $0).map { try render($0, scale: 2) } }
            try await OutputLocation.writeAtomically(to: dest) { try writePPTX(images: imgs, to: $0) }
        case .xlsx:
            // Lines become rows; columns split on tabs or runs of 2+ spaces (position stripper approximation).
            var rows: [[ConversionSpreadsheetEngine.Cell]] = []
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                var lines = (page.string ?? "").components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if lines.isEmpty { lines = (try? ocr(try render(page))) ?? [] }
                for l in lines {
                    let parts = l.replacingOccurrences(of: #"\s{2,}|\t"#, with: "\u{1}", options: .regularExpression).components(separatedBy: "\u{1}")
                    rows.append(parts.map { .init(text: $0, isNumber: ConversionSpreadsheetEngine.isNumeric($0)) })
                }
            }
            guard !rows.isEmpty else { throw FileChangerError.failed("The PDF contains no text or page artwork that can be exported.") }
            let wb = ConversionSpreadsheetEngine.Workbook(sheets: [.init(name: "Sheet1", rows: rows)])
            try await OutputLocation.writeAtomically(to: dest) { try ConversionSpreadsheetEngine.xlsxData(wb, to: $0) }
        default:
            throw FileChangerError.unsupported("Conversion from PDF to \(t.label) is unavailable.")
        }
        return dest
    }

    /// Each page becomes an SVG holding the page picture (a vector emitter is out of scope).
    static func writeSVG(_ doc: PDFDocument, source: URL, progress: ProgressHandler) throws -> URL {
        func svg(_ p: PDFPage) throws -> Data {
            let cg = try render(p, scale: 2)
            guard let png = pngData(cg) else { throw FileChangerError.failed("A PDF page could not be rendered.") }
            let b = p.bounds(for: .mediaBox)
            let rotated = p.rotation % 180 != 0
            let w = rotated ? b.height : b.width, h = rotated ? b.width : b.height
            return Data("<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"\(w)\" height=\"\(h)\" viewBox=\"0 0 \(w) \(h)\"><image width=\"\(w)\" height=\"\(h)\" xlink:href=\"data:image/png;base64,\(png.base64EncodedString())\"/></svg>".utf8)
        }
        if doc.pageCount == 1, let p = doc.page(at: 0) {
            let dest = Conversions.outputURL(for: source, ext: "svg")
            try svg(p).write(to: dest); return dest
        }
        let folder = Conversions.outputFolder(for: source)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            try svg(p).write(to: folder.appendingPathComponent(String(format: "Page %03d.svg", i + 1)))
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        return folder
    }
}
