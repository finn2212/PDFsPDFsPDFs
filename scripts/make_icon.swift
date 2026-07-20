import AppKit

// Usage: swift scripts/make_icon.swift <input.png> <output-dir>
//
// Builds a full-bleed macOS app icon: crops the raw artwork to its *saturated*
// region (excluding the generator's white background and soft drop shadow),
// pre-fills the squircle with a gradient sampled from the artwork edges so no
// background can ever show through, then draws the artwork with slight overscan
// clipped to the squircle.

let args = CommandLine.arguments
guard args.count == 3,
      let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: make_icon.swift <input.png> <output-dir>"); exit(1)
}

let w = cg.width, h = cg.height
guard let src = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
src.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
guard let buf = src.data else { exit(1) }
let px = buf.bindMemory(to: UInt8.self, capacity: w * h * 4)

func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let o = (y * w + x) * 4
    return (Int(px[o]), Int(px[o + 1]), Int(px[o + 2]))
}

/// Saturated = clearly colored, so white background, gray shadow and the
/// near-black signature ink are all excluded.
func isSaturated(_ x: Int, _ y: Int) -> Bool {
    let (r, g, b) = rgb(x, y)
    return max(r, max(g, b)) - min(r, min(g, b)) > 45
}

// Bounding box of the colored rounded square.
var minX = w, maxX = 0, minY = h, maxY = 0
for y in 0..<h {
    for x in 0..<w where isSaturated(x, y) {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX > minX, maxY > minY else { print("no saturated artwork found"); exit(1) }

// Centered square crop of that region.
let side = max(maxX - minX, maxY - minY)
let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
let half = side / 2
let cropX = max(0, min(w - side, cx - half))
let cropYTop = max(0, min(h - side, cy - half))
guard let cropped = cg.cropping(to: CGRect(x: cropX, y: cropYTop, width: side, height: side)) else {
    print("crop failed"); exit(1)
}

/// Average color of a horizontal band inside the artwork, used as backdrop.
func averageColor(atRelativeY ry: Double) -> CGColor {
    let y = min(h - 1, max(0, cy - half + Int(Double(side) * ry)))
    var rs = 0, gs = 0, bs = 0, n = 0
    for x in stride(from: cropX + side / 6, to: cropX + side * 5 / 6, by: 3) where isSaturated(x, y) {
        let (r, g, b) = rgb(x, y)
        rs += r; gs += g; bs += b; n += 1
    }
    guard n > 0 else { return CGColor(red: 0.8, green: 0.15, blue: 0.12, alpha: 1) }
    return CGColor(red: CGFloat(rs / n) / 255, green: CGFloat(gs / n) / 255,
                   blue: CGFloat(bs / n) / 255, alpha: 1)
}
// Source bitmap is top-down, so 0.08 is near the top of the artwork.
let topColor = averageColor(atRelativeY: 0.08)
let bottomColor = averageColor(atRelativeY: 0.92)

// Compose: 1024 canvas, 824 artwork area with Apple-style corner radius.
let canvas = 1024, art = 824
let inset = CGFloat((canvas - art) / 2)
guard let out = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                          bytesPerRow: canvas * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
let artRect = CGRect(x: inset, y: inset, width: CGFloat(art), height: CGFloat(art))
let radius: CGFloat = 186
out.addPath(CGPath(roundedRect: artRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
out.clip()

// Backdrop gradient (bottom-left origin: topColor belongs at the top).
if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [bottomColor, topColor] as CFArray,
                             locations: [0, 1]) {
    out.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: artRect.minY),
                           end: CGPoint(x: 0, y: artRect.maxY),
                           options: [])
}

// Artwork with overscan so its own rounded edge falls outside the squircle.
let overscan: CGFloat = 1.09
let drawSide = CGFloat(art) * overscan
let drawRect = CGRect(x: artRect.midX - drawSide / 2, y: artRect.midY - drawSide / 2,
                      width: drawSide, height: drawSide)
out.interpolationQuality = .high
out.draw(cropped, in: drawRect)

guard let result = out.makeImage(),
      let png = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) else {
    exit(1)
}
let outURL = URL(fileURLWithPath: args[2]).appendingPathComponent("AppIcon-1024.png")
try! png.write(to: outURL)
print("wrote \(outURL.path)")
