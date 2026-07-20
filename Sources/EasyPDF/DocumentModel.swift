import AppKit
import PDFKit
import UniformTypeIdentifiers

struct PlacedStamp: Identifiable {
    let id: UUID
    let page: PDFPage
    /// Unrotated placement rect in page coordinates.
    var rect: CGRect
    /// Rotation around the rect's center, in degrees (counter-clockwise).
    var rotation: CGFloat = 0
    let image: NSImage
    /// Set for text stamps, which stay re-editable via double-click.
    var text: String? = nil
    var fontSize: CGFloat = 14
}

struct PendingStamp {
    let image: NSImage
    let defaultWidth: CGFloat
    let label: String
    /// Set for text stamps so they stay editable after placing.
    var text: String? = nil
    var fontSize: CGFloat = 14
}

final class ImageStampAnnotation: PDFAnnotation {
    /// Padding around the image so selection handles, the delete button and the
    /// rotate grip fit inside the annotation bounds (PDFKit clips to bounds).
    static let pad: CGFloat = 26
    static let handleSize: CGFloat = 9
    static let deleteRadius: CGFloat = 8
    static let rotateRadius: CGFloat = 8
    /// Distance of the widget buttons from the stamp edge.
    static let buttonGap: CGFloat = 11

    let image: NSImage
    let stampID: UUID
    var isSelectedUI = false
    /// Unrotated image rect in page coordinates.
    var imageRect: CGRect = .zero
    /// Rotation in degrees around the image rect's center.
    var rotationDegrees: CGFloat = 0

    /// Annotation bounds must cover the rotated image plus widget padding.
    static func annotationBounds(for imageRect: CGRect, rotation: CGFloat) -> CGRect {
        rotatedBoundingBox(of: imageRect, rotation: rotation).insetBy(dx: -pad, dy: -pad)
    }

