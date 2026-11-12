import AppKit
import Foundation

private func scratchDefaults() -> UserDefaults {
    let name = "shell-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

private func tempDir() throws -> URL {
    let u = Fixtures.scratch.appendingPathComponent("shell-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

extension TestSuites {
    static var shellSuites: [Suite] { [shellModifiers, shellTap, shellLayout, shellActions, shellPlacement] }

    static let shellModifiers = Suite(name: "shell.modifiers", tests: [
        ("bit encoding and glyph order (SHL-10, SHL-11)", {
            try expectEqual(ShellModifierMask(flags: [.command, .shift]).rawValue, 9)
            try expectEqual(ShellModifierMask(rawValue: 15).glyphs, ["⌃", "⌥", "⇧", "⌘"])
            try expectEqual(ShellModifierMask(rawValue: 9).display, "⇧⌘")
            try expectEqual(ShellModifierMask([]).display, "Unset")
            try expect(ShellModifierMask(rawValue: 0).isValid == false && ShellModifierMask(rawValue: 16).isValid == false)
            try expect(ShellModifierMask(rawValue: 8).flags == .shift)
        }),
        ("defaults are Shift / Command / Control", {
            let d = scratchDefaults()
            let m = ShellModifierStore.masks(d)
            try expectEqual(m[.conversion]!.rawValue, 8)
            try expectEqual(m[.tools]!.rawValue, 1)
            try expectEqual(m[.actions]!.rawValue, 4)
        }),
        ("one-time migration rewrites the old Tools default", {
            let d = scratchDefaults()
            d.set(10, forKey: ShellWheel.tools.defaultsKey)
            ShellModifierStore.migrate(d)
            try expectEqual(d.integer(forKey: ShellWheel.tools.defaultsKey), 1)
            d.set(6, forKey: ShellWheel.tools.defaultsKey)      // user choice after migration survives
            ShellModifierStore.migrate(d)
            try expectEqual(d.integer(forKey: ShellWheel.tools.defaultsKey), 6)
        }),
        ("invalid or colliding masks fall back to defaults", {
            let d = scratchDefaults()
            d.set(99, forKey: ShellWheel.conversion.defaultsKey)
            d.set(1, forKey: ShellWheel.actions.defaultsKey)        // collides with tools' default
            let m = ShellModifierStore.masks(d)
            try expectEqual(m[.conversion]!.rawValue, 8)
            try expectEqual(m[.actions]!.rawValue, 4)
        }),
        ("set rejects a mask used by another wheel", {
            let d = scratchDefaults()
            try expect(!ShellModifierStore.set(.shift, for: .tools, d))
            try expect(ShellModifierStore.set([.shift, .option], for: .tools, d))
            try expectEqual(ShellModifierStore.mask(for: .tools, d).rawValue, 10)
        }),
        ("held modifiers pick the wheel with exactly that mask", {
            let d = scratchDefaults()
            try expect(ShellModifierStore.wheel(matching: .shift, d) == .conversion)
            try expect(ShellModifierStore.wheel(matching: .command, d) == .tools)
            try expect(ShellModifierStore.wheel(matching: [.shift, .command], d) == nil)
            try expect(ShellModifierStore.wheel(matching: [], d) == nil)
        }),
    ])

    static let shellTap = Suite(name: "shell.tap", tests: [
        ("quick press and release is a tap", {
            var t = ShellTapDetector()
            try expect(t.flagsChanged(.shift, at: 1.0) == nil)
            try expect(t.flagsChanged([], at: 1.2) == .shift)
        }),
        ("held too long is not a tap", {
            var t = ShellTapDetector()
            _ = t.flagsChanged(.command, at: 0)
            try expect(t.flagsChanged([], at: 2.0) == nil)
        }),
        ("another key in between cancels", {
            var t = ShellTapDetector()
            _ = t.flagsChanged(.command, at: 0)
            t.otherInput()
            try expect(t.flagsChanged([], at: 0.2) == nil)
            _ = t.flagsChanged(.command, at: 1)     // next press works again
            try expect(t.flagsChanged([], at: 1.1) == .command)
        }),
        ("combination reports the peak, not the last key", {
            var t = ShellTapDetector()
            _ = t.flagsChanged(.shift, at: 0)
            _ = t.flagsChanged([.shift, .command], at: 0.1)
            _ = t.flagsChanged(.command, at: 0.2)
            try expect(t.flagsChanged([], at: 0.3) == [.shift, .command])
        }),
    ])

    static let shellLayout = Suite(name: "shell.layout", tests: [
        ("single ring up to ten, two rings above", {
            try expectEqual(ShellWheelLayout(count: 6).petals.count, 6)
            try expect(Set(ShellWheelLayout(count: 6).petals.map(\.innerRadius)).count == 1)
            try expect(Set(ShellWheelLayout(count: 16).petals.map(\.innerRadius)).count == 2)
            try expectEqual(ShellWheelLayout(count: 0).petals.count, 0)
        }),
        ("hit testing: hub and outside miss, petals clockwise from top", {
            let l = ShellWheelLayout(count: 4)
            let r = l.petals[0].midRadius
            try expect(l.hit(CGPoint(x: 0, y: 0)) == nil)
            try expect(l.hit(CGPoint(x: 0, y: -(l.radius + 100))) == nil)
            try expectEqual(l.hit(CGPoint(x: r * 0.7, y: -r * 0.7)) ?? -1, 0)   // upper right
            try expectEqual(l.hit(CGPoint(x: r * 0.7, y: r * 0.7)) ?? -1, 1)    // lower right
            try expectEqual(l.hit(CGPoint(x: -r * 0.7, y: r * 0.7)) ?? -1, 2)
            try expectEqual(l.hit(CGPoint(x: -r * 0.7, y: -r * 0.7)) ?? -1, 3)
        }),
        ("every petal centre hits its own petal", {
            for n in [3, 8, 10, 11, 20] {
                let l = ShellWheelLayout(count: n)
                for p in l.petals { try expectEqual(l.hit(l.labelOffset(of: p)) ?? -1, p.index) }
            }
        }),
        ("display labels keep acronyms", {
            try expectEqual(shellDisplayLabel("MERGE PDFS"), "Merge PDFs")
            try expectEqual(shellDisplayLabel("READ QR CODES"), "Read QR Codes")
            try expectEqual(shellDisplayLabel("TRIM VIDEO"), "Trim Video")
        }),
        ("grouping keeps first-appearance order of groups", {
            let items = [("a", "Image"), ("b", "Doc"), ("c", "Image")]
            try expectEqual(shellGroupedOrder(items, group: { $0.1 }).map(\.0), ["a", "c", "b"])
        }),
        ("drag operation: copy if allowed, else one the source offers", {
            try expect(shellDragOperation(allowed: [.copy, .move]) == .copy)
            try expect(shellDragOperation(allowed: .move) == .move)
            try expect(shellDragOperation(allowed: [.link, .move]) == .move)
            try expect(shellDragOperation(allowed: []) == [])
        }),
    ])

    static let shellActions = Suite(name: "shell.actions", tests: [
        ("copy paths writes one POSIX path per line", {
            let pb = NSPasteboard(name: NSPasteboard.Name("shell-test-\(UUID().uuidString)"))
            let urls = [URL(fileURLWithPath: "/tmp/a b.txt"), URL(fileURLWithPath: "/tmp/c.png")]
            try ShellFileActions.copyPaths(urls, to: pb)
            try expectEqual(pb.string(forType: .string) ?? "", "/tmp/a b.txt\n/tmp/c.png")
        }),
        ("copy paths rejects non-file URLs", {
            let pb = NSPasteboard(name: NSPasteboard.Name("shell-test-\(UUID().uuidString)"))
            do { try ShellFileActions.copyPaths([URL(string: "https://example.com")!], to: pb); throw TestFailure(description: "should throw") }
            catch let e as ShellFileActions.ActionError { try expectEqual(e.message, "Only local file and folder paths can be copied.") }
        }),
        ("copy files puts file URLs on the pasteboard", {
            let pb = NSPasteboard(name: NSPasteboard.Name("shell-test-\(UUID().uuidString)"))
            let u = URL(fileURLWithPath: "/tmp/x.txt")
            try ShellFileActions.copyFiles([u], to: pb)
            let back = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
            try expectEqual(back?.first?.path ?? "", "/tmp/x.txt")
        }),
        ("terminal folder: folder itself, else parent", {
            let dir = try tempDir()
            let file = dir.appendingPathComponent("f.txt")
            try Data().write(to: file)
            try expectEqual(ShellFileActions.terminalFolder(for: dir).path, dir.path)
            try expectEqual(ShellFileActions.terminalFolder(for: file).path, dir.path)
            try expectEqual(ShellFileActions.terminalFolders(for: [file, dir]).count, 1)
        }),
        ("move: moves, renames on clash, refuses its own subfolder", {
            let src = try tempDir(), dst = try tempDir()
            let a = src.appendingPathComponent("a.txt"); try Data("1".utf8).write(to: a)
            try Data("old".utf8).write(to: dst.appendingPathComponent("a.txt"))
            let r = ShellFileActions.move([a], to: dst)
            try expectEqual(r.moved.map(\.lastPathComponent), ["a 2.txt"])
            try expect(!FileManager.default.fileExists(atPath: a.path))
            try expectEqual(r.summary, "Moved 1 item")
            let folder = src.appendingPathComponent("sub"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bad = ShellFileActions.move([src], to: folder)
            try expect(bad.moved.isEmpty && bad.failures.first?.hasPrefix("Choose a destination outside") == true)
        }),
        ("sort by name uses Finder numeric order", {
            let names = ["b10.png", "b2.png", "A1.png"].map { URL(fileURLWithPath: "/x/\($0)") }
            try expectEqual(shellSortedByName(names).map(\.lastPathComponent), ["A1.png", "b2.png", "b10.png"])
        }),
        ("desktop detection", {
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            try expect(shellIsOnDesktop(desktop.appendingPathComponent("a.png")))
            try expect(!shellIsOnDesktop(desktop.appendingPathComponent("sub/a.png")))
        }),
    ])

    static let shellPlacement = Suite(name: "shell.placement", tests: [
        ("over a normal window is not desktop; own, layer-25 and alpha-0 windows are", {
            let r = CGRect(x: 0, y: 0, width: 100, height: 100), pt = CGPoint(x: 50, y: 50)
            func w(layer: Int = 0, alpha: Double = 1, pid: Int32 = 7) -> ShellDropWindow {
                ShellDropWindow(bounds: r, layer: layer, alpha: alpha, pid: pid)
            }
            try expect(!ShellDropPlacement.isOverDesktop(point: pt, windows: [w()], ownPID: 1))
            try expect(ShellDropPlacement.isOverDesktop(point: pt, windows: [w(pid: 1)], ownPID: 1))
            try expect(ShellDropPlacement.isOverDesktop(point: pt, windows: [w(layer: 25)], ownPID: 1))
            try expect(ShellDropPlacement.isOverDesktop(point: pt, windows: [w(alpha: 0)], ownPID: 1))
            try expect(ShellDropPlacement.isOverDesktop(point: CGPoint(x: 500, y: 500), windows: [w()], ownPID: 1))
        }),
        ("AppKit point flips to top-left coordinates", {
            let p = ShellDropPlacement.topLeft(CGPoint(x: 10, y: 100), primaryHeight: 900)
            try expectEqual(p.x, 10)
            try expectEqual(p.y, 800)
        }),
        ("moveToDesktop renames on clash and leaves desktop files alone", {
            let desktop = try tempDir(), src = try tempDir()
            try Data("old".utf8).write(to: desktop.appendingPathComponent("out.png"))
            let f = src.appendingPathComponent("out.png"); try Data("new".utf8).write(to: f)
            let moved = try ShellDropPlacement.moveToDesktop(f, desktop: desktop)
            try expectEqual(moved.lastPathComponent, "out 2.png")
            try expect(!FileManager.default.fileExists(atPath: f.path))
            let folder = src.appendingPathComponent("pages"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try expectEqual(try ShellDropPlacement.moveToDesktop(folder, desktop: desktop).lastPathComponent, "pages")
            let stay = desktop.appendingPathComponent("out.png")
            try expectEqual(try ShellDropPlacement.moveToDesktop(stay, desktop: desktop).path, stay.path)
            try expect(FileManager.default.fileExists(atPath: stay.path))
        }),
    ])
}
