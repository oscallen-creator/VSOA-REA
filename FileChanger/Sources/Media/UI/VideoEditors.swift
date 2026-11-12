import AVFoundation
import AppKit
import SwiftUI

// Video tool editors: trim, split, join, remove audio, speed, snapshots, crop, redact.

// MARK: - Trim Video (VID-01)

struct VideoTrimEditor: View {
    let files: [URL]
    @StateObject private var session: MediaSession
    init(files: [URL]) { self.files = files; _session = StateObject(wrappedValue: MediaSession(url: files[0])) }

    var body: some View {
        MediaLoadingView(session: session) { info in VideoTrimBody(session: session, info: info) }
            .task { await session.load(thumbnails: 14) }
    }
}

private struct VideoTrimBody: View {
    @ObservedObject var session: MediaSession
    let info: MediaInfo
    @State private var span: MediaSpan
    @Environment(\.toolPanel) private var panel

    init(session: MediaSession, info: MediaInfo) {
        self.session = session; self.info = info
        _span = State(initialValue: MediaSpan(start: 0, end: info.duration))
    }

    private var error: String? {
        do { try MediaRange.validateTrim(start: span.start, end: span.end, duration: info.duration); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(spacing: 10) {
            VideoPreview(session: session)
            PlayheadControls(session: session)
            TimelineBar(duration: info.duration, playhead: $session.time, selection: $span, onScrub: { session.seek(to: $0) }) {
                ThumbnailRow(images: session.thumbnails)
            } overlay: { _ in EmptyView() }
            HStack(spacing: 20) {
                TimeField(label: "Start seconds", value: $span.start, range: 0...max(0, span.end - 0.05))
                TimeField(label: "End seconds", value: $span.end, range: (span.start + 0.05)...info.duration)
                Spacer()
            }
            ToolFooter(primary: "Save Edited Copy", isEnabled: error == nil, message: error, reset: { span = MediaSpan(start: 0, end: info.duration) }) {
                let (s, e, url) = (span.start, span.end, session.url)
                runMediaJob(panel, title: "Trimming", files: [url]) { u, p in try await VideoTrimEngine.trim(u, start: s, end: e, progress: p) }
            }
        }
        .padding([.horizontal, .top], 16)
        .onChange(of: span) { _, s in session.playRange = s }
        .onAppear { session.playRange = span }
        .mediaKeys(session: session)
    }
}

// MARK: - Split Video (VID-10..13)

struct VideoSplitEditor: View {
    let files: [URL]
    @StateObject private var session: MediaSession
    init(files: [URL]) { self.files = files; _session = StateObject(wrappedValue: MediaSession(url: files[0])) }

    var body: some View {
        MediaLoadingView(session: session) { info in VideoSplitBody(session: session, info: info) }
            .task { await session.load(thumbnails: 14) }
    }
}

private struct VideoSplitBody: View {
    @ObservedObject var session: MediaSession
    let info: MediaInfo
    @State private var splits: [Double] = []
    @State private var removed: Set<Int> = []
    @State private var selectedClip: Int?
    @State private var mode: VideoSplitEngine.Mode = .clips
    @State private var notice: String?
    @Environment(\.toolPanel) private var panel

