import AppKit
import SwiftUI

// Compress (video): preset balanced/strong, reduction percentage, or target size with fast/accurate (VID-70..73).

struct VideoCompressEditor: View {
    enum Kind: String { case preset, percentage, size }

    let files: [URL]
    @State private var kind = Kind.preset
    @State private var strong = UserDefaults.standard.string(forKey: "defaultVideoCompressionStrength") == "strong"
    @State private var percent = 50
    @State private var sizeText = "10"
    @State private var unit = "MB"
    @State private var accurate = false
    @State private var info: MediaInfo?
    @Environment(\.toolPanel) private var panel

    private var original: Int64 { VideoCompressEngine.fileSize(files[0]) }

    private var mode: Result<VideoCompressMode, FileChangerError> {
        switch kind {
        case .preset: return .success(.preset(strong: strong))
        case .percentage:
            do { _ = try VideoCompressEngine.validateReduction(percent, original: original); return .success(.reduction(percent)) }
            catch { return .failure(.failed(error.localizedDescription)) }
        case .size:
            do {
                let b = try VideoCompressEngine.validateTarget(VideoCompressEngine.bytes(from: sizeText, unit: unit), original: original)
                return .success(.targetSize(bytes: b, accurate: accurate))
            } catch { return .failure(.failed(error.localizedDescription)) }
        }
    }

    private var estimate: String {
        switch kind {
        case .percentage: return VideoCompressEngine.sizeText(original * Int64(100 - percent) / 100)
        case .size: return VideoCompressEngine.bytes(from: sizeText, unit: unit).map(VideoCompressEngine.sizeText) ?? "File size unavailable"
        case .preset:
            guard let info else { return "Estimating" }
            let p = VideoCompressEngine.presetPlan(strong: strong, info: info)
            return VideoCompressEngine.sizeText(Int64(Double(p.videoBitrate + (info.hasAudio ? p.audioBitrate : 0)) * info.duration / 8))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $kind) {
                Text("Preset").tag(Kind.preset); Text("Percentage").tag(Kind.percentage); Text("Target size").tag(Kind.size)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 320)
            switch kind {
            case .preset:
                Picker("", selection: $strong) {
                    Text("Balanced").tag(false); Text("Strong").tag(true)
                }.pickerStyle(.radioGroup).labelsHidden()
                HelperText(text: strong ? "Much smaller files with more visible quality loss." : "Better visual quality with moderate file-size savings.")
            case .percentage:
                HStack {
                    ForEach([25, 50, 75], id: \.self) { v in Button("\(v)%") { percent = v }.buttonStyle(.bordered).tint(percent == v ? Brand.accent : nil) }
                    TextField("", value: $percent, format: .number).frame(width: 60).textFieldStyle(.roundedBorder)
                    Text("% smaller")
                }
                HelperText(text: files.count == 1 ? "Compresses to at most \(100 - percent)% of the original size."
                                                   : "Each file is compressed to at most \(100 - percent)% of its original size.")
            case .size:
                HStack {
                    Text("Target file size")
                    TextField("", text: $sizeText).frame(width: 80).textFieldStyle(.roundedBorder)
                    Picker("", selection: $unit) { ForEach(["KB", "MB", "GB"], id: \.self) { Text($0) } }.labelsHidden().frame(width: 70)
                }
                Picker("", selection: $accurate) { Text("Fast").tag(false); Text("Accurate").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                HelperText(text: accurate ? "Accurate mode re-encodes until the file fits the target." : "Fast mode encodes once and may land above the target.")
            }
            Divider()
            HStack {
                Text("Original \(VideoCompressEngine.sizeText(original))")
                Image(systemName: "arrow.right")
                Text("about \(estimate)").bold()
                if files.count > 1 { Text("(first of \(files.count) files)").foregroundStyle(.secondary) }
            }.font(.callout)
            Spacer()
            ToolFooter(primary: "Compress", isEnabled: { if case .success = mode { return true }; return false }(),
                       message: { if case .failure(let e) = mode { return e.localizedDescription }; return nil }()) {
                guard case .success(let m) = mode else { return }
                runMediaJob(panel, title: "Compressing", files: files) { u, p in try await VideoCompressEngine.compress(u, mode: m, progress: p) }
            }
        }
        .padding([.horizontal, .top], 16)
        .task { info = try? await MediaProbe.info(files[0]) }
    }
}
