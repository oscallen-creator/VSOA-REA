import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import PDFKit

enum ConvFixtures {
    static func dir(_ name: String) throws -> URL {
        let d = Fixtures.scratch.appendingPathComponent("conv-\(name)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func png(_ url: URL, w: Int = 64, h: Int = 48, alpha: Bool = false) throws {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !alpha { ctx.setFillColor(CGColor(red: 1, green: 0.3, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        ctx.setFillColor(CGColor(red: 0, green: 0.2, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 8, y: 8, width: w / 2, height: h / 2))
        let type = url.pathExtension == "jpg" ? "public.jpeg" : "public.png"
        let d = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
        _ = CGImageDestinationFinalize(d)
    }

    static func wav(_ url: URL, seconds: Double = 0.5) throws {
        var f: AVAudioFile? = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
                                                                          AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        let n = Int(44100 * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: f!.processingFormat, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { buf.floatChannelData![0][i] = Float(0.4 * sin(Double(i) * 0.06)) }
        try f!.write(from: buf); f = nil
    }

    static func mp4(_ url: URL, seconds: Double = 1, fps: Int32 = 10, w: Int = 160, h: Int = 96) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for i in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h { for x in 0..<w { let o = y * CVPixelBufferGetBytesPerRow(pb) + x * 4
                base[o] = UInt8((x * 3 + i * 20) % 256); base[o + 1] = UInt8((y * 5) % 256); base[o + 2] = UInt8(i * 25 % 256); base[o + 3] = 255 } }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw TestFailure(description: "fixture video failed: \(String(describing: writer.error))") }
    }

