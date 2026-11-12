import Foundation

/// How a source -> target pair is produced right now.
enum ConversionRoute: Equatable, Sendable {
    case native
    /// Needs at least one of these command-line tools.
    case external([ExternalTool])
    case unsupported(String)

    var isAvailable: Bool {
        switch self {
        case .native: return true
        case .external(let tools): return tools.contains { $0.isAvailable }
        case .unsupported: return false
        }
    }

    /// Install hint shown in Settings > Compatibility when a tool is missing.
    var installHint: String? {
        if case .external(let tools) = self, !isAvailable, let first = tools.first { return first.missingMessage }
        if case .unsupported(let why) = self { return why }
        return nil
    }
}

/// The formats fan: which targets a set of files can convert to, and the conversion itself
/// (CNV-* in docs/inventory/conversion.md).
enum Conversions {
    typealias F = ConversionFormat

    static func format(of url: URL) -> F? {
        if F.isTarGz(url) { return .gzip }
        return F.of(url)
    }

    // MARK: Routing

    private static let nativeAudioRead: Set<F> = [.mp3, .m4a, .wav, .flac, .aiff]
    private static let nativeAudioWrite: Set<F> = [.m4a, .wav, .flac, .aiff]

    static func route(from s: F, to t: F) -> ConversionRoute {
        guard ConversionMatrix.targets(from: s).contains(t) else {
            return .unsupported("Conversion from \(s.label) is unavailable.")
        }
        switch s.group {
        case .images:
            switch t {
            case .webp: return .external([.cwebp, .ffmpeg])
            case .avif: return .external([.ffmpeg])
            default: return .native
            }
        case .audio:
            return nativeAudioRead.contains(s) && nativeAudioWrite.contains(t) ? .native : .external([.ffmpeg])
        case .video:
            if s == .gif { return t == .mp4 || t == .mov ? .native : .external([.ffmpeg]) }
            if (s == .mp4 || s == .mov) && (t == .mp4 || t == .mov || t == .gif) { return .native }
            return .external([.ffmpeg])
        case .documents:
            if t == .pages || s == .pages {
                return .unsupported("Pages documents cannot be read or written without Apple's iWork format library.")
            }
            return .native
        case .spreadsheets:
            if s == .xls { return .unsupported("Reading legacy XLS spreadsheets is not supported.") }
            return .native
        case .archives, .subtitles:
            return .native
        }
    }

    /// An output format is available when at least one source can reach it right now.
    static func isOutputAvailable(_ t: F) -> Bool {
        !t.isInputOnly && F.allCases.contains { s in !s.isOutputOnly && route(from: s, to: t).isAvailable }
    }

    static func isInputAvailable(_ s: F) -> Bool {
        !s.isOutputOnly && ConversionMatrix.targets(from: s).contains { route(from: s, to: $0).isAvailable }
    }

    /// Why a format is unavailable (tool hint), if it is.
    static func unavailableHint(_ f: F) -> String? {
        let routes = F.allCases.compactMap { s -> ConversionRoute? in
            guard ConversionMatrix.targets(from: s).contains(f) else { return nil }
            return route(from: s, to: f)
        }
        if routes.contains(where: { $0.isAvailable }) { return nil }
        return routes.compactMap { $0.installHint }.first
    }

    // MARK: Targets

    static func target(_ f: F) -> ConversionTarget {
        ConversionTarget(id: "\(f.fanGroup.lowercased()).\(f.rawValue)", label: f.label, ext: f.ext, group: f.fanGroup)
    }

    static func format(forTarget t: ConversionTarget) -> F? {
        F(rawValue: String(t.id.split(separator: ".").last ?? ""))
    }

    /// Targets common to all files, in the inventory's order, only those whose route works right now (CNV-08).
    static func targets(for files: [URL]) -> [ConversionTarget] {
        let sources = files.compactMap(format(of:))
        guard !files.isEmpty, sources.count == files.count else { return [] }
        var common = ConversionMatrix.targets(from: sources[0])
        for s in sources.dropFirst() {
            let set = Set(ConversionMatrix.targets(from: s))
            common = common.filter { set.contains($0) }
        }
        return common.filter { t in sources.allSatisfy { route(from: $0, to: t).isAvailable } }.map(target)
    }

    // MARK: Output naming

    /// `photo.png` -> `photo.jpg` beside the source; `.tar.gz` / `.tgz` lose both extensions.
    static func outputURL(for source: URL, ext: String) -> URL {
        var base = source.deletingPathExtension()
        if F.isTarGz(source) {
            if base.pathExtension.lowercased() == "tar" { base = base.deletingPathExtension() }
        }
        return OutputLocation.unique(base.appendingPathExtension(ext))
    }

    /// Folder named after the source (multi-page image output): `deck.pdf` -> `deck`.
    static func outputFolder(for source: URL) -> URL { OutputLocation.unique(source.deletingPathExtension()) }

    // MARK: Convert

    /// Converts one file; returns the written output URL (beside the source, see OutputLocation).
    static func convert(_ file: URL, to target: ConversionTarget, progress: ProgressHandler) async throws -> URL {
        guard let s = format(of: file) else { throw FileChangerError.unsupported("This file type is not supported.") }
        guard let t = format(forTarget: target) else { throw FileChangerError.unsupported("Conversion from \(s.label) is unavailable.") }
        guard FileManager.default.isReadableFile(atPath: file.path) else {
            throw FileChangerError.failed("The source file could not be read.")
        }
        let r = route(from: s, to: t)
        switch r {
        case .unsupported(let why): throw FileChangerError.unsupported(why)
        case .external(let tools) where !r.isAvailable:
            throw FileChangerError.unsupported(tools.first?.missingMessage ?? "A required tool is missing.")
        default: break
        }
        let out: URL
        switch s.group {
        case .images: out = try await ConversionImageEngine.convert(file, from: s, to: t, progress: progress)
        case .audio, .video: out = try await ConversionMediaEngine.convert(file, from: s, to: t, progress: progress)
        case .documents: out = try await ConversionDocumentEngine.convert(file, from: s, to: t, progress: progress)
        case .spreadsheets: out = try await ConversionSpreadsheetEngine.convert(file, from: s, to: t, progress: progress)
        case .archives: out = try await ConversionArchiveEngine.convert(file, from: s, to: t, progress: progress)
        case .subtitles: out = try await ConversionSubtitleEngine.convert(file, from: s, to: t, progress: progress)
        }
        progress(1)
        return out
    }
}

extension Conversions {
    /// The four legend captions of Settings > Formats / Compatibility (CNV-04), for what works right now.
    static func caption(for f: ConversionFormat) -> String {
        let canRead = isInputAvailable(f), canWrite = isOutputAvailable(f)
        switch (canRead, canWrite) {
        case (true, true): return "Input and output format."
        // A format that is only blocked by a missing tool is "unavailable" (the hint names the tool), not input/output-only.
        case (true, false): return f.isInputOnly ? "Input-only format." : "Unavailable for conversion."
        case (false, true): return f.isOutputOnly ? "Output-only format." : "Unavailable for conversion."
        case (false, false): return "Unavailable for conversion."
        }
    }
}
