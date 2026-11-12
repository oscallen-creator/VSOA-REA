import Foundation

/// Tiny XML tree used to read OOXML/ODF/EPUB packages. Entities and DTDs are refused (the original rejects them too).
final class XMLNode {
    let name: String
    var attrs: [String: String]
    var children: [XMLNode] = []
    var text = ""
    weak var parent: XMLNode?

    init(name: String, attrs: [String: String]) { self.name = name; self.attrs = attrs }

    /// Local name without a namespace prefix.
    var local: String { name.split(separator: ":").last.map(String.init) ?? name }

    func attr(_ key: String) -> String? {
        if let v = attrs[key] { return v }
        return attrs.first { $0.key.split(separator: ":").last.map(String.init) == key }?.value
    }

    func first(_ local: String) -> XMLNode? { children.first { $0.local == local } }
    func all(_ local: String) -> [XMLNode] { children.filter { $0.local == local } }

    /// Depth-first search for every descendant with this local name.
    func descendants(_ local: String) -> [XMLNode] {
        var out: [XMLNode] = []
        for c in children { if c.local == local { out.append(c) }; out += c.descendants(local) }
        return out
    }

    /// All character data below this node.
    var allText: String { text + children.map { $0.allText }.joined() }

    static func parse(_ data: Data) -> XMLNode? {
        if let s = String(data: data.prefix(4096), encoding: .utf8), s.contains("<!ENTITY") { return nil }
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        return parser.parse() ? builder.root : nil
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        var stack: [XMLNode] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            let n = XMLNode(name: name, attrs: attributes)
            n.parent = stack.last
            stack.last?.children.append(n)
            if root == nil { root = n }
            stack.append(n)
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    }
}
