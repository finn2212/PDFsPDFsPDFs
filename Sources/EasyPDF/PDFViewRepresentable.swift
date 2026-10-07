import SwiftUI
import PDFKit

/// Text field that commits on Return and cancels on Escape.
final class InlineTextField: NSTextField {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Draws the detected fill-in fields of one page in blue (like Acrobat's
/// Fill & Sign) while the fill-in tool is on. Purely visual: it lets every
/// click through and never touches the document.
final class FieldOverlayView: NSView {
    let page: PDFPage
    weak var pdfView: PDFView?
    weak var model: DocumentModel?

    init(page: PDFPage, pdfView: PDFView, model: DocumentModel?) {
        self.page = page
        self.pdfView = pdfView
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let pdfView, model.textToolActive else { return }
        let accent = NSColor.controlAccentColor
        for field in model.openFields(on: page) {
            let rect = convert(pdfView.convert(field.rect, from: page), from: pdfView)
            let hovered = field.id == model.hoveredFieldID
            accent.withAlphaComponent(hovered ? 0.22 : 0.10).setFill()
            let shape = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            shape.fill()
            accent.withAlphaComponent(hovered ? 0.9 : 0.45).setStroke()
            if field.kind == .line {
                let underline = NSBezierPath()
                underline.move(to: NSPoint(x: rect.minX, y: rect.minY))
                underline.line(to: NSPoint(x: rect.maxX, y: rect.minY))
                underline.lineWidth = hovered ? 2 : 1
                underline.stroke()
            } else {
                shape.lineWidth = hovered ? 1.5 : 1
                shape.stroke()
            }
        }
    }
}

/// Hands PDFKit one field overlay per displayed page.
final class FieldOverlayProvider: NSObject, PDFPageOverlayViewProvider {
    weak var model: DocumentModel?
    private var overlays: [ObjectIdentifier: FieldOverlayView] = [:]

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = FieldOverlayView(page: page, pdfView: view, model: model)
        overlays[ObjectIdentifier(page)] = overlay
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        overlays[ObjectIdentifier(page)] = nil
    }

    func refresh() {
        overlays.values.forEach { $0.needsDisplay = true }
    }
}

final class InteractivePDFView: PDFView, NSTextFieldDelegate {
    weak var model: DocumentModel?
    let fieldOverlays = FieldOverlayProvider()
    /// The detected field the inline editor is filling, for Tab navigation.
    private var editingField: DetectedField?

    private enum DragMode {
        case move(offset: CGPoint)
        /// `anchor` is the fixed corner in the stamp's own unrotated space.
        case resize(anchor: CGPoint, aspect: CGFloat)
        case rotate(center: CGPoint, startAngle: CGFloat, startRotation: CGFloat)
    }

    /// Widget parts of the selection UI, hit-tested in the stamp's own space.
    private enum WidgetPart {
        case delete
        case rotate
        case corner(Int)
    }

    private var draggingStampID: UUID?
    private var dragMode: DragMode?
    private var dragStartRect: CGRect = .zero
    private var dragStartRotation: CGFloat = 0

    // Inline text editing state
    private var textField: InlineTextField?
    private var editingPage: PDFPage?
    private var editingOrigin: CGPoint = .zero
    private var editingReplacesID: UUID?
    private var observers: [NSObjectProtocol] = []
    private var placementTracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    // While a signature waits to be placed, the first click into an inactive
    // window places it instead of only activating the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        let accept = model?.pendingStamp != nil || super.acceptsFirstMouse(for: event)
        Log.ui.notice("acceptsFirstMouse: \(accept, privacy: .public)")
        return accept
    }

    // Routes Cmd+Z / Cmd+Shift+Z from the Edit menu to our document undo stack.
    override var undoManager: UndoManager? { model?.undoManager }

