import SwiftUI
import PDFKit

final class InteractivePDFView: PDFView {
    weak var model: DocumentModel?

    private enum DragMode {
        case move(offset: CGPoint)
        case resize(anchor: CGPoint, aspect: CGFloat)
    }

    private var draggingStampID: UUID?
    private var dragMode: DragMode?
    private var dragStartRect: CGRect = .zero

    override var acceptsFirstResponder: Bool { true }

    // Routes Cmd+Z / Cmd+Shift+Z from the Edit menu to our document undo stack.
    override var undoManager: UndoManager? { model?.undoManager }

    private func pagePoint(for event: NSEvent) -> (CGPoint, PDFPage)? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return nil }
        return (convert(viewPoint, to: page), page)
    }

    override func mouseDown(with event: NSEvent) {
        guard let model, let (point, page) = pagePoint(for: event),
              model.document != nil else {
            super.mouseDown(with: event)
            return
        }

        if model.pendingStamp != nil {
            model.place(at: point, on: page)
            return
        }

        // Selection widget of the currently selected stamp: delete button + resize handles.
        if let selected = model.selectedStamp, selected.page === page {
            let rect = selected.rect

            let deleteCenter = ImageStampAnnotation.deleteButtonCenter(for: rect)
            if hypot(point.x - deleteCenter.x, point.y - deleteCenter.y) <= ImageStampAnnotation.deleteRadius + 4 {
                model.removeSelected()
                return
            }

            let corners = ImageStampAnnotation.handleCenters(for: rect)
            let grabRadius = ImageStampAnnotation.handleSize / 2 + 5
            if let corner = corners.first(where: {
                abs(point.x - $0.x) <= grabRadius && abs(point.y - $0.y) <= grabRadius
            }) {
                // Anchor is the corner diagonally opposite to the grabbed one.
                let anchor = CGPoint(
                    x: corner.x == rect.minX ? rect.maxX : rect.minX,
                    y: corner.y == rect.minY ? rect.maxY : rect.minY
                )
                let aspect = rect.width > 0 ? rect.height / rect.width : 0.4
                draggingStampID = selected.id
                dragStartRect = rect
                dragMode = .resize(anchor: anchor, aspect: aspect)
                return
            }
        }

        if let hit = model.stamp(at: point, page: page) {
            model.select(hit.id)
            draggingStampID = hit.id
            dragStartRect = hit.rect
            dragMode = .move(offset: CGPoint(x: point.x - hit.rect.minX, y: point.y - hit.rect.minY))
            return
        }

        model.select(nil)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let id = draggingStampID, let dragMode,
              let stamp = model.stamps.first(where: { $0.id == id }),
              let (point, page) = pagePoint(for: event),
              page === stamp.page else {
            super.mouseDragged(with: event)
            return
        }

        switch dragMode {
        case .move(let offset):
            let newRect = CGRect(x: point.x - offset.x,
                                 y: point.y - offset.y,
                                 width: stamp.rect.width,
                                 height: stamp.rect.height)
            model.updateRect(newRect, for: id)

        case .resize(let anchor, let aspect):
            let width = max(24, abs(point.x - anchor.x))
            let height = width * aspect
            let newRect = CGRect(
                x: point.x < anchor.x ? anchor.x - width : anchor.x,
                y: point.y < anchor.y ? anchor.y - height : anchor.y,
                width: width,
                height: height
            )
            model.updateRect(newRect, for: id)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let id = draggingStampID {
            model?.commitRectChange(id: id, from: dragStartRect)
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
            if model.pendingStamp != nil {
                model.cancelPending()
                return
            }
            if model.selectedStampID != nil {
                model.select(nil)
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }
}

struct PDFKitView: NSViewRepresentable {
    @ObservedObject var model: DocumentModel

    func makeNSView(context: Context) -> InteractivePDFView {
        let view = InteractivePDFView()
        view.model = model
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .windowBackgroundColor
        model.pdfView = view
        return view
    }

    func updateNSView(_ view: InteractivePDFView, context: Context) {
        if view.document !== model.document {
            view.document = model.document
        }
    }
}
