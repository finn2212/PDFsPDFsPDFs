#if DEBUG
import AppKit
import PDFKit
import SwiftUI

/// Debug-only interaction test: drives the real window with synthetic mouse
/// and keyboard events (clicks, typing, Return, corner drag, double-click),
/// checks the model after every step and saves a screenshot per step.
/// Usage: `.build/debug/EasyPDF --uitest <out-dir> <sample.pdf>`
@MainActor
enum UITest {
    private static var window: NSWindow!
    private static var outDir: URL!
    private static var stepNumber = 0
    private static var failures = 0

    static func run(arguments: [String]) -> Never {
        guard let flag = arguments.firstIndex(of: "--uitest"), arguments.count > flag + 2 else {
            print("usage: --uitest <out-dir> <sample.pdf>")
            exit(2)
        }
        outDir = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let sample = URL(fileURLWithPath: arguments[flag + 2])

        NSApplication.shared.setActivationPolicy(.accessory)
        let store = ProfileStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("easypdf-uitest-\(UUID().uuidString)", isDirectory: true))
        let doc = DocumentModel.shared
        doc.open(url: sample)
        window = Snapshot.makeWindow(store: store, doc: doc, size: CGSize(width: 1240, height: 800))
        Snapshot.settle(0.8)

        if ProcessInfo.processInfo.environment["UITEST_ACCURACY"] == nil {
            textScenario(doc)
            signatureScenario(doc, store: store)
        }
        accuracyScenario(doc)

        print(failures == 0 ? "UITEST PASS" : "UITEST FAIL (\(failures))")
        doc.hasChanges = false
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - The text scenario Finn asked for

