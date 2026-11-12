import Foundation
import AppKit

/// Post-processing for the docx NSAttributedString writes: Apple's exporter has no styles part, flattens tables and
/// writes headings as direct formatting. This adds Heading1-3 styles, tags big/bold paragraphs with them, and swaps
/// marker paragraphs for real `<w:tbl>` tables.
enum ConversionDocx {
    static let markerPrefix = "FCTABLEMARK", markerSuffix = "X"

    @MainActor
    static func export(_ attr: NSAttributedString, tables: [[[String]]] = []) throws -> Data {
        let data = try attr.data(from: NSRange(location: 0, length: attr.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        return try postProcess(data, tables: tables)
    }

    static func tableXML(_ rows: [[String]]) -> String {
        let x = ConvText.escapeXML
        let border = ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"B8B8B8\"/>" }.joined()
        var s = "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>\(border)</w:tblBorders></w:tblPr>"
        for (r, row) in rows.enumerated() {
            s += "<w:tr>"
            for cell in row {
                s += "<w:tc><w:tcPr><w:tcW w:w=\"0\" w:type=\"auto\"/>" + (r == 0 ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"EDEDED\"/>" : "")
                    + "</w:tcPr><w:p><w:r>" + (r == 0 ? "<w:rPr><w:b/></w:rPr>" : "") + "<w:t xml:space=\"preserve\">\(x(cell))</w:t></w:r></w:p></w:tc>"
            }
            s += "</w:tr>"
        }
        return s + "</w:tbl><w:p/>"
    }

    static func postProcess(_ data: Data, tables: [[[String]]]) throws -> Data {
        let tmp = try ConvTemp.make("FileChanger-docx"); defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("in.docx"); try data.write(to: file)
        var entries = try ConvZip.read(file).map { ConvZip.Entry(name: $0.name, data: $0.data) }
        guard let i = entries.firstIndex(where: { $0.name == "word/document.xml" }) else { return data }
        var xml = String(decoding: entries[i].data, as: UTF8.self)
        let para = try NSRegularExpression(pattern: "<w:p>[\\s\\S]*?</w:p>")
        let ns = xml as NSString
        let paras = para.matches(in: xml, range: NSRange(location: 0, length: ns.length))
        func text(_ p: String) -> String {
            (try? NSRegularExpression(pattern: "<w:t[^>]*>([^<]*)</w:t>"))?.matches(in: p, range: NSRange(location: 0, length: (p as NSString).length))
                .map { (p as NSString).substring(with: $0.range(at: 1)) }.joined() ?? ""
        }
        func size(_ p: String) -> Int? {
            guard let m = try? NSRegularExpression(pattern: "<w:sz w:val=\"(\\d+)\"/>").firstMatch(in: p, range: NSRange(location: 0, length: (p as NSString).length)) else { return nil }
            return Int((p as NSString).substring(with: m.range(at: 1)))
        }
        var hist: [Int: Int] = [:]
        for m in paras { let p = ns.substring(with: m.range); if let s = size(p) { hist[s, default: 0] += text(p).count } }
        let body = Double(hist.max { $0.value < $1.value }?.key ?? 24)
        var out = "", last = 0
        for m in paras {
            var p = ns.substring(with: m.range)
            let t = text(p)
            if t.hasPrefix(markerPrefix), t.hasSuffix(markerSuffix), let n = Int(t.dropFirst(markerPrefix.count).dropLast(markerSuffix.count)), n < tables.count {
                p = tableXML(tables[n])
            } else if let s = size(p), p.contains("<w:b/>"), !t.isEmpty {
                let ratio = Double(s) / body
                let level = ratio >= 1.6 ? 1 : (ratio >= 1.3 ? 2 : (ratio >= 1.12 ? 3 : 0))
                if level > 0 {
                    p = p.contains("<w:pPr>") ? p.replacingOccurrences(of: "<w:pPr>", with: "<w:pPr><w:pStyle w:val=\"Heading\(level)\"/><w:outlineLvl w:val=\"\(level - 1)\"/>", options: [], range: p.range(of: "<w:pPr>"))
                                              : p.replacingOccurrences(of: "<w:p>", with: "<w:p><w:pPr><w:pStyle w:val=\"Heading\(level)\"/></w:pPr>", options: [], range: p.range(of: "<w:p>"))
                }
            }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + p
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        xml = out
        entries[i] = ConvZip.Entry(name: "word/document.xml", data: Data(xml.utf8))
        if !entries.contains(where: { $0.name == "word/styles.xml" }) {
            func style(_ n: Int, _ half: Int) -> String {
                "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(n)\"><w:name w:val=\"heading \(n)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/><w:pPr><w:keepNext/><w:outlineLvl w:val=\"\(n - 1)\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"\(half)\"/></w:rPr></w:style>"
            }
            let styles = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/></w:style>\(style(1, 48))\(style(2, 36))\(style(3, 28))</w:styles>"
            entries.append(.init(name: "word/styles.xml", data: Data(styles.utf8)))
            if let c = entries.firstIndex(where: { $0.name == "[Content_Types].xml" }) {
                let ct = String(decoding: entries[c].data, as: UTF8.self).replacingOccurrences(of: "</Types>", with: "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/></Types>")
                entries[c] = .init(name: entries[c].name, data: Data(ct.utf8))
            }
            if let r = entries.firstIndex(where: { $0.name == "word/_rels/document.xml.rels" }) {
                let rels = String(decoding: entries[r].data, as: UTF8.self).replacingOccurrences(of: "</Relationships>", with: "<Relationship Id=\"rIdFCStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>")
                entries[r] = .init(name: entries[r].name, data: Data(rels.utf8))
            }
        }
        let outFile = tmp.appendingPathComponent("out.docx")
        try ConvZip.write(entries, to: outFile)
        return try Data(contentsOf: outFile)
    }
}
