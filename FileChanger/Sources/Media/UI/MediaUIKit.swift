import AVFoundation
import AVKit
import AppKit
import SwiftUI

// Pieces every media editor reuses: the playback session, player surface, playhead controls (VID-04),
// thumbnail/waveform timeline with trim handles (VID-02, VID-07), and the m:ss.cc time field (VID-03).

// MARK: - Session

/// One opened file: probe info, thumbnails/waveform, and an AVPlayer driven by Space / the playhead controls.
@MainActor
final class MediaSession: ObservableObject {
    let url: URL
    let player = AVPlayer()
    @Published var info: MediaInfo?
    @Published var loadError: String?
    @Published var thumbnails: [CGImage?] = []
    @Published var peaks: [Float] = []
    @Published var time = 0.0
    @Published var isPlaying = false
    @Published var waveformFailed = false
    /// Playback stays inside this span (trim preview, "Play Selected Range").
    var playRange: MediaSpan?
    /// Spans playback jumps over (removed split clips).
    var skip: [MediaSpan] = []
    var rate: Float = 1
    private var observer: Any?

    init(url: URL) {
        self.url = url
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
    }

    deinit { if let observer { player.removeTimeObserver(observer) } }

    var duration: Double { info?.duration ?? 0 }

    func load(thumbnails count: Int = 0, waveformBins: Int = 0) async {
        do { info = try await MediaProbe.info(url) } catch {
            loadError = error.localizedDescription
            return
        }
        guard let info else { return }
        if count > 0, info.hasVideo { thumbnails = await MediaThumbnails.strip(url: url, duration: info.duration, count: count) }
        if waveformBins > 0 {
            do { peaks = try await MediaWaveform.peaks(url: url, bins: waveformBins) } catch { waveformFailed = true }
        }
    }

    private func tick(_ t: Double) {
        time = t
        isPlaying = player.rate != 0
        guard isPlaying else { return }
        if let r = playRange, t >= r.end - 0.005 { pause(); seek(to: r.end); return }
        if let s = skip.first(where: { t >= $0.start - 0.001 && t < $0.end }) { seek(to: s.end) }
    }

