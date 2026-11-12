import Foundation

/// srt <-> vtt and srt/vtt -> txt (SUB-01, SUB-02).
enum ConversionSubtitleEngine {
    struct Cue: Equatable { var start: Double; var end: Double; var text: String }

    /// `00:01:02,500` / `00:01:02.500` / `01:02.500` -> seconds.
    static func parseTime(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for p in parts { guard let v = Double(p), v >= 0 else { return nil }; seconds = seconds * 60 + v }
        return seconds
    }

    static func format(_ t: Double, comma: Bool) -> String {
        let ms = Int((t * 1000).rounded())
        let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60, f = ms % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, comma ? "," : ".", f)
    }

    /// Parses SRT or WebVTT. Cues with unreadable or reversed timings are dropped; none left -> error (SUB-02).
    static func parse(_ data: Data) throws -> [Cue] {
        guard var text = String(data: data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data, encoding: .utf8) else {
            throw FileChangerError.failed("The subtitle file is not valid UTF-8.")
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in text.components(separatedBy: "\n\n") {
            try Task.checkCancellation()
            let lines = block.components(separatedBy: "\n").filter { !$0.isEmpty || false }
            guard let ti = lines.firstIndex(where: { $0.contains(" --> ") }) else { continue }
            if lines.first?.hasPrefix("NOTE") == true || lines.first?.hasPrefix("STYLE") == true { continue }
            let halves = lines[ti].components(separatedBy: " --> ")
            guard halves.count == 2, let a = parseTime(halves[0]),
                  let b = parseTime(String(halves[1].split(separator: " ").first ?? "")), b >= a else { continue }
            let body = lines[(ti + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { continue }
            cues.append(Cue(start: a, end: b, text: body))
        }
        guard !cues.isEmpty else { throw FileChangerError.failed("No valid subtitle cues were found.") }
        return cues
    }

    static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { "\($0.offset + 1)\n\(format($0.element.start, comma: true)) --> \(format($0.element.end, comma: true))\n\($0.element.text)\n" }
            .joined(separator: "\n")
    }

    static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { "\(format($0.start, comma: false)) --> \(format($0.end, comma: false))\n\($0.text)\n" }.joined(separator: "\n")
    }

    /// Cue text only, markup tags removed.
    static func plain(_ cues: [Cue]) -> String {
        cues.map { $0.text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }.joined(separator: "\n") + "\n"
    }

    static func convert(_ file: URL, from s: ConversionFormat, to t: ConversionFormat, progress: ProgressHandler) async throws -> URL {
        let cues = try parse(try Data(contentsOf: file))
        let out: String
        switch t {
        case .srt: out = srt(cues)
        case .vtt: out = vtt(cues)
        case .txt: out = plain(cues)
        default: throw FileChangerError.unsupported("Conversion from \(s.label) is unavailable.")
        }
        let dest = Conversions.outputURL(for: file, ext: t.ext)
        try await OutputLocation.writeAtomically(to: dest) { try Data(out.utf8).write(to: $0) }
        return dest
    }
}