    static func rotatedBoundingBox(of rect: CGRect, rotation: CGFloat) -> CGRect {
        guard rotation != 0 else { return rect }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
            .map { rotate(point: $0, around: center, degrees: rotation) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!,
                      width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    static func rotate(point: CGPoint, around center: CGPoint, degrees: CGFloat) -> CGPoint {
        guard degrees != 0 else { return point }
        let rad = degrees * .pi / 180
        let dx = point.x - center.x, dy = point.y - center.y
        return CGPoint(x: center.x + dx * cos(rad) - dy * sin(rad),
                       y: center.y + dx * sin(rad) + dy * cos(rad))
    }

    /// Delete button sits above the stamp's top edge, rotating with it.
    static func deleteButtonCenter(for rect: CGRect, rotation: CGFloat) -> CGPoint {
        rotate(point: CGPoint(x: rect.midX, y: rect.maxY + buttonGap),
               around: CGPoint(x: rect.midX, y: rect.midY), degrees: rotation)
    }

    /// Rotate grip sits below the stamp's bottom edge.
    static func rotateGripCenter(for rect: CGRect, rotation: CGFloat) -> CGPoint {
        rotate(point: CGPoint(x: rect.midX, y: rect.minY - buttonGap),
               around: CGPoint(x: rect.midX, y: rect.midY), degrees: rotation)
    }

    /// Corner-drag resize for a possibly rotated stamp: keeps the aspect ratio
    /// and keeps `anchor` (the opposite corner, in the stamp's unrotated space)
    /// visually fixed. `startRect` must be the rect from the gesture's start so
    /// the pivot doesn't drift while dragging.
    static func resizedRect(startRect: CGRect, anchor: CGPoint, aspect: CGFloat,
                            rotation: CGFloat, dragPoint: CGPoint,
                            minWidth: CGFloat = 24) -> CGRect {
        let startCenter = CGPoint(x: startRect.midX, y: startRect.midY)
        let local = rotate(point: dragPoint, around: startCenter, degrees: -rotation)
        let width = max(minWidth, abs(local.x - anchor.x))
        let height = width * aspect
        var rect = CGRect(x: local.x < anchor.x ? anchor.x - width : anchor.x,
                          y: local.y < anchor.y ? anchor.y - height : anchor.y,
                          width: width, height: height)
        guard rotation != 0 else { return rect }
        // Resizing moves the centre, which shifts the rotated result; compensate
        // so the anchored corner stays where the user grabbed it.
        let newCenter = CGPoint(x: rect.midX, y: rect.midY)
        let want = rotate(point: anchor, around: startCenter, degrees: rotation)
        let have = rotate(point: anchor, around: newCenter, degrees: rotation)
        rect = rect.offsetBy(dx: want.x - have.x, dy: want.y - have.y)
        return rect
    }

    static func handleCenters(for rect: CGRect, rotation: CGFloat) -> [CGPoint] {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
            .map { rotate(point: $0, around: center, degrees: rotation) }
    }

    init(image: NSImage, stampID: UUID, imageRect: CGRect, rotation: CGFloat) {
        self.image = image
        self.stampID = stampID
        self.imageRect = imageRect
        self.rotationDegrees = rotation
        super.init(bounds: Self.annotationBounds(for: imageRect, rotation: rotation),
                   forType: .stamp, withProperties: nil)
        self.shouldDisplay = true
        self.shouldPrint = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(imageRect: CGRect, rotation: CGFloat) {
        self.imageRect = imageRect
        self.rotationDegrees = rotation
        self.bounds = Self.annotationBounds(for: imageRect, rotation: rotation)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let rect = imageRect
        let center = CGPoint(x: rect.midX, y: rect.midY)

        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: rotationDegrees * .pi / 180)
        context.translateBy(x: -center.x, y: -center.y)
        context.draw(cg, in: rect)

        if isSelectedUI {
            let accent = NSColor.controlAccentColor.cgColor

            // Dashed selection frame (drawn in the rotated space)
            context.setStrokeColor(accent)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(rect.insetBy(dx: -2, dy: -2))
            context.setLineDash(phase: 0, lengths: [])

            // Corner resize handles
            let h = Self.handleSize
            for c in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                      CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
                let handleRect = CGRect(x: c.x - h / 2, y: c.y - h / 2, width: h, height: h)
                context.setFillColor(NSColor.white.cgColor)
                context.fill(handleRect)
                context.setStrokeColor(accent)
                context.setLineWidth(1.2)
                context.stroke(handleRect)
            }

            // Delete button (red circle with white ×) above the stamp
            let d = CGPoint(x: rect.midX, y: rect.maxY + Self.buttonGap)
            let dr = Self.deleteRadius
            context.setFillColor(NSColor.systemRed.cgColor)
            context.fillEllipse(in: CGRect(x: d.x - dr, y: d.y - dr, width: dr * 2, height: dr * 2))
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1.6)
            let k = dr * 0.42
            context.move(to: CGPoint(x: d.x - k, y: d.y - k))
            context.addLine(to: CGPoint(x: d.x + k, y: d.y + k))
            context.move(to: CGPoint(x: d.x - k, y: d.y + k))
            context.addLine(to: CGPoint(x: d.x + k, y: d.y - k))
            context.strokePath()

            // Rotate grip (accent circle with a curved arrow) below the stamp
            let g = CGPoint(x: rect.midX, y: rect.minY - Self.buttonGap)
            let gr = Self.rotateRadius
            context.setFillColor(accent)
            context.fillEllipse(in: CGRect(x: g.x - gr, y: g.y - gr, width: gr * 2, height: gr * 2))
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1.5)
            context.addArc(center: g, radius: gr * 0.5,
                           startAngle: .pi * 0.35, endAngle: .pi * 1.75, clockwise: false)
            context.strokePath()
            let tip = CGPoint(x: g.x + gr * 0.5 * cos(.pi * 0.35), y: g.y + gr * 0.5 * sin(.pi * 0.35))
            context.move(to: CGPoint(x: tip.x - 2.4, y: tip.y + 1.0))
            context.addLine(to: tip)
            context.addLine(to: CGPoint(x: tip.x + 1.2, y: tip.y - 2.4))
            context.strokePath()
        }
        context.restoreGState()
    }
}

enum PDFFlattener {
    enum FlattenError: Error { case contextCreationFailed, noPage }

