import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Image-area fixtures are drawn at test time (no binary files).
enum ImgFix {
    static func dir(_ name: String) -> URL {
        let d = Fixtures.scratch.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func image(_ w: Int, _ h: Int, noisy: Bool = false, color: (UInt8, UInt8, UInt8) = (255, 82, 0)) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: ImageFiles.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var seed: UInt32 = 12345
        for i in 0..<(w * h) {
            var (r, g, b) = color
            if noisy { seed = seed &* 1664525 &+ 1013904223; let n = UInt8(truncatingIfNeeded: seed >> 24); r = n; g = n &* 3; b = n &+ 90 }
            px[i * 4] = r; px[i * 4 + 1] = g; px[i * 4 + 2] = b
        }
        px.withUnsafeBytes { ctx.data!.copyMemory(from: $0.baseAddress!, byteCount: w * h * 4) }
        return ctx.makeImage()!
    }

    @discardableResult
    static func write(_ img: CGImage, _ url: URL, type: UTType, props: [CFString: Any] = [:]) throws -> URL {
        let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, img, props as CFDictionary)
        try expect(CGImageDestinationFinalize(d), "fixture write")
        return url
    }

    static let richProps: [CFString: Any] = [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Acme", kCGImagePropertyTIFFModel: "Cam 1", kCGImagePropertyTIFFOrientation: 6],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05", kCGImagePropertyExifLensModel: "Lens"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.5, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 1.5, kCGImagePropertyGPSLongitudeRef: "E"],
        kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["a", "b"], kCGImagePropertyIPTCCaptionAbstract: "hello"],
    ]

    static func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: ImageFiles.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))
    }

    static func message(_ body: () throws -> Void) -> String {
        do { try body(); return "" } catch { return error.localizedDescription }
    }
    static func asyncMessage(_ body: () async throws -> Void) async -> String {
        do { try await body(); return "" } catch { return error.localizedDescription }
    }
    static let noProgress: ProgressHandler = { _ in }
}

extension TestSuites {
    static var imageSuites: [Suite] { [imageResize, imageCompress, imageCrop, imageAdjust, imageAnnotate, imageCollageFrame, imageRedactQR, imageMetadata] }

