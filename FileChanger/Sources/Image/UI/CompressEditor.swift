import SwiftUI

/// IMG-10..14. Compress (images and PDFs).
struct CompressEditor: View {
    enum Mode: String, CaseIterable { case level = "Level", percentage = "Percentage", fileSize = "Target file size" }
    let files: [URL]
    @State private var mode: Mode = .level
    @State private var strength = ImageCompressionStrength.saved
    @State private var size = ImageCompressionSize.saved
    @State private var reduction = 50.0
    @State private var targetNumber = 500.0
    @State private var unitMB = false
    @State private var estimate = "Estimating"
    @Environment(\.toolPanel) private var panel

    private var compressionMode: ImageCompressionMode {
        switch mode {
        case .level: return .level(strength, size)
        case .percentage: return .percentage(Int(reduction))
        case .fileSize: return .targetBytes(Int(targetNumber * (unitMB ? 1_048_576 : 1024)))
        }
    }

    private var problem: String? {
        for u in files { do { _ = try ImageCompressEngine.target(for: compressionMode, originalBytes: ImageFiles.fileSize(u)) } catch { return error.localizedDescription } }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Compression Quality", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).accessibilityIdentifier("compressionTargetMode")
                switch mode {
                case .level:
                    Picker("Level", selection: $strength) { ForEach(ImageCompressionStrength.allCases, id: \.self) { Text($0.label).tag($0) } }
                        .accessibilityIdentifier("compressionLevel")
                    if files.allSatisfy({ FileKind.of($0) == .pdf }) {
                        Text("PDFs are optimized with the macOS Reduce File Size filter; Level and Image size do not apply.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(strength == .balanced ? "Better visual quality with moderate file-size savings." : "Much smaller files with more visible quality loss.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Image size", selection: $size) { ForEach(ImageCompressionSize.allCases, id: \.self) { Text($0.label).tag($0) } }
                case .percentage:
                    VStack(alignment: .leading) {
                        HStack { Text("Reduce by"); Spacer(); Text("\(Int(reduction))%").monospacedDigit() }
                        Slider(value: $reduction, in: 1...99, step: 1).tint(Brand.accent).accessibilityIdentifier("compressionPercentage")
                        HStack {
                            Text("Smaller files with less quality loss.")
                            Spacer()
                            Text("Smaller files with more quality loss.")
                        }.font(.caption2).foregroundStyle(.secondary)
                        Text(files.count == 1 ? "Compresses to at most \(100 - Int(reduction))% of the original size."
                                              : "Each file is compressed to at most \(100 - Int(reduction))% of its original size.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .fileSize:
                    HStack {
                        Text("Target file size")
                        Spacer()
                        TextField("Target file size", value: $targetNumber, format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 90)
                        Picker("Unit", selection: $unitMB) { Text("KB").tag(false); Text("MB").tag(true) }
                            .labelsHidden().frame(width: 70)
                    }
                }
                if files.count == 1, let f = files.first {
                    LabeledContent("Original size and the estimated compressed size") {
                        Text("\(ImageCompressEngine.formatted(ImageFiles.fileSize(f))) \u{2192} \(estimate)").monospacedDigit()
                    }.font(.callout).accessibilityIdentifier("compressionOriginalSize")
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            Spacer(minLength: 0)
            Divider()
            ToolFooter(primary: "Compress", isEnabled: problem == nil, message: problem) { save() }
        }
        .task(id: "\(mode)\(strength)\(size)\(reduction)\(targetNumber)\(unitMB)") { await refreshEstimate() }
    }

    private func refreshEstimate() async {
        guard files.count == 1, let f = files.first else { return }
        estimate = "Estimating"
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }
        let m = compressionMode
        let bytes = await Task.detached { ImageCompressEngine.estimate(f, m) }.value
        if Task.isCancelled { return }
        estimate = bytes.map { ImageCompressEngine.formatted($0) } ?? "File size unavailable"
    }

    private func save() {
        let m = compressionMode
        runImageJob(title: "Compressing", files: files, close: panel.close) { url, progress in
            try await ImageCompressEngine.compress(url, m, progress: progress)
        }
    }
}
