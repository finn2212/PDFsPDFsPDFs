import AppKit
import PDFKit

/// A place on a page that looks like it wants to be filled in, found
/// without any form fields: a line to write on, an empty box, a checkbox,
/// or a "Label:" with free space after it.
struct DetectedField: Identifiable, Equatable {
    enum Kind: Equatable {
        case line, box, checkbox, label
    }

    let id = UUID()
    let kind: Kind
    /// Writable area in page space.
    let rect: CGRect
    /// Font size that fits the field (and its label, if there is one).
    let fontSize: CGFloat

    /// Lower-left of the rendered text (renderText pads 2 pt): sitting on
    /// the line, on the label's baseline, or centred in a box.
    var textOrigin: CGPoint {
        switch kind {
        case .line: return CGPoint(x: rect.minX + 2, y: rect.minY - 1.5)
        case .label: return CGPoint(x: rect.minX, y: rect.minY)
        case .box: return CGPoint(x: rect.minX + 2, y: rect.midY - (fontSize * 1.2 + 4) / 2)
        case .checkbox: return CGPoint(x: rect.minX, y: rect.minY)
        }
    }
}

/// Finds fill-in areas on a page by looking at it like a person would: the
/// page content is rendered (no annotations) and searched for thin
/// horizontal lines with free space above, hollow boxes and small squares.
/// Text labels ending in ":" with blank space after them come from the
/// text layer. Works for vector PDFs and scans alike.
enum FieldDetector {
    /// Pixels per point for the analysis raster.
    private static let scale: CGFloat = 2

    /// Raster + label lines of a page; must run on the main thread
    /// (PDFKit), the pixel analysis can then run anywhere.
    struct Input: @unchecked Sendable {
        let crop: CGRect
        let width: Int
        let height: Int
        let pixels: [UInt8]
        let labels: [(text: String, bounds: CGRect)]
        let excluded: [CGRect]
    }

