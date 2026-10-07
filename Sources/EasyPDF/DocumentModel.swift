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
    /// Font size the image was rendered at.
    var fontSize: CGFloat = 14

    /// Font size as currently shown: dragging a corner scales the rendered
    /// text, so the size follows the rect. renderText draws at 3x.
    var effectiveFontSize: CGFloat {
        let naturalWidth = image.size.width / 3
        guard naturalWidth > 0 else { return fontSize }
        return fontSize * rect.width / naturalWidth
    }
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
    /// Below 1 for the placement preview that follows the cursor.
    var opacity: CGFloat = 1
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
        // PDFKit hands custom annotations an untransformed context: unlike
        // standard annotations they would ignore the page rotation and the
        // crop box offset. Map page space to the displayed page ourselves.
        if let page {
            context.concatenate(page.transform(for: box))
        }
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: rotationDegrees * .pi / 180)
        context.translateBy(x: -center.x, y: -center.y)
        context.setAlpha(opacity)
        context.draw(cg, in: rect)
        context.setAlpha(1)

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

/// The two views of an open document: working on its content, or on its pages.
enum WorkspaceMode: String, CaseIterable, Identifiable {
    case document
    case pages

    var id: String { rawValue }
    var title: String { loc("mode.\(rawValue)") }
    var icon: String { self == .document ? "doc.richtext" : "square.grid.2x2" }
}

/// Files dropped onto an open document, waiting for "append or open?".
struct PendingDrop: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Images waiting for the images → PDF sheet.
struct ImagesRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

@MainActor
final class DocumentModel: ObservableObject {
    static let shared = DocumentModel()

    @Published var document: PDFDocument?
    @Published var fileURL: URL?
    /// Name for documents that exist only in memory (e.g. a merge result).
    @Published var untitledName: String?
    @Published var mode: WorkspaceMode = .document {
        willSet {
            // The PDF view is rebuilt when coming back; remember where we were.
            if mode == .document, newValue == .pages, let page = pdfView?.currentPage, let document {
                resumePageIndex = document.index(for: page)
            }
        }
        didSet { if mode == .pages { endTools() } }
    }
    /// Page to show when the PDF view is (re)created; consumed once.
    var resumePageIndex: Int?
    /// Zoom and page to keep when saving swaps in the reloaded document.
    var viewStateToRestore: ViewState?
    @Published var errorTitle = ""

    struct ViewState {
        let scale: CGFloat
        let autoScales: Bool
        let pageIndex: Int?
    }

    func showError(_ message: String, title: String) {
        errorTitle = title
        saveErrorMessage = message
    }

    /// Form field values when the document was loaded or last saved; a
    /// fallback for edits PDFKit makes without telling us.
    private var formValuesAtLoad: [String] = []

    private static func formValues(in doc: PDFDocument) -> [String] {
        (0..<doc.pageCount).flatMap { index in
            (doc.page(at: index)?.annotations ?? [])
                .filter { $0.type == "Widget" || $0.type == "/Widget" }
                .map { "\($0.fieldName ?? "")=\($0.widgetStringValue ?? "")|\($0.buttonWidgetState.rawValue)" }
        }
    }

    /// True if a form field differs from its value at load/save time.
    var formChangedSinceLoad: Bool {
        guard let document, formFieldCount > 0 else { return false }
        return Self.formValues(in: document) != formValuesAtLoad
    }

