import Foundation
import Compression

/// Scratch folders for one job; removed by the caller's `defer`.
enum ConvTemp {
    static func make(_ prefix: String = "FileChanger-convert") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Runs a child process with an optional working directory, streaming stdout line by line.
enum ConvProcess {
    struct Result: Sendable { let status: Int32; let stdout: Data; let stderr: Data
        var stderrText: String { String(decoding: stderr, as: UTF8.self) }
        var stdoutText: String { String(decoding: stdout, as: UTF8.self) } }

    @discardableResult
    static func run(_ exe: URL, _ args: [String], cwd: URL? = nil, check: Bool = true,
                    onStdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        process.environment = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let box = Box()
        let result: Result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
                let group = DispatchGroup()
                group.enter(); group.enter()
                DispatchQueue.global().async {
                    var pending = Data()
                    while true {
                        let chunk = out.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        box.lock.lock(); box.out.append(chunk); box.lock.unlock()
                        if let onStdoutLine {
                            pending.append(chunk)
                            while let nl = pending.firstIndex(of: 10) {
                                onStdoutLine(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                                pending.removeSubrange(pending.startIndex...nl)
                            }
                        }
                    }
                    group.leave()
                }
                DispatchQueue.global().async {
                    let d = err.fileHandleForReading.readDataToEndOfFile()
                    box.lock.lock(); box.err = d; box.lock.unlock()
                    group.leave()
                }
                process.terminationHandler = { p in
                    group.notify(queue: .global()) {
                        box.lock.lock(); let r = Result(status: p.terminationStatus, stdout: box.out, stderr: box.err); box.lock.unlock()
                        cont.resume(returning: r)
                    }
                }
                do { try process.run() } catch {
                    try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
                    cont.resume(throwing: error)
                }
            }
        } onCancel: { if process.isRunning { process.terminate() } }
        if Task.isCancelled { throw FileChangerError.cancelled }
        if check && result.status != 0 {
            let tail = result.stderrText.suffix(500).trimmingCharacters(in: .whitespacesAndNewlines)
            throw FileChangerError.failed("\(exe.lastPathComponent) failed (\(result.status)). \(tail)")
        }
        return result
    }

    private final class Box: @unchecked Sendable { let lock = NSLock(); var out = Data(); var err = Data() }
}

/// Minimal ZIP reader/writer (stored + deflate) for OOXML, ODF, EPUB and .pages packages, so entry order
/// (EPUB/ODF want an uncompressed `mimetype` first) and paths are under our control.
enum ConvZip {
    struct Entry { let name: String; let data: Data; var store = false }

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 { var c = UInt32(i); for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }; table[i] = c }
        var crc: UInt32 = 0xFFFFFFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }

    static func deflate(_ data: Data) -> Data? {
        if data.isEmpty { return Data() }
        let cap = data.count + data.count / 8 + 1024
        var out = Data(count: cap)
        let n = out.withUnsafeMutableBytes { dst in data.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB) } }
        if n == 0 { return nil }
        out.removeSubrange(n...)
        return out
    }

    static func inflate(_ data: Data, size: Int) -> Data? {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { dst in data.withUnsafeBytes { src in
            compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB) } }
        return n == size ? out : nil
    }

    static func write(_ entries: [Entry], to url: URL) throws {
        var out = Data(), central = Data()
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func u32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        for e in entries {
            let name = Array(e.name.utf8)
            let crc = crc32(e.data)
            var method = 0, payload = e.data
            if !e.store, e.data.count > 64, let d = deflate(e.data), d.count < e.data.count { method = 8; payload = d }
            let offset = UInt32(out.count)
            let head: [UInt8] = u32(0x04034b50) + u16(20) + u16(0x0800) + u16(method) + u16(0) + u16(0x21)
                + u32(crc) + u32(UInt32(payload.count)) + u32(UInt32(e.data.count)) + u16(name.count) + u16(0)
            out.append(contentsOf: head); out.append(contentsOf: name); out.append(payload)
            let cd: [UInt8] = u32(0x02014b50) + u16(20) + u16(20) + u16(0x0800) + u16(method) + u16(0) + u16(0x21)
                + u32(crc) + u32(UInt32(payload.count)) + u32(UInt32(e.data.count)) + u16(name.count) + u16(0) + u16(0)
                + u16(0) + u16(0) + u32(0) + u32(offset)
            central.append(contentsOf: cd); central.append(contentsOf: name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.append(contentsOf: u32(0x06054b50) + u16(0) + u16(0) + u16(entries.count) + u16(entries.count)
                   + u32(UInt32(central.count)) + u32(cdOffset) + u16(0))
        try out.write(to: url)
    }

    /// Reads every file entry. Paths that could escape (absolute, `..`) and oversized packages are refused.
    static func read(_ url: URL, limit: Int = 128 * 1024 * 1024) throws -> [(name: String, data: Data)] {
        let d = try Data(contentsOf: url, options: .mappedIfSafe)
        guard d.count >= 22 else { throw FileChangerError.failed("The source archive is empty.") }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        var eocd = -1
        var i = d.count - 22
        while i >= max(0, d.count - 22 - 65535) { if u32(i) == 0x06054b50 { eocd = i; break }; i -= 1 }
        guard eocd >= 0 else { throw FileChangerError.failed("The file is not a valid ZIP package.") }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        var result: [(String, Data)] = []
        var total = 0
        for _ in 0..<count {
            guard p + 46 <= d.count, u32(p) == 0x02014b50 else { break }
            let method = u16(p + 10), csize = u32(p + 20), usize = u32(p + 24)
            let nlen = u16(p + 28), elen = u16(p + 30), clen = u16(p + 32), lho = u32(p + 42)
            let name = String(decoding: d[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            p += 46 + nlen + elen + clen
            if name.hasSuffix("/") { continue }
            if name.hasPrefix("/") || name.split(separator: "/").contains("..") {
                throw FileChangerError.failed("The package contains unsafe entries or is too large.")
            }
            total += usize
            if total > limit { throw FileChangerError.failed("The package contains unsafe entries or is too large.") }
            guard lho + 30 <= d.count else { continue }
            let start = lho + 30 + u16(lho + 26) + u16(lho + 28)
            guard start + csize <= d.count else { continue }
            let raw = d.subdata(in: start..<(start + csize))
            if method == 0 { result.append((name, raw)) }
            else if method == 8, let inflated = inflate(raw, size: usize) { result.append((name, inflated)) }
        }
        return result
    }

    static func entry(_ entries: [(name: String, data: Data)], _ name: String) -> Data? {
        entries.first { $0.name == name }?.data
    }
}

enum ConvText {
    /// Decode text honouring BOMs, falling back to UTF-8 then Windows-1252 (DOC-07).
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data, encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16BigEndian) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }

    static func escapeXML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // XML 1.0 forbids most control characters.
                if ch.value < 0x20 && ch != "\n" && ch != "\t" && ch != "\r" { continue }
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