    private var clips: [MediaSpan] { MediaRange.clips(splits: splits, duration: info.duration) }
    private var error: String? {
        do { _ = try VideoSplitEngine.kept(splits: splits, removed: removed, duration: info.duration); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(spacing: 0) {
          ScrollView {
           VStack(spacing: 10) {
            VideoPreview(session: session).frame(height: 150)
            PlayheadControls(session: session)
            TimelineBar(duration: info.duration, playhead: $session.time, onScrub: { t in
                session.seek(to: t)
                selectedClip = clips.firstIndex { t >= $0.start && t < $0.end }     // click a clip to select it
            }) {
                ThumbnailRow(images: session.thumbnails)
            } overlay: { scale in
                ZStack(alignment: .topLeading) {
                    ForEach(clips.indices, id: \.self) { i in
                        if removed.contains(i) || selectedClip == i {
                            Rectangle().fill(removed.contains(i) ? Color.black.opacity(0.65) : Brand.accent.opacity(0.2))
                                .frame(width: scale.x(clips[i].length), height: 64).offset(x: scale.x(clips[i].start)).allowsHitTesting(false)
                        }
                    }
                    ForEach(splits.indices, id: \.self) { i in
                        Capsule().fill(Brand.accent).frame(width: 6, height: 74)
                            .overlay(Capsule().stroke(.white, lineWidth: 1))
                            .offset(x: scale.x(splits[i]) - 3, y: -5)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { g in
                                moveSplit(i, to: scale.time(g.location.x))
                            })
                            .help("Drag split \(i + 1)")
                            .accessibilityLabel("Drag split \(i + 1)")
                    }
                }
            }
            HStack {
                Button("Add Split") { addSplit() }
                Text("\(splits.count) split points").foregroundStyle(.secondary)
                Spacer()
                Picker("Export", selection: $mode) {
                    Text("Separate clips").tag(VideoSplitEngine.Mode.clips)
                    Text("Export One Video").tag(VideoSplitEngine.Mode.merged)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 260).accessibilityIdentifier("splitExportMode")
            }
            ScrollView(.horizontal) {
                HStack {
                    ForEach(clips.indices, id: \.self) { i in clipChip(i) }
                }
            }.frame(height: 34)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(splits.indices, id: \.self) { i in
                        HStack {
                            TimeField(label: "\(i + 1) in seconds", value: Binding(get: { splits[i] }, set: { moveSplit(i, to: $0) }), range: 0...info.duration)
                            Button { session.seek(to: splits[i]) } label: { Image(systemName: "eye") }.help("Preview split \(i + 1)")
                            Button { splits.remove(at: i); removed = []; selectedClip = nil } label: { Image(systemName: "minus.circle") }.help("Remove split \(i + 1)")
                        }.buttonStyle(.borderless)
                    }
                }
            }.frame(maxHeight: 70)
            HelperText(text: removed.isEmpty ? "Remove a clip to join the rest into one video." : "Remove a clip to join the rest into one video, or export separate clips.")
            HelperText(text: "Click a clip in the timeline and press Delete to remove it. Space plays the result.")
           }.padding(.horizontal, 16).padding(.top, 8)
          }
            ToolFooter(primary: mode == .merged ? "Export One Video" : "Save Clips", isEnabled: error == nil, message: notice ?? error,
                       reset: { splits = []; removed = []; selectedClip = nil; notice = nil }) {
                let (s, r, m, url) = (splits, removed, mode, session.url)
                runMediaJob(panel, title: "Splitting video", files: [url]) { u, p in try await VideoSplitEngine.split(u, splits: s, removed: r, mode: m, progress: p) }
            }
        }
        .mediaKeys(session: session) {
            guard let i = selectedClip else { return false }
            toggleRemoved(i); return true
        }
    }

    private func clipChip(_ i: Int) -> some View {
        let gone = removed.contains(i)
        return HStack(spacing: 4) {
            Image(systemName: gone ? "eye.slash" : "eye")
            Text("Clip \(i + 1)").strikethrough(gone)
            Button(gone ? "Restore" : "Remove Clip") { toggleRemoved(i) }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selectedClip == i ? Brand.accent.opacity(0.25) : Color.gray.opacity(0.15)))
        .onTapGesture { selectedClip = i; session.seek(to: clips[i].start) }
        .accessibilityLabel(gone ? "Clip removed at \(MediaTime.format(clips[i].start))" : "\(i + 1) clip")
    }

    private func toggleRemoved(_ i: Int) {
        if removed.contains(i) { removed.remove(i) } else { removed.insert(i) }
        session.skip = removed.map { clips[$0] }
    }

    private func addSplit() {
        let t = (session.time * 100).rounded() / 100
        let candidate = (splits + [t]).sorted()
        do {
            try MediaRange.validateSplits(candidate, duration: info.duration)
            guard Set(splits).isDisjoint(with: [t]) else { throw FileChangerError.failed("Split points must be at least 0.05 seconds apart.") }
            splits = candidate; removed = []; selectedClip = nil; session.skip = []; notice = nil
        } catch { notice = "Add split points at least 0.05 seconds apart, inside the video." }
    }

    private func moveSplit(_ i: Int, to t: Double) {
        let lo = (i > 0 ? splits[i - 1] : 0) + MediaRange.minSplitGap, hi = (i + 1 < splits.count ? splits[i + 1] : info.duration) - MediaRange.minSplitGap
        guard lo <= hi else { return }
        splits[i] = min(max(lo, (t * 100).rounded() / 100), hi)
    }
}

