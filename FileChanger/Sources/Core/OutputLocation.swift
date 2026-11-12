import Foundation

/// Where results go: beside the original, never over it. Names follow Finder's " 2", " 3" rule on collision.
enum OutputLocation {
    /// `photo.png` + suffix "-edited" + ext "jpg" -> `photo-edited.jpg` (or `photo-edited 2.jpg` if taken).
    static func sibling(of source: URL, suffix: String = "", ext: String? = nil, in folder: URL? = nil) -> URL {
        let dir = folder ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + suffix
        return unique(dir.appendingPathComponent(base).appendingPathExtension(ext ?? source.pathExtension))
    }

    /// First free name: `name.ext`, `name 2.ext`, `name 3.ext`, ...
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent(), ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            var candidate = dir.appendingPathComponent("\(base) \(n)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Write into a hidden temp file in the destination folder, then move into place only if `body` succeeds.
    /// A failed or cancelled job never leaves a half-written file under the final name.
    static func writeAtomically(to destination: URL, _ body: (URL) async throws -> Void) async throws {
        let dir = destination.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".filechanger-\(UUID().uuidString).\(destination.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await body(temp)
        guard FileManager.default.fileExists(atPath: temp.path) else {
            throw FileChangerError.failed("No output was produced.")
        }
        try FileManager.default.moveItem(at: temp, to: unique(destination))
    }
}

/// One error type for every area; `message` is shown to the user as-is.
enum FileChangerError: LocalizedError, Equatable {
    case failed(String)
    case unsupported(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .failed(let m), .unsupported(let m): return m
        case .cancelled: return "Cancelled."
        }
    }
}
