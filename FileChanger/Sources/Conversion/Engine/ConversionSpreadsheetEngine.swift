import Foundation
import CoreGraphics
import CoreText

/// xlsx / ods / csv / tsv conversions (DOC-18). Reads and writes the OOXML and ODF XML directly.
enum ConversionSpreadsheetEngine {
    typealias F = ConversionFormat

    struct Cell: Equatable { var text: String; var isNumber = false }
    struct Sheet { var name: String; var rows: [[Cell]] }
    struct Workbook { var sheets: [Sheet] }

    static let sizeLimit = 128 * 1024 * 1024

    // MARK: Reading

    static func read(_ url: URL, as f: F) throws -> Workbook {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if ((attrs[.size] as? Int) ?? 0) > sizeLimit || ((attrs[.size] as? Int) ?? 0) == 0 {
            throw FileChangerError.failed("The spreadsheet is empty or exceeds the 128 MB conversion limit.")
        }
        switch f {
        case .csv: return Workbook(sheets: [Sheet(name: "Sheet1", rows: try parseDelimited(url, delimiter: ","))])
        case .tsv: return Workbook(sheets: [Sheet(name: "Sheet1", rows: try parseDelimited(url, delimiter: "\t"))])
        case .xlsx: return try readXLSX(url)
        case .ods: return try readODS(url)
        default: throw FileChangerError.unsupported("Conversion from \(f.label) is unavailable.")
        }
    }

