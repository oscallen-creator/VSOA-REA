import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// META-01..08. Reads, edits and strips metadata with ImageIO (images) and PDFKit (PDF), verifying the result.
struct MetadataField: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case text, list, removalOnly(String), readOnly(String) }
    let id: String           // tag path ("tiff:Make") or PDF attribute name
    let group: String        // IFD0, ExifIFD, GPS, IPTC, XMP-dc, Photoshop, Document...
    let key: String
    var value: String
    let kind: Kind
    var copy: Int? = nil     // "copy N" when the same tag repeats
    var isEditable: Bool { kind == .text || kind == .list }
    var note: String? { switch kind { case .removalOnly(let n), .readOnly(let n): return n; default: return nil } }
    var isRemovable: Bool { if case .readOnly = kind { return false }; return true }
}

enum ImageMetadataEngine {
    static let verifyFailed = "The image could not be verified. No output was saved."
    static let privateRemains = "Private metadata remains; no output was saved"
    static let pixelsChanged = "Image pixels changed; the output was rejected"
    static let groupedNote = "Grouped metadata - remove together"
    static let repeatedNote = "Repeated metadata - remove together"
    static let binaryNote = "[Binary data]"

    /// Rendering/technical tags: never shown, never removed one by one (META-03).
    static let protectedTags: Set<String> = [
        "tiff:Orientation", "tiff:ResolutionUnit", "tiff:XResolution", "tiff:YResolution", "tiff:Compression",
        "tiff:PhotometricInterpretation", "tiff:TileWidth", "tiff:TileLength", "tiff:ImageWidth", "tiff:ImageLength",
        "tiff:BitsPerSample", "tiff:SamplesPerPixel", "tiff:PlanarConfiguration", "tiff:YCbCrPositioning",
        "exif:ColorSpace", "exif:PixelXDimension", "exif:PixelYDimension", "exif:ComponentsConfiguration",
        "exif:Gamma", "exif:ExifVersion", "exif:FlashpixVersion",
    ]
    static func isHidden(prefix: String, name: String) -> Bool { prefix == "iio" || protectedTags.contains("\(prefix):\(name)") }

    static func groupName(prefix: String, name: String) -> String {
        switch prefix {
        case "tiff": return "IFD0"
        case "exif": return name.hasPrefix("GPS") ? "GPS" : "ExifIFD"
        case "exifEX", "aux": return "ExifIFD"
        case "photoshop": return "Photoshop"
        case "Iptc4xmpCore", "Iptc4xmpExt", "iptc": return "IPTC"
        default: return "XMP-\(prefix)"
        }
    }

    // MARK: Reading

    private static func describe(_ value: CFTypeRef?, type: CGImageMetadataType) -> (text: String, kind: MetadataField.Kind) {
        switch value {
        case let s as String: return (s, .text)
        case let n as NSNumber: return (n.stringValue, .text)
        case is Data: return (binaryNote, .removalOnly(binaryNote))
        case let tags as [CGImageMetadataTag]:
            if type == .alternateText || type == .alternateArray { return (tags.compactMap { stringValue($0) }.first ?? "", .removalOnly("Language alternatives - remove only")) }
            return (tags.compactMap { stringValue($0) }.joined(separator: "\n"), .list)
        default: return ("", .removalOnly(groupedNote))
        }
    }

