import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Audio tool editors: trim, channels, normalize, bleep, visualizer.

/// Renders a short preview to a temp file in the background and plays it (channel / normalized / bleep previews).
@MainActor
final class AudioPreviewer: ObservableObject {
    @Published var playing: String?
    @Published var failed = false
    private var player: AVAudioPlayer?
    private var temp: URL?
    private var job: Task<Void, Never>?

    func toggle(_ key: String, render: @escaping @Sendable (URL) async throws -> Void) {
        if playing == key { stop(); return }
        stop()
        playing = key; failed = false
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("filechanger-preview-\(UUID().uuidString).caf")
        temp = out
        job = Task {
            do {
                try await render(out)
                guard !Task.isCancelled, playing == key else { return }
                let p = try AVAudioPlayer(contentsOf: out)
                player = p
                p.play()
                while p.isPlaying, !Task.isCancelled { try? await Task.sleep(nanoseconds: 150_000_000) }
            } catch { if !Task.isCancelled { failed = true } }
            if playing == key { playing = nil }
        }
    }

    func stop() {
        job?.cancel(); player?.stop(); player = nil; playing = nil
        if let temp { try? FileManager.default.removeItem(at: temp) }
        temp = nil
    }
}

@MainActor private func headerLoading(_ files: [URL]) -> MediaSession { MediaSession(url: files[0]) }

// MARK: - Trim Audio (AUD-01, AUD-02)

struct AudioTrimEditor: View {
    let files: [URL]
    @StateObject private var session: MediaSession
    @State private var limit: Double?
    init(files: [URL]) { self.files = files; _session = StateObject(wrappedValue: headerLoading(files)) }

    var body: some View {
        MediaLoadingView(session: session, loading: "Loading waveform") { info in
            AudioTrimBody(session: session, files: files, duration: limit ?? info.duration)
        }
        .task {
            await session.load(waveformBins: 700)
            var shortest = session.info?.duration ?? 0
            for f in files.dropFirst() { if let i = try? await MediaProbe.audio(f) { shortest = min(shortest, i.duration) } }
            limit = shortest
        }
    }
}

private struct AudioTrimBody: View {
    @ObservedObject var session: MediaSession
    let files: [URL]
    let duration: Double
    @State private var span: MediaSpan
    @State private var autoTrim = false
    @State private var threshold = -50.0
    @State private var detected: MediaSpan?
    @State private var detecting = false
    @State private var silent = false
    @Environment(\.toolPanel) private var panel

    init(session: MediaSession, files: [URL], duration: Double) {
        self.session = session; self.files = files; self.duration = duration
        _span = State(initialValue: MediaSpan(start: 0, end: duration))
    }

