import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// PDF → images, one file per page.
///
/// Rendering goes through a hand-built `CGContext` rather than
/// `PDFPage.thumbnail(of:for:)`: the thumbnail path is measurably softer below
/// 300 dpi, rounds the requested size, and cannot express transparency.
/// `NSImage.lockFocus` is worse still — it renders on a black backdrop.
enum PDFToImage {
    static func convert(document: PDFDocument,
                        baseName: String,
                        into folder: URL,
                        options: PDFToImageOptions,
                        progress: (Double) -> Void = { _ in },
                        isCancelled: () -> Bool = { false }) throws -> ConvertResult {
        // Holding the document strongly for the whole loop is load-bearing: PDFKit
        // logs "Drawing a PDFPage when its PDFDocument is nil is unsupported" and
        // renders nothing once the owner is released.
        let doc = document
        let indices = options.pageIndices ?? Array(0..<doc.pageCount)
        guard !indices.isEmpty else { throw ConvertError.noReadableInput }

        var result = ConvertResult()
        let scale = CGFloat(options.dpi) / 72
        let digits = max(2, String(doc.pageCount).count)

        for (step, index) in indices.enumerated() {
            if isCancelled() {
                for url in result.outputs { try? FileManager.default.removeItem(at: url) }
                throw ConvertError.cancelled
            }
            // Without a pool per page a 200-page export at 300 dpi grows from 82 MB
            // to 6.7 GB and never gives it back.
            try autoreleasepool {
                guard let page = doc.page(at: index) else { return }
                let bounds = page.bounds(for: .mediaBox)

                // bounds(for:) reports the *unrotated* size while draw() applies the
                // rotation, so a 90°-rotated page renders into an empty canvas unless
                // width and height are swapped here.
                let quarterTurned = abs(page.rotation % 180) == 90
                let pointSize = quarterTurned
                    ? CGSize(width: bounds.height, height: bounds.width)
                    : bounds.size

                let pixelWidth = Int((pointSize.width * scale).rounded())
                let pixelHeight = Int((pointSize.height * scale).rounded())
                guard pixelWidth > 0, pixelHeight > 0 else { return }

                guard let ctx = CGContext(data: nil,
                                          width: pixelWidth,
                                          height: pixelHeight,
                                          bitsPerComponent: 8,
                                          bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw ConvertError.writeFailed
                }

                // A PDF page is paper: without this fill JPEG output comes out black.
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

                // CGPDFPageGetDrawingTransform never scales up, so the zoom has to
                // come from the CTM and the page is then drawn in points.
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx)

                guard let image = ctx.makeImage() else { throw ConvertError.writeFailed }

                let name = String(format: "%@ %0\(digits)d.%@", baseName, index + 1,
                                  options.format.fileExtension)
                let url = folder.appendingPathComponent(name)
                try write(image, to: url, options: options)
                result.outputs.append(url)
                result.pageCount += 1
            }
            progress(Double(step + 1) / Double(indices.count))
        }

        guard result.pageCount > 0 else { throw ConvertError.noPagesWritten }
        return result
    }

    private static func write(_ image: CGImage, to url: URL, options: PDFToImageOptions) throws {
        // Always one image per destination: passing a count > 1 to a PNG destination
        // silently produces an animated APNG instead of separate files.
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         options.format.utTypeIdentifier,
                                                         1, nil) else {
            throw ConvertError.writeFailed
        }

        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: options.dpi,
            kCGImagePropertyDPIHeight: options.dpi,
        ]
        if options.format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        if options.format == .tiff {
            // Without an explicit LZW setting TIFF pages come out roughly 98x larger.
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFCompression: 5,
            ] as CFDictionary
        }

        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.writeFailed }
    }
}