    private func pagePoint(for event: NSEvent) -> (CGPoint, PDFPage)? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return nil }
        return (convert(viewPoint, to: page), page)
    }

    // MARK: - Selection widget hit-testing

    /// Returns the widget part under `pagePoint`, or nil. Everything is measured
    /// in the stamp's unrotated space (rotation is rigid, so distances match),
    /// and the closest candidate wins so parts can never swallow each other.
    private func widgetPart(at pagePoint: CGPoint, of stamp: PlacedStamp) -> WidgetPart? {
        let rect = stamp.rect
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let local = ImageStampAnnotation.rotate(point: pagePoint, around: center,
                                                degrees: -stamp.rotation)
        let gap = ImageStampAnnotation.buttonGap
        let insideStamp = rect.contains(local)

        var candidates: [(part: WidgetPart, distance: CGFloat, radius: CGFloat)] = []

        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
        for (index, corner) in corners.enumerated() {
            candidates.append((.corner(index),
                               hypot(local.x - corner.x, local.y - corner.y),
                               ImageStampAnnotation.handleSize / 2 + 4))
        }

        // Buttons sit outside the stamp; ignore them for clicks inside it so a
        // click on a tiny stamp can never delete it by accident.
        if !insideStamp {
            let delete = CGPoint(x: rect.midX, y: rect.maxY + gap)
            candidates.append((.delete, hypot(local.x - delete.x, local.y - delete.y),
                               ImageStampAnnotation.deleteRadius + 4))
            let grip = CGPoint(x: rect.midX, y: rect.minY - gap)
            candidates.append((.rotate, hypot(local.x - grip.x, local.y - grip.y),
                               ImageStampAnnotation.rotateRadius + 4))
        }

        return candidates
            .filter { $0.distance <= $0.radius }
            .min { $0.distance < $1.distance }?
            .part
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let model, let (point, page) = pagePoint(for: event),
              model.document != nil else {
            Log.ui.notice("mouseDown: outside any page")
            super.mouseDown(with: event)
            return
        }
        Log.ui.notice("mouseDown: pending \(model.pendingStamp != nil, privacy: .public) textTool \(model.textToolActive, privacy: .public) clicks \(event.clickCount, privacy: .public)")

        // An open editor commits when clicking elsewhere. If a stamp is waiting
        // to be placed, the same click still places it.
        if textField != nil {
            commitTextEditing()
            if model.pendingStamp == nil { return }
        }

        if model.pendingStamp != nil {
            model.place(at: point, on: page)
            return
        }

        // Double-click on a text stamp re-opens it for editing.
        if event.clickCount == 2, let hit = model.stamp(at: point, page: page), hit.text != nil {
            let center = CGPoint(x: hit.rect.midX, y: hit.rect.midY)
            let visibleOrigin = ImageStampAnnotation.rotate(point: hit.rect.origin,
                                                           around: center, degrees: hit.rotation)
            beginTextEditing(at: visibleOrigin, on: page, existing: hit)
            return
        }

        if let selected = model.selectedStamp, selected.page === page,
           let part = widgetPart(at: point, of: selected) {
            switch part {
            case .delete:
                model.removeSelected()
            case .rotate:
                let center = CGPoint(x: selected.rect.midX, y: selected.rect.midY)
                draggingStampID = selected.id
                dragStartRect = selected.rect
                dragStartRotation = selected.rotation
                dragMode = .rotate(center: center,
                                   startAngle: atan2(point.y - center.y, point.x - center.x),
                                   startRotation: selected.rotation)
            case .corner(let index):
                let rect = selected.rect
                let upright = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                               CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
                let opposite = [3, 2, 1, 0][index]
                draggingStampID = selected.id
                dragStartRect = rect
                dragStartRotation = selected.rotation
                dragMode = .resize(anchor: upright[opposite],
                                   aspect: rect.width > 0 ? rect.height / rect.width : 0.4)
            }
            return
        }

        if let hit = model.stamp(at: point, page: page) {
            model.select(hit.id)
            draggingStampID = hit.id
            dragStartRect = hit.rect
            dragStartRotation = hit.rotation
            dragMode = .move(offset: CGPoint(x: point.x - hit.rect.minX, y: point.y - hit.rect.minY))
            return
        }

        // Fill-in tool: a click into a detected field writes right there
        // (checkboxes get a tick); anywhere else starts free text.
        if model.textToolActive {
            model.select(nil)
            if let field = model.field(at: point, on: page) {
                Log.ui.notice("fields: clicked a \(String(describing: field.kind), privacy: .public) field")
                if field.kind == .checkbox {
                    model.tick(field, on: page)
                } else {
                    beginFieldEditing(field, on: page)
                }
                return
            }
            beginTextEditing(at: point, on: page, existing: nil)
            return
        }

        model.select(nil)
        // PDFKit edits form fields itself; toggles and choices change on click.
        let widget = page.annotation(at: point).flatMap { $0.type == "Widget" || $0.type == "/Widget" ? $0 : nil }
        super.mouseDown(with: event)
        if let widget, widget.widgetFieldType != .text {
            model.noteFormEdit()
        }
    }

    // MARK: - Placement preview

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let placementTracking { removeTrackingArea(placementTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        placementTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let model, let (point, page) = pagePoint(for: event) else { return }
        if model.pendingStamp != nil {
            model.updateGhost(at: point, on: page)
        } else if model.textToolActive {
            let hovered = model.field(at: point, on: page)?.id
            if hovered != model.hoveredFieldID {
                model.hoveredFieldID = hovered
                fieldOverlays.refresh()
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        model?.removeGhost()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let id = draggingStampID, let dragMode,
              let stamp = model.stamps.first(where: { $0.id == id }) else {
            super.mouseDragged(with: event)
            return
        }
        // Stay in the dragged stamp's page space even when the cursor crosses
        // into a neighbouring page, so dragging never stalls mid-gesture.
        let point = convert(convert(event.locationInWindow, from: nil), to: stamp.page)

        switch dragMode {
        case .move(let offset):
            let newRect = CGRect(x: point.x - offset.x,
                                 y: point.y - offset.y,
                                 width: stamp.rect.width,
                                 height: stamp.rect.height)
            model.updateRect(newRect, for: id)

        case .resize(let anchor, let aspect):
            let newRect = ImageStampAnnotation.resizedRect(
                startRect: dragStartRect, anchor: anchor, aspect: aspect,
                rotation: stamp.rotation, dragPoint: point)
            model.updateRect(newRect, for: id)

        case .rotate(let center, let startAngle, let startRotation):
            let angle = atan2(point.y - center.y, point.x - center.x)
            var degrees = startRotation + (angle - startAngle) * 180 / .pi
            // Shift snaps to 15° steps.
            if event.modifierFlags.contains(.shift) {
                degrees = (degrees / 15).rounded() * 15
            }
            model.updateRotation(degrees, for: id)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let id = draggingStampID {
            model?.commitRectChange(id: id, from: dragStartRect, oldRotation: dragStartRotation)
            draggingStampID = nil
            dragMode = nil
            return
        }
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let model else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 51, 117: // backspace, forward delete
            if model.selectedStampID != nil {
                model.removeSelected()
                return
            }
        case 53: // escape
            if textField != nil {
                cancelTextEditing()
                return
            }
            if model.pendingStamp != nil {
                model.cancelPending()
                return
            }
            // Deselect first, then end the tool: one step back per Esc.
            if model.selectedStampID != nil {
                model.select(nil)
                return
            }
            if model.textToolActive {
                model.textToolActive = false
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let model else { return }
        if model.pendingStamp != nil {
            addCursorRect(bounds, cursor: .crosshair)
        } else if model.textToolActive {
            addCursorRect(bounds, cursor: .iBeam)
        }
    }

    // MARK: - Inline text editing

    /// Opens a text field on the page at `origin` (lower-left of the text).
    func beginTextEditing(at origin: CGPoint, on page: PDFPage, existing: PlacedStamp?) {
        guard let model else { return }
        commitTextEditing()

        editingPage = page
        editingOrigin = origin
        editingReplacesID = existing?.id
        // A new text starts with nothing selected (Tab leaves the previous one).
        if existing == nil { model.select(nil) }
        // Continue at the size the text has now (it may have been resized).
        if let existing {
            model.textToolFontSize = (existing.effectiveFontSize * 2).rounded() / 2
            // Only the editor shows the text while it is being changed.
            model.select(nil)
            model.setStampVisible(existing.id, false)
        }

        let field = InlineTextField(frame: .zero)
        field.stringValue = existing?.text ?? ""
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.9)
        field.focusRingType = .none
        // Single-line + scrollable: the caret stays visible for long text
        // instead of wrapping out of the fixed-height field.
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.target = self
        field.action = #selector(textFieldAction)
        field.onCancel = { [weak self] in self?.cancelTextEditing() }
        field.placeholderString = loc("text.inlinePlaceholder")

        addSubview(field)
        textField = field
        layoutTextField()

        window?.makeFirstResponder(field)
        model.isEditingText = true

        // Keep the field glued to its page position while scrolling or zooming.
        if observers.isEmpty {
            if let clip = enclosingScrollViewClipView() {
                clip.postsBoundsChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.layoutTextField() }
                })
            }
            observers.append(NotificationCenter.default.addObserver(
                forName: .PDFViewScaleChanged, object: self, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutTextField() }
            })
        }
    }

    private func enclosingScrollViewClipView() -> NSClipView? {
        var view: NSView? = self
        while let current = view {
            if let scroll = current as? NSScrollView { return scroll.contentView }
            for sub in current.subviews {
                if let scroll = sub as? NSScrollView { return scroll.contentView }
            }
            view = current.superview
        }
        return nil
    }

    /// Positions the editor so the typed text sits where the stamp will land:
    /// same baseline and same left edge as `ImageUtils.renderText` produces.
    private func layoutTextField() {
        guard let field = textField, let page = editingPage, let model else { return }
        let scale = scaleFactor
        let pointSize = max(model.textToolFontSize, 4)
        let font = NSFont.systemFont(ofSize: pointSize * scale)
        field.font = font

        let viewPoint = convert(editingOrigin, from: page)
        let cellSize = field.cell?.cellSize ?? NSSize(width: 90, height: font.pointSize * 1.4)
        // Measure what is being typed (the cell only learns it after editing),
        // so the field grows with the text instead of scrolling it away.
        let typed = field.currentEditor()?.string ?? field.stringValue
        let shown = typed.isEmpty ? (field.placeholderString ?? "") : typed
        let textWidth = ceil((shown as NSString).size(withAttributes: [.font: font]).width)
        let width = max(textWidth + font.pointSize * 1.2, 60)
        let height = max(cellSize.height, font.pointSize * 1.3)

        // renderText pads the image by 2 pt and the glyphs sit on a baseline
        // 2 pt + |descender| above the stamp's bottom edge.
        let descender = abs(font.descender)
        let baselineInView = viewPoint.y + (2 * scale) + descender
        // Inside a single-line cell the text is vertically centred.
        let textHeight = font.ascender + descender
        let originY = baselineInView - descender - (height - textHeight) / 2
        field.frame = NSRect(x: viewPoint.x + 2 * scale - 2, y: originY,
                             width: width, height: height)
    }

    /// Starts typing into a detected field, at a size that fits it.
    func beginFieldEditing(_ field: DetectedField, on page: PDFPage) {
        guard let model else { return }
        commitTextEditing()
        model.textToolFontSize = (field.fontSize * 2).rounded() / 2
        beginTextEditing(at: field.textOrigin, on: page, existing: nil)
        editingField = field
    }

    /// Tab / ⇧Tab in the inline editor: keep the text, jump to the next field.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let forward = commandSelector == #selector(NSResponder.insertTab(_:))
        let backward = commandSelector == #selector(NSResponder.insertBacktab(_:))
        guard forward || backward, let model, let page = editingPage else { return false }
        let current = editingField
        commitTextEditing()
        if let (next, nextPage) = model.neighbourField(of: current, on: page, backwards: backward) {
            go(to: next.rect.insetBy(dx: -40, dy: -60), on: nextPage)
            beginFieldEditing(next, on: nextPage)
        }
        return true
    }

    @objc private func textFieldAction() {
        commitTextEditing()
    }

    func controlTextDidChange(_ obj: Notification) {
        layoutTextField()
    }

    /// Live font-size updates from the toolbar while editing.
    func updateEditorFontSize() {
        layoutTextField()
    }

    var isEditingInline: Bool { textField != nil }

    func commitTextEditing() {
        guard let field = textField, let page = editingPage, let model else { return }
        let text = field.stringValue
        let replacing = editingReplacesID
        let origin = editingOrigin
        teardownEditor()
        editingReplacesID = nil

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Clearing an existing text removes it — that is the only way to
            // delete it from within the editor.
            if let replacing { model.removeStamp(id: replacing) }
            return
        }
        model.placeText(text, fontSize: model.textToolFontSize, at: origin,
                        on: page, replacing: replacing)
    }

    func cancelTextEditing() {
        teardownEditor()
        if let id = editingReplacesID {
            model?.setStampVisible(id, true)
        }
        editingReplacesID = nil
    }

    private func teardownEditor() {
        textField?.removeFromSuperview()
        textField = nil
        editingField = nil
        editingPage = nil
        model?.isEditingText = false
        removeObservers()
        window?.makeFirstResponder(self)
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

struct PDFKitView: NSViewRepresentable {
    @ObservedObject var model: DocumentModel
    static let maxInitialScale: CGFloat = 1.25

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Marks the document as changed when text is typed into a form field.
    /// The field editor lives inside the PDF view while a widget is edited.
    final class Coordinator {
        private var observer: NSObjectProtocol?

        @MainActor
        func observeTyping(in view: PDFView, model: DocumentModel) {
            observer = NotificationCenter.default.addObserver(
                forName: NSText.didChangeNotification, object: nil, queue: .main
            ) { [weak view, weak model] note in
                MainActor.assumeIsolated {
                    guard let view, let text = note.object as? NSView, text.isDescendant(of: view),
                          !(text.superview is InlineTextField) else { return }
                    model?.noteFormEdit()
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeNSView(context: Context) -> InteractivePDFView {
        let view = InteractivePDFView()
        view.model = model
        view.fieldOverlays.model = model
        view.pageOverlayViewProvider = view.fieldOverlays
        model.onFieldsChanged = { [weak view] in view?.fieldOverlays.refresh() }
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .windowBackgroundColor
        model.pdfView = view
        context.coordinator.observeTyping(in: view, model: model)
        model.finishInlineEditing = { [weak view] commit in
            guard let view, view.isEditingInline else { return }
            if commit {
                view.commitTextEditing()
            } else {
                view.cancelTextEditing()
            }
        }
        return view
    }

    func updateNSView(_ view: InteractivePDFView, context: Context) {
        if view.document !== model.document {
            view.document = model.document
            if let state = model.viewStateToRestore {
                // Saving swapped in the reloaded file: keep zoom and position.
                model.viewStateToRestore = nil
                view.autoScales = state.autoScales
                if !state.autoScales { view.scaleFactor = state.scale }
                DispatchQueue.main.async {
                    if let index = state.pageIndex, let page = view.document?.page(at: index) {
                        view.go(to: page)
                    }
                }
            } else {
                view.autoScales = true
                let resume = model.resumePageIndex
                model.resumePageIndex = nil
                DispatchQueue.main.async {
                    // Fit-to-width blows small pages up on large windows; cap it.
                    if view.scaleFactor > Self.maxInitialScale {
                        view.autoScales = false
                        view.scaleFactor = Self.maxInitialScale
                    }
                    if let resume, let page = view.document?.page(at: resume) {
                        view.go(to: page)
                    }
                }
            }
        }
        view.window?.invalidateCursorRects(for: view)
        if view.isEditingInline {
            view.updateEditorFontSize()
        }
    }
}
