import Foundation
import AppKit
import WebKit
import PDFKit

/// ppt / pptx -> pdf, jpg, png (DOC-19). Quick Look renders the deck to HTML (`qlmanage -p -o`); WebKit then
/// prints each `div.slide` to a vector PDF page or snapshots it as an image.
enum ConversionOfficeEngine {
    typealias F = ConversionFormat

    static func previewFolder(for file: URL, scratch: URL) async throws -> URL {
        // qlmanage names the output after the file, so work on a copy with a plain name.
        let copy = scratch.appendingPathComponent("deck." + file.pathExtension.lowercased())
        try FileManager.default.copyItem(at: file, to: copy)
        let out = scratch.appendingPathComponent("ql")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = try await ConvProcess.run(URL(fileURLWithPath: "/usr/bin/qlmanage"), ["-p", "-o", out.path, copy.path], check: false)
        let dir = out.appendingPathComponent(copy.lastPathComponent + ".qlpreview")
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("Preview.html").path) else {
            throw FileChangerError.failed("Quick Look could not preview this presentation.")
        }
        return dir
    }

    private final class NavDelegate: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done?.resume(); done = nil }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { done?.resume(); done = nil }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { done?.resume(); done = nil }
    }

    /// Slide pages as (vector PDF page, raster image). `wantImages` skips the snapshots for PDF output.
    @MainActor
    static func renderSlides(previewDir: URL, wantPDF: Bool, wantImages: Bool, progress: ProgressHandler) async throws -> (pdf: PDFDocument, images: [CGImage]) {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        let nav = NavDelegate(); web.navigationDelegate = nav
        web.configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        await withCheckedContinuation { c in nav.done = c; web.loadFileURL(previewDir.appendingPathComponent("Preview.html"), allowingReadAccessTo: previewDir) }
        try await Task.sleep(nanoseconds: 1_500_000_000)   // images and fonts settle
        let height = (try? await web.evaluateJavaScript("document.documentElement.scrollHeight") as? Double) ?? 800
        web.frame = NSRect(x: 0, y: 0, width: 1200, height: min(max(800, height + 40), 60000))
        let json = try await web.evaluateJavaScript("JSON.stringify(Array.from(document.querySelectorAll('div.slide')).map(e=>{const r=e.getBoundingClientRect();return [r.x+scrollX,r.y+scrollY,r.width,r.height]}))") as? String ?? "[]"
        let rects = ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[Double]] ?? []).filter { $0.count == 4 && $0[2] > 0 && $0[3] > 0 }
        guard !rects.isEmpty else { throw FileChangerError.failed("Quick Look could not preview this presentation.") }
        let pdf = PDFDocument()
        var images: [CGImage] = []
        for (i, r) in rects.enumerated() {
            try Task.checkCancellation()
            let rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
            if wantPDF {
                let c = WKPDFConfiguration(); c.rect = rect
                if let d = try? await web.pdf(configuration: c), let page = PDFDocument(data: d)?.page(at: 0) { pdf.insert(page, at: pdf.pageCount) }
            }
            if wantImages {
                let s = WKSnapshotConfiguration(); s.rect = rect; s.snapshotWidth = NSNumber(value: min(2400, r[2] * 2))
                if let img = try? await web.takeSnapshot(configuration: s) {
                    var pr = CGRect(origin: .zero, size: img.size)
                    if let cg = img.cgImage(forProposedRect: &pr, context: nil, hints: nil) { images.append(ConversionImageEngine.flattened(cg)) }
                }
            }
            progress(0.2 + 0.7 * Double(i + 1) / Double(rects.count))
        }
        return (pdf, images)
    }

    static func convert(_ file: URL, from s: F, to t: F, progress: ProgressHandler) async throws -> URL {
        guard ConversionDocumentEngine.fileSize(file) > 0 else { throw FileChangerError.failed("The document is empty or exceeds the 128 MB conversion limit.") }
        let scratch = try ConvTemp.make("FileChanger-powerpoint"); defer { try? FileManager.default.removeItem(at: scratch) }
        let dir = try await previewFolder(for: file, scratch: scratch)
        progress(0.15)
        if t == .pdf {
            let r = try await renderSlides(previewDir: dir, wantPDF: true, wantImages: false, progress: progress)
            guard r.pdf.pageCount > 0 else { throw FileChangerError.failed("The converter finished without creating an output file.") }
            let dest = Conversions.outputURL(for: file, ext: "pdf")
            try await OutputLocation.writeAtomically(to: dest) { temp in if !r.pdf.write(to: temp) { throw FileChangerError.failed("Could not create the PDF.") } }
            return dest
        }
        let r = try await renderSlides(previewDir: dir, wantPDF: false, wantImages: true, progress: progress)
        guard !r.images.isEmpty else { throw FileChangerError.failed("The converter finished without creating an output file.") }
        let encode: (CGImage, URL) throws -> Void = { try ConversionImageEngine.encode(.init(image: $0, properties: [:]), as: t, to: $1) }
        if r.images.count == 1 {
            let dest = Conversions.outputURL(for: file, ext: t.ext)
            try await OutputLocation.writeAtomically(to: dest) { try encode(r.images[0], $0) }
            return dest
        }
        let folder = Conversions.outputFolder(for: file)
        let work = folder.deletingLastPathComponent().appendingPathComponent(".filechanger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            for (i, img) in r.images.enumerated() { try encode(img, work.appendingPathComponent(String(format: "Page %03d.%@", i + 1, t.ext))) }
            try FileManager.default.moveItem(at: work, to: folder)
        } catch { try? FileManager.default.removeItem(at: work); throw error }
        return folder
    }
}