    func seek(to t: Double) {
        let clamped = min(max(0, t), duration)
        time = clamped
        player.seek(to: MediaTime.cm(clamped), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func play() {
        if let r = playRange, time < r.start || time >= r.end - 0.01 { seek(to: r.start) }
        else if duration > 0, time >= duration - 0.01 { seek(to: 0) }
        player.play()
        player.rate = rate
        isPlaying = true
    }

    func pause() { player.pause(); isPlaying = false }
    func toggle() { isPlaying ? pause() : play() }

    func step(frames: Int) {
        pause()
        seek(to: time + Double(frames) / max(1, info?.fps ?? 30))
    }
}

/// Shows "Loading ..." until the probe finishes, then the editor body.
struct MediaLoadingView<Content: View>: View {
    @ObservedObject var session: MediaSession
    var loading = "Loading video"
    @ViewBuilder let content: (MediaInfo) -> Content

    var body: some View {
        Group {
            if let error = session.loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
                    Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                    HStack { Spacer(); CloseButton() }.padding(12)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else if let info = session.info {
                content(info)
            } else {
                ProgressView(loading).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct CloseButton: View {
    @Environment(\.toolPanel) private var panel
    var body: some View { Button("Cancel") { panel.close() }.keyboardShortcut(.cancelAction) }
}

/// Progress relay: the media engines want an escaping handler, the shared progress window hands out a
/// non-escaping one, so engines write here and a polling loop forwards to the window.
final class MediaProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0.0, done = false
    var value: Double { lock.lock(); defer { lock.unlock() }; return v }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return done }
    func set(_ x: Double) { lock.lock(); v = x; lock.unlock() }
    func finish() { lock.lock(); done = true; lock.unlock() }
}

func mediaRelay<In: Sendable>(_ work: @escaping @Sendable (In, @escaping ProgressHandler) async throws -> URL)
    -> @Sendable (In, ProgressHandler) async throws -> URL {
    { input, report in
        let sink = MediaProgressSink()
        let task = Task { () throws -> URL in
            defer { sink.finish() }
            return try await work(input) { sink.set($0) }
        }
        return try await withTaskCancellationHandler {
            while !sink.finished { report(sink.value); try? await Task.sleep(nanoseconds: 100_000_000) }
            return try await task.value
        } onCancel: { task.cancel() }
    }
}

/// Closes the panel, then runs `job` over `files` in the shared progress window.
@MainActor
func runMediaJob(_ panel: ToolPanelContext, title: String, files: [URL],
                 job: @escaping @Sendable (URL, @escaping ProgressHandler) async throws -> URL) {
    panel.close()
    Task { @MainActor in await Operations.run(title: title, files: files, job: mediaRelay(job)) }
}

/// N inputs -> one output (join).
@MainActor
func runMediaCombined(_ panel: ToolPanelContext, title: String, files: [URL],
                      job: @escaping @Sendable ([URL], @escaping ProgressHandler) async throws -> URL) {
    panel.close()
    Task { @MainActor in await Operations.runCombined(title: title, files: files, job: mediaRelay(job)) }
}

// MARK: - Player surface

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        return v
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) { view.playerLayer.player = player }
}

final class PlayerLayerView: NSView {
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
}

/// Video on top, or the fallback line when the file will not play (MED-10).
struct VideoPreview: View {
    @ObservedObject var session: MediaSession
    var fallback = "Playback is unavailable for this video. You can still scrub the timeline and export."

    var body: some View {
        Group {
            if session.info?.hasVideo == false {
                Text("Video preview is unavailable for this file. You can still export the selected range.").foregroundStyle(.secondary)
            } else {
                PlayerSurface(player: session.player)
                    .overlay(alignment: .bottom) {
                        if session.player.currentItem?.status == .failed { Text(fallback).padding(6).background(.black.opacity(0.6)).foregroundStyle(.white) }
                    }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Playhead controls

struct PlayheadControls: View {
    @ObservedObject var session: MediaSession
    var playLabel = "Play preview (Space)"
    var showFrameSteps = true

    var body: some View {
        HStack(spacing: 10) {
            if showFrameSteps {
                Button { session.step(frames: -1) } label: { Image(systemName: "backward.frame") }.help("Back one frame")
            }
            Button { session.toggle() } label: { Image(systemName: session.isPlaying ? "pause.fill" : "play.fill").frame(width: 18) }
                .help(session.isPlaying ? "Pause preview (Space)" : playLabel)
                .accessibilityIdentifier("videoTrimPlaybackToggle")
            if showFrameSteps {
                Button { session.step(frames: 1) } label: { Image(systemName: "forward.frame") }.help("Forward one frame")
            }
            Text(MediaTime.format(session.time)).monospacedDigit().foregroundStyle(.secondary)
                .accessibilityLabel("Playhead position in seconds")
            Text("/ " + MediaTime.format(session.duration)).monospacedDigit().foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
    }
}

extension View {
    /// Space toggles playback; Delete (when `onDelete` is given) removes the selection (SHL-93..95).
    /// The editor takes keyboard focus when it opens so Space works without a click.
    func mediaKeys(session: MediaSession?, onDelete: (() -> Bool)? = nil) -> some View {
        modifier(MediaKeysModifier(session: session, onDelete: onDelete))
    }
}

private struct MediaKeysModifier: ViewModifier {
    let session: MediaSession?
    let onDelete: (() -> Bool)?
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onKeyPress(.space) {
                guard let session else { return .ignored }
                session.toggle()
                return .handled
            }
            .onKeyPress(.delete) { (onDelete?() ?? false) ? .handled : .ignored }
            .onKeyPress(.deleteForward) { (onDelete?() ?? false) ? .handled : .ignored }
    }
}

/// Caption for sources that cannot be written back in their own format.
struct AudioFormatNote: View {
    let files: [URL]
    var body: some View {
        if let f = files.first(where: { FileKind.of($0) == .audio && AudioIO.outputExtension(for: $0) == "m4a" && $0.pathExtension.lowercased() != "m4a" }) {
            HelperText(text: "\(f.pathExtension.uppercased()) files save as M4A (AAC): macOS has no \(f.pathExtension.uppercased()) encoder.")
        }
    }
}

// MARK: - Time field

/// "m:ss.cc" field. Return commits; arrow keys step 0.01 s (Shift = 0.1 s); dragging the label adjusts too.
struct TimeField: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...86_400
    @State private var text = ""
    @State private var dragStart: Double?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary).fixedSize()
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        let base = dragStart ?? value
                        dragStart = base
                        let step = NSEvent.modifierFlags.contains(.shift) ? 0.1 : (NSEvent.modifierFlags.contains(.option) ? 0.001 : 0.01)
                        set(base + Double(g.translation.width) * step)
                    }
                    .onEnded { _ in dragStart = nil })
            TextField("0:00.00", text: $text)
                .textFieldStyle(.roundedBorder).frame(width: 92).monospacedDigit()
                .focused($focused)
                .onSubmit { commit() }
                .onKeyPress(phases: [.down, .repeat]) { press in
                    let big = press.modifiers.contains(.shift)
                    switch press.key {
                    case .upArrow, .rightArrow: set(value + (big ? 0.1 : 0.01)); return .handled
                    case .downArrow, .leftArrow: set(value - (big ? 0.1 : 0.01)); return .handled
                    default: return .ignored
                    }
                }
        }
        .help("\(label): drag to adjust, or use arrow keys for 0.01-second steps")
        .accessibilityElement(children: .combine)
        .onAppear { text = MediaTime.format(value) }
        .onChange(of: value) { _, v in if !focused || dragStart != nil { text = MediaTime.format(v) } }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func set(_ v: Double) {
        value = min(max(range.lowerBound, (v * 100).rounded() / 100), range.upperBound)
        text = MediaTime.format(value)
    }

    private func commit() {
        if let v = MediaTime.parse(text) { set(v) } else { text = MediaTime.format(value) }
    }
}

// MARK: - Timeline

struct TimelineScale {
    var width: CGFloat
    var duration: Double
    func x(_ t: Double) -> CGFloat { duration > 0 ? CGFloat(t / duration) * width : 0 }
    func time(_ x: CGFloat) -> Double { width > 0 ? min(duration, max(0, Double(x / width) * duration)) : 0 }
}

struct ThumbnailRow: View {
    let images: [CGImage?]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(images.indices, id: \.self) { i in
                if let img = images[i] {
                    Image(decorative: img, scale: 1).resizable().scaledToFill().frame(maxWidth: .infinity).clipped()
                } else {
                    Color.gray.opacity(0.3).frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color.black.opacity(0.4))
        .accessibilityLabel("Video thumbnail timeline")
    }
}

struct WaveformBars: View {
    let peaks: [Float]
    var tint: Color = Brand.accent
    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty else { return }
            let w = size.width / CGFloat(peaks.count)
            for (i, p) in peaks.enumerated() {
                let h = max(1, CGFloat(p.squareRoot()) * size.height)
                ctx.fill(Path(CGRect(x: CGFloat(i) * w, y: (size.height - h) / 2, width: max(1, w - 0.5), height: h)), with: .color(tint.opacity(0.85)))
            }
        }
        .background(Color.black.opacity(0.08))
        .accessibilityLabel("Audio waveform")
    }
}