    private static func stringValue(_ tag: CGImageMetadataTag) -> String? {
        switch CGImageMetadataTagCopyValue(tag) {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    private static func tagPath(_ t: CGImageMetadataTag) -> (prefix: String, name: String)? {
        guard let p = CGImageMetadataTagCopyPrefix(t) as String?, let n = CGImageMetadataTagCopyName(t) as String? else { return nil }
        return (p, n)
    }

    static func readImage(_ url: URL) throws -> [MetadataField] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw FileChangerError.failed("\(url.lastPathComponent) could not be read as an image.")
        }
        guard let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil), let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] else { return [] }
        var counts: [String: Int] = [:]
        var fields: [MetadataField] = []
        for t in tags {
            guard let (prefix, name) = tagPath(t), !isHidden(prefix: prefix, name: name) else { continue }
            let id = "\(prefix):\(name)"
            let n = (counts[id] ?? 0) + 1; counts[id] = n
            let (text, kind) = describe(CGImageMetadataTagCopyValue(t), type: CGImageMetadataTagGetType(t))
            fields.append(MetadataField(id: id, group: groupName(prefix: prefix, name: name), key: name, value: text,
                                        kind: n > 1 ? .removalOnly(repeatedNote) : kind, copy: n > 1 ? n : nil))
        }
        if let icc = ImageFiles.properties(url)[kCGImagePropertyProfileName] as? String {
            fields.append(MetadataField(id: "icc", group: "ICC", key: "Profile", value: icc, kind: .readOnly("Colour profile - always kept")))
        }
        if hasContentCredentials(url) {
            fields.append(MetadataField(id: "c2pa", group: "Metadata groups", key: "Content credentials",
                                        value: "Signed metadata - remove entire group", kind: .removalOnly("Signed metadata - remove entire group")))
        }
        return fields.sorted { ($0.group, $0.key, $0.copy ?? 0) < ($1.group, $1.key, $1.copy ?? 0) }
    }

    /// C2PA manifests ride in a JUMBF box/segment labelled "c2pa"; a byte scan is enough to flag them.
    static func hasContentCredentials(_ url: URL) -> Bool {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return d.range(of: Data("jumb".utf8)) != nil && d.range(of: Data("c2pa".utf8)) != nil
    }

    // MARK: Writing

    private static func isLossless(_ type: String) -> Bool {
        [UTType.png, .tiff, .bmp].contains { $0.identifier == type }
    }

    /// Writes `source` to `dest` with `metadata` replacing all existing metadata, keeping pixels intact.
    private static func write(source url: URL, to dest: URL, metadata: CGMutableImageMetadata, orientation: Int?) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else {
            throw FileChangerError.failed("\(url.lastPathComponent) could not be read as an image.")
        }
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, type, CGImageSourceGetCount(src), nil) else {
            throw FileChangerError.unsupported("This format could not save the change. The original file is unchanged.")
        }
        let single = CGImageSourceGetCount(src) == 1
        if isLossless(type as String), single {
            guard let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw FileChangerError.failed(verifyFailed) }
            var opts: [CFString: Any] = [:]
            if let orientation, orientation != 1 { opts[kCGImagePropertyOrientation] = orientation }
            // PNG colour chunks (gamma, sRGB, chromaticities) describe how to render the pixels; keep them.
            if let png = ImageFiles.properties(url)[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
                let keep = png.filter { [kCGImagePropertyPNGGamma, kCGImagePropertyPNGsRGBIntent, kCGImagePropertyPNGChromaticities].contains($0.key) }
                if !keep.isEmpty { opts[kCGImagePropertyPNGDictionary] = keep }
            }
            CGImageDestinationAddImageAndMetadata(out, img, metadata, opts as CFDictionary)
            guard CGImageDestinationFinalize(out) else { throw FileChangerError.failed("This format could not save the change. The original file is unchanged.") }
            return
        }
        var err: Unmanaged<CFError>?
        let opts: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: false,
                                     kCGImageMetadataShouldExcludeGPS: false]
        guard CGImageDestinationCopyImageSource(out, src, opts as CFDictionary, &err) else {
            throw FileChangerError.unsupported("This format could not save the change. The original file is unchanged.")
        }
    }

    private static func orientation(of url: URL) -> Int? { ImageFiles.properties(url)[kCGImagePropertyOrientation] as? Int }

    private static func mutableMetadata(_ url: URL) throws -> CGMutableImageMetadata {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw FileChangerError.failed(verifyFailed) }
        if let m = CGImageSourceCopyMetadataAtIndex(src, 0, nil), let copy = CGImageMetadataCreateMutableCopy(m) { return copy }
        return CGImageMetadataCreateMutable()
    }

    /// Everything left in the file that is not a rendering tag (used to prove Remove All worked).
    static func privateTags(_ url: URL) -> [String] {
        var left: [String] = []
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
           let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] {
            for t in tags { if let (p, n) = tagPath(t), !isHidden(prefix: p, name: n) { left.append("\(p):\(n)") } }
        }
        let props = ImageFiles.properties(url)
        for (k, v) in props {
            let key = k as String
            if ["{GPS}", "{IPTC}", "{MakerApple}", "{MakerCanon}", "{MakerNikon}", "{Photoshop}"].contains(key) { left.append(key) }
            if key == "{Exif}", let d = v as? [String: Any] {
                let technical: Set<String> = ["ColorSpace", "PixelXDimension", "PixelYDimension", "ComponentsConfiguration", "ExifVersion", "FlashPixVersion"]
                left += d.keys.filter { !technical.contains($0) }.map { "exif:\($0)" }
            }
            if key == "{TIFF}", let d = v as? [String: Any] {
                let technical: Set<String> = ["Orientation", "ResolutionUnit", "XResolution", "YResolution", "Compression", "PhotometricInterpretation", "TileWidth", "TileLength"]
                left += d.keys.filter { !technical.contains($0) }.map { "tiff:\($0)" }
            }
        }
        if hasContentCredentials(url) { left.append("c2pa") }
        return left
    }

    /// Mean absolute per-channel difference (0...255) between the decoded pixels of two files.
    static func meanPixelDifference(_ a: URL, _ b: URL) -> Double? {
        guard let x = try? ImageFiles.load(a), let y = try? ImageFiles.load(b), x.width == y.width, x.height == y.height else { return nil }
        func bytes(_ i: CGImage) -> [UInt8]? {
            var px = [UInt8](repeating: 0, count: i.width * i.height * 4)
            guard let c = CGContext(data: &px, width: i.width, height: i.height, bitsPerComponent: 8, bytesPerRow: i.width * 4,
                                    space: ImageFiles.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            c.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height))
            return px
        }
        guard let p = bytes(x), let q = bytes(y), !p.isEmpty else { return nil }
        var sum = 0
        for i in 0..<p.count { sum += abs(Int(p[i]) - Int(q[i])) }
        return Double(sum) / Double(p.count)
    }

    private static func finish(_ tmp: URL, from url: URL, expectHash: Bool) throws {
        if expectHash {
            guard let a = ImageFiles.pixelHash(url), let b = ImageFiles.pixelHash(tmp) else { throw FileChangerError.failed(verifyFailed) }
            guard a == b else { throw FileChangerError.failed(pixelsChanged) }
        }
    }

    /// Remove All: strips every private group, keeping ICC profile, orientation and pixels (verified, fail closed).
    static func removeAll(_ url: URL, progress: ProgressHandler = { _ in }) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        if ext == "webp" {
            let dest = OutputLocation.sibling(of: url, suffix: "-clean")
            try await OutputLocation.writeAtomically(to: dest) { tmp in
                let cleaned = try stripWebP(try Data(contentsOf: url))
                try cleaned.write(to: tmp)
                // Verify when ImageIO can decode WebP: same pixels, no metadata chunks left.
                if let a = ImageFiles.pixelHash(url) {
                    guard ImageFiles.pixelHash(tmp) == a else { throw FileChangerError.failed(pixelsChanged) }
                }
                if !privateTags(tmp).isEmpty { throw FileChangerError.failed(privateRemains) }
            }
            return dest
        }
        let dest = OutputLocation.sibling(of: url, suffix: "-clean")
        let isHEIC = ["heic", "heif"].contains(ext)
        try await OutputLocation.writeAtomically(to: dest) { tmp in
            progress(0.2)
            let meta = CGImageMetadataCreateMutable()
            let o = orientation(of: url)
            if let o, o != 1 { CGImageMetadataSetValueWithPath(meta, nil, "tiff:Orientation" as CFString, o as CFNumber) }
            do {
                try write(source: url, to: tmp, metadata: meta, orientation: o)
                try finish(tmp, from: url, expectHash: true)
                if !privateTags(tmp).isEmpty { throw FileChangerError.failed(privateRemains) }
            } catch let e as FileChangerError where isHEIC && e.errorDescription == privateRemains {
                // HEIC keeps its XMP in the container; re-encode at maximum quality (documented: HDR/portrait effects may change).
                try? FileManager.default.removeItem(at: tmp)
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let raw = CGImageSourceCreateImageAtIndex(src, 0, nil),
                      let out = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.heic.identifier as CFString, 1, nil) else { throw e }
                var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
                if let o, o != 1 { props[kCGImagePropertyOrientation] = o }
                CGImageDestinationAddImage(out, raw, props as CFDictionary)
                guard CGImageDestinationFinalize(out) else { throw e }
                guard privateTags(tmp).isEmpty else { throw e }
                // Re-encoding is lossy: accept only a visually identical result (mean difference under 2/255).
                guard let d = meanPixelDifference(url, tmp), d < 2 else { throw FileChangerError.failed(pixelsChanged) }
            }
            progress(0.9)
        }
        return dest
    }

    /// Saves edits/removals of chosen fields only; every other field must come out unchanged.
    static func save(_ url: URL, removing: Set<String>, editing: [String: String], progress: ProgressHandler = { _ in }) async throws -> URL {
        let before = try readImage(url)
        var source = url
        if removing.contains("c2pa") {
            guard let stripped = stripContentCredentials(try Data(contentsOf: url), ext: url.pathExtension.lowercased()) else {
                throw FileChangerError.unsupported("Content credentials cannot be removed from this format. Use Remove All.")
            }
            source = url.deletingLastPathComponent().appendingPathComponent(".filechanger-c2pa-\(UUID().uuidString).\(url.pathExtension)")
            try stripped.write(to: source)
        }
        defer { if source != url { try? FileManager.default.removeItem(at: source) } }
        let meta = try mutableMetadata(source)
        for id in removing where id != "c2pa" { CGImageMetadataRemoveTagWithPath(meta, nil, id as CFString) }
        for (id, text) in editing where !removing.contains(id) {
            guard let f = before.first(where: { $0.id == id }), f.isEditable else { throw FileChangerError.failed("One of these fields cannot be edited.") }
            if f.kind == .list { try setList(meta, id: id, lines: text) }
            else {
                let value: CFTypeRef = (Double(text) != nil && Double(f.value) != nil) ? NSNumber(value: Double(text) ?? 0) : text as CFString
                guard CGImageMetadataSetValueWithPath(meta, nil, id as CFString, value) else {
                    throw FileChangerError.failed("This format could not save the change to \(f.key). The original file is unchanged.")
                }
            }
        }
        let dest = OutputLocation.sibling(of: url, suffix: "-edited")
        let lossless = ["jpg", "jpeg", "png", "tif", "tiff"].contains(url.pathExtension.lowercased())
        try await OutputLocation.writeAtomically(to: dest) { tmp in
            progress(0.3)
            try write(source: source, to: tmp, metadata: meta, orientation: orientation(of: source))
            try finish(tmp, from: url, expectHash: lossless)
            if removing.contains("c2pa") && hasContentCredentials(tmp) { throw FileChangerError.failed(privateRemains) }
            let after = try readImage(tmp)
            for id in removing where id != "c2pa" {
                if let f = after.first(where: { $0.id == id }) {
                    throw FileChangerError.failed("This format could not save the change to \(f.key). The original file is unchanged.")
                }
            }
            for (id, text) in editing where !removing.contains(id) {
                let norm: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard let f = after.first(where: { $0.id == id }), norm(f.value) == norm(text) || Double(f.value) == Double(text) else {
                    throw FileChangerError.failed("This format could not save the change to \(before.first { $0.id == id }?.key ?? id). The original file is unchanged.")
                }
            }
            let expected = before.filter { !removing.contains($0.id) && editing[$0.id] == nil && $0.id != "c2pa" }
            for f in expected where !after.contains(where: { $0.id == f.id && $0.value == f.value }) {
                throw FileChangerError.failed("The source metadata changed. Reopen the editor.")
            }
        }
        return dest
    }

    private static func setList(_ meta: CGMutableImageMetadata, id: String, lines: String) throws {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let existing = CGImageMetadataCopyTagWithPath(meta, nil, id as CFString),
              let ns = CGImageMetadataTagCopyNamespace(existing) else { throw FileChangerError.failed("One of these fields cannot be edited.") }
        let items = lines.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let elements = items.compactMap { CGImageMetadataTagCreate(ns, nil, "" as CFString, .string, $0 as CFString) }
        guard let tag = CGImageMetadataTagCreate(ns, parts[0] as CFString, parts[1] as CFString,
                                                 CGImageMetadataTagGetType(existing), elements as CFArray),
              CGImageMetadataSetTagWithPath(meta, nil, id as CFString, tag) else {
            throw FileChangerError.failed("This metadata field is not supported.")
        }
    }

    // MARK: Content credentials

    /// Removes C2PA/JUMBF from a JPEG (APP11 segments) or PNG (caBX chunk) without touching pixel data; nil for other formats.
    static func stripContentCredentials(_ data: Data, ext: String) -> Data? {
        let b = [UInt8](data)
        if ext == "jpg" || ext == "jpeg" {
            guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
            var out: [UInt8] = [0xFF, 0xD8]
            var i = 2
            while i + 4 <= b.count, b[i] == 0xFF {
                let marker = b[i + 1]
                if marker == 0xDA { break }
                let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
                guard len >= 2, i + 2 + len <= b.count else { return nil }
                if marker != 0xEB { out += b[i..<i + 2 + len] }
                i += 2 + len
            }
            out += b[i...]
            return Data(out)
        }
        if ext == "png" {
            guard b.count > 8 else { return nil }
            var out = Array(b[0..<8]), i = 8
            while i + 12 <= b.count {
                let len = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
                guard i + 12 + len <= b.count else { return nil }
                if String(decoding: b[i + 4..<i + 8], as: UTF8.self) != "caBX" { out += b[i..<i + 12 + len] }
                i += 12 + len
            }
            return Data(out)
        }
        return nil
    }

    // MARK: WebP

    /// Drops EXIF / XMP / ICC-free chunks from a RIFF WebP and clears the matching VP8X flags.
    static func stripWebP(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count >= 12, b[0..<4].elementsEqual("RIFF".utf8), b[8..<12].elementsEqual("WEBP".utf8) else {
            throw FileChangerError.failed(verifyFailed)
        }
        var out = Array(b[0..<12])
        var pos = 12
        while pos + 8 <= b.count {
            let tag = String(decoding: b[pos..<pos + 4], as: UTF8.self)
            let size = Int(b[pos + 4]) | Int(b[pos + 5]) << 8 | Int(b[pos + 6]) << 16 | Int(b[pos + 7]) << 24
            let end = min(b.count, pos + 8 + size + (size & 1))
            if tag == "EXIF" || tag == "XMP " { pos = end; continue }
            var chunk = Array(b[pos..<end])
            if tag == "VP8X", chunk.count >= 9 { chunk[8] &= ~(0x08 | 0x04) }
            out += chunk
            pos = end
        }
        let size = out.count - 8
        out[4] = UInt8(size & 255); out[5] = UInt8((size >> 8) & 255); out[6] = UInt8((size >> 16) & 255); out[7] = UInt8((size >> 24) & 255)
        return Data(out)
    }
}