    /// Writes the document (or a subset of pages) to `url` with every annotation
    /// (incl. our image stamps and filled form fields) permanently rendered into
    /// the page content. Uses the crop box so output matches what is displayed.
    static func flatten(document: PDFDocument, pageIndices: [Int]? = nil, to url: URL) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw FlattenError.contextCreationFailed
        }
        let indices = pageIndices ?? Array(0..<document.pageCount)
        for pageIndex in indices {
            guard let page = document.page(at: pageIndex) else { throw FlattenError.noPage }
            let crop = page.bounds(for: .cropBox)
            let rotated = page.rotation % 180 != 0
            let displaySize = rotated
                ? CGSize(width: crop.height, height: crop.width)
                : crop.size
            var pageRect = CGRect(origin: .zero, size: displaySize)
            ctx.beginPage(mediaBox: &pageRect)
            ctx.saveGState()
            // PDFPage.draw handles page rotation and renders annotations,
            // including our custom ImageStampAnnotation overlays.
            page.draw(with: .cropBox, to: ctx)
            ctx.restoreGState()
            ctx.endPage()
        }
        ctx.closePDF()
    }
}

enum RecentsStore {
    private static let key = "recentFiles"

    static var urls: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(10)), forKey: key)
    }
}

@MainActor
final class DocumentModel: ObservableObject {
    static let shared = DocumentModel()

    @Published var document: PDFDocument?
    @Published var fileURL: URL?
    @Published var stamps: [PlacedStamp] = []
    @Published var selectedStampID: UUID?
    @Published var pendingStamp: PendingStamp?
    @Published var statusMessage: String?
    @Published var saveErrorMessage: String?
    @Published var hasChanges = false
    /// Bumped on every structural change; thumbnail views re-render on it.
    @Published var docRevision = 0
    @Published var canUndo = false
    @Published var canRedo = false
    /// Acrobat-style text tool: click into the page, then type right there.
    @Published var textToolActive = false
    @Published var textToolFontSize: CGFloat = 14
    /// True while the inline editor has focus (drives the toolbar size control).
    @Published var isEditingText = false

    weak var pdfView: PDFView?
    /// Set by the PDF view so the model can close an open inline text editor
    /// before it swaps or mutates the document (true = commit, false = discard).
    var finishInlineEditing: ((Bool) -> Void)?
    private var annotationsByID: [UUID: ImageStampAnnotation] = [:]

