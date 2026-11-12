import Foundation

extension TestSuites {
    static var coreSuites: [Suite] {
        [Suite(name: "core", tests: [
            ("file kinds", {
                try expectEqual(FileKind.of(URL(fileURLWithPath: "/a/b.HEIC")), .image)
                try expectEqual(FileKind.of(URL(fileURLWithPath: "/a/b.mp4")), .video)
                try expectEqual(FileKind.of(URL(fileURLWithPath: "/a/b.webm")), .video)
                try expectEqual(FileKind.of(URL(fileURLWithPath: "/a/b.m4a")), .audio)
                try expectEqual(FileKind.of(URL(fileURLWithPath: "/a/b.pdf")), .pdf)
                try expectEqual(FileKind.of(URL(fileURLWithPath: "/a/b.docx")), .document)
                try expectEqual(FileKind.of(URL(fileURLWithPath: "/a/b.srt")), .subtitle)
                try expectEqual(FileKind.of(URL(fileURLWithPath: "/a/b.tgz")), .archive)
            }),
            ("unique sibling names", {
                let dir = Fixtures.scratch.appendingPathComponent("naming")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let src = dir.appendingPathComponent("photo.png")
                try Data().write(to: src)
                let first = OutputLocation.sibling(of: src, suffix: "-edited")
                try expectEqual(first.lastPathComponent, "photo-edited.png")
                try Data().write(to: first)
                try expectEqual(OutputLocation.sibling(of: src, suffix: "-edited").lastPathComponent, "photo-edited 2.png")
                try expectEqual(OutputLocation.sibling(of: src, ext: "jpg").lastPathComponent, "photo.jpg")
            }),
            ("atomic write leaves nothing on failure", {
                let dir = Fixtures.scratch.appendingPathComponent("atomic")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent("out.txt")
                do {
                    try await OutputLocation.writeAtomically(to: dest) { tmp in
                        try Data("x".utf8).write(to: tmp)
                        throw FileChangerError.failed("boom")
                    }
                } catch {}
                try expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
                try await OutputLocation.writeAtomically(to: dest) { try Data("ok".utf8).write(to: $0) }
                try expectEqual(String(decoding: try Data(contentsOf: dest), as: UTF8.self), "ok")
            }),
            ("process runner", {
                let r = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), ["hi"])
                try expectEqual(String(decoding: r.stdout, as: UTF8.self), "hi\n")
                do {
                    try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/false"), [])
                    try expect(false, "false should fail")
                } catch is FileChangerError {}
            }),
        ])]
    }
}
