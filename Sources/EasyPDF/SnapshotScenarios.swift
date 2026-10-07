#if DEBUG
import AppKit
import PDFKit
import SwiftUI

@MainActor
extension SnapshotScenario {
    private static func open(_ doc: DocumentModel) {
        if let sample = Snapshot.sample { doc.open(url: sample) }
    }

    /// Scrolls to the signature lines at the bottom of page 1.
    private static func showBottom(_ doc: DocumentModel) {
        guard let page = doc.document?.page(at: 0) else { return }
        doc.pdfView?.go(to: CGRect(x: 0, y: 40, width: 595, height: 330), on: page)
    }

    private static func placeSignature(_ doc: DocumentModel, _ store: ProfileStore) {
        guard let page = doc.document?.page(at: 0),
              let image = store.persons.first?.signatureImage else { return }
        doc.startPlacing(image: image, defaultWidth: 170, label: loc("signature.placeLabel", "Finn Stolle"))
        doc.place(at: CGPoint(x: 160, y: 150), on: page)
    }

    static let all: [SnapshotScenario] = [
        SnapshotScenario(name: "new-14-rotated-page", prepare: { doc, _ in
            if let second = Snapshot.secondSample { doc.open(url: second) }
            doc.document?.page(at: 0)?.rotation = 90
        }, afterShow: { doc, store in
            guard let page = doc.document?.page(at: 0), let image = store.persons.first?.signatureImage else { return }
            doc.changed()
            Snapshot.settle(0.3)
            // Lower right as seen on screen = page space (high x, high y) at 90°.
            doc.startPlacing(image: image, defaultWidth: 170, label: "x")
            doc.place(at: CGPoint(x: 480, y: 700), on: page)
            doc.select(nil)
            doc.placeOnEveryPage(image: store.persons.first!.initialsImage!, width: 46)
            doc.statusMessage = nil
        }),
        SnapshotScenario(name: "new-15-pages-narrow", size: CGSize(width: 940, height: 640), prepare: { doc, _ in
            doc.openAsNew([Snapshot.sample, Snapshot.secondSample].compactMap { $0 })
        }, afterShow: { doc, _ in
            doc.statusMessage = nil
            doc.selectPage(at: 1, extend: false, range: false)
        }),
        SnapshotScenario(name: "new-01-start", prepare: { doc, _ in doc.close() }),
        SnapshotScenario(name: "new-02-document", prepare: { doc, _ in open(doc) }),
        SnapshotScenario(name: "new-04-placing", prepare: { doc, _ in open(doc) }, afterShow: { doc, store in
            showBottom(doc)
            Snapshot.settle(0.4)
            guard let page = doc.document?.page(at: 0), let image = store.persons.first?.signatureImage else { return }
            doc.startPlacing(image: image, defaultWidth: 170, label: loc("signature.placeLabel", "Finn Stolle"))
            doc.updateGhost(at: CGPoint(x: 165, y: 150), on: page)
        }),
        SnapshotScenario(name: "new-05-selected", prepare: { doc, _ in open(doc) }, afterShow: { doc, store in
            showBottom(doc)
            Snapshot.settle(0.4)
            placeSignature(doc, store)
        }),
        SnapshotScenario(name: "new-06-text", prepare: { doc, _ in open(doc) }, afterShow: { doc, store in
            showBottom(doc)
            placeSignature(doc, store)
            doc.select(nil)
            doc.textToolActive = true
        }),
        SnapshotScenario(name: "new-07-pages", prepare: { doc, _ in
            open(doc)
            doc.mode = .pages
        }, afterShow: { doc, _ in
            doc.selectPage(at: 1, extend: false, range: false)
        }),
        SnapshotScenario(name: "new-08-merged", prepare: { doc, _ in
            doc.openAsNew([Snapshot.sample, Snapshot.secondSample].compactMap { $0 })
        }, afterShow: { doc, _ in
            doc.statusMessage = nil
            doc.selectPage(at: 3, extend: false, range: false)
            doc.selectPage(at: 5, extend: false, range: true)
            if let third = doc.document?.page(at: 2) { doc.toggleCut(after: third) }
        }),
        SnapshotScenario(name: "new-09-editor-draw", standalone: { doc, store in
            AnyView(SignatureEditorSheet(request: SignatureEditorRequest(person: Person(), kind: .signature))
                .environmentObject(store).environmentObject(doc))
        }),
        SnapshotScenario(name: "new-10-editor-type", standalone: { doc, store in
            AnyView(SignatureEditorSheet(request: SignatureEditorRequest(
                person: Person(name: "Finn Stolle"), kind: .signature, method: .type))
                .environmentObject(store).environmentObject(doc))
        }),
        SnapshotScenario(name: "new-11-images-sheet", standalone: { doc, _ in
            AnyView(ImagesToPDFSheet(initialFiles: ["IMG_4711.HEIC", "IMG_4712.HEIC", "Scan Seite 3.png"]
                .map { URL(fileURLWithPath: "/tmp/\($0)") })
                .environmentObject(doc))
        }),
        SnapshotScenario(name: "new-12-pages-dark", prepare: { doc, _ in
            NSApp.appearance = NSAppearance(named: .darkAqua)
            doc.openAsNew([Snapshot.sample, Snapshot.secondSample].compactMap { $0 })
        }, afterShow: { doc, _ in
            doc.statusMessage = nil
            doc.selectPage(at: 0, extend: false, range: false)
        }),
        SnapshotScenario(name: "new-13-document-dark", prepare: { doc, _ in
            NSApp.appearance = NSAppearance(named: .darkAqua)
            open(doc)
        }, afterShow: { doc, store in
            showBottom(doc)
            placeSignature(doc, store)
        }),
    ]
}
#endif
