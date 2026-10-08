import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

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
            try testConvertPageSize()
            try testConvertExifOrientation()
            try testConvertMultiFrame()
            try testConvertRejectsPDFInput()
            try testPDFToImageExport()
            try MainActor.assumeIsolated {
                try testPageOperations()
                try testSplitAtCutMarks()
                try testInitialsOnRotatedPage()
                try testShareExport()
                try testSaveKeepsPageStateAndFormEdits()
                try testFieldDetection()
            }
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

    // MARK: - Converter

    /// Two coloured halves, so orientation can be checked by probing pixels.
    private static func makeCGImage(width: Int, height: Int,
                                    left: CGColor, right: CGColor) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw TestError.message("could not create bitmap context")
        }
        ctx.setFillColor(left)
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(right)
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        guard let image = ctx.makeImage() else {
            throw TestError.message("could not render bitmap")
        }
        return image
    }

    private static func writeImage(_ images: [CGImage], name: String, type: UTType,
                                   properties: [CFString: Any] = [:]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString,
                                                         images.count, nil) else {
            throw TestError.message("could not create image destination for \(name)")
        }
        for image in images {
            CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            throw TestError.message("could not write \(name)")
        }
        return url
    }

    /// Renders a page through the same robust page.draw path the converter and
    /// Preview use. Unlike page.thumbnail(of:for:), it applies no colour management
    /// or smoothing, so flat fills read back as the exact device colours — the
    /// thumbnail path shifts pure green to ~(0.51, 0.95, 0.30) and would fail on a
    /// correct converter.
    private static func renderPageRGB(_ page: PDFPage, pixelsWide: Int, pixelsHigh: Int) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: pixelsWide, height: pixelsHigh,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw TestError.message("could not create rgb render context")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        let bounds = page.bounds(for: .mediaBox)
        ctx.scaleBy(x: CGFloat(pixelsWide) / bounds.width, y: CGFloat(pixelsHigh) / bounds.height)
        page.draw(with: .mediaBox, to: ctx)
        guard let image = ctx.makeImage() else { throw TestError.message("could not rasterize page via draw") }
        return image
    }

    /// Samples a device-RGB pixel at fractional (x, y-from-top), returning 0...1 components.
    private static func sampleRGB(_ image: CGImage, fx: Double, fyFromTop: Double) throws -> (r: Double, g: Double, b: Double) {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw TestError.message("could not create sampling context")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let raw = ctx.data else { throw TestError.message("could not read sampled pixels") }
        let x = min(w - 1, max(0, Int(Double(w) * fx)))
        let y = min(h - 1, max(0, Int(Double(h) * fyFromTop)))
        let buf = raw.assumingMemoryBound(to: UInt8.self)
        let o = y * ctx.bytesPerRow + x * 4
        return (Double(buf[o]) / 255, Double(buf[o + 1]) / 255, Double(buf[o + 2]) / 255)
    }

    private static func assertRGB(_ c: (r: Double, g: Double, b: Double),
                                  r: ClosedRange<Double>, g: ClosedRange<Double>, b: ClosedRange<Double>,
                                  what: String) throws {
        guard r.contains(c.r), g.contains(c.g), b.contains(c.b) else {
            throw TestError.message("\(what): unexpected color (\(c.r), \(c.g), \(c.b))")
        }
    }

    /// The media box must come from the chosen page size, not from the CGPDFContext
    /// default. Passing it as NSValue instead of CFData fails silently and yields
    /// 612x792 US Letter on every page.
    private static func testConvertPageSize() throws {
        let image = try makeCGImage(width: 400, height: 400,
                                    left: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                                    right: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        let src = try writeImage([image], name: "conv-square.png", type: .png)
        let out = dir.appendingPathComponent("conv-a4.pdf")

        var options = ImageToPDFOptions()
        options.pageSize = .fitA4
        let result = try ImageToPDF.convert(inputs: [src], to: out, options: options)

        guard result.pageCount == 1 else {
            throw TestError.message("expected 1 page, got \(result.pageCount)")
        }
        guard let doc = PDFDocument(url: out), let page = doc.page(at: 0) else {
            throw TestError.message("converted PDF invalid")
        }
        let box = page.bounds(for: .mediaBox)
        guard abs(box.width - 595.276) < 1, abs(box.height - 841.89) < 1 else {
            throw TestError.message("expected A4 media box, got \(box.size)")
        }

        // Square image on portrait A4: full width, centred band. Sample the vertical
        // centre (fy 0.5), left half red and right half blue.
        let rendered = try renderPageRGB(page, pixelsWide: 300, pixelsHigh: 424)
        try assertRGB(try sampleRGB(rendered, fx: 0.25, fyFromTop: 0.5),
                      r: 0.7...1.0, g: 0.0...0.3, b: 0.0...0.3, what: "fitA4 left half")
        try assertRGB(try sampleRGB(rendered, fx: 0.75, fyFromTop: 0.5),
                      r: 0.0...0.3, g: 0.0...0.3, b: 0.7...1.0, what: "fitA4 right half")
    }

    /// EXIF orientation 6 is what every phone camera writes. Ignoring it puts photos
    /// on their side, which no user reads as anything but a broken app.
    private static func testConvertExifOrientation() throws {
        // Stored landscape, left red / right green. Orientation 6 rotates 90° CW for
        // display, so the page becomes portrait and red must end up on top.
        let image = try makeCGImage(width: 200, height: 100,
                                    left: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                                    right: CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        let src = try writeImage([image], name: "conv-rot6.jpg", type: .jpeg,
                                 properties: [kCGImagePropertyOrientation: 6])
        let out = dir.appendingPathComponent("conv-rot6.pdf")

        var options = ImageToPDFOptions()
        options.pageSize = .pixels
        _ = try ImageToPDF.convert(inputs: [src], to: out, options: options)

        guard let doc = PDFDocument(url: out), let page = doc.page(at: 0) else {
            throw TestError.message("rotated PDF invalid")
        }
        let box = page.bounds(for: .mediaBox)
        guard abs(box.width - 100) < 1, abs(box.height - 200) < 1 else {
            throw TestError.message("orientation 6 should give a 100x200 page, got \(box.size)")
        }

        // OS reference (CGImageSourceCreateThumbnailWithTransform) for this exact
        // source: red at the top (255,39,0), green at the bottom (1,248,1).
        let rendered = try renderPageRGB(page, pixelsWide: 100, pixelsHigh: 200)
        try assertRGB(try sampleRGB(rendered, fx: 0.5, fyFromTop: 0.25),
                      r: 0.7...1.0, g: 0.0...0.3, b: 0.0...0.3, what: "orientation 6 top")
        try assertRGB(try sampleRGB(rendered, fx: 0.5, fyFromTop: 0.75),
                      r: 0.0...0.3, g: 0.7...1.0, b: 0.0...0.3, what: "orientation 6 bottom")
    }

    /// PDFKit counts files, not frames: a three-page TIFF would become one page and
    /// the other two would vanish without any error.
    private static func testConvertMultiFrame() throws {
        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        let frames = try (0..<3).map { _ in try makeCGImage(width: 120, height: 80, left: red, right: blue) }
        let src = try writeImage(frames, name: "conv-multi.tiff", type: .tiff)
        let out = dir.appendingPathComponent("conv-multi.pdf")

        let result = try ImageToPDF.convert(inputs: [src], to: out, options: ImageToPDFOptions())
        guard result.pageCount == 3 else {
            throw TestError.message("multi-frame TIFF should give 3 pages, got \(result.pageCount)")
        }
        guard let doc = PDFDocument(url: out), doc.pageCount == 3 else {
            throw TestError.message("multi-frame PDF does not contain 3 pages")
        }
    }

    /// A CGPDFContext that never began a page still writes a valid 811-byte file that
    /// reads back as one blank page, so "no error" must not count as success.
    private static func testConvertRejectsPDFInput() throws {
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let pdf = try makePDF(name: "conv-input.pdf", size: CGSize(width: 200, height: 200), fill: white)
        let out = dir.appendingPathComponent("conv-frompdf.pdf")

        do {
            _ = try ImageToPDF.convert(inputs: [pdf], to: out, options: ImageToPDFOptions())
            throw TestError.message("converting a PDF input should fail, not produce a blank page")
        } catch let error as ConvertError {
            guard error == .noReadableInput else {
                throw TestError.message("expected noReadableInput, got \(error)")
            }
        }
        guard !FileManager.default.fileExists(atPath: out.path) else {
            throw TestError.message("failed conversion left a file behind")
        }
    }

    private static func testPDFToImageExport() throws {
        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        let green = CGColor(red: 0, green: 1, blue: 0, alpha: 1)
        let src = try makePDF(name: "conv-export.pdf", size: CGSize(width: 200, height: 100),
                              fill: red, rightHalf: green)
        guard let doc = PDFDocument(url: src) else {
            throw TestError.message("could not open export source")
        }
        let folder = dir.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var options = PDFToImageOptions()
        options.format = .png
        options.dpi = 150
        let result = try PDFToImage.convert(document: doc, baseName: "Page", into: folder, options: options)

        guard result.outputs.count == 1, let url = result.outputs.first else {
            throw TestError.message("expected one exported image, got \(result.outputs.count)")
        }
        guard let rep = NSBitmapImageRep(data: try Data(contentsOf: url)) else {
            throw TestError.message("exported image is not readable")
        }
        // 200 pt at 150 dpi is 416.7 px, rounded to 417.
        guard rep.pixelsWide == 417, rep.pixelsHigh == 208 else {
            throw TestError.message("expected 417x208 px, got \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }
        guard let left = rep.colorAt(x: 50, y: 100)?.usingColorSpace(.deviceRGB),
              let right = rep.colorAt(x: 360, y: 100)?.usingColorSpace(.deviceRGB) else {
            throw TestError.message("could not sample exported image")
        }
        try assertColor(left, r: 0.7...1.0, g: 0.0...0.4, b: 0.0...0.4, what: "export left half")
        try assertColor(right, r: 0.0...0.4, g: 0.7...1.0, b: 0.0...0.4, what: "export right half")
    }

    // MARK: - Page grid operations (v2)

    private static let palette: [CGColor] = [
        CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1),
        CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 0, alpha: 1),
        CGColor(red: 0, green: 1, blue: 1, alpha: 1),
    ]

    /// A fresh model holding five single-colour pages, undo grouped per call.
    @MainActor
    private static func makeModel() throws -> (DocumentModel, [PDFPage]) {
        let urls = try palette.enumerated().map {
            try makePDF(name: "ops-\($0.offset).pdf", size: CGSize(width: 200, height: 200), fill: $0.element)
        }
        let model = DocumentModel()
        model.undoManager.groupsByEvent = false
        model.openUntitled(try FileImport.document(from: urls), name: "Test", mode: .pages)
        guard model.pageCount == 5 else { throw TestError.message("merge into model: \(model.pageCount) pages") }
        return (model, model.pages)
    }

    @MainActor
    private static func step(_ model: DocumentModel, _ action: () -> Void) {
        model.undoManager.beginUndoGrouping()
        action()
        model.undoManager.endUndoGrouping()
    }

    @MainActor
    private static func assertOrder(_ model: DocumentModel, _ expected: [PDFPage], _ what: String) throws {
        guard model.pages.count == expected.count, zip(model.pages, expected).allSatisfy({ $0 === $1 }) else {
            throw TestError.message("\(what): unexpected page order")
        }
    }

    @MainActor
    private static func testPageOperations() throws {
        let (model, p) = try makeModel()

        // Drag pages 4 and 5 to the front, undo, redo.
        step(model) { model.movePages([3, 4], to: 0) }
        try assertOrder(model, [p[3], p[4], p[0], p[1], p[2]], "move block to front")
        model.undo()
        try assertOrder(model, p, "undo move")
        model.redo()
        try assertOrder(model, [p[3], p[4], p[0], p[1], p[2]], "redo move")
        model.undo()

        // Drop page 1 behind page 3 (insertion index 3 = before page 4).
        step(model) { model.movePages([0], to: 3) }
        try assertOrder(model, [p[1], p[2], p[0], p[3], p[4]], "move one page back")
        model.undo()

        // Delete pages 2 and 4 in one step; never all pages.
        step(model) { model.deletePages([1, 3]) }
        try assertOrder(model, [p[0], p[2], p[4]], "delete two pages")
        model.undo()
        try assertOrder(model, p, "undo delete")
        step(model) { model.deletePages([0, 1, 2, 3, 4]) }
        guard model.pageCount == 5 else { throw TestError.message("deleting every page must be refused") }

        // Rotate a selection.
        step(model) { model.rotatePages([0, 2], clockwise: true) }
        guard p[0].rotation == 90, p[1].rotation == 0, p[2].rotation == 90 else {
            throw TestError.message("rotate selection")
        }
        model.undo()
        guard p[0].rotation == 0, p[2].rotation == 0 else { throw TestError.message("undo rotate") }

        // Insert a PDF (merge) after page 2, undo.
        let extra = try makePDF(name: "ops-extra.pdf", size: CGSize(width: 200, height: 200),
                                fill: CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        step(model) { model.insertFiles([extra], at: 2) }
        guard model.pageCount == 6, model.selectedIndices == [2] else {
            throw TestError.message("insert file: \(model.pageCount) pages, selection \(model.selectedIndices)")
        }
        model.undo()
        try assertOrder(model, p, "undo insert")

        // Click, ⇧-click, ⌘-click.
        model.selectPage(at: 1, extend: false, range: false)
        model.selectPage(at: 3, extend: false, range: true)
        guard model.selectedIndices == [1, 2, 3] else { throw TestError.message("range selection") }
        model.selectPage(at: 2, extend: true, range: false)
        guard model.selectedIndices == [1, 3] else { throw TestError.message("toggle selection") }

        guard PDFTools.rangeLabel([0, 1, 2, 4]) == "1–3, 5", PDFTools.rangeLabel([6]) == "7" else {
            throw TestError.message("range label")
        }
    }

    @MainActor
    private static func testSplitAtCutMarks() throws {
        let (model, p) = try makeModel()
        model.toggleCut(after: p[1])
        model.toggleCut(after: p[3])
        model.toggleCut(after: p[4]) // after the last page: no extra part
        guard model.parts == [[0, 1], [2, 3], [4]] else { throw TestError.message("parts \(model.parts)") }

        // Cuts follow their page when pages move.
        step(model) { model.movePages([1], to: 0) }
        guard model.parts == [[0], [1, 2, 3], [4]] else {
            throw TestError.message("parts after move \(model.parts)")
        }
        model.undo()

        let folder = dir.appendingPathComponent("parts", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard try model.splitAtCutMarks(folder: folder) == 3 else { throw TestError.message("split count") }
        let counts = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { PDFDocument(url: $0)?.pageCount ?? -1 }
        guard counts == [2, 2, 1] else { throw TestError.message("split page counts \(counts)") }
    }

    /// Initials on every page must land in the lower right corner *as seen*,
    /// upright, also on rotated pages.
    @MainActor
    private static func testInitialsOnRotatedPage() throws {
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let url = try makePDF(name: "initials-src.pdf", size: CGSize(width: 300, height: 400), fill: white)
        let model = DocumentModel()
        model.undoManager.groupsByEvent = false
        model.openUntitled(try FileImport.document(from: [url, url, url, url]), name: "Initials", mode: .document)
        for (index, rotation) in [0, 90, 180, 270].enumerated() {
            model.document?.page(at: index)?.rotation = rotation
        }
        // Red block, wider than tall, so a sideways placement would show.
        let red = NSImage(size: NSSize(width: 60, height: 20), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        step(model) { model.placeOnEveryPage(image: red, width: 60) }
        guard model.stamps.count == 4 else { throw TestError.message("initials on every page: \(model.stamps.count)") }

        let out = dir.appendingPathComponent("initials-out.pdf")
        try model.exportCurrentState(to: out)
        guard let flat = PDFDocument(url: out), flat.pageCount == 4 else {
            throw TestError.message("initials export")
        }
        for index in 0..<4 {
            guard let page = flat.page(at: index) else { continue }
            let size = page.bounds(for: .mediaBox).size
            let rep = try rasterize(page, size: size)
            // 28 pt margin, 60×20 block: (x 212…272, y 28…48) from the lower left as shown.
            let inside = try pixel(rep, pageSize: size, x: size.width - 28 - 30, y: 28 + 10)
            try assertColor(inside, r: 0.7...1, g: 0...0.35, b: 0...0.35, what: "initials page \(index + 1)")
            // Just above the block must be white: proves the block lies flat, not on its side.
            let above = try pixel(rep, pageSize: size, x: size.width - 28 - 30, y: 28 + 20 + 12)
            try assertColor(above, r: 0.85...1, g: 0.85...1, b: 0.85...1, what: "above initials page \(index + 1)")
        }
    }

    @MainActor
    private static func testShareExport() throws {
        let (model, _) = try makeModel()
        model.untitledName = "Vertrag"
        guard model.exportFileName == "Vertrag.pdf" else { throw TestError.message("share name \(model.exportFileName)") }
        let red = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        guard let page = model.document?.page(at: 0) else { return }
        model.startPlacing(image: red, defaultWidth: 40, label: "x")
        // A placement preview must never end up in an export.
        model.updateGhost(at: CGPoint(x: 150, y: 150), on: page)
        model.startPlacing(image: red, defaultWidth: 40, label: "x")
        step(model) { model.place(at: CGPoint(x: 50, y: 50), on: page) }
        guard model.exportFileName.hasSuffix(loc("save.suffix") + ".pdf") else {
            throw TestError.message("signed share name \(model.exportFileName)")
        }
        model.startPlacing(image: red, defaultWidth: 40, label: "x")
        model.updateGhost(at: CGPoint(x: 150, y: 150), on: page)
        let url = try model.exportForSharing()
        guard let shared = PDFDocument(url: url), shared.pageCount == 5,
              url.lastPathComponent == model.exportFileName else {
            throw TestError.message("share export")
        }
        let rep = try rasterize(shared.page(at: 0)!, size: CGSize(width: 200, height: 200))
        try assertColor(try pixel(rep, pageSize: CGSize(width: 200, height: 200), x: 50, y: 50),
                        r: 0.7...1, g: 0...0.35, b: 0...0.35, what: "shared stamp")
        // Ghost spot keeps the page colour (red page 1 → still red, so check via stamp count instead).
        guard page.annotations.filter({ ($0 as? ImageStampAnnotation)?.opacity ?? 1 < 1 }).isEmpty else {
            throw TestError.message("ghost still on the page after export")
        }
    }

    /// Saving reloads the file: cut marks and selection must follow by index,
    /// and filled-in form fields must count as unsaved changes.
    @MainActor
    private static func testSaveKeepsPageStateAndFormEdits() throws {
        let (model, p) = try makeModel()
        if let page = model.document?.page(at: 0) {
            let field = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 120, height: 20),
                                      forType: .widget, withProperties: nil)
            field.widgetFieldType = .text
            field.fieldName = "name"
            page.addAnnotation(field)
        }
        model.toggleCut(after: p[1])
        model.selectPage(at: 3, extend: false, range: false)
        let url = dir.appendingPathComponent("save-state.pdf")
        model.save(to: url)
        guard model.fileURL == url, model.parts == [[0, 1], [2, 3, 4]], model.selectedIndices == [3] else {
            throw TestError.message("save lost cut marks or selection: parts \(model.parts), selection \(model.selectedIndices)")
        }
        guard model.formFieldCount == 1, !model.formChangedSinceLoad, !model.hasChanges else {
            throw TestError.message("form state after save")
        }
        // Typing into a field happens inside PDFKit; the value comparison must see it.
        model.document?.page(at: 0)?.annotations.first { $0.fieldName == "name" }?.widgetStringValue = "Finn"
        guard model.formChangedSinceLoad else { throw TestError.message("form edit not detected") }
    }

    /// A form without form fields: lines, a label with space after it, an
    /// empty box and checkboxes are found; round letters, a rule across the
    /// page and a table are not.
    @MainActor
    private static func testFieldDetection() throws {
        let url = dir.appendingPathComponent("fields.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw TestError.message("fields ctx") }
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let font: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black]
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat) { (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: font) }
        func line(_ x0: CGFloat, _ y: CGFloat, _ x1: CGFloat) {
            ctx.setLineWidth(0.8); ctx.move(to: CGPoint(x: x0, y: y)); ctx.addLine(to: CGPoint(x: x1, y: y)); ctx.strokePath()
        }
        ctx.setStrokeColor(NSColor.black.cgColor)
        line(60, 760, 535)                                       // rule across the page: no field
        text("Oo0 Ordnung, Datum:", 60, 700)                     // round letters, label with space
        text("Straße:", 60, 660); line(120, 658, 380)            // line after a label
        ctx.stroke(CGRect(x: 60, y: 600, width: 11, height: 11)) // checkbox
        ctx.stroke(CGRect(x: 60, y: 500, width: 300, height: 60)) // empty box
        for i in 0...2 { line(60, 400 - CGFloat(i) * 20, 300) }  // table grid: no field
        for x in [60, 180, 300] as [CGFloat] {
            ctx.move(to: CGPoint(x: x, y: 400)); ctx.addLine(to: CGPoint(x: x, y: 360)); ctx.strokePath()
        }
        line(60, 200, 260)                                        // signature line
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()

        guard let page = PDFDocument(url: url)?.page(at: 0), let input = FieldDetector.input(for: page) else {
            throw TestError.message("fields input")
        }
        let fields = FieldDetector.detect(input)
        let kinds = fields.map(\.kind)
        let summary = fields.map { "\($0.kind)@\(Int($0.rect.minX)),\(Int($0.rect.minY))" }.joined(separator: " ")
        guard kinds.filter({ $0 == .checkbox }).count == 1,
              kinds.filter({ $0 == .box }).count == 1,
              kinds.filter({ $0 == .label }).count == 1,
              kinds.filter({ $0 == .line }).count == 2,
              !fields.contains(where: { $0.rect.minY > 740 }),             // not the rule
              !fields.contains(where: { $0.rect.minY > 355 && $0.rect.maxY < 410 }) // not the table
        else {
            throw TestError.message("field detection: \(summary)")
        }
    }
}