    // MARK: Resize
    static let imageResize = Suite(name: "image-resize", tests: [
        ("size math for every mode", {
            let src = CGSize(width: 2000, height: 1000)
            var s = ImageResizeSettings(); s.mode = .percentage; s.percentage = 50
            let p = try ImageResizeEngine.targetSize(for: src, s)
            try expect(p.width == 1000 && p.height == 500)
            s.mode = .longEdge; s.longEdge = 500
            let l = try ImageResizeEngine.targetSize(for: CGSize(width: 1000, height: 2000), s)
            try expect(l.width == 250 && l.height == 500)
            s.mode = .fit; s.width = 400; s.height = 400; s.keepProportions = true; s.priority = .fitInside
            let f = try ImageResizeEngine.targetSize(for: src, s)
            try expect(f.width == 400 && f.height == 200)
            s.priority = .height
            let hh = try ImageResizeEngine.targetSize(for: src, s)
            try expect(hh.height == 400 && hh.width == 800)
            s.priority = .width; s.width = 300
            let ww = try ImageResizeEngine.targetSize(for: src, s)
            try expect(ww.width == 300 && ww.height == 150)
            s.keepProportions = false; s.width = 123; s.height = 45
            let st = try ImageResizeEngine.targetSize(for: src, s)
            try expect(st.width == 123 && st.height == 45)
            s.mode = .preset; s.preset = ImageResizePreset.all[4]; s.keepProportions = true; s.priority = .fitInside
            let pr = try ImageResizeEngine.targetSize(for: CGSize(width: 4000, height: 3000), s)
            try expect(pr.width == 960 && pr.height == 720)
        }),
        ("fit in percent units", {
            var s = ImageResizeSettings(); s.mode = .fit; s.unitPercent = true; s.width = 50; s.height = 50; s.keepProportions = false
            let r = try ImageResizeEngine.targetSize(for: CGSize(width: 400, height: 200), s)
            try expect(r.width == 200 && r.height == 100)
        }),
        ("validation messages", {
            var s = ImageResizeSettings(); s.mode = .percentage; s.percentage = 100
            try expectEqual(ImgFix.message { _ = try ImageResizeEngine.targetSize(for: CGSize(width: 10, height: 10), s) }, "Change the size to resize.")
            s.percentage = 100000
            try expect(ImgFix.message { _ = try ImageResizeEngine.targetSize(for: CGSize(width: 10, height: 10), s) }.contains("percentage"))
            s.mode = .longEdge; s.longEdge = 99999
            try expectEqual(ImgFix.message { _ = try ImageResizeEngine.targetSize(for: CGSize(width: 10, height: 10), s) }, "Keep each side at most 20000 pixels.")
        }),
        ("resize file and refuse animations", {
            let d = ImgFix.dir("resize")
            let src = try ImgFix.write(ImgFix.image(200, 100), d.appendingPathComponent("a.png"), type: .png)
            var s = ImageResizeSettings(); s.mode = .percentage; s.percentage = 50
            let out = try await ImageResizeEngine.resize(src, s, progress: ImgFix.noProgress)
            try expectEqual(out.lastPathComponent, "a-resized.png")
            let sz = ImageFiles.displaySize(out)
            try expect(sz?.width == 100 && sz?.height == 50)
            // 2-frame GIF
            let gif = d.appendingPathComponent("anim.gif")
            let g = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 2, nil)!
            for _ in 0..<2 { CGImageDestinationAddImage(g, ImgFix.image(20, 20), nil) }
            try expect(CGImageDestinationFinalize(g))
            let msg = await ImgFix.asyncMessage { _ = try await ImageResizeEngine.resize(gif, s, progress: ImgFix.noProgress) }
            try expectEqual(msg, "Choose original dimensions to preserve this image's animation.")
        }),
    ])

    // MARK: Compress
    static let imageCompress = Suite(name: "image-compress", tests: [
        ("target and percentage modes hit their size", {
            let d = ImgFix.dir("compress")
            let src = try ImgFix.write(ImgFix.image(400, 300, noisy: true), d.appendingPathComponent("n.jpg"), type: .jpeg,
                                       props: [kCGImageDestinationLossyCompressionQuality: 1.0])
            let orig = ImageFiles.fileSize(src)
            let target = orig / 3
            let out = try await ImageCompressEngine.compress(src, .targetBytes(target), progress: ImgFix.noProgress)
            let size = ImageFiles.fileSize(out)
            try expect(size <= target && size > target / 3, "size \(size) target \(target)")
            let p = try await ImageCompressEngine.compress(src, .percentage(50), progress: ImgFix.noProgress)
            try expect(ImageFiles.fileSize(p) <= orig / 2)
            try expectEqual(out.lastPathComponent, "n-compressed.jpg")
        }),
        ("validation messages", {
            try expectEqual(ImgFix.message { _ = try ImageCompressEngine.target(for: .percentage(99), originalBytes: 1500) },
                            "Choose a reduction from 1% to 99% that leaves at least 1 KB per file.")
            try expectEqual(ImgFix.message { _ = try ImageCompressEngine.target(for: .targetBytes(10), originalBytes: 50000) }, "Enter a target size of at least 1 KB.")
            try expectEqual(ImgFix.message { _ = try ImageCompressEngine.target(for: .targetBytes(60000), originalBytes: 50000) },
                            "Target size cannot exceed the original file size.")
            try expectEqual(try ImageCompressEngine.target(for: .percentage(50), originalBytes: 10000), 5000)
        }),
        ("unreachable target reports smallest attempt; presets shrink", {
            let d = ImgFix.dir("compress2")
            let src = try ImgFix.write(ImgFix.image(300, 300, noisy: true), d.appendingPathComponent("n.jpg"), type: .jpeg,
                                       props: [kCGImageDestinationLossyCompressionQuality: 1.0])
            let msg = await ImgFix.asyncMessage { _ = try await ImageCompressEngine.compress(src, .targetBytes(1024), progress: ImgFix.noProgress) }
            try expect(msg.hasPrefix("Could not reach the target size. Smallest attempt was"), msg)
            let out = try await ImageCompressEngine.compress(src, .level(.strong, .small), progress: ImgFix.noProgress)
            try expect(ImageFiles.fileSize(out) < ImageFiles.fileSize(src))
            // A flat PNG shrinks losslessly (or is refused when it cannot get smaller); never a larger file.
            let png = try ImgFix.write(ImgFix.image(300, 300), d.appendingPathComponent("p.png"), type: .png, props: ImgFix.richProps)
            do {
                let o2 = try await ImageCompressEngine.compress(png, .level(.balanced, .original), progress: ImgFix.noProgress)
                try expect(o2.lastPathComponent == "p-optimized.png" && ImageFiles.fileSize(o2) < ImageFiles.fileSize(png))
            } catch { try expectEqual(error.localizedDescription, "Compressed output would exceed the original or target file size.") }
        }),
        ("animated GIF compresses in Level mode, refuses target modes with an honest message", {
            let d = ImgFix.dir("compress4")
            let gif = d.appendingPathComponent("a.gif")
            let g = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 3, nil)!
            for i in 0..<3 { CGImageDestinationAddImage(g, ImgFix.image(120, 120, noisy: true, color: (UInt8(i * 80), 0, 0)), nil) }
            try expect(CGImageDestinationFinalize(g))
            let msg = await ImgFix.asyncMessage { _ = try await ImageCompressEngine.compress(gif, .percentage(50), progress: ImgFix.noProgress) }
            try expect(msg.contains("Choose Level"), msg)
            do {
                let o = try await ImageCompressEngine.compress(gif, .level(.balanced, .original), progress: ImgFix.noProgress)
                try expect(ImageFiles.isAnimated(o))
            } catch { try expectEqual(error.localizedDescription, "Compressed output would exceed the original or target file size.") }
        }),
        ("pdf compression writes a smaller valid pdf or reports the filter missing", {
            let d = ImgFix.dir("compress3")
            let url = d.appendingPathComponent("doc.pdf")
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
            ctx.beginPDFPage(nil)
            ctx.draw(ImgFix.image(1500, 1500, noisy: true), in: box)
            ctx.endPDFPage(); ctx.closePDF()
            do {
                let out = try await ImageCompressEngine.compress(url, .level(.balanced, .original), progress: ImgFix.noProgress)
                try expect(PDFDocument(url: out)?.pageCount == 1)
                try expect(ImageFiles.fileSize(out) < ImageFiles.fileSize(url))
            } catch let e as FileChangerError {
                try expect(["The macOS PDF compression filter is unavailable.", "Compressed output would exceed the original or target file size."].contains(e.localizedDescription), e.localizedDescription)
            }
        }),
    ])

    // MARK: Crop
    static let imageCrop = Suite(name: "image-crop", tests: [
        ("validation, clamping, ratio", {
            let size = CGSize(width: 100, height: 80)
            try expectEqual(ImgFix.message { try ImageCropEngine.validate(CGRect(x: 90, y: 0, width: 20, height: 10), in: size) }, "Keep the crop inside the image.")
            try expectEqual(ImgFix.message { try ImageCropEngine.validate(CGRect(x: 0, y: 0, width: 0, height: 10), in: size) }, "The crop must be at least 1 x 1 pixel.")
            try ImageCropEngine.validate(CGRect(x: 0, y: 0, width: 100, height: 80), in: size)
            try expect(ImageCropEngine.clamped(CGRect(x: 95, y: -5, width: 20, height: 20), in: size) == CGRect(x: 80, y: 0, width: 20, height: 20))
            let r = ImageCropEngine.fitted(ratio: 1, in: size)
            try expect(r.width == 80 && r.height == 80 && r.minX == 10)
            try expectEqual(ImageCropEngine.nudgeStep(shift: true, option: false), 25)
            try expectEqual(ImageCropEngine.nudgeStep(shift: true, option: true), 1)
        }),
        ("handles resize and keep ratio", {
            let size = CGSize(width: 200, height: 200)
            let r0 = CGRect(x: 50, y: 50, width: 100, height: 100)
            let a = ImageCropEngine.resize(r0, handle: .right, delta: CGPoint(x: 30, y: 0), in: size)
            try expect(a == CGRect(x: 50, y: 50, width: 130, height: 100))
            let b = ImageCropEngine.resize(r0, handle: .topLeft, delta: CGPoint(x: -20, y: 5), in: size)
            try expect(b == CGRect(x: 30, y: 55, width: 120, height: 95))
            let c = ImageCropEngine.resize(r0, handle: .bottomRight, delta: CGPoint(x: 40, y: 0), in: size, ratio: 2)
            try expect(abs(c.width / c.height - 2) < 0.01, "\(c)")
            let e = ImageCropEngine.resize(r0, handle: .left, delta: CGPoint(x: 500, y: 0), in: size)
            try expect(e.width >= 1)
        }),
        ("proportional apply to all", {
            let r = ImageCropEngine.proportional(CGRect(x: 10, y: 20, width: 50, height: 40), from: CGSize(width: 100, height: 100), to: CGSize(width: 400, height: 200))
            try expect(r == CGRect(x: 40, y: 40, width: 200, height: 80), "\(r)")
        }),
        ("crop writes cropped file", {
            let d = ImgFix.dir("crop")
            let src = try ImgFix.write(ImgFix.image(100, 80), d.appendingPathComponent("c.png"), type: .png)
            let out = try await ImageCropEngine.crop(src, rect: CGRect(x: 10, y: 10, width: 30, height: 20), referenceSize: nil, progress: ImgFix.noProgress)
            try expect(out.lastPathComponent == "c-cropped.png" && ImageFiles.displaySize(out) == CGSize(width: 30, height: 20))
            let big = try ImgFix.write(ImgFix.image(200, 160), d.appendingPathComponent("b.png"), type: .png)
            let o2 = try await ImageCropEngine.crop(big, rect: CGRect(x: 10, y: 10, width: 30, height: 20), referenceSize: CGSize(width: 100, height: 80), progress: ImgFix.noProgress)
            try expect(ImageFiles.displaySize(o2) == CGSize(width: 60, height: 40))
        }),
    ])

    // MARK: Adjust
    static let imageAdjust = Suite(name: "image-adjust", tests: [
        ("identity leaves pixels; exposure brightens; warm adds red", {
            let img = ImgFix.image(32, 32, color: (100, 100, 100))
            let same = try ImageAdjustEngine.render(ImageAdjustments(), img)
            try expect(ImgFix.pixel(same, 5, 5).0 == 100)
            var a = ImageAdjustments(); a["exposure"] = 1
            let bright = try ImageAdjustEngine.render(a, img)
            try expect(ImgFix.pixel(bright, 5, 5).0 > 120, "\(ImgFix.pixel(bright, 5, 5))")
            var w = ImageAdjustments(); w["temperature"] = 60
            let warm = ImgFix.pixel(try ImageAdjustEngine.render(w, img), 5, 5)
            try expect(warm.0 > warm.2, "\(warm)")
            var c = ImageAdjustments(); c["temperature"] = -60
            let cool = ImgFix.pixel(try ImageAdjustEngine.render(c, img), 5, 5)
            try expect(cool.2 > cool.0, "\(cool)")
        }),
        ("every slider renders at both ends", {
            let img = ImgFix.image(64, 48, noisy: true)
            for c in ImageAdjustControl.all {
                for v in [c.range.lowerBound, c.range.upperBound] {
                    var a = ImageAdjustments(); a[c.id] = v
                    let out = try ImageAdjustEngine.render(a, img)
                    try expect(out.width == 64 && out.height == 48, c.id)
                }
            }
            try expectEqual(ImageAdjustControl.all[0].display(0.5), "0.50 EV")
            try expectEqual(ImageAdjustControl.all[1].display(12), "+12")
        }),
        ("adjust saves -edited copy", {
            let d = ImgFix.dir("adjust")
            let src = try ImgFix.write(ImgFix.image(40, 40), d.appendingPathComponent("p.jpg"), type: .jpeg)
            var a = ImageAdjustments(); a["contrast"] = 30
            let out = try await ImageAdjustEngine.adjust(src, a, progress: ImgFix.noProgress)
            try expectEqual(out.lastPathComponent, "p-edited.jpg")
        }),
    ])

    // MARK: Annotate
    static let imageAnnotate = Suite(name: "image-annotate", tests: [
        ("validation messages", {
            let size = CGSize(width: 1000, height: 800)
            try expectEqual(ImageAnnotateEngine.validate([], imageSize: size), "Add at least one annotation.")
            try expectEqual(ImageAnnotateEngine.validate([Annotation(kind: .text, points: [CGPoint(x: 10, y: 10)])], imageSize: size), "Enter text for the text box.")
            try expectEqual(ImageAnnotateEngine.validate([Annotation(kind: .image, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)])], imageSize: size), "Choose an image to place on the canvas.")
            try expectEqual(ImageAnnotateEngine.validate([Annotation(kind: .freehand, points: [CGPoint(x: 10, y: 10), CGPoint(x: 12, y: 11)])], imageSize: size), "Draw a slightly longer freehand line.")
            try expectEqual(ImageAnnotateEngine.validate([Annotation(kind: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 12, y: 12)])], imageSize: size), "Make drawn annotations a little larger.")
            try expectEqual(ImageAnnotateEngine.validate([Annotation(kind: .rectangle, points: [CGPoint(x: 2000, y: 10), CGPoint(x: 2100, y: 100)])], imageSize: size), "Keep annotations inside the image.")
            try expect(ImageAnnotateEngine.validate([Annotation(kind: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 100)])], imageSize: size) == nil)
        }),
        ("every kind renders at full resolution", {
            let base = ImgFix.image(400, 300, color: (255, 255, 255))
            let red = ImageRGBA(r: 1, g: 0, b: 0)
            let list: [Annotation] = [
                Annotation(kind: .arrow, color: red, points: [CGPoint(x: 20, y: 20), CGPoint(x: 150, y: 20)]),
                Annotation(kind: .rectangle, color: red, points: [CGPoint(x: 20, y: 50), CGPoint(x: 120, y: 120)]),
                Annotation(kind: .ellipse, color: red, points: [CGPoint(x: 150, y: 50), CGPoint(x: 250, y: 120)]),
                Annotation(kind: .freehand, color: red, points: (0..<20).map { CGPoint(x: 20 + $0 * 10, y: 150 + ($0 % 2) * 10) }),
                Annotation(kind: .highlighter, color: ImageRGBA(r: 1, g: 1, b: 0), points: [CGPoint(x: 20, y: 200), CGPoint(x: 200, y: 200)]),
                Annotation(kind: .number, color: red, points: [CGPoint(x: 300, y: 50)]),
                Annotation(kind: .magnifier, color: red, points: [CGPoint(x: 300, y: 200)]),
                Annotation(kind: .text, color: ImageRGBA(r: 0, g: 0, b: 1), points: [CGPoint(x: 220, y: 130)], text: "Hello", font: .mono),
                Annotation(kind: .image, points: [CGPoint(x: 330, y: 250), CGPoint(x: 390, y: 290)], image: ImgFix.image(10, 10, color: (0, 200, 0))),
            ]
            let out = try ImageAnnotateEngine.render(base, list)
            try expect(out.width == 400 && out.height == 300)
            let p = ImgFix.pixel(out, 70, 50)   // rectangle top edge, red
            try expect(p.0 > 200 && p.1 < 80, "\(p)")
            let g = ImgFix.pixel(out, 360, 270) // pasted image
            try expect(g.1 > 150 && g.0 < 80, "\(g)")
            let n = ImgFix.pixel(out, 300, 45)  // number badge fill
            try expect(n.0 > 200 && n.1 < 100, "\(n)")
        }),
        ("hit testing and moving", {
            let a = Annotation(kind: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 50)])
            let size = CGSize(width: 1000, height: 1000)
            try expect(ImageAnnotateEngine.hit(a, at: CGPoint(x: 30, y: 30), imageSize: size))
            try expect(!ImageAnnotateEngine.hit(a, at: CGPoint(x: 300, y: 300), imageSize: size))
            let m = ImageAnnotateEngine.moved(a, by: CGSize(width: 5, height: -5))
            try expect(m.points[0] == CGPoint(x: 15, y: 5))
        }),
    ])

    // MARK: Collage + Frame
    static let imageCollageFrame = Suite(name: "image-collage-frame", tests: [
        ("collage layout per style", {
            var o = CollageOptions(); o.imageWidth = 100; o.spacing = 10; o.padding = 20; o.columns = 2
            let g = try ImageCollageEngine.layout(aspects: [1, 1, 1], o)
            try expect(g.canvas == CGSize(width: 250, height: 250), "\(g.canvas)")
            try expect(g.frames.count == 3 && g.frames[2].origin == CGPoint(x: 20, y: 130))
            o.style = .horizontal
            let h = try ImageCollageEngine.layout(aspects: [2, 1], o)
            try expect(h.frames[0].width == 200 && h.canvas.width == 20 + 200 + 10 + 100 + 20)
            o.style = .vertical
            let v = try ImageCollageEngine.layout(aspects: [1, 0.5], o)
            try expect(v.frames[1].height == 200)
            o.style = .featured
            let f = try ImageCollageEngine.layout(aspects: [1, 1, 1], o)
            try expect(f.frames[0].width == 200 && f.frames[1].minX == 20 + 200 + 10)
            o.style = .grid; o.canvas = .r169
            let w = try ImageCollageEngine.layout(aspects: [1, 1, 1, 1], o)
            try expect(abs(w.canvas.width / w.canvas.height - 16.0 / 9) < 0.02)
        }),
        ("collage size limits", {
            var o = CollageOptions(); o.imageWidth = 2000; o.columns = 6
            try expectEqual(ImgFix.message { _ = try ImageCollageEngine.layout(aspects: Array(repeating: 1, count: 6), o) }, ImageCollageEngine.sizeMessage)
            o = CollageOptions(); o.imageWidth = 10; o.spacing = 0; o.padding = 0
            try expectEqual(ImgFix.message { _ = try ImageCollageEngine.layout(aspects: [1, 1], o) } , "")
            o.imageWidth = 6
            try expectEqual(ImgFix.message { _ = try ImageCollageEngine.layout(aspects: [1, 1], o) }, ImageCollageEngine.sizeMessage)
        }),
        ("collage renders backgrounds and fit modes", {
            var o = CollageOptions(); o.imageWidth = 100; o.spacing = 10; o.padding = 10; o.columns = 2; o.cornerRadius = 0
            let imgs = [ImgFix.image(200, 100, color: (255, 0, 0)), ImgFix.image(100, 200, color: (0, 0, 255))]
            let fill = try ImageCollageEngine.render(imgs, o)
            try expect(fill.width == 230)
            try expect(ImgFix.pixel(fill, 60, 60).0 > 200)             // red cell centre
            o.fillImage = false; o.background = .transparent
            let fit = try ImageCollageEngine.render(imgs, o)
            try expect(ImgFix.pixel(fit, 60, 15).3 == 0, "fit leaves transparent letterbox")
            o.background = .color(ImageRGBA(r: 0, g: 1, b: 0))
            try expect(ImgFix.pixel(try ImageCollageEngine.render(imgs, o), 2, 2).1 > 200)
        }),
        ("frame canvas, ratios and limits", {
            var o = FrameOptions(); o.padding = 10; o.ratio = .automatic
            let c = try ImageFrameEngine.canvasSize(photo: CGSize(width: 1000, height: 500), o)
            try expect(c == CGSize(width: 1100, height: 600), "\(c)")
            o.ratio = .square
            let sq = try ImageFrameEngine.canvasSize(photo: CGSize(width: 1000, height: 500), o)
            try expect(sq.width == sq.height)
            o.ratio = .r916
            let p = try ImageFrameEngine.canvasSize(photo: CGSize(width: 1000, height: 500), o)
            try expect(abs(p.width / p.height - 9.0 / 16) < 0.01)
            o.padding = 50; o.ratio = .r916
            try expectEqual(ImgFix.message { _ = try ImageFrameEngine.canvasSize(photo: CGSize(width: 12000, height: 400), o) }, ImageFrameEngine.tooLarge)
        }),
        ("frame renders every background kind", {
            let photo = ImgFix.image(120, 80, color: (0, 0, 0))
            var o = FrameOptions(); o.padding = 20; o.shadow = 50; o.corners = 10
            for p in FrameBackgroundPreset.all {
                o.background = .preset(p)
                let out = try ImageFrameEngine.render(photo, o)
                try expect(out.width > 120)
            }
            o.background = .custom(ImageRGBA(r: 0, g: 1, b: 0))
            let c = try ImageFrameEngine.render(photo, o)
            try expect(ImgFix.pixel(c, 1, 1).1 > 200)
            o.background = .blur
            _ = try ImageFrameEngine.render(photo, o)
            let d = ImgFix.dir("frame")
            let bg = try ImgFix.write(ImgFix.image(50, 50, color: (255, 0, 255)), d.appendingPathComponent("bg.png"), type: .png)
            o.background = .image(bg)
            let im = try ImageFrameEngine.render(photo, o)
            try expect(ImgFix.pixel(im, 1, 1).0 > 200 && ImgFix.pixel(im, 1, 1).2 > 200)
            o.background = .image(d.appendingPathComponent("missing.png"))
            try expectEqual(ImgFix.message { _ = try ImageFrameEngine.render(photo, o) }, "Choose a background image.")
        }),
    ])

    // MARK: Redact + QR
    static let imageRedactQR = Suite(name: "image-redact-qr", tests: [
        ("solid and blur redaction", {
            let img = ImgFix.image(100, 100, noisy: true)
            let solid = try ImageRedactEngine.render(img, rects: [CGRect(x: 10, y: 10, width: 30, height: 30)], style: .solid)
            try expect(ImgFix.pixel(solid, 20, 20) == (0, 0, 0, 255))
            try expect(ImgFix.pixel(solid, 80, 80) == ImgFix.pixel(img, 80, 80))
            let blur = try ImageRedactEngine.render(img, rects: [CGRect(x: 10, y: 10, width: 30, height: 30)], style: .blur)
            try expect(ImgFix.pixel(blur, 20, 20) != ImgFix.pixel(img, 20, 20))
            try expect(ImgFix.pixel(blur, 80, 80) == ImgFix.pixel(img, 80, 80))
            try expectEqual(ImgFix.message { _ = try ImageRedactEngine.render(img, rects: [], style: .solid) }, "Draw a rectangle over the area to hide.")
        }),
        ("detected rect helpers", {
            let r = ImageRedactEngine.pixelRect(fromVision: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2), size: CGSize(width: 100, height: 100), grow: 0)
            try expect(abs(r.minX - 10) < 0.01 && abs(r.minY - 10) < 0.01 && abs(r.width - 20) < 0.01 && abs(r.height - 20) < 0.01, "\(r)")
            let fresh = ImageRedactEngine.newRects([CGRect(x: 10, y: 10, width: 20, height: 20), CGRect(x: 60, y: 60, width: 10, height: 10)],
                                                   existing: [CGRect(x: 8, y: 8, width: 30, height: 30)])
            try expect(fresh == [CGRect(x: 60, y: 60, width: 10, height: 10)])
        }),
        ("vision text detection finds drawn text", {
            let img = ImageFiles.render(500, 160) { ctx in
                ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 500, height: 160))
                var a = Annotation(kind: .text, color: .black, points: [CGPoint(x: 20, y: 40)], text: "HELLO WORLD")
                a.fontSize = 90; a.width = 900
                _ = a
            }!
            let drawn = try ImageAnnotateEngine.render(img, [{ var a = Annotation(kind: .text, color: .black, points: [CGPoint(x: 20, y: 30)], text: "HELLO WORLD"); a.fontSize = 60; a.width = 480; return a }()])
            let found = try await ImageRedactEngine.detect(.text, in: drawn)
            try expect(!found.isEmpty, "no text found")
        }),
        ("QR codes round trip", {
            let d = ImgFix.dir("qr")
            let gen = CIFilter(name: "CIQRCodeGenerator")!
            gen.setValue(Data("https://example.com/hello".utf8), forKey: "inputMessage")
            let ci = gen.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
            let cg = ImageAdjustEngine.context.createCGImage(ci, from: ci.extent)!
            let padded = ImageFiles.render(cg.width + 80, cg.height + 80) { ctx in
                ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: cg.width + 80, height: cg.height + 80))
                ImageFiles.draw(cg, in: CGRect(x: 40, y: 40, width: cg.width, height: cg.height), ctx)
            }!
            let url = try ImgFix.write(padded, d.appendingPathComponent("qr.png"), type: .png)
            try expectEqual(try ImageQREngine.read(url).map(\.text), ["https://example.com/hello"])
            let blank = try ImgFix.write(ImgFix.image(100, 100), d.appendingPathComponent("blank.png"), type: .png)
            try expect(try ImageQREngine.read(blank).isEmpty)
        }),
    ])

    // MARK: Metadata
    static let imageMetadata = Suite(name: "image-metadata", tests: [
        ("viewer groups fields and hides rendering tags", {
            let d = ImgFix.dir("meta1")
            let url = try ImgFix.write(ImgFix.image(64, 48), d.appendingPathComponent("m.jpg"), type: .jpeg, props: ImgFix.richProps)
            let fields = try MetadataEngine.read(url)
            let ids = Set(fields.map(\.id))
            try expect(ids.isSuperset(of: ["tiff:Make", "tiff:Model", "exif:GPSLatitude", "exifEX:LensModel"]), "\(ids)")
            try expect(!ids.contains("tiff:Orientation") && !ids.contains("exif:PixelXDimension"))
            try expectEqual(fields.first { $0.id == "tiff:Make" }?.group, "IFD0")
            try expectEqual(fields.first { $0.id == "exif:GPSLatitude" }?.group, "GPS")
            try expectEqual(fields.first { $0.id == "tiff:Make" }?.value, "Acme")
            try expect(fields.first { $0.id == "tiff:Make" }?.isEditable == true)
        }),
        ("Remove All cleans JPEG, PNG and TIFF with identical pixels and orientation kept", {
            let d = ImgFix.dir("meta2")
            for (type, ext) in [(UTType.jpeg, "jpg"), (.png, "png"), (.tiff, "tif")] {
                let url = try ImgFix.write(ImgFix.image(64, 48, noisy: true), d.appendingPathComponent("m.\(ext)"), type: type, props: ImgFix.richProps)
                try expect(!ImageMetadataEngine.privateTags(url).isEmpty, "\(ext) fixture should have private tags")
                let out = try await MetadataEngine.removeAll(url, progress: ImgFix.noProgress)
                try expectEqual(out.lastPathComponent, "m-clean.\(ext)")
                try expectEqual(ImageMetadataEngine.privateTags(out), [])
                try expectEqual(ImageFiles.pixelHash(out), ImageFiles.pixelHash(url))
                try expectEqual(ImageFiles.properties(out)[kCGImagePropertyOrientation] as? Int, 6)
                try expect(FileManager.default.fileExists(atPath: url.path))
            }
        }),
        ("Remove All cleans HEIC (re-encode fallback allowed)", {
            let d = ImgFix.dir("meta3")
            let url = try ImgFix.write(ImgFix.image(64, 48), d.appendingPathComponent("m.heic"), type: .heic, props: ImgFix.richProps)
            let out = try await MetadataEngine.removeAll(url, progress: ImgFix.noProgress)
            try expectEqual(ImageMetadataEngine.privateTags(out), [])
        }),
        ("single-field removal and edit", {
            let d = ImgFix.dir("meta4")
            let url = try ImgFix.write(ImgFix.image(64, 48), d.appendingPathComponent("e.jpg"), type: .jpeg, props: ImgFix.richProps)
            let out = try await MetadataEngine.save(url, removing: ["exif:GPSLatitude", "exif:GPSLongitude"], editing: ["tiff:Make": "Zeta"], progress: ImgFix.noProgress)
            let after = try MetadataEngine.read(out)
            try expect(!after.contains { $0.id == "exif:GPSLatitude" })
            try expectEqual(after.first { $0.id == "tiff:Make" }?.value, "Zeta")
            try expectEqual(after.first { $0.id == "tiff:Model" }?.value, "Cam 1")
            try expectEqual(out.lastPathComponent, "e-edited.jpg")
            let png = try ImgFix.write(ImgFix.image(64, 48), d.appendingPathComponent("e.png"), type: .png, props: ImgFix.richProps)
            let o2 = try await MetadataEngine.save(png, removing: ["tiff:Model"], editing: [:], progress: ImgFix.noProgress)
            try expect(!(try MetadataEngine.read(o2)).contains { $0.id == "tiff:Model" })
        }),
        ("list fields edit as lines", {
            let d = ImgFix.dir("meta5")
            let url = try ImgFix.write(ImgFix.image(64, 48), d.appendingPathComponent("l.jpg"), type: .jpeg, props: ImgFix.richProps)
            let f = try MetadataEngine.read(url).first { $0.id == "dc:subject" }
            try expectEqual(f?.kind, .list)
            try expectEqual(f?.value, "a\nb")
            let out = try await MetadataEngine.save(url, removing: [], editing: ["dc:subject": "x\ny\nz"], progress: ImgFix.noProgress)
            try expectEqual(try MetadataEngine.read(out).first { $0.id == "dc:subject" }?.value, "x\ny\nz")
        }),
        ("content credentials are removable through Save (JPEG) and listed", {
            let d = ImgFix.dir("meta7")
            let plain = try ImgFix.write(ImgFix.image(64, 48, noisy: true), d.appendingPathComponent("p.jpg"), type: .jpeg, props: ImgFix.richProps)
            var b = [UInt8](try Data(contentsOf: plain))
            let payload = Array("jumbc2pa-manifest".utf8) + [UInt8](repeating: 7, count: 20)
            let seg: [UInt8] = [0xFF, 0xEB, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 255)] + payload
            b.insert(contentsOf: seg, at: 2)
            let url = d.appendingPathComponent("c.jpg"); try Data(b).write(to: url)
            try expect(try MetadataEngine.read(url).contains { $0.id == "c2pa" })
            let out = try await MetadataEngine.save(url, removing: ["c2pa"], editing: [:], progress: ImgFix.noProgress)
            try expect(!(try MetadataEngine.read(out)).contains { $0.id == "c2pa" })
            try expectEqual(ImageFiles.pixelHash(out), ImageFiles.pixelHash(plain))
            let gif = d.appendingPathComponent("x.gif")
            let msg = await ImgFix.asyncMessage { _ = try await MetadataEngine.save(gif, removing: ["c2pa"], editing: [:], progress: ImgFix.noProgress) }
            try expect(!msg.isEmpty)
        }),
        ("PNG gamma survives Remove All; ICC row is read-only", {
            let d = ImgFix.dir("meta8")
            var props = ImgFix.richProps
            props[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGGamma: 0.45455]
            let url = try ImgFix.write(ImgFix.image(32, 32), d.appendingPathComponent("g.png"), type: .png, props: props)
            try expect((ImageFiles.properties(url)[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyPNGGamma] != nil, "fixture gamma")
            let out = try await MetadataEngine.removeAll(url, progress: ImgFix.noProgress)
            try expect((ImageFiles.properties(out)[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyPNGGamma] != nil, "gamma kept")
            if let icc = try MetadataEngine.read(url).first(where: { $0.id == "icc" }) { try expect(!icc.isRemovable) }
        }),
        ("webp metadata chunks are stripped", {
            func chunk(_ tag: String, _ body: [UInt8]) -> [UInt8] {
                let n = body.count
                return Array(tag.utf8) + [UInt8(n & 255), UInt8((n >> 8) & 255), 0, 0] + body + (n % 2 == 1 ? [0] : [])
            }
            let vp8x = chunk("VP8X", [0x0C, 0, 0, 0, 9, 0, 0, 9, 0, 0])
            var riff = Array("WEBP".utf8) + vp8x + chunk("EXIF", [1, 2, 3, 4]) + chunk("XMP ", [5, 6]) + chunk("VP8 ", [7, 7, 7, 7])
            let n = riff.count
            riff = Array("RIFF".utf8) + [UInt8(n & 255), UInt8((n >> 8) & 255), 0, 0] + riff
            let out = [UInt8](try ImageMetadataEngine.stripWebP(Data(riff)))
            let text = String(decoding: out, as: UTF8.self)
            try expect(!text.contains("EXIF") && !text.contains("XMP ") && text.contains("VP8 "))
            try expectEqual(out[20], 0)    // VP8X flags cleared
            try expectEqual(Int(out[4]) | Int(out[5]) << 8, out.count - 8)
        }),
        ("pdf metadata read, edit and Remove All", {
            let d = ImgFix.dir("meta6")
            let url = d.appendingPathComponent("p.pdf")
            let doc = PDFDocument()
            doc.insert(PDFPage(image: NSImageFromCG(ImgFix.image(50, 50)))!, at: 0)
            doc.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Secret", PDFDocumentAttribute.authorAttribute: "Me", PDFDocumentAttribute.keywordsAttribute: ["k1", "k2"]]
            try expect(doc.write(to: url))
            let f = try MetadataEngine.read(url)
            try expectEqual(f.first { $0.id == "Title" }?.value, "Secret")
            let edited = try await MetadataEngine.save(url, removing: ["Author"], editing: ["Title": "Public"], progress: ImgFix.noProgress)
            let e = try MetadataEngine.read(edited)
            try expectEqual(e.first { $0.id == "Title" }?.value, "Public")
            try expect(!e.contains { $0.id == "Author" })
            let clean = try await MetadataEngine.removeAll(url, progress: ImgFix.noProgress)
            let c = try MetadataEngine.read(clean)
            try expect(!c.contains { $0.id == "Title" || $0.id == "Author" || $0.id == "Keywords" }, "\(c)")
            try expectEqual(clean.lastPathComponent, "p-clean.pdf")
        }),
    ])
}

import AppKit
func NSImageFromCG(_ cg: CGImage) -> NSImage { NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
