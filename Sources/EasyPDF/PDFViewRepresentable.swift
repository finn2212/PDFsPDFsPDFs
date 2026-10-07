import SwiftUI
import PDFKit

/// Text field that commits on Return and cancels on Escape.
final class InlineTextField: NSTextField {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

final class InteractivePDFView: PDFView, NSTextFieldDelegate {
    weak var model: DocumentModel?

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
            super.mouseDown(with: event)
            return
        }

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

        // Text tool: click into the page and start typing right there.
        if model.textToolActive {
            model.select(nil)
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
        guard let model, model.pendingStamp != nil, let (point, page) = pagePoint(for: event) else { return }
        model.updateGhost(at: point, on: page)
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

/// The PDF view plus the floating context bar as a real subview on top of
/// it. A SwiftUI overlay above an AppKit view is not reliably hit-tested
/// before the view below, so clicks on the bar could land in the PDF.
final class PDFCanvasView: NSView {
    let pdfView = InteractivePDFView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Pins the bar bottom-centre; it sizes itself to its content, so it
    /// covers exactly the capsule and nothing else.
    func installBar(_ bar: NSView) {
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar, positioned: .above, relativeTo: pdfView)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            bar.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
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

    func makeNSView(context: Context) -> PDFCanvasView {
        let canvas = PDFCanvasView()
        let view = canvas.pdfView
        view.model = model
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
        canvas.installBar(NSHostingView(rootView: DocumentContextBar().environmentObject(model)))
        return canvas
    }

    func updateNSView(_ canvas: PDFCanvasView, context: Context) {
        let view = canvas.pdfView
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
