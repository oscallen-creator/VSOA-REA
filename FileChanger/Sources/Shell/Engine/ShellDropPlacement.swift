import AppKit
import CoreGraphics
import os

/// One on-screen window, as CGWindowList reports it (top-left global coordinates).
struct ShellDropWindow {
    var bounds: CGRect, layer: Int, alpha: Double, pid: Int32
}

/// Drop-on-Desktop placement: the converted copy lands where the user let go.
enum ShellDropPlacement {
    /// Unverified: Finder's `desktop position` may be the icon centre or its top-left. Tune after a live test.
    static let iconOffset = CGPoint(x: 0, y: 0)
    /// Spacing between icons when several files are dropped at once.
    static let iconStep: CGFloat = 100

    private static let log = Logger(subsystem: "io.github.oscallen-creator.filechanger", category: "placement")

    /// True when no normal window of another app covers the point (our wheel and progress panels do not count).
    static func isOverDesktop(point: CGPoint, windows: [ShellDropWindow], ownPID: Int32) -> Bool {
        !windows.contains { $0.pid != ownPID && $0.layer == 0 && $0.alpha > 0 && $0.bounds.contains(point) }
    }

    /// AppKit global point (origin bottom-left of the primary screen) to the top-left global space of CGWindowList and Finder.
    static func topLeft(_ p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    static func onScreenWindows() -> [ShellDropWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { w in
            guard let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
                  let pid = w[kCGWindowOwnerPID as String] as? Int32 else { return nil }
            return ShellDropWindow(bounds: rect, layer: w[kCGWindowLayer as String] as? Int ?? 0,
                                   alpha: w[kCGWindowAlpha as String] as? Double ?? 1, pid: pid)
        }
    }

    /// Decide once, at drop time: the cursor's top-left point if it is over the bare Desktop, else nil.
    @MainActor static func desktopDropPoint(_ appKitPoint: CGPoint) -> CGPoint? {
        guard let primary = NSScreen.screens.first else { return nil }
        let p = topLeft(appKitPoint, primaryHeight: primary.frame.height)
        return isOverDesktop(point: p, windows: onScreenWindows(), ownPID: ProcessInfo.processInfo.processIdentifier) ? p : nil
    }

    static var realDesktop: URL { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0] }

    /// Files and folders alike; already on the Desktop stays put.
    static func moveToDesktop(_ url: URL, desktop: URL = realDesktop) throws -> URL {
        guard url.standardizedFileURL.deletingLastPathComponent().path != desktop.standardizedFileURL.path else { return url }
        let dest = OutputLocation.unique(desktop.appendingPathComponent(url.lastPathComponent))
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    /// Ask Finder to put the icon at `point` (top-left global). Blocking; call off the main thread.
    /// Path and coordinates travel as argv, never inside the script text.
    static func position(_ url: URL, at point: CGPoint) {
        let script = "on run argv\ntell application \"Finder\" to set desktop position of (POSIX file (item 1 of argv) as alias) to {(item 2 of argv) as integer, (item 3 of argv) as integer}\nend run"
        let args = ["-e", script, url.path, String(Int(point.x + iconOffset.x)), String(Int(point.y + iconOffset.y))]
        var lastError = ""
        for attempt in 0..<5 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.3) }   // Finder may not see a new file yet
            let p = Process(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = args
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { lastError = error.localizedDescription; break }
            p.waitUntilExit()
            if p.terminationStatus == 0 { return }
            lastError = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        log.error("could not position \(url.lastPathComponent, privacy: .public): \(lastError, privacy: .public)")
    }

    /// Move onto the Desktop and place the icon; the `index`th file steps right. Returns the final URL.
    static func place(_ url: URL, at point: CGPoint, index: Int) async throws -> URL {
        let dest = try moveToDesktop(url)
        let target = CGPoint(x: point.x + CGFloat(index) * iconStep, y: point.y)
        await Task.detached { position(dest, at: target) }.value
        return dest
    }
}