    /// Plain text PDF with `pages` pages, one line each.
    static func pdf(_ url: URL, pages: Int, text: String = "Page") throws {
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for i in 1...pages {
            ctx.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(text) number \(i) of the sample document", attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)]) as CFAttributedString)
            ctx.textPosition = CGPoint(x: 20, y: 100); CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    static func files(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }
}

extension TestSuites {
    static var conversionSuites: [Suite] {
        let noProgress: ProgressHandler = { _ in }
        func target(_ f: ConversionFormat) -> ConversionTarget { Conversions.target(f) }
        return [
            Suite(name: "conversion matrix", tests: [
                ("47 formats in inventory order", {
                    try expectEqual(ConversionFormat.allCases.count, 47)
                    try expectEqual(ConversionFormat.allCases.prefix(10).map(\.rawValue), ["jpg", "png", "webp", "heic", "tiff", "svg", "avif", "bmp", "raw", "pdf"])
                    try expectEqual(ConversionFormat.gzip.rawValue, "gz")
                }),
                ("matrix rows", {
                    typealias F = ConversionFormat
                    try expectEqual(ConversionMatrix.targets(from: .jpg), [.png, .webp, .heic, .tiff, .avif, .bmp, .pdf])
                    try expectEqual(ConversionMatrix.targets(from: .svg), [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf])
                    try expectEqual(ConversionMatrix.targets(from: .pdf), [.docx, .pages, .pptx, .xlsx, .jpg, .png, .svg, .epub, .txt, .md])
                    try expectEqual(ConversionMatrix.targets(from: .mp3), [.m4a, .wav, .flac, .ogg, .opus, .aiff, .wma])
                    try expectEqual(ConversionMatrix.targets(from: .mp4), [.mov, .mkv, .webm, .avi, .wmv, .gif, .mp3])
                    try expectEqual(ConversionMatrix.targets(from: .gif), [.mp4, .mov, .mkv, .webm, .avi, .wmv])
                    try expectEqual(ConversionMatrix.targets(from: .docx), [.pages, .pdf, .txt, .md, .html, .epub, .png, .jpg])
                    try expectEqual(ConversionMatrix.targets(from: .rtf), [.docx, .pages, .pdf, .txt, .md, .html, .epub, .png, .jpg])
                    try expectEqual(ConversionMatrix.targets(from: .txt), [.docx, .pages, .pdf, .md, .html, .epub, .jpg, .png])
                    try expectEqual(ConversionMatrix.targets(from: .pptx), [.pdf, .jpg, .png])
                    try expectEqual(ConversionMatrix.targets(from: .epub), [.pdf, .docx, .pages, .txt, .md, .html])
                    try expectEqual(ConversionMatrix.targets(from: .xlsx), [.ods, .csv, .tsv, .pdf])
                    try expectEqual(ConversionMatrix.targets(from: .xls), [.xlsx, .ods, .csv, .tsv, .pdf])
                    try expectEqual(ConversionMatrix.targets(from: .srt), [.vtt, .txt])
                    try expectEqual(ConversionMatrix.targets(from: .rar), [.zip, .tar, .gzip])
                    try expectEqual(ConversionMatrix.targets(from: .html), [])
                    for f in F.allCases { try expect(!ConversionMatrix.targets(from: f).contains(where: { $0.isInputOnly })) }
                }),
                ("extension aliases", {
                    try expectEqual(ConversionFormat.of(extension: "JPEG"), .jpg)
                    try expectEqual(ConversionFormat.of(extension: "heif"), .heic)
                    try expectEqual(ConversionFormat.of(extension: "m4v"), .mp4)
                    try expectEqual(ConversionFormat.of(extension: "markdown"), .md)
                    try expectEqual(ConversionFormat.of(extension: "tgz"), .gzip)
                    try expectEqual(ConversionFormat.of(extension: "cr2"), .raw)
                    try expectEqual(Conversions.format(of: URL(fileURLWithPath: "/a/b.tar.gz")), .gzip)
                }),
                ("targets for files are common and available", {
                    let png = URL(fileURLWithPath: "/a/x.png"), jpg = URL(fileURLWithPath: "/a/y.jpg")
                    let t = Conversions.targets(for: [png, jpg]).map(\.ext)
                    try expect(t.contains("tiff") && t.contains("pdf") && !t.contains("png") && !t.contains("jpg"), "\(t)")
                    try expect(!t.contains("webp") || ExternalTool.cwebp.isAvailable || ExternalTool.ffmpeg.isAvailable)
                    try expect(!t.contains("avif") || ExternalTool.ffmpeg.isAvailable)
                    try expect(Conversions.targets(for: [png, URL(fileURLWithPath: "/a/z.mp4")]).isEmpty)
                    try expect(Conversions.targets(for: [URL(fileURLWithPath: "/a/z.xyz")]).isEmpty)
                    if !ExternalTool.ffmpeg.isAvailable {
                        try expect(!Conversions.targets(for: [URL(fileURLWithPath: "/a/z.mp3")]).map(\.ext).contains("ogg"))
                        try expect(Conversions.targets(for: [URL(fileURLWithPath: "/a/z.mp3")]).map(\.ext).contains("flac"))
                    }
                }),
                ("compatibility captions", {
                    try expectEqual(Conversions.caption(for: .png), "Input and output format.")
                    try expectEqual(Conversions.caption(for: .html), "Output-only format.")
                    try expectEqual(Conversions.caption(for: .raw), "Input-only format.")
                    try expectEqual(Conversions.caption(for: .pages), "Unavailable for conversion.")
                    try expectEqual(Conversions.caption(for: .xls), "Unavailable for conversion.")
                    if !ExternalTool.cwebp.isAvailable && !ExternalTool.ffmpeg.isAvailable {
                        try expectEqual(Conversions.caption(for: .webp), "Unavailable for conversion.")
                        try expect(Conversions.unavailableHint(.webp) != nil)
                    }
                    try expect(Conversions.targets(for: [URL(fileURLWithPath: "/a/x.xls")]).isEmpty)
                    try expect(Conversions.unavailableHint(.pages) != nil)
                }),
                ("output naming", {
                    let d = try ConvFixtures.dir("naming")
                    let src = d.appendingPathComponent("photo.png")
                    try Data().write(to: src)
                    try expectEqual(Conversions.outputURL(for: src, ext: "jpg").lastPathComponent, "photo.jpg")
                    try expectEqual(Conversions.outputURL(for: d.appendingPathComponent("a.tar.gz"), ext: "zip").lastPathComponent, "a.zip")
                    try Data().write(to: d.appendingPathComponent("photo.jpg"))
                    try expectEqual(Conversions.outputURL(for: src, ext: "jpg").lastPathComponent, "photo 2.jpg")
                }),
            ]),
            Suite(name: "conversion profiles", tests: [
                ("defaults and persistence", {
                    let ud = UserDefaults(suiteName: "conv-test-\(UUID().uuidString)")!
                    try expectEqual(ConversionProfile.string(.jpg, .quality, defaults: ud), "balanced")
                    try expectEqual(ConversionProfile.string(.mov, .quality, defaults: ud), "high")
                    try expectEqual(ConversionProfile.int(.m4a, .audioBitrate, defaults: ud), 256)
                    try expectEqual(ConversionProfile.int(.gif, .gifFrameRate, defaults: ud), 15)
                    try expectEqual(ConversionProfile.int(.gif, .gifMaxWidth, defaults: ud), 960)
                    try expect(ConversionProfile.bool(.jpg, .preserveMetadata, defaults: ud))
                    ConversionProfile.set("192", .m4a, .audioBitrate, defaults: ud)
                    try expectEqual(ud.string(forKey: "conversionProfile.m4a.audioBitrate"), "192")
                    try expectEqual(ConversionProfile.int(.m4a, .audioBitrate, defaults: ud), 192)
                    ConversionProfile.restoreDefaults(.m4a, defaults: ud)
                    try expectEqual(ConversionProfile.int(.m4a, .audioBitrate, defaults: ud), 256)
                    try expect(ConversionProfile.params(for: .bmp).isEmpty)
                    try expectEqual(ConversionProfile.params(for: .zip), [.compression])
                }),
            ]),
            Suite(name: "conversion images", tests: [
                ("png to jpg flattens alpha and keeps size", {
                    let d = try ConvFixtures.dir("img")
                    let src = d.appendingPathComponent("a.png"); try ConvFixtures.png(src, alpha: true)
                    let out = try await Conversions.convert(src, to: target(.jpg), progress: noProgress)
                    try expectEqual(out.lastPathComponent, "a.jpg")
                    let s = CGImageSourceCreateWithURL(out as CFURL, nil)!
                    let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as! [CFString: Any]
                    try expectEqual(p[kCGImagePropertyPixelWidth] as? Int, 64)
                    try expectEqual(CGImageSourceGetType(s) as String?, "public.jpeg")
                }),
                ("png to tiff heic bmp pdf", {
                    let d = try ConvFixtures.dir("img2")
                    let src = d.appendingPathComponent("a.png"); try ConvFixtures.png(src)
                    for f in [ConversionFormat.tiff, .bmp, .heic, .pdf] {
                        let out = try await Conversions.convert(src, to: target(f), progress: noProgress)
                        try expect((try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int ?? 0) > 100, "\(f)")
                    }
                    try expectEqual(PDFDocument(url: d.appendingPathComponent("a.pdf"))?.pageCount, 1)
                }),
                ("svg rasterises", {
                    let d = try ConvFixtures.dir("svg")
                    let src = d.appendingPathComponent("v.svg")
                    try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"><rect width="100" height="50" fill="red"/></svg>"#.utf8).write(to: src)
                    let out = try await Conversions.convert(src, to: target(.png), progress: noProgress)
                    let s = CGImageSourceCreateWithURL(out as CFURL, nil)!
                    let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as! [CFString: Any]
                    try expect((p[kCGImagePropertyPixelWidth] as? Int ?? 0) >= 100)
                }),
            ]),
            Suite(name: "conversion media", tests: [
                ("wav to m4a, flac, aiff", {
                    let d = try ConvFixtures.dir("aud")
                    let src = d.appendingPathComponent("t.wav"); try ConvFixtures.wav(src)
                    for f in [ConversionFormat.m4a, .flac, .aiff] {
                        let out = try await Conversions.convert(src, to: target(f), progress: noProgress)
                        let file = try AVAudioFile(forReading: out)
                        try expect(abs(Double(file.length) / file.processingFormat.sampleRate - 0.5) < 0.1, "\(f) duration")
                    }
                }),
                ("flac back to wav at 24-bit setting", {
                    let d = try ConvFixtures.dir("aud2")
                    let src = d.appendingPathComponent("t.wav"); try ConvFixtures.wav(src)
                    let flac = try await Conversions.convert(src, to: target(.flac), progress: noProgress)
                    ConversionProfile.set("bit24", .wav, .audioSampleDepth)
                    defer { ConversionProfile.restoreDefaults(.wav) }
                    try FileManager.default.removeItem(at: src)
                    let out = try await Conversions.convert(flac, to: target(.wav), progress: noProgress)
                    let f = try AVAudioFile(forReading: out)
                    try expectEqual(f.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
                }),
                ("mp4 to gif and gif to mov", {
                    let d = try ConvFixtures.dir("vid")
                    let src = d.appendingPathComponent("c.mp4"); try await ConvFixtures.mp4(src)
                    let gif = try await Conversions.convert(src, to: target(.gif), progress: noProgress)
                    let s = CGImageSourceCreateWithURL(gif as CFURL, nil)!
                    try expect(CGImageSourceGetCount(s) >= 5, "frames \(CGImageSourceGetCount(s))")
                    let mov = try await Conversions.convert(gif, to: target(.mov), progress: noProgress)
                    let dur = try await AVURLAsset(url: mov).load(.duration).seconds
                    try expect(dur > 0.5 && dur < 2.5, "duration \(dur)")
                }),
                ("mp4 to mov export", {
                    let d = try ConvFixtures.dir("vid2")
                    let src = d.appendingPathComponent("c.mp4"); try await ConvFixtures.mp4(src)
                    let mov = try await Conversions.convert(src, to: target(.mov), progress: noProgress)
                    let tracks = try await AVURLAsset(url: mov).loadTracks(withMediaType: .video)
                    try expectEqual(tracks.count, 1)
                }),
                ("ffmpeg arguments", {
                    let a = ConversionMediaEngine.ffmpegArguments(input: URL(fileURLWithPath: "/i.wav"), output: URL(fileURLWithPath: "/o.mp3"), from: .wav, to: .mp3)
                    try expect(a.contains("libmp3lame") && a.contains("256k") && a.last == "/o.mp3")
                    let w = ConversionMediaEngine.ffmpegArguments(input: URL(fileURLWithPath: "/i.mkv"), output: URL(fileURLWithPath: "/o.webm"), from: .mkv, to: .webm)
                    try expect(w.contains("libvpx-vp9") && w.contains("libopus"))
                    let g = ConversionMediaEngine.ffmpegArguments(input: URL(fileURLWithPath: "/i.mkv"), output: URL(fileURLWithPath: "/o.gif"), from: .mkv, to: .gif)
                    try expect(g.joined(separator: " ").contains("fps=15,scale='min(960,iw)':-2"))
                }),
            ]),
            Suite(name: "conversion documents", tests: [
                ("md to html", {
                    let d = try ConvFixtures.dir("md")
                    let src = d.appendingPathComponent("n.md")
                    try Data("# Title\n\nHello **bold** and `code`.\n\n- a\n- b\n\n| x | y |\n|---|---|\n| 1 | 2 |\n".utf8).write(to: src)
                    let out = try await Conversions.convert(src, to: target(.html), progress: noProgress)
                    let html = try String(contentsOf: out)
                    try expect(html.contains("<h1>Title</h1>") && html.contains("<strong>bold</strong>") && html.contains("<li>a</li>") && html.contains("<td>2</td>"), html)
                }),
                ("rtf to docx and docx to pdf", {
                    let d = try ConvFixtures.dir("rtf")
                    let src = d.appendingPathComponent("r.rtf")
                    let a = NSAttributedString(string: "Hello document world\nSecond paragraph", attributes: [.font: NSFont.systemFont(ofSize: 12)])
                    try a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: src)
                    let docx = try await Conversions.convert(src, to: target(.docx), progress: noProgress)
                    let entries = try ConvZip.read(docx)
                    try expect(entries.contains { $0.name == "word/document.xml" })
                    let pdf = try await Conversions.convert(docx, to: target(.pdf), progress: noProgress)
                    try expect(PDFDocument(url: pdf)?.string?.contains("Hello document world") == true)
                    let md = try await Conversions.convert(docx, to: target(.md), progress: noProgress)
                    try expect(try String(contentsOf: md).contains("Second paragraph"))
                }),
                ("txt to epub to txt", {
                    let d = try ConvFixtures.dir("epub")
                    let src = d.appendingPathComponent("b.txt")
                    try Data("Chapter text one.\n\nMore words here.".utf8).write(to: src)
                    let epub = try await Conversions.convert(src, to: target(.epub), progress: noProgress)
                    let entries = try ConvZip.read(epub)
                    try expectEqual(entries.first?.name, "mimetype")
                    try expect(entries.contains { $0.name == "EPUB/nav.xhtml" } && entries.contains { $0.name == "EPUB/chapter-0001.xhtml" })
                    let txt = try await Conversions.convert(epub, to: target(.txt), progress: noProgress)
                    try expect(try String(contentsOf: txt).contains("More words here"))
                }),
                ("pdf to txt, images, pptx, docx", {
                    let d = try ConvFixtures.dir("pdf")
                    let src = d.appendingPathComponent("p.pdf"); try ConvFixtures.pdf(src, pages: 2)
                    let txt = try await Conversions.convert(src, to: target(.txt), progress: noProgress)
                    try expect(try String(contentsOf: txt).contains("number 2"))
                    let png = try await Conversions.convert(src, to: target(.png), progress: noProgress)
                    try expectEqual(ConvFixtures.files(in: png), ["Page 001.png", "Page 002.png"])
                    let pptx = try await Conversions.convert(src, to: target(.pptx), progress: noProgress)
                    try expectEqual(try ConvZip.read(pptx).filter { $0.name.hasPrefix("ppt/slides/slide") && $0.name.hasSuffix(".xml") }.count, 2)
                    let docx = try await Conversions.convert(src, to: target(.docx), progress: noProgress)
                    try expect(try ConvZip.read(docx).contains { $0.name == "word/document.xml" })
                }),
                ("md to docx keeps headings and tables", {
                    let d = try ConvFixtures.dir("mddocx")
                    let src = d.appendingPathComponent("n.md")
                    try Data("# Big Title\n\nIntro paragraph.\n\n| x | y |\n|---|---|\n| 1 | 2 |\n".utf8).write(to: src)
                    let out = try await Conversions.convert(src, to: target(.docx), progress: noProgress)
                    let xml = String(decoding: ConvZip.entry(try ConvZip.read(out), "word/document.xml") ?? Data(), as: UTF8.self)
                    try expect(xml.contains("<w:tbl>"), "table missing")
                    try expect(xml.contains("w:pStyle w:val=\"Heading1\""), "heading styling missing")
                }),
                ("markdown from attributed headings", {
                    let a = NSMutableAttributedString(string: "Big\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)])
                    a.append(NSAttributedString(string: "body text here and more body text\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
                    let md = ConversionMarkdown.markdown(from: a)
                    try expect(md.hasPrefix("# Big"), md)
                }),
            ]),
            Suite(name: "conversion spreadsheets", tests: [
                ("csv to xlsx to csv round trip", {
                    let d = try ConvFixtures.dir("sheet")
                    let src = d.appendingPathComponent("s.csv")
                    let csv = "name,qty,note\nApple,3,\"a, b\"\nPear,12.5,\"say \"\"hi\"\"\"\n"
                    try Data(csv.utf8).write(to: src)
                    let xlsx = try await Conversions.convert(src, to: target(.xlsx), progress: noProgress)
                    try expect(try ConvZip.read(xlsx).contains { $0.name == "xl/worksheets/sheet1.xml" })
                    try FileManager.default.removeItem(at: src)
                    let back = try await Conversions.convert(xlsx, to: target(.csv), progress: noProgress)
                    try expectEqual(try String(contentsOf: back), csv)
                    let ods = try await Conversions.convert(xlsx, to: target(.ods), progress: noProgress)
                    let tsv = try await Conversions.convert(ods, to: target(.tsv), progress: noProgress)
                    try expectEqual(try String(contentsOf: tsv), "name\tqty\tnote\nApple\t3\ta, b\nPear\t12.5\t\"say \"\"hi\"\"\"\n")
                    let pdf = try await Conversions.convert(xlsx, to: target(.pdf), progress: noProgress)
                    try expect(PDFDocument(url: pdf)?.string?.contains("Pear") == true)
                }),
            ]),
            Suite(name: "conversion subtitles and archives", tests: [
                ("srt to vtt to srt and txt", {
                    let d = try ConvFixtures.dir("sub")
                    let src = d.appendingPathComponent("s.srt")
                    try Data("1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\n<i>World</i>\n".utf8).write(to: src)
                    let vtt = try await Conversions.convert(src, to: target(.vtt), progress: noProgress)
                    let v = try String(contentsOf: vtt)
                    try expect(v.hasPrefix("WEBVTT") && v.contains("00:00:01.000 --> 00:00:02.500"), v)
                    try FileManager.default.removeItem(at: src)
                    let srt = try await Conversions.convert(vtt, to: target(.srt), progress: noProgress)
                    try expect(try String(contentsOf: srt).contains("00:00:03,000 --> 00:00:04,000"))
                    let txt = try await Conversions.convert(vtt, to: target(.txt), progress: noProgress)
                    try expectEqual(try String(contentsOf: txt), "Hello\nWorld\n")
                }),
                ("subtitle errors", {
                    let d = try ConvFixtures.dir("sub2")
                    let bad = d.appendingPathComponent("b.srt"); try Data("nothing here".utf8).write(to: bad)
                    do { _ = try await Conversions.convert(bad, to: target(.vtt), progress: noProgress); throw TestFailure(description: "no error") }
                    catch let e as FileChangerError { try expectEqual(e.localizedDescription, "No valid subtitle cues were found.") }
                    let bin = d.appendingPathComponent("c.srt"); try Data([0xFF, 0xFE, 0xFD, 0x80]).write(to: bin)
                    do { _ = try await Conversions.convert(bin, to: target(.vtt), progress: noProgress); throw TestFailure(description: "no error") }
                    catch let e as FileChangerError { try expectEqual(e.localizedDescription, "The subtitle file is not valid UTF-8.") }
                }),
                ("zip to tar to gzip and extract", {
                    let d = try ConvFixtures.dir("arc")
                    let folder = d.appendingPathComponent("stuff"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Data("hello".utf8).write(to: folder.appendingPathComponent("a.txt"))
                    let zip = d.appendingPathComponent("stuff.zip")
                    _ = try await ConvProcess.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", folder.path, zip.path])
                    let tar = try await Conversions.convert(zip, to: target(.tar), progress: noProgress)
                    let gz = try await Conversions.convert(tar, to: target(.gzip), progress: noProgress)
                    try expectEqual(gz.lastPathComponent, "stuff.gz")
                    let out = try await ConversionArchiveEngine.extractBeside(gz, progress: noProgress)
                    let found = FileManager.default.enumerator(atPath: out.path)?.allObjects.compactMap { $0 as? String } ?? []
                    try expect(found.contains { $0.hasSuffix("a.txt") }, "\(found)")
                    let back = try await Conversions.convert(gz, to: target(.zip), progress: noProgress)
                    try expect(back.pathExtension == "zip")
                }),
            ]),
            Suite(name: "conversion pdf tools", tests: [
                ("merge then split", {
                    let d = try ConvFixtures.dir("tools")
                    let a = d.appendingPathComponent("a.pdf"), b = d.appendingPathComponent("b.pdf")
                    try ConvFixtures.pdf(a, pages: 2); try ConvFixtures.pdf(b, pages: 3)
                    let merged = try await ConversionPDFTools.merge([a, b], progress: noProgress)
                    try expectEqual(PDFDocument(url: merged)?.pageCount, 5)
                    let folder = try await ConversionPDFTools.split(merged, mode: .everyPage, progress: noProgress)
                    try expectEqual(ConvFixtures.files(in: folder), (1...5).map { String(format: "Page %03d.pdf", $0) })
                    let ranged = try await ConversionPDFTools.split(a.deletingLastPathComponent().appendingPathComponent(merged.lastPathComponent), mode: .ranges("1-2, 5"), progress: noProgress)
                    try expectEqual(ConvFixtures.files(in: ranged), ["Page 005.pdf", "Pages 001-002.pdf"])
                    try expectEqual(try ConversionPDFTools.parseRanges("2-, 1", pageCount: 4), [2...4, 1...1])
                }),
                ("organize reorders and rotates", {
                    let d = try ConvFixtures.dir("org")
                    let a = d.appendingPathComponent("a.pdf"); try ConvFixtures.pdf(a, pages: 3)
                    let out = try await ConversionPDFTools.organize(a, pages: [.init(original: 2), .init(original: 0, rotation: 90), .init(original: 1)], equalWidths: false, progress: noProgress)
                    let doc = PDFDocument(url: out)!
                    try expect(doc.page(at: 0)!.string!.contains("number 3"))
                    try expectEqual(doc.page(at: 1)!.rotation, 90)
                }),
                ("create pdf from image and text", {
                    let d = try ConvFixtures.dir("create")
                    let img = d.appendingPathComponent("i.png"); try ConvFixtures.png(img)
                    let txt = d.appendingPathComponent("t.txt"); try Data("some text".utf8).write(to: txt)
                    let out = try await ConversionPDFTools.createPDF([img, txt], progress: noProgress)
                    try expectEqual(PDFDocument(url: out)?.pageCount, 2)
                }),
                ("pdf/a conversion", {
                    let d = try ConvFixtures.dir("pdfa")
                    let a = d.appendingPathComponent("a.pdf"); try ConvFixtures.pdf(a, pages: 1)
                    let out = try await ConversionPDFTools.convertPDFA(a, progress: noProgress)
                    let raw = String(decoding: try Data(contentsOf: out), as: UTF8.self)
                    try expect(raw.contains("/Type /Metadata") && raw.contains("/OutputIntents"), "missing PDF/A markers")
                    try expectEqual(PDFDocument(url: out)?.pageCount, 1)
                    try expect(raw.contains("/FontFile"), "fonts are not embedded")
                    try expectEqual(ConversionPDFTools.scanForbidden(Data("/Type /Foo /JavaScript 5 0 R".utf8)), "JavaScript")
                    try expectEqual(ConversionPDFTools.scanForbidden(Data("/JSFoo".utf8)), nil)
                }),
            ]),
        ]
    }
}