    private var error: String? {
        if silent && autoTrim { return "The selected range is silent at this threshold. Lower the threshold or turn off automatic trimming." }
        do { try MediaRange.validateTrim(start: span.start, end: span.end, duration: duration); try AudioSilence.validate(thresholdDB: threshold); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(spacing: 10) {
            if session.waveformFailed { HelperText(text: "Waveform unavailable. You can still adjust the range.") }
            TimelineBar(duration: duration, playhead: $session.time, selection: $span, height: 90, onScrub: { session.seek(to: $0) }) {
                WaveformBars(peaks: session.peaks)
            } overlay: { scale in
                if let d = detected, autoTrim {
                    Rectangle().stroke(.green, lineWidth: 2).frame(width: scale.x(d.length), height: 90).offset(x: scale.x(d.start)).allowsHitTesting(false)
                }
            }.padding(.top, 6)
            HStack {
                Button { if session.isPlaying { session.pause() } else { session.playRange = span; session.play() } } label: {
                    Label(session.isPlaying ? "Pause Preview" : "Play Selected Range", systemImage: session.isPlaying ? "pause.fill" : "play.fill")
                }
                Text(MediaTime.format(session.time)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                TimeField(label: "Start", value: $span.start, range: 0...max(0, span.end - 0.05))
                TimeField(label: "End", value: $span.end, range: (span.start + 0.05)...duration)
            }
            Toggle("Trim silent ends automatically", isOn: $autoTrim)
            if autoTrim {
                HStack {
                    Text("Silence threshold")
                    Slider(value: $threshold, in: -80 ... -10, step: 1).accessibilityLabel("Silence threshold in decibels")
                    Text("\(Int(threshold)) dB").monospacedDigit().frame(width: 56)
                    if detecting { ProgressView().controlSize(.small); Text("Detecting silence").foregroundStyle(.secondary) }
                }
            }
            AudioFormatNote(files: files)
            if files.count > 1 {
                HelperText(text: "Range applies to all files, up to the shortest file's duration.")
            }
            ToolFooter(primary: "Save Edited Copy", isEnabled: error == nil, message: error, reset: {
                span = MediaSpan(start: 0, end: duration); autoTrim = false
            }) {
                let (s, e, auto, th) = (span.start, span.end, autoTrim, threshold)
                runMediaJob(panel, title: "Trimming", files: files) { u, p in
                    try await AudioTrimEngine.trim(u, start: s, end: e, autoTrimSilence: auto, thresholdDB: th, progress: p)
                }
            }
        }
        .padding([.horizontal, .top], 16)
        .task(id: "\(autoTrim)|\(threshold)|\(span.start)|\(span.end)") {
            guard autoTrim else { detected = nil; silent = false; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            detecting = true
            let (url, s, th) = (session.url, span, threshold)
            let result = await Task.detached { () -> MediaSpan?? in
                guard let src = try? await AudioIO.open(url) else { return nil }
                return .some(try? AudioSilence.nonSilentSpan(src.file, thresholdDB: th, within: s))
            }.value
            detecting = false
            if let r = result { detected = r ?? nil; silent = (r ?? nil) == nil }
        }
        .onChange(of: span) { _, s in session.playRange = s }
        .onAppear { session.playRange = span }
        .mediaKeys(session: session)
    }
}

// MARK: - Convert Audio Channels (AUD-10..12)

struct AudioChannelsEditor: View {
    let files: [URL]
    @StateObject private var session: MediaSession
    init(files: [URL]) { self.files = files; _session = StateObject(wrappedValue: headerLoading(files)) }

    var body: some View {
        MediaLoadingView(session: session, loading: "Loading waveform") { info in AudioChannelsBody(session: session, files: files, info: info) }
            .task { await session.load() }
    }
}

private struct AudioChannelsBody: View {
    @ObservedObject var session: MediaSession
    let files: [URL]
    let info: MediaInfo
    @State private var channels = 2
    @State private var left = 1.0
    @State private var right = 1.0
    @State private var peaks: [[Float]] = []
    @State private var waveformFailed = false
    @StateObject private var preview = AudioPreviewer()
    @Environment(\.toolPanel) private var panel

    private var error: String? {
        do { try AudioChannelsEngine.validate(channels: channels, left: left, right: right); return nil } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Output channels", selection: $channels) { Text("Mono").tag(1); Text("Stereo").tag(2) }.pickerStyle(.segmented).frame(width: 320)
            if waveformFailed { HelperText(text: "Channel waveforms unavailable. You can still convert the audio.") }
            ForEach(0..<max(1, min(2, info.audioChannels)), id: \.self) { c in
                HStack {
                    Button { previewChannel(c) } label: { Image(systemName: preview.playing == "ch\(c)" ? "stop.fill" : "play.fill") }
                        .help(preview.playing == "ch\(c)" ? "Stop channel preview" : "\(name(c)) channel preview")
                    Text(name(c)).frame(width: 44, alignment: .leading)
                    if c < peaks.count { WaveformBars(peaks: peaks[c]).frame(height: 36).clipShape(RoundedRectangle(cornerRadius: 4)) }
                    else { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                    Slider(value: c == 0 ? $left : $right, in: 0...1).frame(width: 140).accessibilityLabel("\(name(c)) volume")
                    Text("\(Int(((c == 0 ? left : right) * 100).rounded()))%").monospacedDigit().frame(width: 44)
                }
            }
            HStack {
                Button { previewOutput() } label: {
                    Label(preview.playing == "out" ? "Stop" : "Output channel preview", systemImage: "speaker.wave.2")
                }.help("Play the complete Mono or Stereo output with the selected volume balance").accessibilityIdentifier("audioChannelsOutputPreview")
                if preview.failed { Text("Could not play the output preview.").font(.caption).foregroundStyle(.red) }
            }
            AudioFormatNote(files: files)
            if files.count > 1 { HelperText(text: "Previewing the first of \(files.count) files. Settings apply to every selected file.") }
            Spacer()
            ToolFooter(primary: "Save Edited Copy", isEnabled: error == nil, message: error, reset: { channels = 2; left = 1; right = 1 }) {
                let (c, l, r) = (channels, left, right)
                runMediaJob(panel, title: "Converting channels", files: files) { u, p in try await AudioChannelsEngine.convert(u, channels: c, left: l, right: r, progress: p) }
            }
        }
        .padding([.horizontal, .top], 16)
        .task {
            var all: [[Float]] = []
            for c in 0..<max(1, min(2, info.audioChannels)) {
                guard let p = try? await MediaWaveform.peaks(url: session.url, bins: 400, channel: c) else { waveformFailed = true; return }
                all.append(p); peaks = all
            }
        }
        .onDisappear { preview.stop() }
    }

    private func name(_ c: Int) -> String { info.audioChannels < 2 ? "Mono" : (c == 0 ? "Left" : "Right") }

    private func previewChannel(_ c: Int) {
        let url = session.url
        preview.toggle("ch\(c)") { out in
            let s = try await AudioIO.open(url)
            try AudioChannelsEngine.render(s, channels: 1, left: 1, right: 1, solo: c, maxSeconds: 60, to: out, ext: "caf") { _ in }
        }
    }

    private func previewOutput() {
        let (url, c, l, r) = (session.url, channels, left, right)
        preview.toggle("out") { out in
            let s = try await AudioIO.open(url)
            try AudioChannelsEngine.render(s, channels: c, left: l, right: r, maxSeconds: 60, to: out, ext: "caf") { _ in }
        }
    }
}

// MARK: - Normalize Volume (AUD-20)

struct AudioNormalizeEditor: View {
    let files: [URL]
    @StateObject private var session: MediaSession
    init(files: [URL]) { self.files = files; _session = StateObject(wrappedValue: headerLoading(files)) }

    var body: some View {
        MediaLoadingView(session: session, loading: "Loading file details") { _ in AudioNormalizeBody(url: files[0], files: files) }
            .task { await session.load() }
    }
}

private struct AudioNormalizeBody: View {
    let url: URL
    let files: [URL]
    @State private var target = AudioNormalizeEngine.defaultTarget
    @State private var range = AudioNormalizeEngine.defaultRange
    @State private var truePeak = AudioNormalizeEngine.defaultTruePeak
    @State private var measured: LoudnessMeter.Result?
    @State private var measuring = true
    @StateObject private var preview = AudioPreviewer()
    @Environment(\.toolPanel) private var panel

    private var error: String? {
        do { try AudioNormalizeEngine.validate(target: target, range: range, truePeak: truePeak); return nil } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Target loudness", value: $target, unit: "LUFS", help: "16 LUFS is a balanced default for spoken audio and music.")
            row("Loudness range", value: $range, unit: "LU", help: "Material wider than this is squeezed with slow gain riding (1 to 50 LU).")
            row("True peak limit", value: $truePeak, unit: "dBTP", help: "The true peak limit helps prevent clipping after encoding.")
            HStack {
                if measuring { ProgressView().controlSize(.small); Text("Updating preview").foregroundStyle(.secondary) }
                else if let m = measured, m.integrated.isFinite {
                    Text(String(format: "Measured %.1f LUFS, peak %.1f dBTP", m.integrated, 20 * log10(max(m.truePeak, 1e-6)))).foregroundStyle(.secondary)
                } else { Text("Normalized preview unavailable. You can still normalize this audio.").foregroundStyle(.secondary) }
                Spacer()
                Button { previewNormalized() } label: { Label(preview.playing != nil ? "Stop" : "Normalized preview", systemImage: "play.fill") }
                    .disabled(measured?.integrated.isFinite != true).accessibilityIdentifier("normalizationPlaybackToggle")
            }
            if preview.failed { Text("Normalized audio preview is unavailable. You can still export with these settings.").font(.caption).foregroundStyle(.red) }
            AudioFormatNote(files: files)
            if files.count > 1 { HelperText(text: "Previewing the first of \(files.count) files. Settings apply to every selected file.") }
            Spacer()
            ToolFooter(primary: "Save Edited Copy", isEnabled: error == nil, message: error, reset: {
                target = AudioNormalizeEngine.defaultTarget; range = AudioNormalizeEngine.defaultRange; truePeak = AudioNormalizeEngine.defaultTruePeak
            }) {
                let (t, r, p) = (target, range, truePeak)
                runMediaJob(panel, title: "Normalizing volume", files: files) { u, prog in try await AudioNormalizeEngine.normalize(u, target: t, range: r, truePeak: p, progress: prog) }
            }
        }
        .padding([.horizontal, .top], 16)
        .task {
            let u = url
            measured = await Task.detached { try? await LoudnessMeter.measure(url: u) }.value
            measuring = false
        }
        .onDisappear { preview.stop() }
    }

    private func row(_ title: String, value: Binding<Double>, unit: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).frame(width: 130, alignment: .leading)
                TextField("", value: value, format: .number.precision(.fractionLength(0...1))).textFieldStyle(.roundedBorder).frame(width: 80)
                Text(unit).foregroundStyle(.secondary)
            }
            HelperText(text: help)
        }
    }

    private func previewNormalized() {
        guard let m = measured, let plan = try? AudioNormalizeEngine.plan(measured: m, target: target, range: range, truePeak: truePeak) else { return }
        let (u, tp) = (url, truePeak)
        preview.toggle("norm") { out in
            let s = try await AudioIO.open(u)
            try AudioNormalizeEngine.render(s, gain: plan.gain, ceiling: pow(10, tp / 20) * 0.995, limit: plan.limit, ride: plan.ride, maxSeconds: 30, to: out, ext: "caf") { _ in }
        }
    }
}

