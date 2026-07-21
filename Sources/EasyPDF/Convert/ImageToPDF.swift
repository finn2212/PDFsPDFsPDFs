import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images → PDF.
///
/// There is exactly one code path here: a `CGPDFContext` that the decoded image is
/// drawn into. The two obvious alternatives were measured and both lose data silently:
/// `CGImageDestination` with `UTType.pdf` ignores EXIF orientation and DPI, drops the
/// alpha channel (onto white for PNG, onto *black* for HEIC) and keeps only the first
/// frame of a multi-page TIFF; `PDFPage(image:)` always re-compresses to JPEG,
/// composites partially transparent pixels wrong, and counts files instead of frames.
enum ImageToPDF {
    /// The PDF format caps page dimensions at 14400 pt; below 3 pt readers misbehave.
    private static let minPageSide: CGFloat = 3
    private static let maxPageSide: CGFloat = 14400
    /// A 154-byte BMP with a forged 30000x30000 header allocates 7.2 GB before any
    /// API complains, so the pixel count is checked from metadata before decoding.
    private static let maxMegapixels = 100

    static func convert(inputs: [URL],
                        to destination: URL,
                        options: ImageToPDFOptions,
                        progress: (Double) -> Void = { _ in },
                        isCancelled: () -> Bool = { false }) throws -> ConvertResult {
        guard !inputs.isEmpty else { throw ConvertError.noReadableInput }

        var result = ConvertResult()
        var sources: [URL] = []
        for url in inputs {
            // CGImageSourceCreateWithURL does not return nil for a PDF — it reports
            // type com.adobe.pdf and the right page count, then decodes nothing.
            if ConvertSupport.contentType(of: url)?.conforms(to: .pdf) == true {
                result.warnings.append(.fileSkipped(file: url.lastPathComponent,
                                                    reason: loc("convert.warn.reasonPDF")))
                continue
            }
            guard ConvertSupport.isConvertibleImage(url) else {
                result.warnings.append(.fileSkipped(file: url.lastPathComponent,
                                                    reason: loc("convert.warn.reasonType")))
                continue
            }
            sources.append(url)
        }
        guard !sources.isEmpty else { throw ConvertError.noReadableInput }

        var defaultBox = CGRect(x: 0, y: 0, width: 595.276, height: 841.89)
        guard let ctx = CGContext(destination as CFURL, mediaBox: &defaultBox, nil) else {
            throw ConvertError.writeFailed
        }

        var wrote = 0
        for (index, url) in sources.enumerated() {
            if isCancelled() {
                ctx.closePDF()
                try? FileManager.default.removeItem(at: destination)
                throw ConvertError.cancelled
            }
            try autoreleasepool {
                if ConvertSupport.isSVG(url) {
                    wrote += try appendSVG(url, to: ctx, options: options, result: &result)
                } else {
                    wrote += try appendRaster(url, to: ctx, options: options, result: &result)
                }
            }
            progress(Double(index + 1) / Double(sources.count))
        }

        ctx.closePDF()

        // A CGPDFContext that never saw beginPDFPage still writes a valid 811-byte
        // file that PDFKit reads back as one blank page, and reports no error at all.
        guard wrote > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw ConvertError.noPagesWritten
        }