/// Scrubbable timeline: content behind, optional trim selection with two end handles, playhead on top.
struct TimelineBar<Background: View, Overlay: View>: View {
    let duration: Double
    @Binding var playhead: Double
    var selection: Binding<MediaSpan>?
    var minGap = 0.05
    var height: CGFloat = 64
    var onScrub: (Double) -> Void = { _ in }
    @ViewBuilder var background: Background
    @ViewBuilder var overlay: (TimelineScale) -> Overlay

    var body: some View {
        GeometryReader { geo in
            let scale = TimelineScale(width: geo.size.width, duration: duration)
            ZStack(alignment: .topLeading) {
                background.frame(width: geo.size.width, height: height).clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { g in
                        let t = scale.time(g.location.x)
                        playhead = t
                        onScrub(t)
                    })
                    .accessibilityLabel("Video timeline. Drag to scrub.")
                if let selection {
                    let s = selection.wrappedValue
                    Color.black.opacity(0.5).frame(width: scale.x(s.start), height: height).allowsHitTesting(false)
                    Color.black.opacity(0.5).frame(width: max(0, geo.size.width - scale.x(s.end)), height: height)
                        .offset(x: scale.x(s.end)).allowsHitTesting(false)
                }
                overlay(scale)
                if let selection {
                    TrimHandle(label: "Trim start", isStart: true, scale: scale, time: Binding(
                        get: { selection.wrappedValue.start },
                        set: { selection.wrappedValue.start = min(max(0, $0), selection.wrappedValue.end - minGap) }), height: height)
                    TrimHandle(label: "Trim end", isStart: false, scale: scale, time: Binding(
                        get: { selection.wrappedValue.end },
                        set: { selection.wrappedValue.end = max(min(duration, $0), selection.wrappedValue.start + minGap) }), height: height)
                }
                Rectangle().fill(.white).frame(width: 2, height: height + 8).shadow(radius: 1)
                    .offset(x: scale.x(playhead) - 1, y: -4).allowsHitTesting(false)
            }
            .coordinateSpace(name: "timeline")
        }
        .frame(height: height)
    }
}

