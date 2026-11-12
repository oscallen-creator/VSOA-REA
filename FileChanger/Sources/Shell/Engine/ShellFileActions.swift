import AppKit

/// Logic of the six Actions-wheel petals that does not need a window (SHL-24..29).
enum ShellFileActions {
    struct ActionError: LocalizedError {
        let title: String
        let message: String
        var errorDescription: String? { message }
    }

    static func localURLs(_ urls: [URL]) -> [URL] { urls.filter { $0.isFileURL } }

    /// Full POSIX paths, one per line.
    static func pathText(_ urls: [URL]) -> String { urls.map(\.path).joined(separator: "\n") }

    static func copyPaths(_ urls: [URL], to pb: NSPasteboard = .general) throws {
        let local = localURLs(urls)
        guard !local.isEmpty, local.count == urls.count else {
            throw ActionError(title: "Couldn't copy file paths", message: "Only local file and folder paths can be copied.")
        }
        pb.clearContents()
        guard pb.setString(pathText(local), forType: .string) else {
            throw ActionError(title: "Couldn't copy file paths", message: "The paths couldn't be placed on the clipboard.")
        }
    }

    static func copyFiles(_ urls: [URL], to pb: NSPasteboard = .general) throws {
        let local = localURLs(urls)
        guard !local.isEmpty, local.count == urls.count else {
            throw ActionError(title: "Couldn't copy files", message: "Only local files and folders can be copied.")
        }
        pb.clearContents()
        guard pb.writeObjects(local as [NSURL]) else {
            throw ActionError(title: "Couldn't copy files", message: "The files couldn't be placed on the clipboard.")
        }
    }

    /// Folder a terminal opens in: the item itself if a folder, else its parent (SHL-27).
    static func terminalFolder(for url: URL) -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        return url.deletingLastPathComponent()
    }

    /// Unique folders for all items, in order.
    static func terminalFolders(for urls: [URL]) -> [URL] {
        var seen = Set<String>(), out: [URL] = []
        for u in urls { let f = terminalFolder(for: u); if seen.insert(f.path).inserted { out.append(f) } }
        return out
    }

    /// Why `destination` cannot receive `item`, or nil when fine (SHL-26).
    static func moveProblem(item: URL, destination: URL) -> String? {
        var isDir: ObjCBool = false
        guard destination.isFileURL, FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue else {
            return "Choose an existing local folder."
        }
        let dest = destination.standardizedFileURL.path, src = item.standardizedFileURL.path
        if dest == src || dest.hasPrefix(src + "/") { return "Choose a destination outside \(item.lastPathComponent)." }
        return nil
    }

    struct MoveResult {
        var moved: [URL] = []
        var failures: [String] = []
        var summary: String {
            if moved.isEmpty { return failures.isEmpty ? "No items were moved." : "The move was not completed. " + failures.joined(separator: " ") }
            return "Moved \(moved.count) item\(moved.count == 1 ? "" : "s")"
        }
    }

    /// Moves items into `folder`; name clashes get Finder-style " 2" names. Items already there are skipped.
    static func move(_ items: [URL], to folder: URL) -> MoveResult {
        var result = MoveResult()
        let fm = FileManager.default
        for item in items {
            if let problem = moveProblem(item: item, destination: folder) { result.failures.append(problem); continue }
            if item.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { continue }
            let target = OutputLocation.unique(folder.appendingPathComponent(item.lastPathComponent))
            do { try fm.moveItem(at: item, to: target); result.moved.append(target) }
            catch { result.failures.append("\(item.lastPathComponent): \(error.localizedDescription)") }
        }
        return result
    }
}

/// What the Float petal does when a Float is already open (SHL-65).
enum ShellFloatBehavior: String, CaseIterable, Identifiable {
    case createNew, addToExisting
    var id: String { rawValue }
    var label: String { self == .createNew ? "Create a New Float" : "Add Files to an Existing Float" }
}

/// Order a Float's files by name the way Finder lists them (SHL-63).
func shellSortedByName(_ urls: [URL]) -> [URL] {
    urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

/// Folder to select/reveal on the Desktop after a job (SHL-35).
func shellIsOnDesktop(_ url: URL) -> Bool {
    let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.standardizedFileURL.path ?? ""
    return !desktop.isEmpty && url.standardizedFileURL.deletingLastPathComponent().path == desktop
}
