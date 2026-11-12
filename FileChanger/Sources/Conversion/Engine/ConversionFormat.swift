import Foundation

/// Every format the conversion wheel knows (CNV-01), in the inventory's case order.
enum ConversionFormat: String, CaseIterable, Sendable, Hashable {
    case jpg, png, webp, heic, tiff, svg, avif, bmp, raw
    case pdf
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma
    case mp4, mov, mkv, webm, avi, wmv, gif
    case docx, pages, ppt, pptx, txt, md, rtf, rtfd, textClipping, html, epub
    case xlsx, xls, ods, csv, tsv
    case srt, vtt
    case zip, tar
    case gzip = "gz"
    case rar

    enum Group: String, CaseIterable, Sendable {
        case images = "Images", documents = "Documents", spreadsheets = "Spreadsheets"
        case audio = "Audio", video = "Video", archives = "Archives", subtitles = "Subtitles"
    }

    var group: Group {
        switch self {
        case .jpg, .png, .webp, .heic, .tiff, .svg, .avif, .bmp, .raw: return .images
        case .pdf, .docx, .pages, .ppt, .pptx, .txt, .md, .rtf, .rtfd, .textClipping, .html, .epub: return .documents
        case .xlsx, .xls, .ods, .csv, .tsv: return .spreadsheets
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma: return .audio
        case .mp4, .mov, .mkv, .webm, .avi, .wmv, .gif: return .video
        case .srt, .vtt: return .subtitles
        case .zip, .tar, .gzip, .rar: return .archives
        }
    }

    /// Group name used on the fan (ConversionTarget.group).
    var fanGroup: String {
        switch group {
        case .images: return "Image"
        case .documents: return "Document"
        case .spreadsheets: return "Spreadsheet"
        case .audio: return "Audio"
        case .video: return "Video"
        case .archives: return "Archive"
        case .subtitles: return "Subtitle"
        }
    }

    /// Read but never offered as a target (CNV-02).
    var isInputOnly: Bool { Self.inputOnly.contains(self) }
    static let inputOnly: Set<ConversionFormat> = [.raw, .rar, .ppt, .xls, .rtf, .rtfd, .textClipping]

    /// Produced but never a source (CNV-03).
    var isOutputOnly: Bool { self == .html }

    /// Extension written for this format.
    var ext: String {
        switch self {
        case .textClipping: return "textClipping"
        default: return rawValue
        }
    }

    /// Display label: the raw value uppercased (CNV-01), "GZIP" for gz.
    var label: String {
        switch self {
        case .gzip: return "GZIP"
        case .textClipping: return "Text Clipping"
        default: return rawValue.uppercased()
        }
    }

    static let rawExtensions: Set<String> = ["3fr", "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "iiq", "kdc", "mos", "mrw",
        "nef", "nrw", "orf", "pef", "ptx", "raf", "raw", "rw2", "rwl", "sr2", "srf", "srw"]

    /// Extensions that read as this format (CNV-06 aliases included).
    var inputExtensions: [String] {
        switch self {
        case .jpg: return ["jpg", "jpeg", "jpe"]
        case .tiff: return ["tiff", "tif"]
        case .heic: return ["heic", "heif"]
        case .svg: return ["svg", "svgz"]
        case .raw: return Self.rawExtensions.sorted()
        case .wav: return ["wav", "wave"]
        case .ogg: return ["ogg", "oga"]
        case .aiff: return ["aiff", "aif", "aifc"]
        case .mp4: return ["mp4", "m4v"]
        case .md: return ["md", "markdown"]
        case .html: return ["html", "htm"]
        case .vtt: return ["vtt", "webvtt"]
        case .gzip: return ["gz", "tgz", "gzip"]
        default: return [rawValue]
        }
    }

    static func of(extension ext: String) -> ConversionFormat? {
        let e = ext.lowercased()
        return allCases.first { $0.inputExtensions.contains(e) }
    }

    static func of(_ url: URL) -> ConversionFormat? { of(extension: url.pathExtension) }

    /// A `.tar.gz` / `.tgz` is a gzip archive of a tar; `.tar.gz` converts like gzip.
    static func isTarGz(_ url: URL) -> Bool {
        let n = url.lastPathComponent.lowercased()
        return n.hasSuffix(".tar.gz") || n.hasSuffix(".tgz")
    }
}

/// The observed source -> targets matrix (section 2.1 of the conversion inventory).
enum ConversionMatrix {
    typealias F = ConversionFormat

    private static let imageTargets: [F] = [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf]
    private static let audio: [F] = [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma]
    private static let video: [F] = [.mp4, .mov, .mkv, .webm, .avi, .wmv]
    private static let docSet: [F] = [.docx, .pages, .pdf, .txt, .md, .html, .epub, .png, .jpg]
    private static let sheetSet: [F] = [.xlsx, .ods, .csv, .tsv, .pdf]

    /// Targets a source offers: the static array, minus the source itself and the input-only formats.
    static func targets(from source: F) -> [F] {
        let list: [F]
        switch source {
        case .jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .svg, .raw: list = imageTargets
        case .pdf: list = [.docx, .pages, .pptx, .xlsx, .jpg, .png, .svg, .epub, .txt, .md]
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma: list = audio
        case .mp4, .mov, .mkv, .webm, .avi, .wmv: list = video + [.gif, .mp3]
        case .gif: list = video
        case .docx, .pages, .md, .rtf, .rtfd, .textClipping: list = docSet
        case .txt: list = [.docx, .pages, .pdf, .md, .html, .epub, .jpg, .png]
        case .ppt, .pptx: list = [.pdf, .jpg, .png]
        case .epub: list = [.pdf, .docx, .pages, .txt, .md, .html]
        case .xlsx, .xls, .ods, .csv, .tsv: list = sheetSet
        case .srt: list = [.vtt, .txt]
        case .vtt: list = [.srt, .txt]
        case .zip: list = [.tar, .gzip]
        case .tar: list = [.zip, .gzip]
        case .gzip: list = [.zip, .tar]
        case .rar: list = [.zip, .tar, .gzip]
        case .html: list = []
        }
        return list.filter { $0 != source && !$0.isInputOnly }
    }
}
