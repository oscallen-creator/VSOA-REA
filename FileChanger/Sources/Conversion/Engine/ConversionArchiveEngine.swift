import Foundation

/// zip <-> tar <-> gzip, rar -> others, and the Extract Archive tool (ARC-01..07).
/// Everything unpacks into a scratch folder and is repacked, like the original's `contents` + `payload.tar` flow.
enum ConversionArchiveEngine {
    typealias F = ConversionFormat
    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    static let tar = URL(fileURLWithPath: "/usr/bin/tar")
    static let gzip = URL(fileURLWithPath: "/usr/bin/gzip")
    static let zip = URL(fileURLWithPath: "/usr/bin/zip")
    /// Optional `unar` for RAR; bsdtar (/usr/bin/tar) reads most RAR files without it.
    static var unarURL: URL? {
        ["/opt/homebrew/bin/unar", "/usr/local/bin/unar"].map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// compression profile -> gzip/zip level.
    static func level(_ f: F) -> String {
        switch ConversionProfile.string(f, .compression) { case "fast": return "1"; case "maximum": return "9"; default: return "6" }
    }

    static func detect(_ url: URL) -> F? {
        if F.isTarGz(url) { return .gzip }
        return F.of(url)
    }

    /// Extracts any supported archive into `folder` (created if needed).
    static func extract(_ archive: URL, as f: F, into folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch f {
        case .zip:
            _ = try await ConvProcess.run(ditto, ["-x", "-k", archive.path, folder.path])
        case .tar, .rar:
            if f == .rar, let unar = unarURL { _ = try await ConvProcess.run(unar, ["-q", "-o", folder.path, archive.path]); break }
            _ = try await ConvProcess.run(tar, ["-xf", archive.path, "-C", folder.path])
        case .gzip:
            let wrapsTar = F.isTarGz(archive) ? true : try await isTarPayload(archive)
            if wrapsTar {
                _ = try await ConvProcess.run(tar, ["-xzf", archive.path, "-C", folder.path])
            } else {
                // Single compressed file: name = archive name without .gz
                let name = archive.deletingPathExtension().lastPathComponent
                let out = folder.appendingPathComponent(name.isEmpty ? "file" : name)
                let r = try await ConvProcess.run(gzip, ["-dc", archive.path])
                try r.stdout.write(to: out)
            }
        default: throw FileChangerError.unsupported("Conversion from \(f.label) is unavailable.")
        }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              items.contains(where: { $0 != "__MACOSX" }) else {
            throw FileChangerError.failed("The source archive is empty.")
        }
    }

    /// True when a .gz wraps a tar stream (checks the ustar magic at offset 257 of the payload).
    static func isTarPayload(_ url: URL) async throws -> Bool {
        let r = try await ConvProcess.run(gzip, ["-dc", url.path], check: false)
        guard r.stdout.count > 262 else { return false }
        return r.stdout.subdata(in: 257..<262) == Data("ustar".utf8)
    }

    static func convert(_ file: URL, from s: F, to t: F, progress: ProgressHandler) async throws -> URL {
        let scratch = try ConvTemp.make("FileChanger-archive"); defer { try? FileManager.default.removeItem(at: scratch) }
        let contents = scratch.appendingPathComponent("contents")
        try await extract(file, as: s, into: contents)
        progress(0.5)
        let dest = Conversions.outputURL(for: file, ext: t.ext)
        try await OutputLocation.writeAtomically(to: dest) { temp in
            switch t {
            case .zip:
                _ = try await ConvProcess.run(zip, ["-q", "-r", "-X", "-\(level(.zip))", temp.path, "."], cwd: contents)
            case .tar:
                _ = try await ConvProcess.run(tar, ["-cf", temp.path, "-C", contents.path, "."])
            case .gzip:
                // A gzip of a folder is a tar.gz payload; a lone file compresses on its own.
                let items = try FileManager.default.contentsOfDirectory(atPath: contents.path).filter { $0 != "__MACOSX" }
                var isDir: ObjCBool = false
                let single = items.count == 1 && FileManager.default.fileExists(atPath: contents.appendingPathComponent(items[0]).path, isDirectory: &isDir) && !isDir.boolValue
                if single && s != .tar && s != .rar {
                    let r = try await ConvProcess.run(gzip, ["-c", "-\(level(.gzip))", contents.appendingPathComponent(items[0]).path])
                    try r.stdout.write(to: temp)
                } else {
                    let payload = scratch.appendingPathComponent("payload.tar")
                    _ = try await ConvProcess.run(tar, ["-cf", payload.path, "-C", contents.path, "."])
                    let r = try await ConvProcess.run(gzip, ["-c", "-\(level(.gzip))", payload.path])
                    try r.stdout.write(to: temp)
                }
            default: throw FileChangerError.unsupported("Conversion from \(s.label) is unavailable.")
            }
        }
        return dest
    }

    /// Extract Archive tool (ARC-07): folder named after the archive, beside it.
    static func extractBeside(_ archive: URL, progress: ProgressHandler) async throws -> URL {
        guard let f = detect(archive) else { throw FileChangerError.unsupported("This file type is not supported.") }
        var base = archive.deletingPathExtension()
        if F.isTarGz(archive), base.pathExtension.lowercased() == "tar" { base = base.deletingPathExtension() }
        let folder = OutputLocation.unique(base)
        progress(0.1)
        do { try await extract(archive, as: f, into: folder) } catch { try? FileManager.default.removeItem(at: folder); throw error }
        progress(1)
        return folder
    }
}
