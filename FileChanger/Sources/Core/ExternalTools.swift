import Foundation

/// Optional command-line helpers. FileChanger ships none of them; when the user has installed one
/// (for example `brew install ffmpeg webp exiftool`), formats that Apple frameworks cannot write light up.
enum ExternalTool: String, CaseIterable, Sendable {
    case ffmpeg, cwebp, exiftool

    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    var url: URL? {
        let fm = FileManager.default
        let paths = Self.searchPaths + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in paths {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(rawValue)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    var isAvailable: Bool { url != nil }

    /// Message for a feature that needs this tool, naming the install command.
    var missingMessage: String {
        let formula = self == .cwebp ? "webp" : rawValue
        return "This needs \(rawValue). Install it with: brew install \(formula)"
    }
}

/// Runs a child process to completion; cancelling the Swift task terminates it.
enum ProcessRunner {
    struct Output: Sendable { let status: Int32; let stdout: Data; let stderr: Data }

    @discardableResult
    static func run(_ executable: URL, _ arguments: [String], check: Bool = true) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let result: Output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                // Drain pipes concurrently so a chatty child cannot fill a buffer and stall.
                var stdoutData = Data(), stderrData = Data()
                let group = DispatchGroup()
                group.enter(); group.enter()
                DispatchQueue.global().async { stdoutData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                DispatchQueue.global().async { stderrData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                process.terminationHandler = { p in
                    group.notify(queue: .global()) {
                        cont.resume(returning: Output(status: p.terminationStatus, stdout: stdoutData, stderr: stderrData))
                    }
                }
                do { try process.run() } catch {
                    // Close our write ends so the two reader threads finish instead of blocking forever.
                    try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        if Task.isCancelled { throw FileChangerError.cancelled }
        if check && result.status != 0 {
            let tail = String(decoding: result.stderr.suffix(600), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw FileChangerError.failed("\(executable.lastPathComponent) failed (\(result.status)). \(tail)")
        }
        return result
    }
}