// MARK: - Join Videos (VID-20)

struct VideoJoinEditor: View {
    @State var files: [URL]
    @Environment(\.toolPanel) private var panel

    init(files: [URL]) { _files = State(initialValue: files) }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                HelperText(text: "Videos join in this order. Drag to reorder.")
                Spacer()
                Button("Sort by Name") { files = VideoJoinEngine.sortedByName(files) }
                    .help("Order the files by name, as Finder lists them").accessibilityIdentifier("sortSourcesByName")
            }
            List {
                ForEach(files, id: \.self) { f in
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                        Text(f.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    }
                }
                .onMove { files.move(fromOffsets: $0, toOffset: $1) }
            }.accessibilityIdentifier("orderedSourceList")
            ToolFooter(primary: "Join Videos", isEnabled: files.count >= 2, message: files.count < 2 ? "Select at least two videos to join." : nil) {
                let list = files
                runMediaCombined(panel, title: "Joining videos", files: list) { urls, p in try await VideoJoinEngine.join(urls, progress: p) }
            }
        }.padding([.horizontal, .top], 16)
    }
}

// MARK: - Remove Audio (VID-30)

struct VideoMuteEditor: View {
    let files: [URL]
    @Environment(\.toolPanel) private var panel

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "speaker.slash.fill").font(.system(size: 40)).foregroundStyle(Brand.accent)
            Text(files.count == 1 ? "The audio track will be removed. The video is copied untouched." :
                    "The audio track will be removed from \(files.count) videos. The video is copied untouched.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
            ToolFooter(primary: "Save Edited Copy") {
                runMediaJob(panel, title: "Removing audio", files: files) { u, p in try await VideoMuteEngine.mute(u, progress: p) }
            }
        }.padding(.horizontal, 24)
    }
}

// MARK: - Change Video Speed (VID-40)

struct VideoSpeedEditor: View {
    let files: [URL]
    @StateObject private var session: MediaSession
    init(files: [URL]) { self.files = files; _session = StateObject(wrappedValue: MediaSession(url: files[0])) }

    var body: some View {
        MediaLoadingView(session: session) { info in VideoSpeedBody(session: session, info: info) }
            .task { await session.load() }
    }
}

private struct VideoSpeedBody: View {
    @ObservedObject var session: MediaSession
    let info: MediaInfo
    @State private var speed = 1.0
    @Environment(\.toolPanel) private var panel

    private var error: String? {
        do { try MediaRange.validateSpeed(speed); return nil } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(spacing: 10) {
            VideoPreview(session: session, fallback: "Video preview is unavailable for this file. You can still export at the selected speed.")
            PlayheadControls(session: session)
            HStack {
                Text("Playback speed")
                Slider(value: $speed, in: 0.25...4).accessibilityLabel("Playback speed")
                TextField("", value: $speed, format: .number.precision(.fractionLength(0...2))).frame(width: 56).textFieldStyle(.roundedBorder)
                Text("x")
            }
            HStack {
                ForEach([0.5, 1, 1.5, 2, 4], id: \.self) { v in
                    Button(String(format: "%gx", v)) { speed = v }.buttonStyle(.bordered)
                }
                Spacer()
                Text("New length " + MediaTime.format(info.duration / max(0.25, speed))).foregroundStyle(.secondary).monospacedDigit()
            }
            ToolFooter(primary: "Save Edited Copy", isEnabled: error == nil, message: error, reset: { speed = 1 }) {
                let s = speed
                runMediaJob(panel, title: "Changing speed", files: [session.url]) { u, p in try await VideoSpeedEngine.changeSpeed(u, speed: s, progress: p) }
            }
        }
        .padding([.horizontal, .top], 16)
        .onChange(of: speed) { _, s in session.rate = Float(min(4, max(0.25, s))); if session.isPlaying { session.player.rate = session.rate } }
        .mediaKeys(session: session)
    }
}

// MARK: - Video Snapshots (VID-50)

