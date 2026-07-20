import AppKit
import PDFKit

/// Headless verification of the core PDF pipeline: stamping + flattening,
/// merging, splitting, page rotation and text rendering.
enum SelfTest {
    static func run() -> Never {
        do {
            try testStampFlatten()
            try testMergeAndSplit()
            try testRotationFlatten()
            try testTextRendering()
            print("SELFTEST PASS")
            exit(0)
        } catch {
            print("SELFTEST FAIL: \(error)")
            exit(1)
        }
    }

    enum TestError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            if case .message(let m) = self { return m }
            return "unknown"
        }
    }

    private static var dir: URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("easypdf-selftest", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Creates a single-page PDF filled with `fill` (and optionally a second color on the right half).
    private static func makePDF(name: String, size: CGSize,
                                fill: CGColor,
                                rightHalf: CGColor? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw TestError.message("could not create PDF context for \(name)")
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(fill)
        ctx.fill(mediaBox)
        if let rightHalf {
            ctx.setFillColor(rightHalf)
            ctx.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private static func rasterize(_ page: PDFPage, size: CGSize) throws -> NSBitmapImageRep {
        let thumb = page.thumbnail(of: size, for: .mediaBox)
        guard let tiff = thumb.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            throw TestError.message("could not rasterize page")
        }
        return rep
    }

    /// Reads a pixel using PDF page coordinates (origin bottom-left).
    private static func pixel(_ rep: NSBitmapImageRep, pageSize: CGSize,
                              x: CGFloat, y: CGFloat) throws -> NSColor {
        let px = Int(x / pageSize.width * CGFloat(rep.pixelsWide))
        let py = Int((pageSize.height - y) / pageSize.height * CGFloat(rep.pixelsHigh))
        let cx = max(0, min(rep.pixelsWide - 1, px))
        let cy = max(0, min(rep.pixelsHigh - 1, py))
        guard let c = rep.colorAt(x: cx, y: cy)?.usingColorSpace(.deviceRGB) else {
            throw TestError.message("could not read pixel at (\(x), \(y))")
        }
        return c
    }

    private static func assertColor(_ c: NSColor, r: ClosedRange<CGFloat>, g: ClosedRange<CGFloat>,
                                    b: ClosedRange<CGFloat>, what: String) throws {
        guard r.contains(c.redComponent), g.contains(c.greenComponent), b.contains(c.blueComponent) else {
            throw TestError.message("\(what): unexpected color \(c)")
        }
    }

    // MARK: - Tests

    private static func testStampFlatten() throws {
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let srcURL = try makePDF(name: "stamp-src.pdf", size: CGSize(width: 400, height: 400), fill: white)
        let outURL = dir.appendingPathComponent("stamp-out.pdf")

        guard let doc = PDFDocument(url: srcURL), let page = doc.page(at: 0) else {
            throw TestError.message("could not reopen stamp source")
        }

        let stampImage = NSImage(size: NSSize(width: 50, height: 50), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let annotation = ImageStampAnnotation(
            image: stampImage, stampID: UUID(),
            bounds: ImageStampAnnotation.annotationBounds(for: CGRect(x: 100, y: 100, width: 50, height: 50)))
        page.addAnnotation(annotation)

        try PDFFlattener.flatten(document: doc, to: outURL)

        guard let outDoc = PDFDocument(url: outURL), outDoc.pageCount == 1,
              let outPage = outDoc.page(at: 0) else {
            throw TestError.message("flattened stamp PDF invalid")
        }
        guard outPage.annotations.isEmpty else {
            throw TestError.message("flattened page still contains annotations")
        }

        let rep = try rasterize(outPage, size: CGSize(width: 400, height: 400))
        let pageSize = CGSize(width: 400, height: 400)
        try assertColor(try pixel(rep, pageSize: pageSize, x: 125, y: 125),
                        r: 0.7...1.0, g: 0.0...0.4, b: 0.0...0.4, what: "stamp center")
        try assertColor(try pixel(rep, pageSize: pageSize, x: 320, y: 320),
                        r: 0.9...1.0, g: 0.9...1.0, b: 0.9...1.0, what: "blank area")
    }

    private static func testMergeAndSplit() throws {
        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        let green = CGColor(red: 0, green: 1, blue: 0, alpha: 1)
        let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        let size = CGSize(width: 200, height: 200)
        let a = try makePDF(name: "merge-a.pdf", size: size, fill: red)
        let b = try makePDF(name: "merge-b.pdf", size: size, fill: green)
        let c = try makePDF(name: "merge-c.pdf", size: size, fill: blue)

        // Merge
        let mergedURL = dir.appendingPathComponent("merged.pdf")
        try PDFTools.merge(urls: [a, b, c], to: mergedURL)
        guard let merged = PDFDocument(url: mergedURL), merged.pageCount == 3 else {
            throw TestError.message("merge did not produce 3 pages")
        }
        let repPage2 = try rasterize(merged.page(at: 1)!, size: size)
        // Color management shifts pure green noticeably; check for green dominance.
        try assertColor(try pixel(repPage2, pageSize: size, x: 100, y: 100),
                        r: 0.0...0.65, g: 0.7...1.0, b: 0.0...0.65, what: "merged page 2")

        // Range parsing
        guard PDFTools.parsePageRanges("1-2", pageCount: 3) == [0, 1],
              PDFTools.parsePageRanges("3, 1", pageCount: 3) == [2, 0],
              PDFTools.parsePageRanges("4", pageCount: 3) == nil,
              PDFTools.parsePageRanges("abc", pageCount: 3) == nil else {
            throw TestError.message("page range parsing incorrect")
        }

        // Extract range
        let extractURL = dir.appendingPathComponent("extract.pdf")
        try PDFTools.extract(from: merged, pageIndices: [0, 2], to: extractURL)
        guard let extracted = PDFDocument(url: extractURL), extracted.pageCount == 2 else {
            throw TestError.message("extract did not produce 2 pages")
        }

        // Split into singles
        let splitFolder = dir.appendingPathComponent("singles", isDirectory: true)
        try? FileManager.default.removeItem(at: splitFolder)
        try FileManager.default.createDirectory(at: splitFolder, withIntermediateDirectories: true)
        let count = try PDFTools.splitIntoSinglePages(document: merged, baseName: "Test", folder: splitFolder)
        let written = try FileManager.default.contentsOfDirectory(atPath: splitFolder.path)
            .filter { $0.hasSuffix(".pdf") }
        guard count == 3, written.count == 3 else {
            throw TestError.message("split into singles produced \(written.count) files, expected 3")
        }

        // Flatten a page subset (used when extracting pages that carry unsaved stamps)
        let subsetURL = dir.appendingPathComponent("subset.pdf")
        try PDFFlattener.flatten(document: merged, pageIndices: [2], to: subsetURL)
        guard let subset = PDFDocument(url: subsetURL), subset.pageCount == 1 else {
            throw TestError.message("subset flatten did not produce 1 page")
        }
        let subsetRep = try rasterize(subset.page(at: 0)!, size: size)
        try assertColor(try pixel(subsetRep, pageSize: size, x: 100, y: 100),
                        r: 0.0...0.5, g: 0.0...0.5, b: 0.65...1.0, what: "subset page (blue)")

        // Page deletion + lossless write
        merged.removePage(at: 1)
        let reducedURL = dir.appendingPathComponent("reduced.pdf")
        guard merged.write(to: reducedURL),
              let reduced = PDFDocument(url: reducedURL), reduced.pageCount == 2 else {
            throw TestError.message("page deletion + write failed")
        }
    }

    private static func testRotationFlatten() throws {
        // Landscape page: left half red, right half blue. Rotated 90° clockwise,
        // red must end up at the top of the portrait output.
        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        let srcURL = try makePDF(name: "rot-src.pdf", size: CGSize(width: 400, height: 200),
                                 fill: red, rightHalf: blue)
        guard let doc = PDFDocument(url: srcURL), let page = doc.page(at: 0) else {
            throw TestError.message("could not open rotation source")
        }
        page.rotation = 90

        let outURL = dir.appendingPathComponent("rot-out.pdf")
        try PDFFlattener.flatten(document: doc, to: outURL)

        guard let outDoc = PDFDocument(url: outURL), let outPage = outDoc.page(at: 0) else {
            throw TestError.message("could not open rotated output")
        }
        let bounds = outPage.bounds(for: .mediaBox)
        guard abs(bounds.width - 200) < 1, abs(bounds.height - 400) < 1 else {
            throw TestError.message("rotated output has wrong size: \(bounds)")
        }

        let outSize = CGSize(width: 200, height: 400)
        let rep = try rasterize(outPage, size: outSize)
        try assertColor(try pixel(rep, pageSize: outSize, x: 100, y: 350),
                        r: 0.7...1.0, g: 0.0...0.45, b: 0.0...0.45, what: "rotated top (red)")
        try assertColor(try pixel(rep, pageSize: outSize, x: 100, y: 50),
                        r: 0.0...0.5, g: 0.0...0.5, b: 0.65...1.0, what: "rotated bottom (blue)")
    }

    private static func testTextRendering() throws {
        guard let png = ImageUtils.renderText("Easy PDF 17.07.2026", fontSize: 14),
              let image = NSImage(data: png), image.size.width > 10 else {
            throw TestError.message("text rendering produced no usable image")
        }
        let strokes: [[CGPoint]] = [[CGPoint(x: 10, y: 10), CGPoint(x: 120, y: 60), CGPoint(x: 200, y: 20)]]
        guard let strokePNG = ImageUtils.renderStrokes(strokes, canvasSize: CGSize(width: 560, height: 220)),
              let strokeImage = NSImage(data: strokePNG), strokeImage.size.width > 0 else {
            throw TestError.message("stroke rendering produced no image")
        }
    }
}
