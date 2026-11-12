import Foundation
import UniformTypeIdentifiers

/// What a dropped file is, decided once from its type so every area routes the same way.
enum FileKind: String, CaseIterable, Sendable {
    case image, audio, video, pdf, document, spreadsheet, presentation, ebook, archive, subtitle, other

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        // Extensions UTType misfiles or does not know on macOS 15.
        switch ext {
        case "srt", "vtt", "webvtt", "ass", "ssa", "sbv": return .subtitle
        case "epub": return .ebook
        case "pages", "docx", "doc", "odt", "rtf", "rtfd", "txt", "md", "markdown", "html", "htm": return .document
        case "xlsx", "xls", "ods", "csv", "tsv", "numbers": return .spreadsheet
        case "pptx", "ppt", "odp", "key": return .presentation
        case "zip", "tar", "tgz", "gz", "gzip", "bz2", "xz", "7z", "rar": return .archive
        case "webm", "mkv", "avi", "wmv", "flv": return .video
        case "opus", "ogg", "oga", "flac", "amr", "wma": return .audio
        case "svg", "svgz", "avif", "webp", "heic", "heif": return .image
        default: break
        }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .presentation) { return .presentation }
        if type.conforms(to: .spreadsheet) { return .spreadsheet }
        if type.conforms(to: .text) || type.conforms(to: .compositeContent) { return .document }
        return .other
    }
}
