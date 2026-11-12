import Foundation
import SwiftUI

/// A slice of the Tools wheel (opened by tapping its modifier, Command by default, while dragging files).
/// Dropping files on it opens the tool's options panel; the panel's primary button saves new files.
struct FileToolSpec: Identifiable {
    let id: String              // Tangerine's tool id, e.g. "trimVideo"
    let wheelLabel: String      // all-caps slice label, e.g. "TRIM"
    let title: String           // panel title, e.g. "Trim Video"
    let symbol: String          // SF Symbol name
    let kinds: Set<FileKind>    // file kinds this tool accepts
    let minFiles: Int
    let maxFiles: Int           // Int.max for batch tools
    let action: FileToolAction

    func accepts(_ files: [URL]) -> Bool {
        files.count >= minFiles && files.count <= maxFiles && files.allSatisfy { kinds.contains(FileKind.of($0)) }
    }
}

/// What dropping files on a tool slice does.
enum FileToolAction {
    /// Opens `ToolPanel` with this editor (most tools).
    case panel(@MainActor (_ files: [URL]) -> AnyView)
    /// Runs at once with no options window (e.g. Extract Archive); usually calls `Operations.run`.
    case run(@MainActor (_ files: [URL]) -> Void)
}

/// A petal of the Conversion wheel (Shift tap while dragging, by default). Dropping files on it converts them at once.
struct ConversionTarget: Identifiable, Hashable, Sendable {
    let id: String              // stable id, e.g. "image.png"
    let label: String           // petal label, e.g. "PNG"
    let ext: String             // output extension
    let group: String           // fan group, e.g. "Image"
}

/// Progress callback for long jobs: fraction 0...1 for the current file.
typealias ProgressHandler = @Sendable (Double) -> Void
