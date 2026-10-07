import AppKit
import PDFKit

/// Detected fill-in areas: finding them, looking them up, filling them.
extension DocumentModel {
    /// Analyses every page in the background, one page per main-thread turn
    /// (rendering needs PDFKit), and publishes results as they come in.
    /// `reset` drops all results (new document); otherwise only pages
    /// without results yet are analysed (pages inserted by a merge).
    func detectFields(reset: Bool = true) {
        if reset {
            detectionGeneration += 1
            detectedFields = [:]
            hoveredFieldID = nil
            detectionQueue = []
        }
        let known = Set(detectedFields.keys).union(detectionQueue.map(ObjectIdentifier.init))
        let missing = pages.prefix(80).filter { !known.contains(ObjectIdentifier($0)) }
        guard !missing.isEmpty else { return }
        let wasIdle = detectionQueue.isEmpty
        detectionQueue += missing
        guard reset || wasIdle else { return }
        let generation = detectionGeneration
        DispatchQueue.main.async { [weak self] in
            self?.detectNextPage(generation: generation)
        }
    }

    private func detectNextPage(generation: Int) {
        guard generation == detectionGeneration, !detectionQueue.isEmpty else { return }
        let page = detectionQueue.removeFirst()
        let pageID = ObjectIdentifier(page)
        guard let input = FieldDetector.input(for: page) else {
            DispatchQueue.main.async { [weak self] in self?.detectNextPage(generation: generation) }
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fields = FieldDetector.detect(input)
            DispatchQueue.main.async {
                guard let self, generation == self.detectionGeneration else { return }
                self.detectedFields[pageID] = fields
                self.onFieldsChanged?()
                self.detectNextPage(generation: generation)
            }
        }
    }

    /// Fields on a page that are still empty (no text or mark placed in them).
    func openFields(on page: PDFPage) -> [DetectedField] {
        let onPage = stamps.filter { $0.page === page }
        return (detectedFields[ObjectIdentifier(page)] ?? []).filter { field in
            !onPage.contains { stamp in
                let i = stamp.rect.intersection(field.rect)
                return !i.isNull && i.width * i.height > 0.25 * min(stamp.rect.width * stamp.rect.height,
                                                                     field.rect.width * field.rect.height)
            }
        }
    }

    var openFieldCount: Int {
        pages.reduce(0) { $0 + openFields(on: $1).count }
    }

    func field(at point: CGPoint, on page: PDFPage) -> DetectedField? {
        openFields(on: page).first { $0.rect.insetBy(dx: -3, dy: -3).contains(point) }
    }

    /// The open text field after (or before) `field` in reading order,
    /// across pages; checkboxes are skipped (nothing to type there).
    func neighbourField(of field: DetectedField?, on page: PDFPage, backwards: Bool) -> (DetectedField, PDFPage)? {
        var sequence: [(DetectedField, PDFPage)] = []
        for p in pages {
            sequence += openFields(on: p).filter { $0.kind != .checkbox }.map { ($0, p) }
        }
        guard !sequence.isEmpty else { return nil }
        if let field, let index = sequence.firstIndex(where: { $0.0.id == field.id }) {
            let next = backwards ? index - 1 : index + 1
            return sequence.indices.contains(next) ? sequence[next] : nil
        }
        // The field just got filled (it is no longer open): continue after
        // the first open field that comes after it in reading order.
        let pageIndex = document?.index(for: page) ?? 0
        let anchorY = field?.rect.maxY ?? .greatestFiniteMagnitude
        let anchorX = field?.rect.minX ?? -.greatestFiniteMagnitude
        let after = sequence.filter { candidate in
            let i = document?.index(for: candidate.1) ?? 0
            if i != pageIndex { return backwards ? i < pageIndex : i > pageIndex }
            if abs(candidate.0.rect.maxY - anchorY) <= 6 {
                return backwards ? candidate.0.rect.minX < anchorX : candidate.0.rect.minX > anchorX
            }
            return backwards ? candidate.0.rect.maxY > anchorY : candidate.0.rect.maxY < anchorY
        }
        return backwards ? after.last : after.first
    }

    /// Ticks a detected checkbox: the mark sized and centred in the box.
    func tick(_ field: DetectedField, on page: PDFPage, mark: String = "✓") {
        let size = max(8, field.rect.height * 0.95)
        guard let png = ImageUtils.renderText(mark, fontSize: size), let image = NSImage(data: png) else { return }
        let natural = CGSize(width: image.size.width / 3, height: image.size.height / 3)
        let rect = CGRect(x: field.rect.midX - natural.width / 2, y: field.rect.midY - natural.height / 2,
                          width: natural.width, height: natural.height)
        restoreStamp(PlacedStamp(id: UUID(), page: page, rect: rect, rotation: CGFloat(page.rotation),
                                 image: image, text: mark, fontSize: size))
        Log.ui.notice("fields: ticked a checkbox")
    }
}
