#!/usr/bin/env swift
// Renders the DMG installer window background: a soft gradient, an arrow pointing
// from the app icon slot to the Applications slot, and a bilingual instruction.
// Output: assets/dmg/background.png (600x400) + background@2x.png (1200x800).
// The DMG window is 600x400 pt; Finder draws the two icons on top at fixed
// positions, so this image only supplies the gradient, arrow and text.
import AppKit

let W: CGFloat = 600, H: CGFloat = 400
// Icon centres in Finder (top-left origin). Kept in sync with make_dmg.sh.
let appIconX: CGFloat = 155
let appsIconX: CGFloat = 445
let iconTopLeftY: CGFloat = 195
// Same height in this bottom-left drawing space.
let iconCenterY = H - iconTopLeftY

let accent = NSColor(calibratedRed: 0.15, green: 0.42, blue: 0.92, alpha: 1)
let ink = NSColor(calibratedWhite: 0.16, alpha: 1)
let subtle = NSColor(calibratedWhite: 0.42, alpha: 1)

func draw(in rect: NSRect) {
    // Background gradient.
    let top = NSColor(calibratedRed: 0.972, green: 0.976, blue: 0.984, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.902, green: 0.918, blue: 0.945, alpha: 1)
    NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)

    // Arrow, centred vertically on the icons, sitting in the gap between them.
    let arrowLeft: CGFloat = 248
    let arrowRight: CGFloat = 352
    let shaftHeight: CGFloat = 12
    let headWidth: CGFloat = 30
    let headHeight: CGFloat = 30
    let y = iconCenterY

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: arrowLeft, y: y - shaftHeight / 2))
    arrow.line(to: NSPoint(x: arrowRight - headWidth, y: y - shaftHeight / 2))
    arrow.line(to: NSPoint(x: arrowRight - headWidth, y: y - headHeight / 2))
    arrow.line(to: NSPoint(x: arrowRight, y: y))
    arrow.line(to: NSPoint(x: arrowRight - headWidth, y: y + headHeight / 2))
    arrow.line(to: NSPoint(x: arrowRight - headWidth, y: y + shaftHeight / 2))
    arrow.line(to: NSPoint(x: arrowLeft, y: y + shaftHeight / 2))
    arrow.close()
    accent.withAlphaComponent(0.92).setFill()
    arrow.fill()

    // Headline (DE) + subtitle (EN), top-centred.
    func centeredText(_ text: String, font: NSFont, color: NSColor, baselineFromTop: CGFloat) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: para,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let r = NSRect(x: 0, y: H - baselineFromTop - size.height, width: W, height: size.height)
        (text as NSString).draw(in: r, withAttributes: attrs)
    }

    centeredText("PDFsPDFsPDFs installieren",
                 font: .systemFont(ofSize: 25, weight: .semibold), color: ink, baselineFromTop: 46)
    centeredText("Install PDFsPDFsPDFs",
                 font: .systemFont(ofSize: 13, weight: .regular), color: subtle, baselineFromTop: 80)

    // Instruction line, bottom-centred, both languages.
    centeredText("Symbol in den Programme-Ordner ziehen",
                 font: .systemFont(ofSize: 13, weight: .medium), color: ink, baselineFromTop: H - 66)
    centeredText("Drag the icon onto the Applications folder",
                 font: .systemFont(ofSize: 12, weight: .regular), color: subtle, baselineFromTop: H - 46)
}

func render(scale: Int, to path: String) {
    let pxW = Int(W) * scale, pxH = Int(H) * scale
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        FileHandle.standardError.write("could not create bitmap\n".data(using: .utf8)!)
        exit(1)
    }
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(in: NSRect(x: 0, y: 0, width: W, height: H))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("could not encode png\n".data(using: .utf8)!)
        exit(1)
    }
    try? data.write(to: URL(fileURLWithPath: path))
}

let outDir = "assets/dmg"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
render(scale: 1, to: "\(outDir)/background.png")
render(scale: 2, to: "\(outDir)/background@2x.png")
print("Wrote \(outDir)/background.png + @2x")