    let undoManager = UndoManager()
    private var undoObservers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name: Notification.Name in [.NSUndoManagerDidCloseUndoGroup,
                                        .NSUndoManagerDidUndoChange,
                                        .NSUndoManagerDidRedoChange,
                                        .NSUndoManagerCheckpoint] {
            undoObservers.append(center.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshUndoState()
                }
            })
        }
    }

    private func refreshUndoState() {
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
    }

    var pageCount: Int { document?.pageCount ?? 0 }

    var selectedStamp: PlacedStamp? {
        stamps.first { $0.id == selectedStampID }
    }

    // MARK: - Open / Save

    /// Asks the user what to do with unsaved changes. Returns false if the
    /// current action should be cancelled.
    func confirmDiscardIfNeeded() -> Bool {
        guard hasChanges, document != nil else { return true }
        let alert = NSAlert()
        alert.messageText = loc("unsaved.title")
        alert.informativeText = loc("unsaved.message")
        alert.addButton(withTitle: loc("unsaved.save"))
        alert.addButton(withTitle: loc("unsaved.discard"))
        alert.addButton(withTitle: loc("unsaved.cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveInPlace()
            return !hasChanges // save failed/cancelled → keep current document
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func open(url: URL) {
        // An open editor belongs to the outgoing document; keep what was typed.
        finishInlineEditing?(true)
        guard confirmDiscardIfNeeded() else { return }
        guard let doc = PDFDocument(url: url) else { return }
        document = doc
        fileURL = url
        stamps = []
        annotationsByID = [:]
        selectedStampID = nil
        pendingStamp = nil
        statusMessage = nil
        hasChanges = false
        docRevision += 1
        undoManager.removeAllActions()
        refreshUndoState()
        RecentsStore.add(url)
    }

    func requestOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    /// Cmd+S: overwrite the current file in place.
    func saveInPlace() {
        guard document != nil else { return }
        if let url = fileURL {
            save(to: url)
        } else {
            requestSaveAsPanel()
        }
    }

    func requestSaveAsPanel() {
        guard document != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let baseName = fileURL?.deletingPathExtension().lastPathComponent ?? "Dokument"
        let suffix = stamps.isEmpty ? "" : loc("save.suffix")
        panel.nameFieldStringValue = baseName + suffix + ".pdf"
        if let dir = fileURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        if panel.runModal() == .OK, let url = panel.url {
            save(to: url)
        }
    }

    /// Writes the current in-memory state to `url` without touching model state.
    /// Flattens if stamps exist, otherwise writes losslessly.
    func exportCurrentState(to url: URL) throws {
        guard let doc = document else { return }
        select(nil)
        let liveStamps = stamps.filter { (0..<doc.pageCount).contains(doc.index(for: $0.page)) }
        if liveStamps.isEmpty {
            // Pure page operations: lossless write preserves text, links, forms.
            guard doc.write(to: url) else { throw PDFFlattener.FlattenError.contextCreationFailed }
        } else {
            try PDFFlattener.flatten(document: doc, to: url)
        }
    }

    func save(to url: URL) {
        guard let doc = document else { return }
        // Saving reloads the document, which would orphan an open editor.
        finishInlineEditing?(true)
        do {
            try exportCurrentState(to: url)
            // Remember the visible page so the view doesn't jump to page 1.
            let visiblePageIndex = pdfView?.currentPage.map { doc.index(for: $0) }
            if let saved = PDFDocument(url: url) {
                document = saved
                fileURL = url
                stamps = []
                annotationsByID = [:]
                hasChanges = false
                docRevision += 1
                // The undo stack references the pre-save document; drop it.
                undoManager.removeAllActions()
                refreshUndoState()
                if let visiblePageIndex, visiblePageIndex != NSNotFound {
                    let target = min(visiblePageIndex, saved.pageCount - 1)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let page = self.document?.page(at: target) else { return }
                        self.pdfView?.go(to: page)
                    }
                }
            }
            statusMessage = loc("status.saved", url.lastPathComponent)
        } catch {
            saveErrorMessage = "\(error)"
        }
    }

    func printDocument() {
        guard let pdfView, pdfView.document != nil else { return }
        // Never print the selection widget (frame, handles, delete button).
        select(nil)
        pdfView.print(with: NSPrintInfo.shared, autoRotate: true, pageScaling: .pageScaleDownToFit)
    }

    func undo() { undoManager.undo() }
    func redo() { undoManager.redo() }

    // MARK: - Stamps

    func place(at pagePoint: CGPoint, on page: PDFPage) {
        guard let pending = pendingStamp else { return }
        let imgSize = pending.image.size
        let aspect = imgSize.width > 0 ? imgSize.height / imgSize.width : 0.4
        let width = pending.defaultWidth
        let height = width * aspect
        let rect = CGRect(x: pagePoint.x - width / 2, y: pagePoint.y - height / 2,
                          width: width, height: height)
        let stamp = PlacedStamp(id: UUID(), page: page, rect: rect, image: pending.image,
                                text: pending.text, fontSize: pending.fontSize)
        pendingStamp = nil
        restoreStamp(stamp)
        select(stamp.id)
    }

    /// Adds (or re-adds after undo) a stamp; inverse of removeStamp.
    func restoreStamp(_ stamp: PlacedStamp) {
        let annotation = ImageStampAnnotation(image: stamp.image, stampID: stamp.id,
                                              imageRect: stamp.rect, rotation: stamp.rotation)
        stamp.page.addAnnotation(annotation)
        annotationsByID[stamp.id] = annotation
        stamps.append(stamp)
        hasChanges = true
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.removeStamp(id: stamp.id) }
        }
        refreshUndoState()
    }

    func removeStamp(id: UUID) {
        guard let idx = stamps.firstIndex(where: { $0.id == id }) else { return }
        let stamp = stamps[idx]
        if let annotation = annotationsByID[id] {
            stamp.page.removeAnnotation(annotation)
        }
        annotationsByID[id] = nil
        stamps.remove(at: idx)
        if selectedStampID == id { selectedStampID = nil }
        hasChanges = true
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restoreStamp(stamp) }
        }
        refreshUndoState()
    }

    func removeSelected() {
        guard let id = selectedStampID else { return }
        removeStamp(id: id)
    }

    func stamp(at pagePoint: CGPoint, page: PDFPage) -> PlacedStamp? {
        stamps.last { stamp in
            guard stamp.page === page else { return false }
            // Undo the rotation, then hit-test against the upright rect.
            let center = CGPoint(x: stamp.rect.midX, y: stamp.rect.midY)
            let local = ImageStampAnnotation.rotate(point: pagePoint, around: center,
                                                    degrees: -stamp.rotation)
            return stamp.rect.insetBy(dx: -6, dy: -6).contains(local)
        }
    }

    func select(_ id: UUID?) {
        selectedStampID = id
        for (stampID, annotation) in annotationsByID {
            annotation.isSelectedUI = (stampID == id)
            // Re-setting bounds pokes PDFView into redrawing the annotation.
            annotation.bounds = annotation.bounds
        }
    }

    /// Live update while dragging/resizing/rotating – no undo registration.
    func updateRect(_ rect: CGRect, rotation: CGFloat? = nil, for id: UUID) {
        guard let idx = stamps.firstIndex(where: { $0.id == id }) else { return }
        stamps[idx].rect = rect
        if let rotation { stamps[idx].rotation = rotation }
        annotationsByID[id]?.update(imageRect: rect, rotation: stamps[idx].rotation)
        hasChanges = true
    }

    func updateRotation(_ degrees: CGFloat, for id: UUID) {
        guard let stamp = stamps.first(where: { $0.id == id }) else { return }
        updateRect(stamp.rect, rotation: degrees, for: id)
    }

    /// Called once a drag/resize/rotate gesture finishes; registers one undo step.
    func commitRectChange(id: UUID, from oldRect: CGRect, oldRotation: CGFloat? = nil) {
        guard let stamp = stamps.first(where: { $0.id == id }) else { return }
        let previousRotation = oldRotation ?? stamp.rotation
        guard stamp.rect != oldRect || stamp.rotation != previousRotation else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.setRect(id: id, to: oldRect, rotation: previousRotation) }
        }
        refreshUndoState()
    }

    func setRect(id: UUID, to rect: CGRect, rotation: CGFloat? = nil) {
        guard let stamp = stamps.first(where: { $0.id == id }) else { return }
        let oldRect = stamp.rect
        let oldRotation = stamp.rotation
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.setRect(id: id, to: oldRect, rotation: oldRotation) }
        }
        updateRect(rect, rotation: rotation, for: id)
        refreshUndoState()
    }

    /// Rotates the selected stamp by a fixed step (toolbar buttons / shortcuts).
    func rotateSelected(by degrees: CGFloat) {
        guard let stamp = selectedStamp else { return }
        let normalized = ((stamp.rotation + degrees).truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        setRect(id: stamp.id, to: stamp.rect, rotation: normalized)
    }

    func resizeSelected(width: CGFloat) {
        guard let stamp = selectedStamp else { return }
        let aspect = stamp.rect.width > 0 ? stamp.rect.height / stamp.rect.width : 0.4
        let center = CGPoint(x: stamp.rect.midX, y: stamp.rect.midY)
        let newRect = CGRect(x: center.x - width / 2,
                             y: center.y - width * aspect / 2,
                             width: width, height: width * aspect)
        updateRect(newRect, for: stamp.id)
    }

    func cancelPending() {
        pendingStamp = nil
    }

    // MARK: - Text / Datum

    /// Turns text into a placed stamp at the given page position.
    /// `origin` is the lower-left corner of the text in page coordinates.
    @discardableResult
    func placeText(_ text: String, fontSize: CGFloat, at origin: CGPoint,
                   on page: PDFPage, replacing existingID: UUID? = nil) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let png = ImageUtils.renderText(trimmed, fontSize: fontSize),
              let image = NSImage(data: png) else { return nil }

        var rotation: CGFloat = 0
        // renderText draws at 3x, so a third of the pixel size is the point size.
        let size = CGSize(width: image.size.width / 3, height: image.size.height / 3)
        var rect = CGRect(origin: origin, size: size)

        let isReplacement = existingID != nil && stamps.contains { $0.id == existingID }
        // Replacing = remove + add; group them so one Cmd+Z undoes the edit.
        if isReplacement { undoManager.beginUndoGrouping() }
        defer { if isReplacement { undoManager.endUndoGrouping() } }

        if let existingID, let old = stamps.first(where: { $0.id == existingID }) {
            rotation = old.rotation
            // Keep the visual centre so edited text doesn't jump, especially
            // when it is rotated (rotation pivots around the centre).
            rect = CGRect(x: old.rect.midX - size.width / 2,
                          y: old.rect.midY - size.height / 2,
                          width: size.width, height: size.height)
            removeStamp(id: existingID)
        }
        let stamp = PlacedStamp(id: UUID(), page: page, rect: rect, rotation: rotation,
                                image: image, text: trimmed, fontSize: fontSize)
        restoreStamp(stamp)
        select(stamp.id)
        return stamp.id
    }

    var todayString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: Date())
    }

    func startPlacingText(_ text: String, fontSize: CGFloat) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let png = ImageUtils.renderText(trimmed, fontSize: fontSize),
              let image = NSImage(data: png) else { return }
        pendingStamp = PendingStamp(image: image,
                                    defaultWidth: max(image.size.width / 3, 10),
                                    label: trimmed,
                                    text: trimmed,
                                    fontSize: fontSize)
    }

    func startPlacingToday(fontSize: CGFloat = 14) {
        startPlacingText(todayString, fontSize: fontSize)
    }

    // MARK: - Seiten-Operationen

    func rotatePage(_ index: Int, clockwise: Bool) {
        guard let page = document?.page(at: index) else { return }
        page.rotation = ((page.rotation + (clockwise ? 90 : -90)) % 360 + 360) % 360
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.rotatePage(index, clockwise: !clockwise) }
        }
        changed()
    }

    func deletePage(_ index: Int) {
        guard let doc = document, doc.pageCount > 1, let page = doc.page(at: index) else { return }
        // The editor may target the page that is about to vanish.
        finishInlineEditing?(false)
        // Clear the selection widget first so no annotation keeps isSelectedUI
        // set while off-document (it would reappear selected after undo).
        select(nil)
        // Keep the stamps' annotations on the removed page so undo can restore everything.
        let affected = stamps.filter { $0.page === page }
        stamps.removeAll { $0.page === page }
        doc.removePage(at: index)
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.reinsertPage(page, at: index, stamps: affected) }
        }
        changed()
    }

    func reinsertPage(_ page: PDFPage, at index: Int, stamps affected: [PlacedStamp]) {
        guard let doc = document else { return }
        doc.insert(page, at: min(index, doc.pageCount))
        stamps.append(contentsOf: affected)
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.deletePage(index) }
        }
        changed()
    }

    func movePage(_ index: Int, offset: Int) {
        guard let doc = document else { return }
        let target = index + offset
        guard target >= 0, target < doc.pageCount, target != index else { return }
        doc.exchangePage(at: index, withPageAt: target)
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.movePage(target, offset: -offset) }
        }
        changed()
    }

    /// True if any not-yet-flattened stamp sits on one of the given pages.
    func hasUnsavedStamps(onPageIndices indices: [Int]) -> Bool {
        guard let doc = document else { return false }
        let wanted = Set(indices)
        return stamps.contains { wanted.contains(doc.index(for: $0.page)) }
    }

    /// Extracts pages WYSIWYG: pages carrying unsaved stamps are flattened so
    /// the output matches what is on screen; otherwise the copy is lossless.
    func extractPages(_ indices: [Int], to url: URL) throws {
        guard let doc = document else { return }
        select(nil)
        if hasUnsavedStamps(onPageIndices: indices) {
            try PDFFlattener.flatten(document: doc, pageIndices: indices, to: url)
        } else {
            try PDFTools.extract(from: doc, pageIndices: indices, to: url)
        }
    }

    /// Splits the open document (incl. unsaved stamps) into one PDF per page.
    func splitIntoSingles(folder: URL) throws -> Int {
        guard let doc = document else { return 0 }
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Dokument"
        for i in 0..<doc.pageCount {
            let name = String(format: "%@ – %@ %02d.pdf", base, loc("split.pageWord"), i + 1)
            try extractPages([i], to: folder.appendingPathComponent(name))
        }
        return doc.pageCount
    }

    func extractPage(_ index: Int) {
        guard document != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let baseName = fileURL?.deletingPathExtension().lastPathComponent ?? "Dokument"
        panel.nameFieldStringValue = "\(baseName) – \(loc("split.pageWord")) \(index + 1).pdf"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try extractPages([index], to: url)
                statusMessage = loc("status.saved", url.lastPathComponent)
            } catch {
                saveErrorMessage = "\(error)"
            }
        }
    }

    private func changed() {
        hasChanges = true
        docRevision += 1
        pdfView?.layoutDocumentView()
        refreshUndoState()
    }
}
