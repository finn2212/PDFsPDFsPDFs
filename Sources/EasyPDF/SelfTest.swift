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
            try testStampRotation()
            try testRotatedResizeKeepsAnchor()
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
            imageRect: CGRect(x: 100, y: 100, width: 50, height: 50), rotation: 0)
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

    /// A wide stamp rotated by 90° must land tall in the flattened output,
    /// and the rotated hit-test geometry must follow it.
    private static func testStampRotation() throws {
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let srcURL = try makePDF(name: "stamprot-src.pdf", size: CGSize(width: 400, height: 400), fill: white)
        let outURL = dir.appendingPathComponent("stamprot-out.pdf")

        guard let doc = PDFDocument(url: srcURL), let page = doc.page(at: 0) else {
            throw TestError.message("could not open stamp rotation source")
        }

        // 120 x 30 red bar centred at (200, 200), rotated 90° → 30 wide, 120 tall.
        let stampImage = NSImage(size: NSSize(width: 120, height: 30), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let rect = CGRect(x: 140, y: 185, width: 120, height: 30)
        let annotation = ImageStampAnnotation(image: stampImage, stampID: UUID(),
                                              imageRect: rect, rotation: 90)
        page.addAnnotation(annotation)

        // Bounds must cover the rotated image, otherwise PDFKit clips it.
        let expected = ImageStampAnnotation.annotationBounds(for: rect, rotation: 90)
        guard abs(expected.width - (30 + 2 * ImageStampAnnotation.pad)) < 1,
              abs(expected.height - (120 + 2 * ImageStampAnnotation.pad)) < 1 else {
            throw TestError.message("rotated annotation bounds wrong: \(expected)")
        }

        try PDFFlattener.flatten(document: doc, to: outURL)

        guard let outDoc = PDFDocument(url: outURL), let outPage = outDoc.page(at: 0) else {
            throw TestError.message("could not open rotated stamp output")
        }
        let pageSize = CGSize(width: 400, height: 400)
        let rep = try rasterize(outPage, size: pageSize)

        // Along the vertical axis the bar is now red far above/below centre …
        try assertColor(try pixel(rep, pageSize: pageSize, x: 200, y: 250),
                        r: 0.7...1.0, g: 0.0...0.4, b: 0.0...0.4, what: "rotated stamp above centre")
        try assertColor(try pixel(rep, pageSize: pageSize, x: 200, y: 150),
                        r: 0.7...1.0, g: 0.0...0.4, b: 0.0...0.4, what: "rotated stamp below centre")
        // … and white where the unrotated bar used to extend horizontally.
        try assertColor(try pixel(rep, pageSize: pageSize, x: 250, y: 200),
                        r: 0.9...1.0, g: 0.9...1.0, b: 0.9...1.0, what: "beside rotated stamp")

        // Hit-test geometry: a point inside the rotated bar maps into the rect.
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let inside = ImageStampAnnotation.rotate(point: CGPoint(x: 200, y: 250),
                                                 around: center, degrees: -90)
        guard rect.contains(inside) else {
            throw TestError.message("rotated hit-test point not inside rect: \(inside)")
        }
        let outside = ImageStampAnnotation.rotate(point: CGPoint(x: 250, y: 200),
                                                  around: center, degrees: -90)
        guard !rect.contains(outside) else {
            throw TestError.message("point beside rotated stamp wrongly hit-tested inside")
        }
    }

    /// Dragging a corner of a rotated stamp must keep the opposite corner
    /// visually fixed — otherwise the stamp drifts away across a drag.
    private static func testRotatedResizeKeepsAnchor() throws {
        let start = CGRect(x: 100, y: 100, width: 100, height: 50)
        let rotation: CGFloat = 45
        let aspect = start.height / start.width
        // Grab the top-right corner; the bottom-left one must stay put.
        let anchor = CGPoint(x: start.minX, y: start.minY)
        let startCenter = CGPoint(x: start.midX, y: start.midY)
        let fixedBefore = ImageStampAnnotation.rotate(point: anchor, around: startCenter,
                                                      degrees: rotation)

        var rect = start
        // Simulate a drag in several steps, feeding each result back in like the
        // view does, to catch cumulative drift.
        for step in 1...8 {
            let grabbed = CGPoint(x: start.maxX + CGFloat(step) * 6,
                                  y: start.maxY + CGFloat(step) * 3)
            let dragPoint = ImageStampAnnotation.rotate(point: grabbed, around: startCenter,
                                                        degrees: rotation)
            rect = ImageStampAnnotation.resizedRect(startRect: start, anchor: anchor,
                                                    aspect: aspect, rotation: rotation,
                                                    dragPoint: dragPoint)
            // The anchored corner of the *resulting* rect must map to the same
            // visual position it had before the drag.
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let corner = CGPoint(x: rect.minX, y: rect.minY)
            let fixedNow = ImageStampAnnotation.rotate(point: corner, around: center,
                                                       degrees: rotation)
            let drift = hypot(fixedNow.x - fixedBefore.x, fixedNow.y - fixedBefore.y)
            guard drift < 0.01 else {
                throw TestError.message("rotated resize drifted by \(drift) pt at step \(step)")
            }
        }
        guard rect.width > start.width else {
            throw TestError.message("rotated resize did not grow the stamp")
        }
        guard abs(rect.height / rect.width - aspect) < 0.001 else {
            throw TestError.message("rotated resize broke the aspect ratio")
        }

        // Unrotated resize keeps the plain anchor corner exactly.
        let plain = ImageStampAnnotation.resizedRect(startRect: start, anchor: anchor,
                                                     aspect: aspect, rotation: 0,
                                                     dragPoint: CGPoint(x: 260, y: 180))
        guard abs(plain.minX - anchor.x) < 0.001, abs(plain.minY - anchor.y) < 0.001 else {
            throw TestError.message("unrotated resize moved the anchor: \(plain)")
        }
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