    /// A form field was filled in or toggled (PDFKit edits widgets itself).
    func noteFormEdit() {
        guard document != nil, !hasChanges else { return }
        hasChanges = true
    }
    @Published var stamps: [PlacedStamp] = []
    @Published var selectedStampID: UUID?
    @Published var pendingStamp: PendingStamp? {
        didSet {
            if pendingStamp != nil {
                if textToolActive { textToolActive = false }
            } else {
                removeGhost()
            }
        }
    }
    @Published var statusMessage: String?
    @Published var saveErrorMessage: String?
    @Published var hasChanges = false
    /// Bumped on every structural change; thumbnail views re-render on it.
    @Published var docRevision = 0
    @Published var canUndo = false
    @Published var canRedo = false
    /// Acrobat-style text tool: click into the page, then type right there.
    @Published var textToolActive = false {
        didSet {
            if textToolActive {
                if pendingStamp != nil { pendingStamp = nil }
                select(nil)
            } else if oldValue {
                finishInlineEditing?(true)
            }
        }
    }
    @Published var textToolFontSize: CGFloat = 14
    /// True while the inline editor has focus (drives the size control).
    @Published var isEditingText = false
    /// Pages selected in the page grid, by page identity (survives reordering).
    @Published var selectedPages: Set<ObjectIdentifier> = []
    /// Cut marks: a new part starts after each of these pages.
    @Published var cutMarks: Set<ObjectIdentifier> = []
    /// Number of fillable form fields in the open document.
    @Published var formFieldCount = 0
    @Published var formHintDismissed = false
    @Published var pendingDrop: PendingDrop?
    @Published var imagesRequest: ImagesRequest?
    @Published var exportImagesRequested = false
    /// Signature picker popover (also opened from the Tools menu).
    @Published var showSignaturePicker = false
    /// Signature editor sheet: the person being edited, and which asset.
    @Published var signatureEditor: SignatureEditorRequest?

    weak var pdfView: PDFView?
    /// Set by the PDF view so the model can close an open inline text editor
    /// before it swaps or mutates the document (true = commit, false = discard).
    var finishInlineEditing: ((Bool) -> Void)?
    private var annotationsByID: [UUID: ImageStampAnnotation] = [:]
    /// Semi-transparent preview of the pending stamp under the cursor.
    private var ghost: ImageStampAnnotation?
    /// Anchor for ⇧-click range selection in the page grid.
    var lastClickedPage: ObjectIdentifier?
    /// Identifies the page drag in flight, so only our own drags reorder.
    var pageDragToken: String?

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

    /// File name shown in the title bar.
    var displayName: String {
        fileURL?.lastPathComponent ?? untitledName.map { $0 + ".pdf" } ?? loc("app.name")
    }