enum PDFMetadataEngine {
    static let attributes: [(key: PDFDocumentAttribute, label: String)] = [
        (.titleAttribute, "Title"), (.authorAttribute, "Author"), (.subjectAttribute, "Subject"), (.keywordsAttribute, "Keywords"),
        (.creatorAttribute, "Creator"), (.producerAttribute, "Producer"), (.creationDateAttribute, "CreationDate"), (.modificationDateAttribute, "ModDate"),
    ]

    static func read(_ url: URL) throws -> [MetadataField] {
        guard let doc = PDFDocument(url: url) else { throw FileChangerError.failed("\(url.lastPathComponent) could not be read as a PDF.") }
        let attrs = doc.documentAttributes ?? [:]
        var out: [MetadataField] = []
        for (key, label) in attributes {
            guard let v = attrs[key] else { continue }
            switch v {
            case let s as String where !s.isEmpty: out.append(MetadataField(id: label, group: "Document", key: label, value: s, kind: .text))
            case let a as [String]: out.append(MetadataField(id: label, group: "Document", key: label, value: a.joined(separator: "\n"), kind: .list))
            case let d as Date: out.append(MetadataField(id: label, group: "Document", key: label, value: ISO8601DateFormatter().string(from: d), kind: .removalOnly("Dates are removal-only")))
            default: break
            }
        }
        return out
    }

