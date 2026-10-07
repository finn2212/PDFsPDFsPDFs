import AppKit

enum ImageUtils {

    /// Renders drawn strokes (top-left origin coordinates) into a transparent PNG,
    /// cropped to the ink's bounding box with padding, at 3x resolution.
    static func renderStrokes(_ strokes: [[CGPoint]], canvasSize: CGSize) -> Data? {
        let points = strokes.flatMap { $0 }
        guard !points.isEmpty else { return nil }

        let padding: CGFloat = 10
        let minX = max(0, points.map(\.x).min()! - padding)
        let maxX = min(canvasSize.width, points.map(\.x).max()! + padding)
        let minY = max(0, points.map(\.y).min()! - padding)
        let maxY = min(canvasSize.height, points.map(\.y).max()! + padding)
        let cropW = max(maxX - minX, 1)
        let cropH = max(maxY - minY, 1)

        let scale: CGFloat = 3
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(cropW * scale),
            pixelsHigh: Int(cropH * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let transform = NSAffineTransform()
        transform.scale(by: scale)
        // Flip: stroke points use top-left origin, bitmap uses bottom-left.
        transform.translateX(by: -minX, yBy: cropH + minY)
        transform.scaleX(by: 1, yBy: -1)
        transform.concat()

        NSColor.black.setStroke()
        for stroke in strokes where !stroke.isEmpty {
            let path = NSBezierPath()
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: stroke[0])
            if stroke.count == 1 {
                path.line(to: CGPoint(x: stroke[0].x + 0.1, y: stroke[0].y))
            }
            for p in stroke.dropFirst() { path.line(to: p) }
            path.stroke()
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Makes near-white pixels transparent (for photographed/scanned signatures).
    static func removeWhiteBackground(from data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buffer = ctx.data else { return nil }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)

        let lower: CGFloat = 0.82
        let upper: CGFloat = 0.97
        for i in 0..<(width * height) {
            let o = i * 4
            let a = CGFloat(pixels[o + 3]) / 255
            guard a > 0 else { continue }
            let r = CGFloat(pixels[o]) / 255 / a
            let g = CGFloat(pixels[o + 1]) / 255 / a
            let b = CGFloat(pixels[o + 2]) / 255 / a
            let brightness = (r + g + b) / 3
            if brightness > lower {
                let newAlpha = max(0, min(1, (upper - brightness) / (upper - lower)))
                pixels[o] = UInt8(min(255, r * newAlpha * 255))
                pixels[o + 1] = UInt8(min(255, g * newAlpha * 255))
                pixels[o + 2] = UInt8(min(255, b * newAlpha * 255))
                pixels[o + 3] = UInt8(newAlpha * 255)
            }
        }

        guard let outCG = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: outCG)
        return rep.representation(using: .png, properties: [:])
    }

    /// Renders text (multi-line capable) into a transparent PNG at 3x resolution.
    static func renderText(_ text: String, fontSize: CGFloat) -> Data? {
        let font = NSFont.systemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let bounds = attributed.boundingRect(
            with: NSSize(width: 2000, height: 2000),
            options: [.usesLineFragmentOrigin]
        )
        let padding: CGFloat = 2
        let size = CGSize(width: ceil(bounds.width) + padding * 2,
                          height: ceil(bounds.height) + padding * 2)
        guard size.width > padding * 2, size.height > padding * 2 else { return nil }

        let scale: CGFloat = 3
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = NSAffineTransform()
        transform.scale(by: scale)
        transform.concat()
        attributed.draw(with: NSRect(x: padding, y: padding,
                                     width: size.width - padding * 2,
                                     height: size.height - padding * 2),
                        options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Script fonts for typed signatures, in order of preference; only the
    /// installed ones are offered.
    static let signatureFonts: [String] = [
        "SnellRoundhand", "BradleyHandITCTT-Bold", "SavoyeLetPlain", "Noteworthy-Light",
    ].filter { NSFont(name: $0, size: 12) != nil }

    /// Renders a typed signature in a script font into a transparent PNG at 3x,
    /// cropped to the ink (swashes reach far outside the typographic bounds).
    static func renderSignature(_ text: String, fontName: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let font = NSFont(name: fontName, size: 44) ?? NSFont.systemFont(ofSize: 44)
        let attributed = NSAttributedString(string: trimmed, attributes: [
            .font: font, .foregroundColor: NSColor.black,
        ])
        let bounds = attributed.boundingRect(with: NSSize(width: 4000, height: 400),
                                             options: [.usesLineFragmentOrigin])
        let padding: CGFloat = 40
        let size = CGSize(width: ceil(bounds.width) + padding * 2,
                          height: ceil(bounds.height) + padding * 2)
        let scale: CGFloat = 3
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = NSAffineTransform()
        transform.scale(by: scale)
        transform.concat()
        attributed.draw(with: NSRect(x: padding, y: padding, width: bounds.width + 4,
                                     height: bounds.height + 4),
                        options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage, let cropped = cropToInk(cg, padding: Int(6 * scale)) else {
            return rep.representation(using: .png, properties: [:])
        }
        return NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
    }

    /// Crops an image to the bounding box of its non-transparent pixels.
    static func cropToInk(_ image: CGImage, padding: Int) -> CGImage? {
        let width = image.width, height = image.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buffer = ctx.data else { return nil }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // Buffer rows run top-down, matching CGImage cropping coordinates.
        let rect = CGRect(x: max(0, minX - padding), y: max(0, minY - padding),
                          width: min(width, maxX + padding + 1) - max(0, minX - padding),
                          height: min(height, maxY + padding + 1) - max(0, minY - padding))
        return image.cropping(to: rect)
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