struct VideoSnapshotEditor: View {
    let files: [URL]
    @StateObject private var session: MediaSession
    init(files: [URL]) { self.files = files; _session = StateObject(wrappedValue: MediaSession(url: files[0])) }

    var body: some View {
        MediaLoadingView(session: session) { info in VideoSnapshotBody(session: session, info: info) }
            .task { await session.load(thumbnails: 14) }
    }
}

private struct VideoSnapshotBody: View {
    @ObservedObject var session: MediaSession
    let info: MediaInfo
    @State private var times: [Double] = []
    @State private var selected: Int?
    @Environment(\.toolPanel) private var panel

    var body: some View {
        VStack(spacing: 10) {
            VideoPreview(session: session)
            PlayheadControls(session: session)
            TimelineBar(duration: info.duration, playhead: $session.time, onScrub: { session.seek(to: $0) }) {
                ThumbnailRow(images: session.thumbnails)
            } overlay: { scale in
                ForEach(times.indices, id: \.self) { i in
                    Rectangle().fill(Brand.accent).frame(width: 3, height: 64).offset(x: scale.x(times[i]) - 1.5).allowsHitTesting(false)
                }
            }
            HStack {
                Button("Add frame") {
                    let t = (session.time * 1000).rounded() / 1000
                    if !times.contains(t) { times.append(t); times.sort() }
                }
                Button("Remove selected frame") { if let s = selected, times.indices.contains(s) { times.remove(at: s); selected = nil } }
                    .disabled(selected == nil)
                Spacer()
                Text("\(times.count) frames").foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack {
                    ForEach(times.indices, id: \.self) { i in
                        Button { selected = i; session.seek(to: times[i]) } label: {
                            Text(MediaTime.format(times[i])).monospacedDigit().padding(.horizontal, 8).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(selected == i ? Brand.accent.opacity(0.3) : Color.gray.opacity(0.15)))
                        }.buttonStyle(.plain).help("Preview frame at \(MediaTime.format(times[i]))")
                    }
                }
            }.frame(height: 30)
            ToolFooter(primary: "Save Snapshots", isEnabled: !times.isEmpty, message: times.isEmpty ? "Add a frame to save." : nil, reset: { times = [] }) {
                let t = times
                runMediaJob(panel, title: "Saving snapshots", files: [session.url]) { u, p in try await VideoSnapshotEngine.snapshots(u, times: t, progress: p) }
            }
        }
        .padding([.horizontal, .top], 16)
        .mediaKeys(session: session) {
            guard let s = selected, times.indices.contains(s) else { return false }
            times.remove(at: s); selected = nil; return true
        }
    }
}

// MARK: - Crop Video (VID-60)

struct VideoCropEditor: View {
    let files: [URL]
    @StateObject private var session: MediaSession
    @State private var frame: CGImage?
    init(files: [URL]) { self.files = files; _session = StateObject(wrappedValue: MediaSession(url: files[0])) }

    var body: some View {
        MediaLoadingView(session: session) { info in VideoCropBody(session: session, info: info, frame: frame) }
            .task {
                await session.load()
                frame = try? await MediaThumbnails.frame(url: files[0], at: 0, exact: false)
            }
    }
}

private struct VideoCropBody: View {
    @ObservedObject var session: MediaSession
    let info: MediaInfo
    let frame: CGImage?
    @State private var items: [RectCanvas.Item]
    @State private var selected: UUID?
    @State private var aspect: CGFloat?
    @State private var maxHeight: CGFloat = 0     // 0 = original
    @Environment(\.toolPanel) private var panel

    init(session: MediaSession, info: MediaInfo, frame: CGImage?) {
        self.session = session; self.info = info; self.frame = frame
        let id = UUID()
        _items = State(initialValue: [.init(id: id, rect: CGRect(origin: .zero, size: info.displaySize))])
        _selected = State(initialValue: id)
    }