        result.outputs = [destination]
        result.pageCount = wrote
        return result
    }

    // MARK: - Raster images

    private static func appendRaster(_ url: URL,
                                     to ctx: CGContext,
                                     options: ImageToPDFOptions,
                                     result: inout ConvertResult) throws -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConvertError.decodeFailed(file: url.lastPathComponent)
        }
        let name = url.lastPathComponent
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { throw ConvertError.decodeFailed(file: name) }

        let limit = options.expandFrames ? min(frameCount, options.maxFrames) : 1
        // GIF is the format where a "restore to background" disposal turns cleared
        // regions into opaque black, so those frames get composited onto white.
        let isGIF = (CGImageSourceGetType(source) as String?) == UTType.gif.identifier

        var written = 0
        for frame in 0..<limit {
            try autoreleasepool {
                let props = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any]
                try checkPixelBudget(props, file: name)

                guard var image = CGImageSourceCreateImageAtIndex(source, frame, nil) else {
                    // The ImageIO GIF decoder returns nil above roughly 4.7 MP per
                    // frame while still reporting the correct frame count.
                    if isGIF { throw ConvertError.gifTooLarge(file: name) }
                    throw ConvertError.decodeFailed(file: name)
                }

                // Only meaningful *after* the decode: -5 is kCGImageStatusUnexpectedEOF.
                // A truncated JPEG otherwise decodes to full size with grey filler.
                if CGImageSourceGetStatusAtIndex(source, frame) != .statusComplete {
                    result.warnings.append(.truncatedSource(file: name))
                }

                if isGIF, let flattened = flattenOntoWhite(image) {
                    image = flattened
                }

                let orientation = (props?[kCGImagePropertyOrientation] as? Int) ?? 1
                if options.quality == .smaller {
                    if image.alphaInfo != .none, let flattened = flattenOntoWhite(image) {
                        image = flattened
                        result.warnings.append(.alphaFlattened(file: name))
                    }
                    if let recompressed = jpegBacked(image, quality: options.jpegQuality) {
                        image = recompressed
                    }
                }

                let pixelSize = CGSize(width: image.width, height: image.height)
                let (orient, orientedSize) = orientationTransform(orientation, size: pixelSize)
                let layout = pageLayout(for: orientedSize,
                                        dpi: dpi(from: props),
                                        mode: options.pageSize)
                if layout.clamped {
                    result.warnings.append(.pageClamped(file: name))
                }

                ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData(layout.page)] as CFDictionary)
                ctx.saveGState()
                // Fit first (page space → oriented image space), then orient
                // (oriented space → raw pixel space). Applying the EXIF rotation via
                // the CTM rather than re-rendering is what keeps a JPEG source
                // byte-identical: re-rendering through CIImage doubled the file size.
                ctx.translateBy(x: layout.draw.origin.x, y: layout.draw.origin.y)
                ctx.scaleBy(x: layout.draw.width / orientedSize.width,
                            y: layout.draw.height / orientedSize.height)
                ctx.concatenate(orient)
                ctx.draw(image, in: CGRect(origin: .zero, size: pixelSize))
                ctx.restoreGState()
                ctx.endPDFPage()
                written += 1
            }
        }

        if written < frameCount && options.expandFrames {
            result.warnings.append(.framesSkipped(file: name, converted: written, expected: frameCount))
        }
        return written
    }

    // MARK: - SVG

    /// Apple's SVG renderer produces a real vector page with searchable text, but it
    /// silently drops features (marker-end, bold+italic combined, foreignObject), so
    /// every SVG conversion carries a warning — the file cannot be inspected for them.
    private static func appendSVG(_ url: URL,
                                  to ctx: CGContext,
                                  options: ImageToPDFOptions,
                                  result: inout ConvertResult) throws -> Int {
        let name = url.lastPathComponent
        // NSImageRep.imageTypes does not list public.svg-image even where SVG works,
        // so a successful load is the only usable capability check.
        guard let image = NSImage(contentsOf: url) else {
            throw ConvertError.decodeFailed(file: name)
        }
        let size = image.size
        guard size.width > 0, size.height > 0,
              size.width.isFinite, size.height.isFinite else {
            throw ConvertError.decodeFailed(file: name)
        }

        let layout = pageLayout(for: size, dpi: CGSize(width: 72, height: 72), mode: options.pageSize)
        if layout.clamped {
            result.warnings.append(.pageClamped(file: name))
        }

        ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData(layout.page)] as CFDictionary)
        ctx.saveGState()
        let graphicsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        image.draw(in: layout.draw)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
        ctx.endPDFPage()

        result.warnings.append(.svgFeaturesUnsupported(file: name))
        return 1
    }

    // MARK: - Geometry

    struct PageLayout {
        var page: CGRect
        var draw: CGRect
        var clamped: Bool
    }

    static func pageLayout(for imageSize: CGSize, dpi: CGSize, mode: PageSizeMode) -> PageLayout {
        if let paper = mode.paperSize {
            // Auto portrait/landscape, aspect preserved, centred — never stretched.
            let landscape = imageSize.width > imageSize.height
            let sheet = landscape ? CGSize(width: paper.height, height: paper.width) : paper
            let scale = min(sheet.width / imageSize.width, sheet.height / imageSize.height)
            let drawn = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let draw = CGRect(x: (sheet.width - drawn.width) / 2,
                              y: (sheet.height - drawn.height) / 2,
                              width: drawn.width, height: drawn.height)
            return PageLayout(page: CGRect(origin: .zero, size: sheet), draw: draw, clamped: false)
        }

        var size: CGSize
        switch mode {
        case .dpi:
            let x = dpi.width > 0 ? dpi.width : 72
            let y = dpi.height > 0 ? dpi.height : 72
            size = CGSize(width: imageSize.width * 72 / x, height: imageSize.height * 72 / y)
        default:
            size = imageSize
        }

        let clampedWidth = min(max(size.width, minPageSide), maxPageSide)
        let clampedHeight = min(max(size.height, minPageSide), maxPageSide)
        let clamped = clampedWidth != size.width || clampedHeight != size.height
        size = CGSize(width: clampedWidth, height: clampedHeight)
        return PageLayout(page: CGRect(origin: .zero, size: size),
                          draw: CGRect(origin: .zero, size: size),
                          clamped: clamped)
    }

    /// Maps stored pixels to display orientation, and reports the resulting size.
    /// Orientations 5–8 swap width and height.
    static func orientationTransform(_ orientation: Int, size: CGSize) -> (CGAffineTransform, CGSize) {
        let w = size.width, h = size.height
        switch orientation {
        case 2:
            return (CGAffineTransform(translationX: w, y: 0).scaledBy(x: -1, y: 1), size)
        case 3:
            return (CGAffineTransform(translationX: w, y: h).scaledBy(x: -1, y: -1), size)
        case 4:
            return (CGAffineTransform(translationX: 0, y: h).scaledBy(x: 1, y: -1), size)
        case 5:
            return (CGAffineTransform(translationX: h, y: 0)
                        .rotated(by: .pi / 2)
                        .translatedBy(x: w, y: 0)
                        .scaledBy(x: -1, y: 1),
                    CGSize(width: h, height: w))
        case 6:
            return (CGAffineTransform(translationX: 0, y: w).rotated(by: -.pi / 2),
                    CGSize(width: h, height: w))
        case 7:
            return (CGAffineTransform(translationX: 0, y: w)
                        .rotated(by: -.pi / 2)
                        .translatedBy(x: w, y: 0)
                        .scaledBy(x: -1, y: 1),
                    CGSize(width: h, height: w))
        case 8:
            return (CGAffineTransform(translationX: h, y: 0).rotated(by: .pi / 2),
                    CGSize(width: h, height: w))
        default:
            return (.identity, size)
        }
    }

    // MARK: - Helpers

    /// kCGPDFContextMediaBox expects the raw bytes of a CGRect as CFData. Passing an
    /// NSValue fails silently and every page comes out as 612x792 US Letter.
    static func boxData(_ rect: CGRect) -> CFData {
        var box = rect
        return Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
    }

    private static func dpi(from props: [CFString: Any]?) -> CGSize {
        let x = (props?[kCGImagePropertyDPIWidth] as? CGFloat) ?? 0
        let y = (props?[kCGImagePropertyDPIHeight] as? CGFloat) ?? 0
        return CGSize(width: x > 0 ? x : 72, height: y > 0 ? y : 72)
    }

    private static func checkPixelBudget(_ props: [CFString: Any]?, file: String) throws {
        guard let width = props?[kCGImagePropertyPixelWidth] as? Int,
              let height = props?[kCGImagePropertyPixelHeight] as? Int else { return }
        let megapixels = (width * height) / 1_000_000
        if megapixels > maxMegapixels {
            throw ConvertError.imageTooLarge(file: file, megapixels: megapixels)
        }
    }

    private static func flattenOntoWhite(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Re-encodes as JPEG and reads it back, so the PDF embeds our chosen quality as
    /// a DCTDecode stream. Setting kCGImageDestinationLossyCompressionQuality on a
    /// PDF destination is ignored outright — q0.0 and q1.0 produce identical bytes.
    private static func jpegBacked(_ image: CGImage, quality: CGFloat) -> CGImage? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