    /// Finn's flow: place a text, make it look different, click it again,
    /// make it bigger/smaller again, edit it and put it back.
    private static func textScenario(_ doc: DocumentModel) {
        guard let page = doc.document?.page(at: 0), let pdfView = doc.pdfView else {
            check(false, "Dokument und PDF-Ansicht sind da")
            return
        }
        pdfView.go(to: CGRect(x: 0, y: 60, width: 595, height: 300), on: page)
        Snapshot.settle(0.4)
        func stamp(_ text: String) -> PlacedStamp? { doc.stamps.first { $0.text == text } }
        func size(_ text: String) -> Int { Int((stamp(text)?.effectiveFontSize ?? 0).rounded()) }

        // 1. Place a text: Text button, click into the page, type, Return.
        press("tool.text")
        check(doc.textToolActive, "1 · Knopf „Text“ schaltet das Werkzeug ein")
        click(page: page, at: CGPoint(x: 140, y: 262), in: pdfView)
        check(doc.isEditingText, "1 · Klick in die Seite öffnet das Eingabefeld")
        type("Max Mustermann")
        if let field = pdfView.subviews.compactMap({ $0 as? InlineTextField }).first, let font = field.font {
            let needed = ("Max Mustermann" as NSString).size(withAttributes: [.font: font]).width
            check(field.frame.width >= needed, "1 · Eingabefeld wächst mit dem Text (kein abgeschnittener Anfang)")
        }
        shot("1-tippen")
        key("\r", code: 36)
        check(stamp("Max Mustermann") != nil && !doc.isEditingText, "1 · Enter setzt „Max Mustermann“ (14 pt)")
        check(doc.selectedStamp?.text == "Max Mustermann", "1 · der neue Text ist gleich ausgewählt")
        shot("1-platziert")

        // 2. Make it different: + four times in the bar → 22 pt, re-rendered.
        for _ in 0..<4 { press("size.larger") }
        check(size("Max Mustermann") == 22 && doc.selectedStamp?.text == "Max Mustermann",
              "2 · + vergrößert den Text auf \(size("Max Mustermann")) pt, er bleibt ausgewählt")
        shot("2-anders")

        // A second text elsewhere, while the tool is still on.
        click(page: page, at: CGPoint(x: 140, y: 205), in: pdfView)
        check(doc.isEditingText && doc.selectedStamp == nil, "2 · Klick daneben hebt die Auswahl auf und startet neuen Text")
        type("Hamburg, 07.10.2026")
        key("\r", code: 36)
        check(stamp("Hamburg, 07.10.2026") != nil && doc.stamps.count == 2, "2 · zweiter Text gesetzt")
        key("\u{1b}", code: 53)
        check(doc.selectedStamp == nil && doc.textToolActive, "2 · Esc hebt erst die Auswahl auf, das Werkzeug bleibt an")
        shot("2-zweiter-text")

        // 3. Click the first text again: selected, no new text field.
        guard let first = stamp("Max Mustermann") else { return }
        click(page: page, at: CGPoint(x: first.rect.midX, y: first.rect.midY), in: pdfView)
        check(doc.selectedStamp?.text == "Max Mustermann" && !doc.isEditingText,
              "3 · Klick auf den Text wählt ihn aus (kein neues Eingabefeld)")
        shot("3-ausgewaehlt")

        // 4. Change it again: drag the corner bigger, then − twice.
        guard let selected = doc.selectedStamp else { return }
        let start = selected.rect
        drag(page: page, from: CGPoint(x: start.maxX, y: start.maxY),
             to: CGPoint(x: start.maxX + 60, y: start.maxY + 8), in: pdfView)
        let dragged = size("Max Mustermann")
        check(dragged > 22, "4 · Eckgriff ziehen vergrößert (22 → \(dragged) pt)")
        shot("4a-groesser")
        for _ in 0..<2 { press("size.smaller") }
        check(size("Max Mustermann") == dragged - 4 && doc.selectedStamp?.text == "Max Mustermann",
              "4 · − verkleinert in 2-pt-Schritten (\(dragged) → \(size("Max Mustermann")) pt)")
        shot("4b-kleiner")

        // 5. Edit it and put it back: double-click, replace the text, Return.
        guard let current = doc.selectedStamp else { return }
        let center = CGPoint(x: current.rect.midX, y: current.rect.midY)
        click(page: page, at: center, in: pdfView)
        click(page: page, at: center, in: pdfView, clickCount: 2)
        check(doc.isEditingText, "5 · Doppelklick öffnet den Text zum Bearbeiten")
        check(abs(doc.textToolFontSize - current.effectiveFontSize) < 0.6,
              "5 · Eingabefeld hat die aktuelle Größe (\(Int(doc.textToolFontSize)) pt)")
        let visible = page.annotations.compactMap { $0 as? ImageStampAnnotation }.filter(\.shouldDisplay)
        check(visible.count == 1 && doc.selectedStamp == nil,
              "5 · beim Bearbeiten ist nur das Eingabefeld zu sehen, nicht der alte Text dahinter")
        (window.firstResponder as? NSText)?.selectAll(nil)
        type("Erika Musterfrau")
        shot("5-bearbeiten")
        key("\r", code: 36)
        check(stamp("Erika Musterfrau") != nil && stamp("Max Mustermann") == nil && doc.stamps.count == 2,
              "5 · Text ersetzt, kein Duplikat")
        if let edited = stamp("Erika Musterfrau") {
            check(abs(edited.effectiveFontSize - current.effectiveFontSize) < 0.6,
                  "5 · Größe bleibt erhalten (\(Int(edited.effectiveFontSize.rounded())) pt)")
            check(abs(edited.rect.midY - current.rect.midY) < 1.5, "5 · Text bleibt auf seiner Zeile")
        }
        shot("5-fertig")

        // 6. Undo and redo the edit.
        doc.undo()
        check(stamp("Max Mustermann") != nil && stamp("Erika Musterfrau") == nil, "6 · ⌘Z holt den alten Text zurück")
        doc.redo()
        check(stamp("Erika Musterfrau") != nil, "6 · ⇧⌘Z stellt die Bearbeitung wieder her")

        // 6b. Double-click and Esc: nothing changes, the text shows again.
        if let edited = stamp("Erika Musterfrau") {
            let point = CGPoint(x: edited.rect.midX, y: edited.rect.midY)
            click(page: page, at: point, in: pdfView)
            click(page: page, at: point, in: pdfView, clickCount: 2)
            key("\u{1b}", code: 53)
            let shown = page.annotations.compactMap { $0 as? ImageStampAnnotation }.filter(\.shouldDisplay).count
            check(!doc.isEditingText && stamp("Erika Musterfrau") != nil && shown == 2,
                  "6 · Doppelklick + Esc bricht ab, der Text ist unverändert wieder da")
        }

        // 7. Esc twice ends everything; export burns both texts in.
        key("\u{1b}", code: 53)
        key("\u{1b}", code: 53)
        check(!doc.textToolActive && doc.selectedStamp == nil, "7 · Esc beendet Auswahl und Werkzeug")
        let onPage = page.annotations.filter { $0 is ImageStampAnnotation }.count
        check(onPage == doc.stamps.count, "7 · auf der Seite hängen genau \(doc.stamps.count) Elemente (gefunden: \(onPage))")
        let out = outDir.appendingPathComponent("uitest-ergebnis.pdf")
        do {
            try doc.exportCurrentState(to: out)
            check(PDFDocument(url: out)?.pageCount == doc.pageCount, "7 · PDF mit eingebrannten Texten geschrieben")
            if let flat = PDFDocument(url: out)?.page(at: 0) {
                let image = flat.thumbnail(of: CGSize(width: 1190, height: 1684), for: .mediaBox)
                if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: outDir.appendingPathComponent("uitest-ergebnis-seite1.png"))
                }
            }
        } catch {
            check(false, "7 · Export: \(error)")
        }
        shot("7-ende")
    }

    // MARK: - Signing

    /// Pick a signature, move the mouse over the page (preview follows),
    /// click to place, then delete it with the × and undo.
    private static func signatureScenario(_ doc: DocumentModel, store: ProfileStore) {
        guard let page = doc.document?.page(at: 0), let pdfView = doc.pdfView else { return }
        doc.endTools()
        store.update(Snapshot.samplePerson())
        guard let image = store.persons.first?.signatureImage else { return }
        let before = doc.stamps.count

        // The real path: "Sign" button → popover → signature tile.
        press("tool.sign")
        Snapshot.settle(0.6)
        let popover = NSApp.windows.first { $0 !== window && $0.isVisible && String(describing: Swift.type(of: $0)).contains("Popover") }
        check(doc.showSignaturePicker && popover != nil, "U · „Unterschreiben“ öffnet die Auswahl")
        if let popover, let id = store.persons.first?.id,
           let frame = UITestTargets.frames["tile.signature.\(id)"],
           let host = findView(typeContaining: "HostingView", in: popover.contentView?.superview) {
            Snapshot.capture(window: popover, to: outDir.appendingPathComponent("uitest-popover.png"))
            let point = host.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            mouse(.leftMouseDown, at: point, in: popover)
            mouse(.leftMouseUp, at: point, in: popover)
            Snapshot.settle(0.6)
        } else {
            print("   (Popover oder Kachel nicht gefunden: popover \(popover != nil))")
        }
        check(doc.pendingStamp != nil && !doc.showSignaturePicker,
              "U · Klick auf die Kachel schließt die Auswahl und startet das Platzieren")
        if doc.pendingStamp == nil {
            doc.startPlacing(image: image, defaultWidth: 170, label: loc("signature.placeLabel", "Finn Stolle"))
        }
        for x in stride(from: 300, through: 175, by: -25) {
            move(page: page, to: CGPoint(x: CGFloat(x), y: 140), in: pdfView)
        }
        let preview = page.annotations.compactMap { $0 as? ImageStampAnnotation }.filter { $0.opacity < 1 }
        check(preview.count == 1, "U · halbtransparente Vorschau folgt der Maus")
        shot("U1-vorschau")

        click(page: page, at: CGPoint(x: 175, y: 140), in: pdfView)
        let placed = doc.stamps.count == before + 1 && doc.stamps.last?.text == nil
        check(placed && doc.pendingStamp == nil, "U · Klick setzt die Unterschrift")
        check(page.annotations.compactMap { $0 as? ImageStampAnnotation }.allSatisfy { $0.opacity == 1 },
              "U · Vorschau ist danach weg")
        shot("U2-gesetzt")

        // Delete with the red × above the selection, then undo.
        if let stamp = doc.selectedStamp {
            let deleteButton = ImageStampAnnotation.deleteButtonCenter(for: stamp.rect, rotation: stamp.rotation)
            click(page: page, at: deleteButton, in: pdfView)
            check(doc.stamps.count == before, "U · rotes × löscht die Unterschrift")
            shot("U3-geloescht")
            // ⌘Z arrives as a key event; AppKit redraws after handling it.
            undoViaKeyEvent(doc)
            check(doc.stamps.count == before + 1, "U · ⌘Z holt sie zurück")
            shot("U4-zurueck")
        }
    }

    /// Runs undo the way ⌘Z does: after handling a key event AppKit gives
    /// the window a display pass (the offscreen test window gets none on its own).
    private static func undoViaKeyEvent(_ doc: DocumentModel) {
        doc.undo()
        window.displayIfNeeded()
        Snapshot.settle(0.3)
    }

    /// Places a solid red block by clicking and checks, on the captured
    /// window pixels, that it shows up exactly where the click was.
    private static func accuracyScenario(_ doc: DocumentModel) {
        guard let page = doc.document?.page(at: 0), let pdfView = doc.pdfView else { return }
        let crop = page.bounds(for: .cropBox)
        pdfView.go(to: CGRect(x: crop.minX, y: crop.minY + 150, width: crop.width, height: 300), on: page)
        Snapshot.settle(0.5)
        let red = NSImage(size: NSSize(width: 240, height: 90), flipped: false) { rect in
            NSColor.systemRed.setFill()
            rect.fill()
            return true
        }
        // Middle of the page, and right at the bottom of the visible area —
        // where signature lines end up after scrolling down.
        let bottomInView = NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.minY + 24)
        let bottom = pdfView.convert(bottomInView, to: page)
        for (name, target) in [("Mitte", CGPoint(x: crop.minX + 200, y: crop.minY + 300)),
                               ("unterer Rand", CGPoint(x: crop.minX + 200, y: bottom.y))] {
            doc.startPlacing(image: red, defaultWidth: 80, label: "Test")
            Snapshot.settle(0.2)
            move(page: page, to: target, in: pdfView)
            click(page: page, at: target, in: pdfView)
            doc.select(nil)
            window.displayIfNeeded()
            Snapshot.settle(0.5)
            shot("A-genauigkeit-\(name == "Mitte" ? "mitte" : "unten")")
            guard let image = Snapshot.image(of: window) else { return }
            let scale = CGFloat(image.width) / window.frame.width
            func isRed(at pagePoint: CGPoint) -> Bool {
                let p = windowPoint(page: page, at: pagePoint, in: pdfView)
                let x = Int(p.x * scale), y = Int((window.frame.height - p.y) * scale)
                guard let color = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))
                    .flatMap({ NSBitmapImageRep(cgImage: $0).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) }) else { return false }
                return color.redComponent > 0.75 && color.greenComponent < 0.45 && color.blueComponent < 0.45
            }
            check(doc.pendingStamp == nil && isRed(at: target),
                  "A · Klick (\(name)) setzt den Block genau an der Klickstelle")
            check(!isRed(at: CGPoint(x: target.x + 60, y: target.y)),
                  "A · und nicht daneben (\(name))")
        }
        print("   crop box origin \(crop.origin)")
    }

    private static func move(page: PDFPage, to pagePoint: CGPoint, in view: PDFView) {
        let point = windowPoint(page: page, at: pagePoint, in: view)
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 0, pressure: 0) else { return }
        view.mouseMoved(with: event)
        Snapshot.settle(0.05)
    }

    // MARK: - Event helpers

    private static func windowPoint(page: PDFPage, at pagePoint: CGPoint, in view: PDFView) -> NSPoint {
        view.convert(view.convert(pagePoint, from: page), to: nil)
    }

    /// View that received the last mouse down; drags and the mouse up go
    /// there, as NSWindow does it.
    private static var mouseTarget: NSView?

    /// Delivers a mouse event to the view under the point. The test app is
    /// never activated (that would take focus away from the user), and
    /// NSWindow.sendEvent swallows clicks into inactive apps as "activate
    /// window" clicks — so dispatch the way an active window would.
    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1,
                              in target: NSWindow? = nil) {
        let window: NSWindow = target ?? Self.window
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: clickCount, pressure: 1) else { return }
        switch type {
        case .leftMouseDown:
            mouseTarget = window.contentView?.superview?.hitTest(point)
            if let target = mouseTarget, target.acceptsFirstResponder {
                window.makeFirstResponder(target)
            }
            if mouseTarget is NSControl {
                // AppKit controls track the click in their own loop and wait
                // for the mouse-up in the event queue: queue it first.
                if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               eventNumber: 0, clickCount: clickCount, pressure: 0) {
                    NSApp.postEvent(up, atStart: false)
                }
                mouseTarget?.mouseDown(with: event)
                mouseTarget = nil
            } else {
                mouseTarget?.mouseDown(with: event)
            }
        case .leftMouseDragged:
            mouseTarget?.mouseDragged(with: event)
        case .leftMouseUp:
            mouseTarget?.mouseUp(with: event)
            mouseTarget = nil
        default:
            window.sendEvent(event)
        }
    }

    private static func click(page: PDFPage, at pagePoint: CGPoint, in view: PDFView, clickCount: Int = 1) {
        let point = windowPoint(page: page, at: pagePoint, in: view)
        mouse(.leftMouseDown, at: point, clickCount: clickCount)
        mouse(.leftMouseUp, at: point, clickCount: clickCount)
        Snapshot.settle(0.15)
    }

    private static func drag(page: PDFPage, from: CGPoint, to: CGPoint, in view: PDFView) {
        let a = windowPoint(page: page, at: from, in: view)
        let b = windowPoint(page: page, at: to, in: view)
        mouse(.leftMouseDown, at: a)
        for step in 1...8 {
            let t = CGFloat(step) / 8
            mouse(.leftMouseDragged, at: NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        mouse(.leftMouseUp, at: b)
        Snapshot.settle(0.15)
    }

    private static func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: code) else { return }
        (window.firstResponder ?? window).keyDown(with: event)
        Snapshot.settle(0.05)
    }

    private static func type(_ text: String) {
        for character in text {
            key(String(character), code: 0)
        }
        Snapshot.settle(0.15)
    }

    /// Clicks a control tagged with `.uiTestTarget(id)` at its live position.
    private static func press(_ id: String) {
        let point: NSPoint
        if let frame = UITestTargets.frames[id], let hosting = window.contentView {
            // SwiftUI's global space is the hosting view's (flipped) space.
            point = hosting.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        } else {
            check(false, "Knopf „\(id)“ ist sichtbar")
            return
        }
        mouse(.leftMouseDown, at: point)
        mouse(.leftMouseUp, at: point)
        Snapshot.settle(0.3)
    }

    private static func appKitButtons(in view: NSView) -> [NSView] {
        view.subviews.flatMap { sub -> [NSView] in
            (sub is NSButton && !sub.isHidden ? [sub] : []) + appKitButtons(in: sub)
        }
    }

    private static func findView(typeContaining name: String, in view: NSView?) -> NSView? {
        guard let view, !view.isHidden else { return nil }
        if String(describing: Swift.type(of: view)).contains(name) { return view }
        for subview in view.subviews {
            if let found = findView(typeContaining: name, in: subview) { return found }
        }
        return nil
    }

    // MARK: - Reporting

    private static func check(_ condition: Bool, _ what: String) {
        print("\(condition ? "✓" : "✗") \(what)")
        fflush(stdout)
        if !condition { failures += 1 }
    }

    private static func shot(_ name: String) {
        window.displayIfNeeded()
        Snapshot.settle(0.1)
        stepNumber += 1
        Snapshot.capture(window: window, to: outDir.appendingPathComponent(String(format: "uitest-%02d-%@.png", stepNumber, name)))
    }
}
#endif