    private var rect: CGRect { items.first?.rect ?? .zero }
    private var error: String? {
        do { _ = try VideoCropEngine.validate(rect, frame: info.displaySize); return nil } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(spacing: 10) {
            RectCanvas(image: frame, imageSize: info.displaySize, items: $items, selected: $selected, allowsDrawing: false,
                       aspect: aspect, accessibility: "Crop selection. Drag to reposition.", emptyHint: "", itemLabel: "Crop selection. Drag to reposition.")
            HStack {
                ForEach([("Free", nil), ("1:1", 1.0), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("4:3", 4.0 / 3), ("3:4", 3.0 / 4)] as [(String, Double?)], id: \.0) { chip in
                    Button(chip.0) { applyAspect(chip.1.map { CGFloat($0) }) }
                        .buttonStyle(.bordered).tint(aspect == chip.1.map { CGFloat($0) } ? Brand.accent : nil)
                }
                Spacer()
            }
            HStack(spacing: 14) {
                field("X", \.origin.x); field("Y", \.origin.y)
                field("Width", \.size.width).accessibilityLabel("Crop width in pixels")
                field("Height", \.size.height).accessibilityLabel("Crop height in pixels")
                Text("px").foregroundStyle(.secondary)
                Spacer()
                Picker("Maximum height", selection: $maxHeight) {
                    Text("Original").tag(CGFloat(0)); Text("2160p").tag(CGFloat(2160)); Text("1080p").tag(CGFloat(1080)); Text("720p").tag(CGFloat(720))
                }.frame(width: 210)
            }
            ToolFooter(primary: "Save Edited Copy", isEnabled: error == nil, message: error,
                       reset: { items = [.init(id: items.first?.id ?? UUID(), rect: CGRect(origin: .zero, size: info.displaySize))]; aspect = nil }) {
                let (r, mh) = (rect, maxHeight)
                runMediaJob(panel, title: "Cropping", files: [session.url]) { u, p in try await VideoCropEngine.crop(u, rect: r, maxHeight: mh > 0 ? mh : nil, progress: p) }
            }
        }.padding([.horizontal, .top], 16)
    }

    private func field(_ title: String, _ key: WritableKeyPath<CGRect, CGFloat>) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            TextField("", value: Binding(get: { Int(rect[keyPath: key].rounded()) }, set: { v in
                if !items.isEmpty { items[0].rect[keyPath: key] = CGFloat(v) }
            }), format: .number).frame(width: 64).textFieldStyle(.roundedBorder)
        }
    }

    private func applyAspect(_ a: CGFloat?) {
        aspect = a
        guard let a, !items.isEmpty else { return }
        var r = items[0].rect
        r.size.height = r.width / a
        if r.maxY > info.displaySize.height { r.size.height = info.displaySize.height - r.minY; r.size.width = r.height * a }
        items[0].rect = r
    }
}

// MARK: - Redact Video (VID-80..82)

struct VideoRedactEditor: View {
    let files: [URL]
    @StateObject private var session: MediaSession
    init(files: [URL]) { self.files = files; _session = StateObject(wrappedValue: MediaSession(url: files[0])) }

    var body: some View {
        MediaLoadingView(session: session) { info in VideoRedactBody(session: session, info: info) }
            .task { await session.load() }
    }
}

private struct RedactionLayer: Identifiable {
    let id = UUID()
    var rect: CGRect
    var span: MediaSpan
}

private struct VideoRedactBody: View {
    @ObservedObject var session: MediaSession
    let info: MediaInfo
    @State private var layers: [RedactionLayer] = []
    @State private var selected: UUID?
    @State private var style: VideoRedactionStyle = .solid
    @State private var frame: CGImage?
    @Environment(\.toolPanel) private var panel

    private var error: String? {
        do { try VideoRedactEngine.validate(layers.map { VideoRedaction(rect: $0.rect, start: $0.span.start, end: $0.span.end) },
                                            frame: info.displaySize, duration: info.duration); return nil }
        catch { return layers.isEmpty ? nil : error.localizedDescription }
    }

    private var canvasItems: Binding<[RectCanvas.Item]> {
        Binding(get: {
            layers.filter { session.time >= $0.span.start && session.time <= $0.span.end || $0.id == selected }.map { .init(id: $0.id, rect: $0.rect) }
        }, set: { new in
            for n in new { if let i = layers.firstIndex(where: { $0.id == n.id }) { layers[i].rect = n.rect } }
        })
    }