// MARK: - Bleep Audio (AUD-40..42)

struct AudioBleepEditor: View {
    let files: [URL]
    @StateObject private var session: MediaSession
    init(files: [URL]) { self.files = files; _session = StateObject(wrappedValue: headerLoading(files)) }

    var body: some View {
        MediaLoadingView(session: session, loading: "Loading waveform") { info in AudioBleepBody(session: session, info: info) }
            .task { await session.load(waveformBins: 700) }
    }
}

private struct BleepItem: Identifiable { let id = UUID(); var span: MediaSpan }

private struct AudioBleepBody: View {
    @ObservedObject var session: MediaSession
    let info: MediaInfo
    @State private var bleeps: [BleepItem] = []
    @State private var selected: UUID?
    @State private var dragStart: Double?
    @State private var dragNow: Double?
    @StateObject private var preview = AudioPreviewer()
    @Environment(\.toolPanel) private var panel

    private var ranges: [MediaSpan] { bleeps.map(\.span) }
    private var error: String? {
        do { try MediaRange.validateRanges(ranges, duration: info.duration, emptyMessage: "Add at least one bleep range."); return nil }
        catch { return bleeps.isEmpty ? nil : error.localizedDescription }
    }

    var body: some View {
        VStack(spacing: 8) {
            if session.waveformFailed { HelperText(text: "Waveform unavailable. You can still adjust the range.") }
            TimelineBar(duration: info.duration, playhead: $session.time, height: 80, onScrub: { session.seek(to: $0) }) {
                WaveformBars(peaks: session.peaks)
            } overlay: { _ in EmptyView() }.padding(.top, 6)
            bleepLayer
            HStack {
                Button("Add bleep at playhead") {
                    let s = min(session.time, max(0, info.duration - 0.05))
                    let b = BleepItem(span: MediaSpan(start: s, end: min(info.duration, s + 0.5)))
                    bleeps.append(b); selected = b.id
                }
                Button("Bleep Entire Audio") { let b = BleepItem(span: MediaSpan(start: 0, end: info.duration)); bleeps = [b]; selected = b.id }
                Button("Delete") { deleteSelected() }.disabled(selected == nil)
                Spacer()
                Button { previewBleeps() } label: { Label(preview.playing != nil ? "Pause" : "With Bleeps", systemImage: preview.playing != nil ? "pause.fill" : "play.fill") }
                    .disabled(bleeps.isEmpty)
            }
            if preview.failed { Text("Could not play the bleep preview.").font(.caption).foregroundStyle(.red) }
            if let i = bleeps.firstIndex(where: { $0.id == selected }) {
                HStack(spacing: 16) {
                    Text("Selected Bleep").foregroundStyle(.secondary)
                    TimeField(label: "Bleep start", value: $bleeps[i].span.start, range: 0...max(0, bleeps[i].span.end - 0.05))
                    TimeField(label: "Bleep end", value: $bleeps[i].span.end, range: (bleeps[i].span.start + 0.05)...info.duration)
                    Spacer()
                }
            } else {
                HelperText(text: "Drag across the Bleep layer to add a section, then drag a clip or either edge to adjust it.")
            }
            AudioFormatNote(files: [session.url])
            Spacer(minLength: 0)
            ToolFooter(primary: "Save Bleeped Copy", isEnabled: !bleeps.isEmpty && error == nil,
                       message: bleeps.isEmpty ? "Add at least one bleep range." : error, reset: { bleeps = []; selected = nil }) {
                let r = ranges
                runMediaJob(panel, title: "Bleeping audio", files: [session.url]) { u, p in try await AudioBleepEngine.bleep(u, ranges: r, progress: p) }
            }
        }
        .padding([.horizontal, .top], 16)
        .mediaKeys(session: session) { guard selected != nil else { return false }; deleteSelected(); return true }
        .onDisappear { preview.stop() }
    }

