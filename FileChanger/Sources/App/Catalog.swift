import Foundation

/// Joins every area's tools. The shell asks this, never an area directly.
enum Catalog {
    @MainActor static var tools: [FileToolSpec] { ImageTools.all + MediaTools.all + DocumentTools.all }

    @MainActor static func tools(for files: [URL]) -> [FileToolSpec] { tools.filter { $0.accepts(files) } }
}