    @MainActor
    static func input(for page: PDFPage) -> Input? {
        guard let pageRef = page.pageRef else { return nil }
        let crop = page.bounds(for: .cropBox)
        let width = Int((crop.width * scale).rounded(.up))
        let height = Int((crop.height * scale).rounded(.up))
        guard width > 0, height > 0, width * height < 40_000_000 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -crop.minX, y: -crop.minY)
            // Page content only: our stamps and form widgets are annotations.
            ctx.drawPDFPage(pageRef)
            return true
        }
        guard drawn else { return nil }

        var labels: [(text: String, bounds: CGRect)] = []
        if let all = page.selection(for: crop) {
            for line in all.selectionsByLine() {
                let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.count >= 2, text.count <= 40, text.hasSuffix(":") else { continue }
                labels.append((text: text, bounds: line.bounds(for: page)))
            }
        }
        let widgets = page.annotations
            .filter { $0.type == "Widget" || $0.type == "/Widget" }
            .map(\.bounds)
        return Input(crop: crop, width: width, height: height, pixels: pixels,
                     labels: labels, excluded: widgets)
    }

    // MARK: - Analysis

    private struct Box {
        var minX: Int, maxX: Int, minY: Int, maxY: Int, count: Int
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
    }

    static func detect(_ input: Input) -> [DetectedField] {
        let w = input.width, h = input.height
        let ink = input.pixels.map { $0 < 170 }
        let components = connectedComponents(ink, width: w, height: h)

        // Page-space helpers. Raster rows run top-down.
        func pageX(_ px: Int) -> CGFloat { input.crop.minX + CGFloat(px) / scale }
        func pageY(_ row: Int) -> CGFloat { input.crop.maxY - CGFloat(row) / scale }
        func inkRatio(x0: Int, x1: Int, y0: Int, y1: Int) -> Double {
            let xa = max(0, x0), xb = min(w - 1, x1), ya = max(0, y0), yb = min(h - 1, y1)
            guard xb >= xa, yb >= ya else { return 0 }
            var count = 0
            for y in ya...yb {
                let row = y * w
                for x in xa...xb where ink[row + x] { count += 1 }
            }
            return Double(count) / Double((xb - xa + 1) * (yb - ya + 1))
        }

        var fields: [DetectedField] = []
        let pt = Int(scale)

        // 1. Hollow boxes and checkboxes: straight, solid edges and inked
        // corners — round glyphs like "o", "0" or "O" have neither.
        for c in components where c.width >= 7 * pt && c.height >= 7 * pt {
            let band = pt + 1
            let interior = inkRatio(x0: c.minX + band + 1, x1: c.maxX - band - 1,
                                    y0: c.minY + band + 1, y1: c.maxY - band - 1)
            guard interior < 0.02 else { continue }
            let insetX = c.width / 10, insetY = c.height / 10
            let top = inkRatio(x0: c.minX + insetX, x1: c.maxX - insetX, y0: c.minY, y1: c.minY + band - 1)
            let bottom = inkRatio(x0: c.minX + insetX, x1: c.maxX - insetX, y0: c.maxY - band + 1, y1: c.maxY)
            let left = inkRatio(x0: c.minX, x1: c.minX + band - 1, y0: c.minY + insetY, y1: c.maxY - insetY)
            let right = inkRatio(x0: c.maxX - band + 1, x1: c.maxX, y0: c.minY + insetY, y1: c.maxY - insetY)
            guard min(top, bottom, left, right) > 0.45 else { continue }
            // 1 pt corner squares: a square's corner is ink, a circle passes
            // more than a point away from its bounding box corner.
            let k = pt - 1
            let corners = [
                inkRatio(x0: c.minX, x1: c.minX + k, y0: c.minY, y1: c.minY + k),
                inkRatio(x0: c.maxX - k, x1: c.maxX, y0: c.minY, y1: c.minY + k),
                inkRatio(x0: c.minX, x1: c.minX + k, y0: c.maxY - k, y1: c.maxY),
                inkRatio(x0: c.maxX - k, x1: c.maxX, y0: c.maxY - k, y1: c.maxY),
            ]
            guard corners.allSatisfy({ $0 >= 0.5 }) else { continue }
            let wPt = CGFloat(c.width) / scale, hPt = CGFloat(c.height) / scale
            let rect = CGRect(x: pageX(c.minX), y: pageY(c.maxY + 1), width: wPt, height: hPt)
            let aspect = wPt / hPt
            if wPt <= 22, hPt <= 22, aspect > 0.7, aspect < 1.4 {
                fields.append(DetectedField(kind: .checkbox, rect: rect, fontSize: hPt * 0.95))
            } else if wPt >= 40, hPt >= 12, hPt <= 300 {
                let inner = rect.insetBy(dx: 1.5, dy: 1.5)
                let size = min(14, max(8, min(hPt, 26) * 0.6))
                // Tall boxes: write in the first line at the top.
                let lineRect = hPt > 40
                    ? CGRect(x: inner.minX, y: inner.maxY - size * 1.8, width: inner.width, height: size * 1.8)
                    : inner
                fields.append(DetectedField(kind: .box, rect: lineRect, fontSize: size))
            }
        }

        // 2. Lines to write on: thin horizontal strokes (also runs of "_").
        var thin = components.filter { $0.height <= 3 * pt && $0.width >= 3 * pt
            && Double($0.count) >= 0.55 * Double($0.width * $0.height) }
        thin.sort { ($0.minY + $0.maxY, $0.minX) < ($1.minY + $1.maxY, $1.minX) }
        var segments: [Box] = []
        for c in thin {
            if var last = segments.last, abs((last.minY + last.maxY) - (c.minY + c.maxY)) <= 2 * pt,
               c.minX - last.maxX <= 3 * pt, c.minX >= last.minX {
                last.maxX = max(last.maxX, c.maxX)
                last.minY = min(last.minY, c.minY)
                last.maxY = max(last.maxY, c.maxY)
                last.count += c.count
                segments[segments.count - 1] = last
            } else {
                segments.append(c)
            }
        }
        for s in segments {
            let wPt = CGFloat(s.width) / scale
            // Shorter than a word, or a rule across the page: not a field.
            guard wPt >= 36, wPt <= input.crop.width * 0.7 else { continue }
            // Free space above the line, over its whole length.
            var free = 0
            let maxFree = 26 * pt
            while free < maxFree,
                  inkRatio(x0: s.minX + 2, x1: s.maxX - 2, y0: s.minY - free - 1, y1: s.minY - free - 1) < 0.02 {
                free += 1
            }
            let freePt = CGFloat(free) / scale
            guard freePt >= 9 else { continue }
            let height = min(freePt - 1, 22)
            let rect = CGRect(x: pageX(s.minX), y: pageY(s.minY), width: wPt, height: height)
            fields.append(DetectedField(kind: .line, rect: rect, fontSize: min(14, max(8, height * 0.62))))
        }

        // 3. "Label:" followed by blank space on the same line — unless a
        // box or line right below it is what the label is about.
        let shapes = fields
        for label in input.labels {
            let b = label.bounds
            let fieldBelow = shapes.contains { shape in
                let top = shape.kind == .box ? shape.rect.maxY + 6 : shape.rect.minY
                return top <= b.minY && top >= b.minY - 22 && shape.rect.minX <= b.maxX && shape.rect.maxX >= b.minX
            }
            if fieldBelow { continue }
            let x0 = Int(((b.maxX + 3) - input.crop.minX) * scale)
            let rowTop = Int((input.crop.maxY - b.maxY - 1) * scale)
            let rowBottom = Int((input.crop.maxY - b.minY + 1) * scale)
            let limit = Int((input.crop.width - 28) * scale)
            var x = x0
            while x < limit, inkRatio(x0: x, x1: x + pt, y0: rowTop, y1: rowBottom) < 0.01 {
                x += pt
            }
            let freePt = CGFloat(x - x0) / scale
            guard freePt >= 50 else { continue }
            let size = min(14, max(8, b.height * 0.85))
            let rect = CGRect(x: b.maxX + 5, y: b.minY - 2, width: min(freePt - 6, 300), height: max(b.height + 4, size * 1.4))
            fields.append(DetectedField(kind: .label, rect: rect, fontSize: size))
        }

        // Real form fields win; overlapping finds keep the more specific one.
        let order: [DetectedField.Kind] = [.checkbox, .box, .line, .label]
        var result: [DetectedField] = []
        for field in fields.sorted(by: { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }) {
            if input.excluded.contains(where: { $0.intersects(field.rect.insetBy(dx: 2, dy: 2)) }) { continue }
            if result.contains(where: { overlap($0.rect, field.rect) > 0.3 }) { continue }
            result.append(field)
        }
        // Reading order: top to bottom, then left to right.
        return result.sorted {
            abs($0.rect.maxY - $1.rect.maxY) > 6 ? $0.rect.maxY > $1.rect.maxY : $0.rect.minX < $1.rect.minX
        }
    }

    /// Intersection relative to the smaller rect.
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        return (i.width * i.height) / max(1, min(a.width * a.height, b.width * b.height))
    }

    /// 8-connected components over the ink mask, via run-length union-find.
    private static func connectedComponents(_ ink: [Bool], width w: Int, height h: Int) -> [Box] {
        struct Run { let y: Int, x0: Int, x1: Int; var label: Int }
        var runs: [Run] = []
        var rowStart = [Int](repeating: 0, count: h + 1)
        for y in 0..<h {
            rowStart[y] = runs.count
            var x = 0
            let row = y * w
            while x < w {
                if ink[row + x] {
                    let start = x
                    while x < w, ink[row + x] { x += 1 }
                    runs.append(Run(y: y, x0: start, x1: x - 1, label: runs.count))
                } else {
                    x += 1
                }
            }
        }
        rowStart[h] = runs.count
        var parent = Array(0..<runs.count)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for y in 1..<max(h, 1) {
            var j = rowStart[y - 1]
            let prevEnd = rowStart[y]
            for i in rowStart[y]..<rowStart[y + 1] {
                let r = runs[i]
                while j < prevEnd, runs[j].x1 < r.x0 - 1 { j += 1 }
                var k = j
                while k < prevEnd, runs[k].x0 <= r.x1 + 1 {
                    let a = find(i), b = find(k)
                    if a != b { parent[a] = b }
                    k += 1
                }
            }
        }
        var boxes: [Int: Box] = [:]
        for (i, r) in runs.enumerated() {
            let root = find(i)
            let n = r.x1 - r.x0 + 1
            if var b = boxes[root] {
                b.minX = min(b.minX, r.x0); b.maxX = max(b.maxX, r.x1)
                b.minY = min(b.minY, r.y); b.maxY = max(b.maxY, r.y)
                b.count += n
                boxes[root] = b
            } else {
                boxes[root] = Box(minX: r.x0, maxX: r.x1, minY: r.y, maxY: r.y, count: n)
            }
        }
        return Array(boxes.values)
    }
}
