import Foundation

/// One adjustable conversion default (CNV-30..40). Stored as `conversionProfile.<format>.<param>` in UserDefaults.
enum ConversionParam: String, CaseIterable, Sendable {
    case quality, preserveMetadata, videoMaxHeight, audioBitrate, audioSampleDepth
    case gifFrameRate, gifMaxWidth, compression, epubLayout, epubReflowVersion, pdfOfficeLayout

    var title: String {
        switch self {
        case .quality: return "Quality"
        case .preserveMetadata: return "Preserve metadata"
        case .videoMaxHeight: return "Maximum video height"
        case .audioBitrate: return "Audio bitrate"
        case .audioSampleDepth: return "Bit depth"
        case .gifFrameRate: return "Frame rate"
        case .gifMaxWidth: return "Maximum width"
        case .compression: return "Compression"
        case .epubLayout: return "EPUB layout"
        case .epubReflowVersion: return "EPUB reflow version"
        case .pdfOfficeLayout: return "PDF layout"
        }
    }

    /// A choice list for the settings UI: (stored value, caption, optional explanation).
    struct Choice: Hashable, Sendable { let value: String; let caption: String; let detail: String? }

    var choices: [Choice] {
        switch self {
        case .quality:
            return [.init(value: "compact", caption: "Smaller File", detail: nil),
                    .init(value: "balanced", caption: "Balanced", detail: nil),
                    .init(value: "high", caption: "Higher Quality", detail: nil)]
        case .videoMaxHeight:
            return [.init(value: "0", caption: "Original", detail: nil), .init(value: "2160", caption: "2160p", detail: nil),
                    .init(value: "1080", caption: "1080p", detail: nil), .init(value: "720", caption: "720p", detail: nil)]
        case .audioBitrate:
            return [128, 192, 256, 320].map { .init(value: "\($0)", caption: "\($0) kbps", detail: nil) }
        case .audioSampleDepth:
            return [.init(value: "matchSource", caption: "Match source", detail: nil), .init(value: "bit16", caption: "16-bit", detail: nil),
                    .init(value: "bit24", caption: "24-bit", detail: nil), .init(value: "bit32", caption: "32-bit integer", detail: nil),
                    .init(value: "float32", caption: "32-bit float", detail: nil)]
        case .gifFrameRate:
            return [5, 10, 15, 20, 24, 30].map { .init(value: "\($0)", caption: "\($0) fps", detail: nil) }
        case .gifMaxWidth:
            return [480, 960, 1280].map { .init(value: "\($0)", caption: "\($0) px", detail: nil) }
        case .compression:
            return [.init(value: "fast", caption: "Faster", detail: nil), .init(value: "balanced", caption: "Balanced", detail: nil),
                    .init(value: "maximum", caption: "Smallest File", detail: nil)]
        case .epubLayout:
            return [.init(value: "adjustable", caption: "Adjustable text",
                          detail: "Create adjustable, selectable text with parsed headings and tables. Keep illustrations and complex equations as separate artwork."),
                    .init(value: "fixed", caption: "Fixed layout",
                          detail: "Create a fixed layout book of page images. Text resizing, selection, and search are unavailable.")]
        case .pdfOfficeLayout:
            return [.init(value: "editable", caption: "Editable paragraphs",
                          detail: "Create normal paragraphs, headings, and tables that reflow when edited. Recognize scanned text with OCR. Keep illustrations as inline images."),
                    .init(value: "preservePages", caption: "Preserve original pages",
                          detail: "Keep every page as a sharp image, including tables, equations, and scanned content. Text cannot be edited.")]
        case .preserveMetadata, .epubReflowVersion: return []
        }
    }
}

/// Per-output-format defaults the drop uses (SHL-40: no per-drop dialog).
enum ConversionProfile {
    static func key(_ format: ConversionFormat, _ param: ConversionParam) -> String {
        "conversionProfile.\(format.rawValue).\(param.rawValue)"
    }

    /// Which parameters an output format exposes (CNV-41). Empty = "This output format has no adjustable conversion defaults."
    static func params(for format: ConversionFormat) -> [ConversionParam] {
        switch format {
        case .jpg, .webp, .heic, .avif: return [.quality, .preserveMetadata]
        case .png, .tiff: return [.preserveMetadata]
        case .mp4, .mov, .mkv, .webm, .avi, .wmv: return [.quality, .videoMaxHeight, .preserveMetadata]
        case .gif: return [.gifFrameRate, .gifMaxWidth]
        case .m4a, .mp3, .ogg, .opus, .wma: return [.audioBitrate]
        case .wav, .aiff, .flac: return [.audioSampleDepth]
        case .zip, .tar, .gzip: return [.compression]
        case .epub: return [.epubLayout]
        case .docx, .pages: return [.pdfOfficeLayout]
        default: return []
        }
    }

    static func defaultValue(_ format: ConversionFormat, _ param: ConversionParam) -> String {
        switch param {
        case .quality: return format == .mov ? "high" : "balanced"
        case .preserveMetadata: return "true"
        case .videoMaxHeight: return "0"
        case .audioBitrate: return "256"
        case .audioSampleDepth: return "matchSource"
        case .gifFrameRate: return "15"
        case .gifMaxWidth: return "960"
        case .compression: return "balanced"
        case .epubLayout: return "adjustable"   // stored byte 1; assumed to be adjustable text
        case .epubReflowVersion: return "1"
        case .pdfOfficeLayout: return "editable"
        }
    }

    static func string(_ format: ConversionFormat, _ param: ConversionParam, defaults: UserDefaults = .standard) -> String {
        if let v = defaults.object(forKey: key(format, param)) {
            if let s = v as? String { return s }
            if let b = v as? Bool { return b ? "true" : "false" }
            if let n = v as? NSNumber { return n.stringValue }
        }
        return defaultValue(format, param)
    }

    static func int(_ format: ConversionFormat, _ param: ConversionParam, defaults: UserDefaults = .standard) -> Int {
        Int(string(format, param, defaults: defaults)) ?? Int(defaultValue(format, param)) ?? 0
    }

    static func bool(_ format: ConversionFormat, _ param: ConversionParam, defaults: UserDefaults = .standard) -> Bool {
        string(format, param, defaults: defaults) == "true"
    }

    static func set(_ value: String, _ format: ConversionFormat, _ param: ConversionParam, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key(format, param))
    }

    static func restoreDefaults(_ format: ConversionFormat, defaults: UserDefaults = .standard) {
        for p in ConversionParam.allCases { defaults.removeObject(forKey: key(format, p)) }
    }

    // Typed views used by the engines.
    enum Quality: String { case compact, balanced, high }
    static func quality(_ f: ConversionFormat) -> Quality { Quality(rawValue: string(f, .quality)) ?? .balanced }

    /// Numeric image quality for lossy encoders (the inventory does not give the numbers).
    static func imageQuality(_ f: ConversionFormat) -> Double {
        switch quality(f) { case .compact: return 0.55; case .balanced: return 0.8; case .high: return 0.95 }
    }
}