    private func deleteSelected() { bleeps.removeAll { $0.id == selected }; selected = nil }

    private var bleepLayer: some View {
        GeometryReader { geo in
            let scale = TimelineScale(width: geo.size.width, duration: info.duration)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12))
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("timeline")).onChanged { g in
                        dragStart = scale.time(g.startLocation.x); dragNow = scale.time(g.location.x)
                    }.onEnded { _ in
                        if let a = dragStart, let b = dragNow, abs(b - a) >= 0.05 {
                            let item = BleepItem(span: MediaSpan(start: min(a, b), end: max(a, b)))
                            bleeps.append(item); selected = item.id
                        }
                        dragStart = nil; dragNow = nil
                    })
                if bleeps.isEmpty && dragStart == nil { Text("Drag to add a bleep").font(.caption).foregroundStyle(.secondary).padding(.leading, 8).allowsHitTesting(false) }
                if let a = dragStart, let b = dragNow {
                    Rectangle().stroke(Brand.accent, style: StrokeStyle(lineWidth: 1, dash: [4]))
                        .frame(width: scale.x(abs(b - a)), height: 26).offset(x: scale.x(min(a, b))).allowsHitTesting(false)
                }
                ForEach($bleeps) { $b in
                    RangeClip(scale: scale, span: $b.span, selected: selected == b.id, onSelect: { selected = b.id })
                }
            }
            .coordinateSpace(name: "timeline")
        }
        .frame(height: 34)
        .accessibilityLabel("Bleep layer")
    }

    private func previewBleeps() {
        let (url, r) = (session.url, ranges)
        preview.toggle("bleep") { out in
            let s = try await AudioIO.open(url)
            try AudioBleepEngine.render(s, ranges: r, maxSeconds: 120, to: out, ext: "caf") { _ in }
        }
    }
}