/// Rounded end cap (VID-02); drag it or focus it and use the arrow keys.
struct TrimHandle: View {
    let label: String
    let isStart: Bool
    let scale: TimelineScale
    @Binding var time: Double
    let height: CGFloat
    @FocusState private var focused: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4).fill(Brand.accent)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(focused ? .white : .clear, lineWidth: 2))
            .overlay(Capsule().fill(.white.opacity(0.8)).frame(width: 2, height: 16))
            .frame(width: 12, height: height + 6)
            .offset(x: scale.x(time) - (isStart ? 12 : 0), y: -3)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { time = scale.time($0.location.x + (isStart ? 6 : -6)) })
            .focusable().focused($focused).focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                let step = press.modifiers.contains(.shift) ? 0.1 : 0.01
                switch press.key {
                case .leftArrow, .downArrow: time -= step; return .handled
                case .rightArrow, .upArrow: time += step; return .handled
                default: return .ignored
                }
            }
            .help("Drag the ends to trim")
            .accessibilityLabel(label)
            .accessibilityValue("\(String(format: "%.2f", time)) seconds")
    }
}

/// A draggable span on a timeline row: drag the body to move it, either edge to resize (bleeps, redaction layers).
struct RangeClip: View {
    let scale: TimelineScale
    @Binding var span: MediaSpan
    var selected: Bool
    var tint: Color = Brand.accent
    var minLength = 0.05
    var onSelect: () -> Void = {}
    @State private var origin: MediaSpan?

    var body: some View {
        let width = max(10, scale.x(span.length))
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(tint.opacity(selected ? 0.75 : 0.45))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? .white : tint, lineWidth: selected ? 2 : 1))
            HStack {
                edge.gesture(edgeDrag(start: true))
                Spacer(minLength: 0)
                edge.gesture(edgeDrag(start: false))
            }
        }
        .frame(width: width, height: 26)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline")).onChanged { g in
            onSelect()
            let o = origin ?? span
            origin = o
            let delta = scale.time(abs(g.translation.width)) * (g.translation.width < 0 ? -1 : 1)
            let len = o.length
            let start = min(max(0, o.start + delta), scale.duration - len)
            span = MediaSpan(start: start, end: start + len)
        }.onEnded { _ in origin = nil })
        .onTapGesture { onSelect() }
        .offset(x: scale.x(span.start))
        .help("Drag to move. Drag either end to change duration.")
    }

    private var edge: some View { Rectangle().fill(.white.opacity(0.9)).frame(width: 5).contentShape(Rectangle().inset(by: -3)) }

    private func edgeDrag(start: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { g in
            onSelect()
            let t = scale.time(g.location.x)
            if start { span.start = min(max(0, t), span.end - minLength) } else { span.end = max(min(scale.duration, t), span.start + minLength) }
        }
    }
}

// MARK: - Small shared views

struct HelperText: View {
    let text: String
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

/// A frame of video or a still, with a rectangle layer on top that can be drawn, moved and resized
/// (crop selection, redaction rectangles). Rectangles are in image pixels, origin top-left.
struct RectCanvas: View {
    struct Item: Identifiable { let id: UUID; var rect: CGRect }
    let image: CGImage?
    let imageSize: CGSize
    @Binding var items: [Item]
    @Binding var selected: UUID?
    var allowsDrawing = true
    var aspect: CGFloat?
    var accessibility = "Redaction preview. Draw rectangles to cover areas."
    var emptyHint = "Draw a rectangle over the area to hide."
    var itemLabel = "Redaction rectangle"
    var onCreate: (CGRect) -> Void = { _ in }
    @State private var drawStart: CGPoint?
    @State private var drawRect: CGRect?
    @State private var moveOrigin: CGRect?