    static func save(_ url: URL, removing: Set<String>, editing: [String: String], all: Bool = false, progress: ProgressHandler = { _ in }) async throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw FileChangerError.failed("\(url.lastPathComponent) could not be read as a PDF.") }
        var attrs = all ? [:] : (doc.documentAttributes ?? [:])
        for (key, label) in attributes {
            if removing.contains(label) { attrs[key] = nil }
            else if let t = editing[label] {
                attrs[key] = key == .keywordsAttribute ? t.split(whereSeparator: \.isNewline).map { String($0) } : t
            }
        }
        doc.documentAttributes = attrs
        let dest = OutputLocation.sibling(of: url, suffix: all ? "-clean" : "-edited")
        try await OutputLocation.writeAtomically(to: dest) { tmp in
            guard doc.write(to: tmp) else { throw FileChangerError.failed("PDFKit could not write the cleaned PDF.") }
            // Verify: removed fields are gone (macOS itself re-stamps Creator, Producer and dates).
            let system: Set<String> = ["Creator", "Producer", "CreationDate", "ModDate"]
            for f in try read(tmp) where (all || removing.contains(f.id)) && !system.contains(f.id) {
                throw FileChangerError.failed(ImageMetadataEngine.privateRemains)
            }
        }
        return dest
    }
}

/// One entry point for the Metadata tool.
enum MetadataEngine {
    static func read(_ url: URL) throws -> [MetadataField] {
        FileKind.of(url) == .pdf ? try PDFMetadataEngine.read(url) : try ImageMetadataEngine.readImage(url)
    }
    static func removeAll(_ url: URL, progress: ProgressHandler) async throws -> URL {
        FileKind.of(url) == .pdf ? try await PDFMetadataEngine.save(url, removing: [], editing: [:], all: true, progress: progress)
                                  : try await ImageMetadataEngine.removeAll(url, progress: progress)
    }
    static func save(_ url: URL, removing: Set<String>, editing: [String: String], progress: ProgressHandler) async throws -> URL {
        FileKind.of(url) == .pdf ? try await PDFMetadataEngine.save(url, removing: removing, editing: editing, progress: progress)
                                  : try await ImageMetadataEngine.save(url, removing: removing, editing: editing, progress: progress)
    }
}