    /// Base for derived file names ("<base> – Seite 1.pdf").
    var baseName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? untitledName ?? loc("file.untitled")
    }

    /// The pages in their current order.
    var pages: [PDFPage] {
        guard let document else { return [] }
        return (0..<document.pageCount).compactMap { document.page(at: $0) }
    }

    /// Ends every tool and placement, e.g. before switching to the page grid.
    func endTools() {
        finishInlineEditing?(true)
        if textToolActive { textToolActive = false }
        if pendingStamp != nil { pendingStamp = nil }
        select(nil)
    }

    var selectedStamp: PlacedStamp? {
        stamps.first { $0.id == selectedStampID }
    }

    // MARK: - Open / Save

    /// Asks the user what to do with unsaved changes. Returns false if the
    /// current action should be cancelled.
    func confirmDiscardIfNeeded() -> Bool {
        guard hasChanges || formChangedSinceLoad, document != nil else { return true }
        let alert = NSAlert()
        alert.messageText = loc("unsaved.title")
        alert.informativeText = loc("unsaved.message")
        alert.addButton(withTitle: loc("unsaved.save"))
        alert.addButton(withTitle: loc("unsaved.discard"))
        alert.addButton(withTitle: loc("unsaved.cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveInPlace()
            return !hasChanges && !formChangedSinceLoad // save failed/cancelled → keep current document
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
        guard let doc = PDFDocument(url: url) else {
            showError(loc("error.cantOpen", url.lastPathComponent), title: loc("alert.openError"))
            return
        }
        load(doc, url: url, untitledName: nil, mode: .document)
        RecentsStore.add(url)
    }

    /// Shows an in-memory document (merge result, converted images) that has
    /// no file yet; saving asks for a location.
    @discardableResult
    func openUntitled(_ doc: PDFDocument, name: String, mode: WorkspaceMode) -> Bool {
        finishInlineEditing?(true)
        guard confirmDiscardIfNeeded() else { return false }
        load(doc, url: nil, untitledName: name, mode: mode)
        hasChanges = true
        return true
    }

    private func load(_ doc: PDFDocument, url: URL?, untitledName: String?, mode: WorkspaceMode) {
        endTools()
        resumePageIndex = nil
        document = doc
        fileURL = url
        self.untitledName = untitledName
        stamps = []
        annotationsByID = [:]
        selectedStampID = nil
        selectedPages = []
        cutMarks = []
        lastClickedPage = nil
        statusMessage = nil
        hasChanges = false
        formFieldCount = Self.countFormFields(in: doc)
        formValuesAtLoad = Self.formValues(in: doc)
        formHintDismissed = false
        docRevision += 1
        undoManager.removeAllActions()
        refreshUndoState()
        self.mode = mode
    }

    /// Back to the start screen.
    func close() {
        finishInlineEditing?(true)
        guard confirmDiscardIfNeeded() else { return }
        endTools()
        document = nil
        fileURL = nil
        untitledName = nil
        stamps = []
        annotationsByID = [:]
        selectedPages = []
        cutMarks = []
        lastClickedPage = nil
        hasChanges = false
        undoManager.removeAllActions()
        refreshUndoState()
    }

    private static func countFormFields(in doc: PDFDocument) -> Int {
        var names = Set<String>()
        var unnamed = 0
        for index in 0..<doc.pageCount {
            for annotation in doc.page(at: index)?.annotations ?? []
            where annotation.type == "Widget" || annotation.type == "/Widget" {
                if let name = annotation.fieldName { names.insert(name) } else { unnamed += 1 }
            }
        }
        return names.count + unnamed
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
        removeGhost()
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
            // Remember the visible page and zoom so the view doesn't jump.
            let visiblePageIndex = pdfView?.currentPage.map { doc.index(for: $0) }
            if let pdfView {
                viewStateToRestore = ViewState(scale: pdfView.scaleFactor, autoScales: pdfView.autoScales,
                                               pageIndex: visiblePageIndex.flatMap { $0 == NSNotFound ? nil : $0 })
            }
            if let saved = PDFDocument(url: url) {
                // Selection and cut marks refer to the old page objects; the
                // saved file has the same pages in the same order.
                let selected = selectedIndices
                let cuts = pages.enumerated().filter { cutMarks.contains(ObjectIdentifier($0.element)) }.map(\.offset)
                document = saved
                fileURL = url
                untitledName = nil
                RecentsStore.add(url)
                let newPages = pages
                selectedPages = Set(selected.compactMap { newPages.indices.contains($0) ? ObjectIdentifier(newPages[$0]) : nil })
                cutMarks = Set(cuts.compactMap { newPages.indices.contains($0) ? ObjectIdentifier(newPages[$0]) : nil })
                lastClickedPage = nil
                stamps = []
                annotationsByID = [:]
                hasChanges = false
                formFieldCount = Self.countFormFields(in: saved)
                formValuesAtLoad = Self.formValues(in: saved)
                docRevision += 1
                // The undo stack references the pre-save document; drop it.
                undoManager.removeAllActions()
                refreshUndoState()
            }
            statusMessage = loc("status.saved", url.lastPathComponent)
        } catch {
            showError(error.localizedDescription, title: loc("alert.saveError"))
        }
    }

    func printDocument() {
        guard let pdfView, pdfView.document != nil else { return }
        // Never print the selection widget (frame, handles, delete button).
        select(nil)
        removeGhost()
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
        // Counter the page rotation so the stamp appears upright on screen.
        let stamp = PlacedStamp(id: UUID(), page: page, rect: rect,
                                rotation: CGFloat(page.rotation), image: pending.image,
                                text: pending.text, fontSize: pending.fontSize)
        pendingStamp = nil
        restoreStamp(stamp)
        select(stamp.id)
    }

    /// Size a pending stamp will get when placed.
    private func placementSize(for pending: PendingStamp) -> CGSize {
        let imgSize = pending.image.size
        let aspect = imgSize.width > 0 ? imgSize.height / imgSize.width : 0.4
        return CGSize(width: pending.defaultWidth, height: pending.defaultWidth * aspect)
    }

    /// Moves the placement preview to `pagePoint`, creating it on first use.
    func updateGhost(at pagePoint: CGPoint, on page: PDFPage) {
        guard let pending = pendingStamp else {
            removeGhost()
            return
        }
        let size = placementSize(for: pending)
        let rect = CGRect(x: pagePoint.x - size.width / 2, y: pagePoint.y - size.height / 2,
                          width: size.width, height: size.height)
        if let ghost, ghost.image !== pending.image {
            removeGhost()
        }
        let annotation: ImageStampAnnotation
        if let ghost {
            annotation = ghost
            annotation.update(imageRect: rect, rotation: CGFloat(page.rotation))
        } else {
            annotation = ImageStampAnnotation(image: pending.image, stampID: UUID(),
                                              imageRect: rect, rotation: CGFloat(page.rotation))
            annotation.opacity = 0.45
            annotation.shouldPrint = false
            ghost = annotation
        }
        if annotation.page !== page {
            if let previous = annotation.page {
                detach(annotation, from: previous)
            }
            page.addAnnotation(annotation)
            redraw(page)
        }
    }

    func removeGhost() {
        guard let ghost else { return }
        if let page = ghost.page {
            detach(ghost, from: page)
        }
        self.ghost = nil
    }

    /// PDFView does not always repaint after an annotation is added to or
    /// removed from a page; ask for it explicitly.
    private func redraw(_ page: PDFPage) {
        pdfView?.annotationsChanged(on: page)
    }

    /// Hides a stamp on screen (e.g. while its text is being edited).
    func setStampVisible(_ id: UUID, _ visible: Bool) {
        guard let annotation = annotationsByID[id], annotation.shouldDisplay != visible else { return }
        annotation.shouldDisplay = visible
        annotation.bounds = annotation.bounds
        if let page = annotation.page { redraw(page) }
    }

    /// Removes one of our annotations so it also vanishes from the screen.
    /// PDFKit leaves the last drawing of a removed custom annotation on
    /// screen (standard annotations disappear); hiding it first while it is
    /// still on the page makes PDFKit repaint that area.
    private func detach(_ annotation: ImageStampAnnotation, from page: PDFPage) {
        annotation.shouldDisplay = false
        annotation.bounds = annotation.bounds
        page.removeAnnotation(annotation)
        redraw(page)
    }

    /// Adds (or re-adds after undo) a stamp; inverse of removeStamp.
    func restoreStamp(_ stamp: PlacedStamp) {
        let annotation = ImageStampAnnotation(image: stamp.image, stampID: stamp.id,
                                              imageRect: stamp.rect, rotation: stamp.rotation)
        stamp.page.addAnnotation(annotation)
        redraw(stamp.page)
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
            detach(annotation, from: stamp.page)
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
            let selected = stampID == id
            guard annotation.isSelectedUI != selected else { continue }
            annotation.isSelectedUI = selected
            // Re-setting bounds pokes PDFView into redrawing the annotation.
            annotation.bounds = annotation.bounds
            if let page = annotation.page { redraw(page) }
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

    /// Re-renders the selected text at `size` (crisp, unlike scaling the
    /// image), keeping its centre and rotation; one undo step.
    func setSelectedTextSize(_ size: CGFloat) {
        guard let stamp = selectedStamp, let text = stamp.text else { return }
        let size = min(max(size, 6), 96)
        guard let png = ImageUtils.renderText(text, fontSize: size), let image = NSImage(data: png) else { return }
        let natural = CGSize(width: image.size.width / 3, height: image.size.height / 3)
        let rect = CGRect(x: stamp.rect.midX - natural.width / 2, y: stamp.rect.midY - natural.height / 2,
                          width: natural.width, height: natural.height)
        let replacement = PlacedStamp(id: UUID(), page: stamp.page, rect: rect, rotation: stamp.rotation,
                                      image: image, text: text, fontSize: size)
        undoManager.beginUndoGrouping()
        removeStamp(id: stamp.id)
        restoreStamp(replacement)
        undoManager.endUndoGrouping()
        undoManager.setActionName(loc("text.size"))
        select(replacement.id)
        // The next text starts at the size just chosen.
        textToolFontSize = size
    }

    /// Grows or shrinks the selected stamp around its centre; one undo step.
    func scaleSelected(by factor: CGFloat) {
        guard let stamp = selectedStamp else { return }
        let width = min(max(stamp.rect.width * factor, 16), 700)
        let aspect = stamp.rect.width > 0 ? stamp.rect.height / stamp.rect.width : 0.4
        let newRect = CGRect(x: stamp.rect.midX - width / 2, y: stamp.rect.midY - width * aspect / 2,
                             width: width, height: width * aspect)
        setRect(id: stamp.id, to: newRect)
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

        var rotation = CGFloat(page.rotation)
        // renderText draws at 3x, so a third of the pixel size is the point size.
        let size = CGSize(width: image.size.width / 3, height: image.size.height / 3)
        var rect = CGRect(origin: origin, size: size)
        if rotation != 0 {
            // On a rotated page the text grows to the right *on screen*; place the
            // rect around the centre the user sees, then counter-rotate it.
            let center = ImageStampAnnotation.rotate(
                point: CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2),
                around: origin, degrees: rotation)
            rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height)
        }

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

    /// Tick or cross for forms without fields.
    func startPlacingMark(_ mark: String) {
        startPlacingText(mark, fontSize: max(textToolFontSize, 14) + 4)
    }

    /// Starts placing a signature or initials image.
    func startPlacing(image: NSImage, defaultWidth: CGFloat, label: String) {
        pendingStamp = PendingStamp(image: image, defaultWidth: defaultWidth, label: label)
    }

    /// Places `image` in the lower right corner of every page (initials on
    /// every page of a contract); one undo step.
    func placeOnEveryPage(image: NSImage, width: CGFloat) {
        guard let doc = document else { return }
        endTools()
        let aspect = image.size.width > 0 ? image.size.height / image.size.width : 0.4
        let size = CGSize(width: width, height: width * aspect)
        let margin: CGFloat = 28
        undoManager.beginUndoGrouping()
        for page in pages {
            let box = page.bounds(for: .cropBox)
            // Lower right as seen on screen, whatever the page rotation.
            let visual: CGPoint
            switch ((page.rotation % 360) + 360) % 360 {
            // Shown rotated clockwise: at 90° the page's right edge is at the
            // bottom and its top edge on the right, and so on.
            case 90: visual = CGPoint(x: box.maxX - margin - size.height / 2, y: box.maxY - margin - size.width / 2)
            case 180: visual = CGPoint(x: box.minX + margin + size.width / 2, y: box.maxY - margin - size.height / 2)
            case 270: visual = CGPoint(x: box.minX + margin + size.height / 2, y: box.minY + margin + size.width / 2)
            default: visual = CGPoint(x: box.maxX - margin - size.width / 2, y: box.minY + margin + size.height / 2)
            }
            let rect = CGRect(x: visual.x - size.width / 2, y: visual.y - size.height / 2,
                              width: size.width, height: size.height)
            restoreStamp(PlacedStamp(id: UUID(), page: page, rect: rect,
                                     rotation: CGFloat(page.rotation), image: image))
        }
        undoManager.endUndoGrouping()
        undoManager.setActionName(loc("undo.initialsEveryPage"))
        refreshUndoState()
        statusMessage = locCount("status.initialsPlaced", doc.pageCount)
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
        selectedPages.remove(ObjectIdentifier(page))
        let hadCut = cutMarks.remove(ObjectIdentifier(page)) != nil
        doc.removePage(at: index)
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.reinsertPage(page, at: index, stamps: affected, cut: hadCut) }
        }
        changed()
    }

    func reinsertPage(_ page: PDFPage, at index: Int, stamps affected: [PlacedStamp], cut: Bool = false) {
        guard let doc = document else { return }
        doc.insert(page, at: min(index, doc.pageCount))
        stamps.append(contentsOf: affected)
        if cut { cutMarks.insert(ObjectIdentifier(page)) }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.deletePage(index) }
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
        for i in 0..<doc.pageCount {
            let name = String(format: "%@ – %@ %02d.pdf", baseName, loc("split.pageWord"), i + 1)
            try extractPages([i], to: folder.appendingPathComponent(name))
        }
        return doc.pageCount
    }

    func changed() {
        hasChanges = true
        docRevision += 1
        pdfView?.layoutDocumentView()
        refreshUndoState()
    }
}