    var body: some View {
        GeometryReader { geo in
            let fit = fitRect(in: geo.size)
            let s = fit.width / max(1, imageSize.width)
            ZStack(alignment: .topLeading) {
                Color.black
                if let image { Image(decorative: image, scale: 1).resizable().frame(width: fit.width, height: fit.height).position(x: fit.midX, y: fit.midY) }
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(allowsDrawing ? DragGesture(minimumDistance: 4).onChanged { g in
                        let a = toImage(g.startLocation, fit, s), b = toImage(g.location, fit, s)
                        drawRect = normalized(a, b)
                    }.onEnded { _ in
                        if let r = drawRect, r.width >= 2, r.height >= 2 { onCreate(r) }
                        drawRect = nil
                    } : nil)
                    .onTapGesture { selected = nil }
                ForEach($items) { $item in
                    let r = viewRect(item.rect, fit, s)
                    let isSel = selected == item.id
                    Rectangle().fill(Brand.accent.opacity(isSel ? 0.25 : 0.12))
                        .overlay(Rectangle().stroke(Brand.accent, lineWidth: isSel ? 2 : 1))
                        .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                        .gesture(DragGesture(minimumDistance: 1).onChanged { g in
                            selected = item.id
                            let o = moveOrigin ?? item.rect
                            moveOrigin = o
                            var n = o.offsetBy(dx: g.translation.width / s, dy: g.translation.height / s)
                            n.origin.x = min(max(0, n.origin.x), imageSize.width - n.width)
                            n.origin.y = min(max(0, n.origin.y), imageSize.height - n.height)
                            item.rect = n
                        }.onEnded { _ in moveOrigin = nil })
                        .onTapGesture { selected = item.id }
                        .accessibilityLabel(itemLabel)
                    if isSel { handles(for: $item, fit: fit, s: s) }
                }
                if let d = drawRect {
                    let r = viewRect(d, fit, s)
                    Rectangle().stroke(Brand.accent, style: StrokeStyle(lineWidth: 1, dash: [4])).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                }
                if items.isEmpty && drawRect == nil, !emptyHint.isEmpty {
                    Text(emptyHint).foregroundStyle(.white.opacity(0.8)).padding(6).background(.black.opacity(0.5)).clipShape(Capsule())
                        .position(x: geo.size.width / 2, y: geo.size.height / 2).allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "canvas")
            .clipped()
        }
        .frame(minHeight: 180)
        .accessibilityLabel(accessibility)
    }

    private func fitRect(in size: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: size) }
        let s = min(size.width / imageSize.width, size.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func toImage(_ p: CGPoint, _ fit: CGRect, _ s: CGFloat) -> CGPoint {
        CGPoint(x: min(max(0, (p.x - fit.minX) / s), imageSize.width), y: min(max(0, (p.y - fit.minY) / s), imageSize.height))
    }

    private func viewRect(_ r: CGRect, _ fit: CGRect, _ s: CGFloat) -> CGRect {
        CGRect(x: fit.minX + r.minX * s, y: fit.minY + r.minY * s, width: r.width * s, height: r.height * s)
    }

    private func normalized(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        var r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        if let aspect { r.size.height = r.width / aspect; if r.maxY > imageSize.height { r.size.height = imageSize.height - r.minY; r.size.width = r.height * aspect } }
        return r
    }

    /// Four corner handles; dragging one moves that corner (opposite corner stays put).
    @ViewBuilder private func handles(for item: Binding<Item>, fit: CGRect, s: CGFloat) -> some View {
        let r = viewRect(item.wrappedValue.rect, fit, s)
        ForEach(0..<4, id: \.self) { corner in
            let p = CGPoint(x: corner % 2 == 0 ? r.minX : r.maxX, y: corner < 2 ? r.minY : r.maxY)
            Circle().fill(.white).overlay(Circle().stroke(Brand.accent, lineWidth: 2)).frame(width: 12, height: 12)
                .position(p)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas")).onChanged { g in
                    let cur = item.wrappedValue.rect
                    let anchor = CGPoint(x: corner % 2 == 0 ? cur.maxX : cur.minX, y: corner < 2 ? cur.maxY : cur.minY)
                    let moving = toImage(g.location, fit, s)
                    var n = normalized(anchor, moving)
                    if aspect != nil {
                        // keep the anchor corner fixed when the aspect clamp changed the size
                        if moving.x < anchor.x { n.origin.x = anchor.x - n.width }
                        if moving.y < anchor.y { n.origin.y = anchor.y - n.height }
                    }
                    if n.width >= 2, n.height >= 2 { item.wrappedValue.rect = n }
                })
                .accessibilityLabel("Resize crop " + ["top-left", "top-right", "bottom-left", "bottom-right"][corner])
        }
    }
}
