import Foundation
import SwiftUI

/// Video and audio tools on the wheel (VID-*, AUD-*, MED-* in docs/inventory/media.md). Owned by the media builder.
enum MediaTools {
    private static func tool(_ id: String, _ label: String, _ title: String, _ symbol: String, kinds: Set<FileKind>,
                             min: Int = 1, max: Int = 1, _ make: @escaping @MainActor ([URL]) -> AnyView) -> FileToolSpec {
        FileToolSpec(id: id, wheelLabel: label, title: title, symbol: symbol, kinds: kinds, minFiles: min, maxFiles: max, action: .panel(make))
    }

    @MainActor static var all: [FileToolSpec] {
        [
            tool("trimVideo", "TRIM", "Trim Video", "scissors", kinds: [.video]) { AnyView(VideoTrimEditor(files: $0)) },
            tool("splitVideo", "SPLIT", "Split Video", "rectangle.split.2x1", kinds: [.video]) { AnyView(VideoSplitEditor(files: $0)) },
            tool("joinVideos", "JOIN", "Join Videos", "film.stack", kinds: [.video], min: 2, max: .max) { AnyView(VideoJoinEditor(files: $0)) },
            tool("muteVideo", "MUTE", "Remove Audio", "speaker.slash.fill", kinds: [.video], max: .max) { AnyView(VideoMuteEditor(files: $0)) },
            tool("changeVideoSpeed", "SPEED", "Change Video Speed", "speedometer", kinds: [.video]) { AnyView(VideoSpeedEditor(files: $0)) },
            tool("videoSnapshots", "SNAP", "Video Snapshots", "camera", kinds: [.video]) { AnyView(VideoSnapshotEditor(files: $0)) },
            tool("cropVideo", "CROP", "Crop Video", "crop", kinds: [.video]) { AnyView(VideoCropEditor(files: $0)) },
            tool("redactVideo", "REDACT", "Redact Video", "eye.slash", kinds: [.video]) { AnyView(VideoRedactEditor(files: $0)) },
            // The image builder's `compress` covers images and PDFs; video has its own id.
            tool("compressVideo", "COMPRESS", "Compress", "arrow.down.right.and.arrow.up.left", kinds: [.video], max: .max) { AnyView(VideoCompressEditor(files: $0)) },
            tool("trimAudio", "TRIM", "Trim Audio", "scissors", kinds: [.audio], max: .max) { AnyView(AudioTrimEditor(files: $0)) },
            tool("audioChannels", "CHANNELS", "Convert Audio Channels", "hifispeaker.2", kinds: [.audio, .video], max: .max) { AnyView(AudioChannelsEditor(files: $0)) },
            tool("normalizeAudio", "NORMALIZE", "Normalize Volume", "waveform", kinds: [.audio], max: .max) { AnyView(AudioNormalizeEditor(files: $0)) },
            tool("redactAudio", "BLEEP", "Bleep Audio", "waveform.badge.minus", kinds: [.audio]) { AnyView(AudioBleepEditor(files: $0)) },
            tool("audioToVideo", "VISUALIZE", "Audio Visualizer", "waveform.path", kinds: [.audio]) { AnyView(AudioVisualizerEditor(files: $0)) },
        ]
    }
}
