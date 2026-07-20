import AppKit
import PDFKit
import UniformTypeIdentifiers

struct PlacedStamp: Identifiable {
    let id: UUID
    let page: PDFPage
    var rect: CGRect
    let image: NSImage
}

struct PendingStamp {
    let image: NSImage
    let defaultWidth: CGFloat
    let label: String
}

final class ImageStampAnnotation: PDFAnnotation {
    /// Padding around the image so selection handles and the delete button
    /// can be drawn inside the annotation's bounds (PDFKit clips to bounds).
    static let pad: CGFloat = 18
    static let handleSize: CGFloat = 9
    static let deleteRadius: CGFloat = 8

    let image: NSImage
    let stampID: UUID
    var isSelectedUI = false

    /// The rect the image itself occupies (annotation bounds minus padding).
    var imageRect: CGRect { bounds.insetBy(dx: Self.pad, dy: Self.pad) }

    static func annotationBounds(for imageRect: CGRect) -> CGRect {
        imageRect.insetBy(dx: -pad, dy: -pad)
    }

    static func deleteButtonCenter(for imageRect: CGRect) -> CGPoint {
        CGPoint(x: imageRect.midX, y: imageRect.maxY + 9)
    }

    static func handleCenters(for imageRect: CGRect) -> [CGPoint] {
        [CGPoint(x: imageRect.minX, y: imageRect.minY),
         CGPoint(x: imageRect.maxX, y: imageRect.minY),
         CGPoint(x: imageRect.minX, y: imageRect.maxY),
         CGPoint(x: imageRect.maxX, y: imageRect.maxY)]
    }

    init(image: NSImage, stampID: UUID, bounds: CGRect) {
        self.image = image
        self.stampID = stampID
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        self.shouldDisplay = true
        self.shouldPrint = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let rect = imageRect
        context.saveGState()
        context.draw(cg, in: rect)

        if isSelectedUI {
            let accent = NSColor.controlAccentColor.cgColor

            // Dashed selection frame
            context.setStrokeColor(accent)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(rect.insetBy(dx: -2, dy: -2))
            context.setLineDash(phase: 0, lengths: [])

            // Corner resize handles
            let h = Self.handleSize
            for center in Self.handleCenters(for: rect) {
                let handleRect = CGRect(x: center.x - h / 2, y: center.y - h / 2, width: h, height: h)
                context.setFillColor(NSColor.white.cgColor)
                context.fill(handleRect)
                context.setStrokeColor(accent)
                context.setLineWidth(1.2)
                context.stroke(handleRect)
            }

            // Delete button (red circle with white ×) above the stamp
            let c = Self.deleteButtonCenter(for: rect)
            let r = Self.deleteRadius
            let circle = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            context.setFillColor(NSColor.systemRed.cgColor)
            context.fillEllipse(in: circle)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1.6)
            let k = r * 0.42
            context.move(to: CGPoint(x: c.x - k, y: c.y - k))
            context.addLine(to: CGPoint(x: c.x + k, y: c.y + k))
            context.move(to: CGPoint(x: c.x - k, y: c.y + k))
            context.addLine(to: CGPoint(x: c.x + k, y: c.y - k))
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

    weak var pdfView: PDFView?
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
        let stamp = PlacedStamp(id: UUID(), page: page, rect: rect, image: pending.image)
        pendingStamp = nil
        restoreStamp(stamp)
        select(stamp.id)
    }

    /// Adds (or re-adds after undo) a stamp; inverse of removeStamp.
    func restoreStamp(_ stamp: PlacedStamp) {
        let annotation = ImageStampAnnotation(image: stamp.image, stampID: stamp.id,
                                              bounds: ImageStampAnnotation.annotationBounds(for: stamp.rect))
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
        stamps.last { $0.page === page && $0.rect.insetBy(dx: -6, dy: -6).contains(pagePoint) }
    }

    func select(_ id: UUID?) {
        selectedStampID = id
        for (stampID, annotation) in annotationsByID {
            annotation.isSelectedUI = (stampID == id)
            // Re-setting bounds pokes PDFView into redrawing the annotation.
            annotation.bounds = annotation.bounds
        }
    }

    /// Live update while dragging/resizing – no undo registration.
    func updateRect(_ rect: CGRect, for id: UUID) {
        guard let idx = stamps.firstIndex(where: { $0.id == id }) else { return }
        stamps[idx].rect = rect
        annotationsByID[id]?.bounds = ImageStampAnnotation.annotationBounds(for: rect)
        hasChanges = true
    }

    /// Called once a drag/resize gesture finishes; registers a single undo step.
    func commitRectChange(id: UUID, from oldRect: CGRect) {
        guard let stamp = stamps.first(where: { $0.id == id }), stamp.rect != oldRect else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.setRect(id: id, to: oldRect) }
        }
        refreshUndoState()
    }

    func setRect(id: UUID, to rect: CGRect) {
        guard let stamp = stamps.first(where: { $0.id == id }) else { return }
        let old = stamp.rect
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.setRect(id: id, to: old) }
        }
        updateRect(rect, for: id)
        refreshUndoState()
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

    func startPlacingText(_ text: String, fontSize: CGFloat) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let png = ImageUtils.renderText(trimmed, fontSize: fontSize),
              let image = NSImage(data: png) else { return }
        // Rendered at 3x, so a third of the pixel width is the natural point size.
        pendingStamp = PendingStamp(image: image,
                                    defaultWidth: max(image.size.width / 3, 10),
                                    label: trimmed)
    }

    func startPlacingToday(fontSize: CGFloat = 14) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        startPlacingText(formatter.string(from: Date()), fontSize: fontSize)
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