    /// RFC 4180 parser with a configurable delimiter; numbers are detected for typed output.
    static func parseDelimited(_ url: URL, delimiter: Character) throws -> [[Cell]] {
        let data = try Data(contentsOf: url)
        guard let text = ConvText.decode(data) else {
            throw FileChangerError.failed("The file has invalid text encoding or too much text. Save it as UTF-8 in TextEdit and try again.")
        }
        var rows: [[Cell]] = [], row: [Cell] = [], field = "", quoted = false, wasQuoted = false
        var chars = Array(text.unicodeScalars)[...]
        func endField() { row.append(Cell(text: field, isNumber: !wasQuoted && isNumeric(field))); field = ""; wasQuoted = false }
        let delim = delimiter.unicodeScalars.first!
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" { if chars.first == "\"" { field.unicodeScalars.append("\""); chars.removeFirst() } else { quoted = false } }
                else { field.unicodeScalars.append(c) }
            } else if c == "\"" && field.isEmpty { quoted = true; wasQuoted = true }
            else if c == delim { endField() }
            else if c == "\n" || c == "\r" {
                try Task.checkCancellation()
                if c == "\r", chars.first == "\n" { chars.removeFirst() }
                endField(); rows.append(row); row = []
            } else { field.unicodeScalars.append(c) }
        }
        if !field.isEmpty || !row.isEmpty || wasQuoted { endField(); rows.append(row) }
        return rows
    }

    static func isNumeric(_ s: String) -> Bool {
        guard !s.isEmpty, s.count < 20, Double(s) != nil else { return false }
        if s.hasPrefix("0") && s.count > 1 && !s.hasPrefix("0.") { return false }   // keep zip codes / ids as text
        let lower = s.lowercased()
        return !(lower.contains("nan") || lower.contains("inf"))
    }

    static func columnIndex(_ ref: String) -> Int {
        var n = 0
        for ch in ref.unicodeScalars where ch.value >= 65 && ch.value <= 90 { n = n * 26 + Int(ch.value) - 64 }
        return max(0, n - 1)
    }

    static func columnName(_ index: Int) -> String {
        var n = index + 1, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(UInt8(65 + r))) + s; n = (n - 1) / 26 }
        return s
    }

    static func readXLSX(_ url: URL) throws -> Workbook {
        let entries = try ConvZip.read(url)
        guard let wbData = ConvZip.entry(entries, "xl/workbook.xml"), let wb = XMLNode.parse(wbData) else {
            throw FileChangerError.failed("The spreadsheet could not be read.")
        }
        var shared: [String] = []
        if let d = ConvZip.entry(entries, "xl/sharedStrings.xml"), let sst = XMLNode.parse(d) {
            shared = sst.all("si").map { si in si.descendants("t").map { $0.text }.joined() }
        }
        var rels: [String: String] = [:]
        if let d = ConvZip.entry(entries, "xl/_rels/workbook.xml.rels"), let r = XMLNode.parse(d) {
            for rel in r.all("Relationship") { if let id = rel.attr("Id"), let t = rel.attr("Target") { rels[id] = t } }
        }
        var sheets: [Sheet] = []
        for s in wb.first("sheets")?.all("sheet") ?? [] {
            guard let rid = s.attr("id") ?? s.attrs["r:id"], var target = rels[rid] else { continue }
            target = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard let d = ConvZip.entry(entries, target), let ws = XMLNode.parse(d) else { continue }
            var rows: [[Cell]] = []
            for r in ws.first("sheetData")?.all("row") ?? [] {
                try Task.checkCancellation()
                let rowIndex = (Int(r.attr("r") ?? "") ?? rows.count + 1) - 1
                while rows.count < rowIndex { rows.append([]) }
                var row: [Cell] = []
                for c in r.all("c") {
                    let col = columnIndex(c.attr("r") ?? "")
                    while row.count < col { row.append(Cell(text: "")) }
                    let type = c.attr("t") ?? "n"
                    let v = c.first("v")?.text ?? ""
                    switch type {
                    case "s": row.append(Cell(text: Int(v).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""))
                    case "inlineStr": row.append(Cell(text: c.first("is")?.descendants("t").map { $0.text }.joined() ?? ""))
                    case "b": row.append(Cell(text: v == "1" ? "TRUE" : "FALSE"))
                    case "str", "e": row.append(Cell(text: v))
                    default: row.append(Cell(text: v, isNumber: !v.isEmpty))
                    }
                }
                rows.append(row)
            }
            sheets.append(Sheet(name: s.attr("name") ?? "Sheet\(sheets.count + 1)", rows: rows))
        }
        guard !sheets.isEmpty else { throw FileChangerError.failed("The spreadsheet is empty or exceeds the 128 MB conversion limit.") }
        return Workbook(sheets: sheets)
    }

    static func readODS(_ url: URL) throws -> Workbook {
        let entries = try ConvZip.read(url)
        guard let d = ConvZip.entry(entries, "content.xml"), let root = XMLNode.parse(d),
              let body = root.first("body")?.first("spreadsheet") else {
            throw FileChangerError.failed("The spreadsheet could not be read.")
        }
        var sheets: [Sheet] = []
        for t in body.all("table") {
            var rows: [[Cell]] = []
            for r in t.descendants("table-row") {
                try Task.checkCancellation()
                let rrep = min(Int(r.attr("number-rows-repeated") ?? "1") ?? 1, 1000)
                var row: [Cell] = []
                for c in r.children where c.local == "table-cell" || c.local == "covered-table-cell" {
                    let crep = min(Int(c.attr("number-columns-repeated") ?? "1") ?? 1, 1024)
                    let type = c.attr("value-type") ?? ""
                    let text = c.all("p").map { $0.allText }.joined(separator: "\n")
                    let cell: Cell
                    switch type {
                    case "float", "percentage", "currency": cell = Cell(text: c.attr("value") ?? text, isNumber: true)
                    case "boolean": cell = Cell(text: (c.attr("boolean-value") ?? "") == "true" ? "TRUE" : "FALSE")
                    case "date": cell = Cell(text: c.attr("date-value") ?? text)
                    default: cell = Cell(text: text)
                    }
                    for _ in 0..<crep { row.append(cell) }
                }
                while let last = row.last, last.text.isEmpty { row.removeLast() }
                for _ in 0..<rrep { rows.append(row) }
            }
            while let last = rows.last, last.isEmpty { rows.removeLast() }
            sheets.append(Sheet(name: t.attr("name") ?? "Sheet\(sheets.count + 1)", rows: rows))
        }
        guard !sheets.isEmpty else { throw FileChangerError.failed("The spreadsheet could not be read.") }
        return Workbook(sheets: sheets)
    }

    // MARK: Writing

    static func delimited(_ sheet: Sheet, delimiter: String) -> String {
        sheet.rows.map { row in
            row.map { c -> String in
                if c.text.contains(delimiter) || c.text.contains("\"") || c.text.contains("\n") || c.text.contains("\r") {
                    return "\"" + c.text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return c.text
            }.joined(separator: delimiter)
        }.joined(separator: "\n") + "\n"
    }

    static func xlsxData(_ wb: Workbook, to url: URL) throws {
        let x = ConvText.escapeXML
        var entries: [ConvZip.Entry] = []
        let n = wb.sheets.count
        entries.append(.init(name: "[Content_Types].xml", data: Data(("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        """ + (1...n).map { "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined() + "</Types>").utf8)))
        entries.append(.init(name: "_rels/.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """.utf8)))
        entries.append(.init(name: "xl/workbook.xml", data: Data(("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>
        """ + wb.sheets.enumerated().map { "<sheet name=\"\(x(String($0.element.name.prefix(31))))\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>" }.joined() + "</sheets></workbook>").utf8)))
        entries.append(.init(name: "xl/_rels/workbook.xml.rels", data: Data(("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        """ + (1...n).map { "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>" }.joined()
            + "<Relationship Id=\"rId\(n + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>").utf8)))
        entries.append(.init(name: "xl/styles.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs></styleSheet>
        """.utf8)))
        for (i, sheet) in wb.sheets.enumerated() {
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
            for (r, row) in sheet.rows.enumerated() {
                try Task.checkCancellation()
                xml += "<row r=\"\(r + 1)\">"
                for (c, cell) in row.enumerated() where !cell.text.isEmpty {
                    let ref = "\(columnName(c))\(r + 1)"
                    if cell.isNumber { xml += "<c r=\"\(ref)\"><v>\(x(cell.text))</v></c>" }
                    else { xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(x(cell.text))</t></is></c>" }
                }
                xml += "</row>"
            }
            xml += "</sheetData></worksheet>"
            entries.append(.init(name: "xl/worksheets/sheet\(i + 1).xml", data: Data(xml.utf8)))
        }
        try ConvZip.write(entries, to: url)
    }

    static func odsData(_ wb: Workbook, to url: URL) throws {
        let x = ConvText.escapeXML
        var body = ""
        for sheet in wb.sheets {
            body += "<table:table table:name=\"\(x(sheet.name))\">"
            let width = sheet.rows.map { $0.count }.max() ?? 1
            body += "<table:table-column table:number-columns-repeated=\"\(max(1, width))\"/>"
            for row in sheet.rows {
                body += "<table:table-row>"
                for cell in row {
                    if cell.text.isEmpty { body += "<table:table-cell/>" }
                    else if cell.isNumber { body += "<table:table-cell office:value-type=\"float\" office:value=\"\(x(cell.text))\"><text:p>\(x(cell.text))</text:p></table:table-cell>" }
                    else { body += "<table:table-cell office:value-type=\"string\" calcext:value-type=\"string\"><text:p>\(x(cell.text))</text:p></table:table-cell>" }
                }
                body += "</table:table-row>"
            }
            body += "</table:table>"
        }
        let content = """
        <?xml version="1.0" encoding="UTF-8"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:calcext="urn:org:documentfoundation:names:experimental:calc:xmlns:calcext:1.0" office:version="1.2"><office:body><office:spreadsheet>\(body)</office:spreadsheet></office:body></office:document-content>
        """
        let manifest = """
        <?xml version="1.0" encoding="UTF-8"?><manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>
        """
        try ConvZip.write([.init(name: "mimetype", data: Data("application/vnd.oasis.opendocument.spreadsheet".utf8), store: true),
                           .init(name: "META-INF/manifest.xml", data: Data(manifest.utf8)),
                           .init(name: "content.xml", data: Data(content.utf8))], to: url)
    }

    /// Paginated grid PDF: Helvetica 9 pt, columns sized to content (max 220 pt), wide sheets split across pages.
    static func pdf(_ wb: Workbook, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 792, height: 612)   // US Letter landscape
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw FileChangerError.failed("Could not create the PDF.") }
        let font = CTFontCreateWithName("Helvetica" as CFString, 9, nil)
        let bold = CTFontCreateWithName("Helvetica-Bold" as CFString, 9, nil)
        let margin: CGFloat = 36, rowH: CGFloat = 15, pad: CGFloat = 4
        func line(_ s: String, _ f: CTFont) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: s.replacingOccurrences(of: "\n", with: " "), attributes: [.font: f, .foregroundColor: CGColor(gray: 0, alpha: 1)]) as CFAttributedString)
        }
        var anyPage = false
        for sheet in wb.sheets {
            try Task.checkCancellation()
            let cols = max(1, sheet.rows.map { $0.count }.max() ?? 1)
            var widths = [CGFloat](repeating: 30, count: cols)
            for row in sheet.rows.prefix(2000) {
                for (c, cell) in row.enumerated() {
                    let w = CTLineGetTypographicBounds(line(String(cell.text.prefix(120)), font), nil, nil, nil) + Double(pad * 2)
                    widths[c] = min(220, max(widths[c], CGFloat(w)))
                }
            }
            // Column groups that fit the page width.
            var groups: [Range<Int>] = [], start = 0, acc: CGFloat = 0
            for c in 0..<cols {
                if acc + widths[c] > box.width - margin * 2 && c > start { groups.append(start..<c); start = c; acc = 0 }
                acc += widths[c]
            }
            groups.append(start..<cols)
            let perPage = max(1, Int((box.height - margin * 2 - 18) / rowH))
            let rowCount = max(1, sheet.rows.count)
            for g in groups {
                var r0 = 0
                repeat {
                    try Task.checkCancellation()
                    ctx.beginPDFPage(nil); anyPage = true
                    ctx.setFillColor(CGColor(gray: 0.45, alpha: 1))
                    ctx.textPosition = CGPoint(x: margin, y: box.height - margin + 6)
                    CTLineDraw(line(sheet.name, bold), ctx)
                    var y = box.height - margin - 10
                    for r in r0..<min(rowCount, r0 + perPage) {
                        var x = margin
                        for c in g {
                            let w = widths[c]
                            let text = r < sheet.rows.count && c < sheet.rows[r].count ? sheet.rows[r][c].text : ""
                            ctx.saveGState()
                            ctx.clip(to: CGRect(x: x, y: y - rowH, width: w, height: rowH))
                            ctx.setStrokeColor(CGColor(gray: 0.8, alpha: 1)); ctx.setLineWidth(0.5)
                            ctx.stroke(CGRect(x: x, y: y - rowH, width: w, height: rowH))
                            if !text.isEmpty {
                                ctx.textPosition = CGPoint(x: x + pad, y: y - rowH + 4.5)
                                CTLineDraw(line(String(text.prefix(300)), font), ctx)
                            }
                            ctx.restoreGState()
                            x += w
                        }
                        y -= rowH
                    }
                    ctx.endPDFPage()
                    r0 += perPage
                } while r0 < rowCount
            }
        }
        if !anyPage { ctx.beginPDFPage(nil); ctx.endPDFPage() }
        ctx.closePDF()
    }

    // MARK: Entry point

    static func convert(_ file: URL, from s: F, to t: F, progress: ProgressHandler) async throws -> URL {
        let wb = try read(file, as: s)
        progress(0.5)
        let dest = Conversions.outputURL(for: file, ext: t.ext)
        try await OutputLocation.writeAtomically(to: dest) { temp in
            switch t {
            case .csv: try Data(delimited(wb.sheets[0], delimiter: ",").utf8).write(to: temp)
            case .tsv: try Data(delimited(wb.sheets[0], delimiter: "\t").utf8).write(to: temp)
            case .xlsx: try xlsxData(wb, to: temp)
            case .ods: try odsData(wb, to: temp)
            case .pdf: try pdf(wb, to: temp)
            default: throw FileChangerError.unsupported("Conversion from \(s.label) is unavailable.")
            }
        }
        return dest
    }
}
