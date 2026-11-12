import Foundation
import AppKit

/// Markdown <-> HTML and attributed text (DOC-06, DOC-08). Small CommonMark subset: headings, paragraphs,
/// lists, quotes, fenced code, rules, tables, emphasis, code spans, links, images. Raw HTML is escaped.
enum ConversionMarkdown {
    static func inline(_ raw: String) -> String {
        var s = ConvText.escapeXML(raw).replacingOccurrences(of: "&quot;", with: "\"")
        func rx(_ pattern: String, _ template: String) { s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression) }
        var codes: [String] = []
        // Protect code spans from further formatting.
        while let r = s.range(of: "`([^`]+)`", options: .regularExpression) {
            codes.append(String(s[r].dropFirst().dropLast()))
            s.replaceSubrange(r, with: "\u{1}\(codes.count - 1)\u{1}")
        }
        rx(#"!\[([^\]]*)\]\(([^)\s]+)\)"#, #"<img alt="$1" src="$2">"#)
        rx(#"\[([^\]]+)\]\(([^)\s]+)\)"#, #"<a href="$2">$1</a>"#)
        rx(#"\*\*(.+?)\*\*"#, "<strong>$1</strong>")
        rx(#"__(.+?)__"#, "<strong>$1</strong>")
        rx(#"(?<![\*\w])\*(?!\s)(.+?)(?<!\s)\*(?!\*)"#, "<em>$1</em>")
        rx(#"(?<![_\w])_(?!\s)(.+?)(?<!\s)_(?![_\w])"#, "<em>$1</em>")
        rx(#"~~(.+?)~~"#, "<del>$1</del>")
        for (i, c) in codes.enumerated() { s = s.replacingOccurrences(of: "\u{1}\(i)\u{1}", with: "<code>\(c)</code>") }
        return s
    }

    static func body(_ md: String) -> String {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out = "", para: [String] = [], i = 0
        func flush() { if !para.isEmpty { out += "<p>\(inline(para.joined(separator: " ")))</p>\n"; para = [] } }
        func isTableSep(_ l: String) -> Bool { l.contains("-") && l.allSatisfy { "|-: \t".contains($0) } && l.contains("|") }
        func cells(_ l: String) -> [String] {
            var t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") { t.removeFirst() }
            if t.hasSuffix("|") { t.removeLast() }
            return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func listMatch(_ l: String) -> (indent: Int, ordered: Bool, text: String)? {
            let indent = l.prefix { $0 == " " }.count
            let t = l.dropFirst(indent)
            if let m = t.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                let marker = t[m].trimmingCharacters(in: .whitespaces)
                return (indent, marker.first!.isNumber, String(t[m.upperBound...]))
            }
            return nil
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); i += 1; continue }
            if trimmed.hasPrefix("```") {
                flush(); i += 1
                var code: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[i]); i += 1 }
                i += 1
                out += "<pre><code>\(ConvText.escapeXML(code.joined(separator: "\n")))</code></pre>\n"; continue
            }
            if let m = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                let level = trimmed[m].filter { $0 == "#" }.count
                let text = trimmed[m.upperBound...].replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
                out += "<h\(level)>\(inline(text))</h\(level)>\n"; i += 1; continue
            }
            if trimmed.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil { flush(); out += "<hr>\n"; i += 1; continue }
            if trimmed.hasPrefix(">") {
                flush()
                var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    q.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst().drop { $0 == " " })); i += 1
                }
                out += "<blockquote>\(body(q.joined(separator: "\n")))</blockquote>\n"; continue
            }
            if trimmed.contains("|"), i + 1 < lines.count, isTableSep(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flush()
                out += "<table>\n<thead><tr>" + cells(trimmed).map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead>\n<tbody>\n"
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    out += "<tr>" + cells(lines[i]).map { "<td>\(inline($0))</td>" }.joined() + "</tr>\n"; i += 1
                }
                out += "</tbody></table>\n"; continue
            }
            if listMatch(line) != nil {
                flush()
                var items: [(Int, Bool, String)] = []
                while i < lines.count, let m = listMatch(lines[i]) { items.append((m.indent, m.ordered, m.text)); i += 1 }
                // Nested lists by indent depth.
                var stack: [(indent: Int, tag: String)] = []
                for (n, it) in items.enumerated() {
                    let tag = it.1 ? "ol" : "ul"
                    while let top = stack.last, it.0 < top.indent { out += "</li></\(top.tag)>\n"; stack.removeLast() }
                    if let top = stack.last, it.0 == top.indent { out += "</li>\n" }
                    else if stack.isEmpty || it.0 > stack.last!.indent { out += "<\(tag)>\n"; stack.append((it.0, tag)) }
                    out += "<li>\(inline(it.2))"
                    if n == items.count - 1 { while let top = stack.popLast() { out += "</li></\(top.tag)>\n" } }
                }
                continue
            }
            para.append(trimmed); i += 1
        }
        flush()
        return out
    }

    /// Pulls pipe tables out of Markdown, leaving a marker paragraph per table (used to build real docx tables).
    static func extractTables(_ md: String) -> (markdown: String, tables: [[[String]]]) {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [String] = [], tables: [[[String]]] = [], i = 0
        func cells(_ l: String) -> [String] {
            var t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") { t.removeFirst() }
            if t.hasSuffix("|") { t.removeLast() }
            return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func isSep(_ l: String) -> Bool { let t = l.trimmingCharacters(in: .whitespaces); return t.contains("-") && t.contains("|") && t.allSatisfy { "|-: \t".contains($0) } }
        var inFence = false
        while i < lines.count {
            let l = lines[i]
            if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            if !inFence, l.contains("|"), i + 1 < lines.count, isSep(lines[i + 1]) {
                var rows = [cells(l)]; i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { rows.append(cells(lines[i])); i += 1 }
                out += ["", "\(ConversionDocx.markerPrefix)\(tables.count)\(ConversionDocx.markerSuffix)", ""]
                tables.append(rows); continue
            }
            out.append(l); i += 1
        }
        return (out.joined(separator: "\n"), tables)
    }

    /// Self-contained HTML page (DOC-08 styling).
    static func page(title: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(ConvText.escapeXML(title))</title>
        <style>body{font:12pt Arial,sans-serif;line-height:1.35;margin:2em auto;max-width:48em}table{border-collapse:collapse;table-layout:fixed;width:100%}td,th{border:1px solid #aaa;padding:4px 6px;vertical-align:top}section{break-before:page}img{max-width:100%}pre{background:#f4f4f4;padding:8px;overflow:auto}blockquote{border-left:3px solid #ccc;margin-left:0;padding-left:1em;color:#444}</style>
        </head><body>
        \(body)</body></html>
        """
    }

    /// Attributed text -> Markdown: heading levels by font size, bold/italic runs, links, bullet lines.
    static func markdown(from attr: NSAttributedString) -> String {
        let text = attr.string as NSString
        var bodySize: CGFloat = 0
        var sizes: [CGFloat: Int] = [:]
        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { v, r, _ in
            if let f = v as? NSFont { sizes[f.pointSize, default: 0] += r.length }
        }
        bodySize = sizes.max { $0.value < $1.value }?.key ?? 12
        var out: [String] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { _, range, _, _ in
            guard range.length > 0 else { out.append(""); return }
            var line = ""
            var headLevel = 0
            attr.enumerateAttributes(in: range) { attrs, r, _ in
                var piece = text.substring(with: r)
                let font = attrs[.font] as? NSFont
                if let f = font, r.location == range.location {
                    if f.pointSize >= bodySize * 1.6 { headLevel = 1 } else if f.pointSize >= bodySize * 1.3 { headLevel = 2 }
                    else if f.pointSize >= bodySize * 1.12 { headLevel = 3 }
                }
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                if headLevel == 0, !trimmed.isEmpty, let f = font {
                    let t = f.fontDescriptor.symbolicTraits
                    let lead = piece.prefix { $0 == " " }, tail = piece.reversed().prefix { $0 == " " }
                    if t.contains(.bold) && t.contains(.italic) { piece = lead + "***" + trimmed + "***" + tail }
                    else if t.contains(.bold) { piece = lead + "**" + trimmed + "**" + tail }
                    else if t.contains(.italic) { piece = lead + "*" + trimmed + "*" + tail }
                }
                if let link = attrs[.link], !trimmed.isEmpty { piece = "[\(trimmed)](\(link))" }
                line += piece
            }
            if let m = line.range(of: #"^\s*[•◦▪\-\u{2022}]\s*\t?\s*"#, options: .regularExpression) { line = "- " + line[m.upperBound...] }
            else if let m = line.range(of: #"^\s*(\d+)[.)]\s*\t\s*"#, options: .regularExpression) {
                let n = line[m].filter { $0.isNumber }; line = "\(n). " + line[m.upperBound...]
            }
            if headLevel > 0 { line = String(repeating: "#", count: headLevel) + " " + line.trimmingCharacters(in: .whitespaces) }
            out.append(line.replacingOccurrences(of: "\u{FFFC}", with: ""))
        }
        // One blank line between blocks; list items stay tight.
        var result: [String] = []
        for (n, l) in out.enumerated() {
            if l.isEmpty { continue }
            if let prev = result.last, !(prev.hasPrefix("- ") && l.hasPrefix("- ")), n > 0 { result.append("") }
            result.append(l)
        }
        return result.joined(separator: "\n") + "\n"
    }
}