    var body: some View {
        VStack(spacing: 8) {
            RectCanvas(image: frame, imageSize: info.displaySize, items: canvasItems, selected: $selected, onCreate: { r in
                let l = RedactionLayer(rect: r, span: MediaSpan(start: 0, end: info.duration))
                layers.append(l); selected = l.id
            })
            HStack {
                Slider(value: Binding(get: { session.time }, set: { session.seek(to: $0) }), in: 0...info.duration)
                PlayheadControls(session: session, showFrameSteps: true)
            }
            HStack {
                Picker("Style", selection: $style) {
                    Text("Solid").tag(VideoRedactionStyle.solid); Text("Blur").tag(VideoRedactionStyle.blur)
                }.pickerStyle(.segmented).frame(width: 180)
                HelperText(text: "Blur softens details. Use Solid for sensitive information.")
                Spacer()
                Button("Add redaction at playhead") {
                    let w = info.displaySize.width / 3, h = info.displaySize.height / 4
                    let l = RedactionLayer(rect: CGRect(x: (info.displaySize.width - w) / 2, y: (info.displaySize.height - h) / 2, width: w, height: h),
                                           span: MediaSpan(start: session.time, end: min(info.duration, session.time + 2)))
                    layers.append(l); selected = l.id
                }.disabled(session.time >= info.duration - 0.05)
            }
            Text("Redactions").font(.caption.bold()).frame(maxWidth: .infinity, alignment: .leading)
            if !layers.isEmpty {
                // One row per layer; drag a bar to move its time range, drag its ends to resize.
                // Fixed heights sized to content (ScrollViews are greedy): the panel is 560 pt, so two bars and
                // one and a half rows show; more layers scroll.
                let barsHeight = CGFloat(layers.count) * 30 + 6
                ScrollView {
                TimelineBar(duration: info.duration, playhead: $session.time, height: barsHeight, onScrub: { session.seek(to: $0) }) {
                    Color.gray.opacity(0.15)
                } overlay: { scale in
                    ForEach($layers) { $l in
                        RangeClip(scale: scale, span: $l.span, selected: selected == l.id, onSelect: { selected = l.id })
                            .offset(y: CGFloat(layers.firstIndex { $0.id == l.id } ?? 0) * 30 + 3)
                            .accessibilityLabel("redactionTrack-\(l.id.uuidString)")
                    }
                }
                }.frame(height: min(barsHeight, 66))
            }
            ScrollView {
                VStack(spacing: 4) {
                    if layers.isEmpty { HelperText(text: "Drag to add") }
                    ForEach(layers.indices, id: \.self) { i in layerRow(i) }
                }
            }.frame(height: layers.isEmpty ? 18 : min(CGFloat(layers.count) * 34 - 4, 48))
            ToolFooter(primary: "Save Redacted Copy", isEnabled: !layers.isEmpty && error == nil,
                       message: layers.isEmpty ? "Draw rectangles to cover areas." : error, reset: { layers = []; selected = nil }) {
                let items = layers.map { VideoRedaction(rect: $0.rect, start: $0.span.start, end: $0.span.end) }, st = style
                runMediaJob(panel, title: "Redacting video", files: [session.url]) { u, p in try await VideoRedactEngine.redact(u, items: items, style: st, progress: p) }
            }
        }
        .padding([.horizontal, .top], 16)
        .task(id: Int(session.time * 4)) { frame = try? await MediaThumbnails.frame(url: session.url, at: session.time, maxSize: CGSize(width: 1280, height: 720), exact: false) }
        .mediaKeys(session: session) {
            guard let s = selected else { return false }
            layers.removeAll { $0.id == s }; selected = nil; return true
        }
    }

    private func layerRow(_ i: Int) -> some View {
        let id = layers[i].id
        return HStack(spacing: 8) {
            Text("Redaction layer \(i + 1)").frame(width: 120, alignment: .leading).font(.caption)
            TimeField(label: "Start seconds", value: $layers[i].span.start, range: 0...max(0, layers[i].span.end - 0.05))
            TimeField(label: "End seconds", value: $layers[i].span.end, range: (layers[i].span.start + 0.05)...info.duration)
            Button("Show for Entire Video") { layers[i].span = MediaSpan(start: 0, end: info.duration) }.controlSize(.small)
            Button { layers.removeAll { $0.id == id }; if selected == id { selected = nil } } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete Redaction")
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected == id ? Brand.accent.opacity(0.18) : .clear))
        .onTapGesture { selected = id; session.seek(to: layers[i].span.start) }
    }
}