// MARK: - Audio Visualizer (AUD-50, AUD-51)

struct AudioVisualizerEditor: View {
    let files: [URL]
    @State private var style = VisualizerStyle.waveform
    @State private var shape = VisualizerShape.automatic
    @State private var imageURL: URL?
    @State private var image: NSImage?
    @State private var imageError: String?
    @Environment(\.toolPanel) private var panel

    private var error: String? {
        if style == .staticImage && imageURL == nil { return "Choose an image for the visualization." }
        return imageError
    }

    private var canvasSize: CGSize { AudioVisualizerEngine.canvas(shape, image: image?.size) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Visualization style", selection: $style) {
                Text("Waveform").tag(VisualizerStyle.waveform); Text("Choose a static image").tag(VisualizerStyle.staticImage)
            }.pickerStyle(.segmented).frame(width: 360)
            HStack {
                Button(imageURL == nil ? (style == .staticImage ? "Choose a visualization image" : "Choose a background image") : imageURL!.lastPathComponent) { chooseImage() }
                if imageURL != nil { Button { imageURL = nil; image = nil; imageError = nil } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless) }
            }
            Picker("Video shape", selection: $shape) { ForEach(VisualizerShape.allCases, id: \.self) { Text($0.label).tag($0) } }
                .frame(width: 300).help("Shape")
            ZStack {
                Color.black
                if let image { Image(nsImage: image).resizable().scaledToFit().opacity(style == .waveform ? 0.4 : 1) }
                if style == .waveform {
                    Canvas { ctx, size in
                        for i in 0..<60 {
                            let h = CGFloat(abs(sin(Double(i) * 0.37) * cos(Double(i) * 0.11))) * size.height * 0.4 + 2
                            ctx.fill(Path(CGRect(x: CGFloat(i) * size.width / 60 + 1, y: size.height / 2 - h, width: 3, height: h * 2)), with: .color(Brand.accent))
                        }
                    }
                }
            }
            .aspectRatio(canvasSize.width / canvasSize.height, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 220)
            .accessibilityLabel("Waveform visualization preview")
            Text("\(Int(canvasSize.width)) x \(Int(canvasSize.height)), H.264 + AAC mp4").font(.caption).foregroundStyle(.secondary)
            Spacer()
            ToolFooter(primary: "Create Visualization", isEnabled: error == nil, message: error) {
                let (st, sh, img) = (style, shape, imageURL)
                runMediaJob(panel, title: "Creating visualization", files: files) { u, p in
                    try await AudioVisualizerEngine.create(u, style: st, imageURL: img, shape: sh, progress: p)
                }
            }
        }.padding([.horizontal, .top], 16)
    }

    private func chooseImage() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.canChooseDirectories = false
        guard p.runModal() == .OK, let url = p.url else { return }
        if let img = NSImage(contentsOf: url) { imageURL = url; image = img; imageError = nil } else { imageError = "Could not read the image." }
    }
}
