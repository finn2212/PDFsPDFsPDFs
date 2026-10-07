import SwiftUI
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Finder double-click, "Open with", drop on Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            Task { @MainActor in
                DocumentModel.shared.open(url: url)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            // Text still open in the inline editor counts as a change.
            DocumentModel.shared.finishInlineEditing?(true)
            return DocumentModel.shared.confirmDiscardIfNeeded() ? .terminateNow : .terminateCancel
        }
    }
}

struct EasyPDFApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = ProfileStore()
    @StateObject private var doc = DocumentModel.shared

    // Sparkle auto-updater (feed + public key are configured in Info.plist).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(doc)
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(loc("menu.checkUpdates")) {
                    updaterController.checkForUpdates(nil)
                }
            }

            CommandGroup(replacing: .newItem) {
                Button(loc("menu.open")) { doc.requestOpenPanel() }
                    .keyboardShortcut("o")

                Menu(loc("menu.recents")) {
                    ForEach(RecentsStore.urls, id: \.self) { url in
                        Button(url.lastPathComponent) { doc.open(url: url) }
                    }
                }

                Divider()

                Button(loc("start.merge.title") + "…") { doc.requestMergePanel() }
                Button(loc("start.images.title") + "…") { doc.requestImagesPanel() }

            }

            CommandGroup(replacing: .saveItem) {
                // Replacing the group drops the system Close item: ⌘W closes
                // the document (back to the start screen), else the window.
                Button(loc("menu.close")) {
                    if doc.document != nil, NSApp.keyWindow === NSApp.mainWindow {
                        doc.close()
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w")

                Divider()

                Button(loc("menu.save")) { doc.saveInPlace() }
                    .keyboardShortcut("s")
                    .disabled(doc.document == nil)

                Button(loc("menu.saveAs")) { doc.requestSaveAsPanel() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(doc.document == nil)

                Button(loc("menu.saveCopy")) { doc.saveCopy() }
                    .disabled(doc.document == nil)

                Button(loc("menu.exportImages")) { doc.exportImagesRequested = true }
                    .disabled(doc.document == nil)
            }

            CommandGroup(replacing: .printItem) {
                Button(loc("menu.print")) {
                    doc.mode = .document
                    DispatchQueue.main.async { doc.printDocument() }
                }
                .keyboardShortcut("p")
                .disabled(doc.document == nil)
            }

            CommandGroup(replacing: .undoRedo) {
                Button(loc("toolbar.undo")) { Self.undo(redo: false) }
                    .keyboardShortcut("z")
                Button(loc("toolbar.redo")) { Self.undo(redo: true) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            CommandGroup(before: .sidebar) {
                ForEach(Array(WorkspaceMode.allCases.enumerated()), id: \.element) { index, mode in
                    Button(mode.title) { doc.mode = mode }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                        .disabled(doc.document == nil)
                }
                Divider()
            }

            CommandGroup(after: .sidebar) {
                Button(loc("menu.zoomIn")) { doc.pdfView?.zoomIn(nil) }
                    .keyboardShortcut("+")
                Button(loc("menu.zoomOut")) { doc.pdfView?.zoomOut(nil) }
                    .keyboardShortcut("-")
                Button(loc("menu.zoomFit")) { doc.pdfView?.autoScales = true }
                    .keyboardShortcut("0")
            }

            CommandMenu(loc("menu.tools")) {
                Button(loc("tool.sign")) {
                    SignatureActions.sign(doc: doc, store: store)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(doc.document == nil)
                Button(loc("tool.text")) {
                    doc.mode = .document
                    doc.textToolActive.toggle()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(doc.document == nil)
                Button(loc("tool.date")) {
                    doc.mode = .document
                    doc.startPlacingToday(fontSize: doc.textToolFontSize)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(doc.document == nil)
                Button(loc("tool.check.tick")) {
                    doc.mode = .document
                    doc.startPlacingMark("✓")
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(doc.document == nil)
                Divider()
                Button(loc("signature.manage")) {
                    doc.signatureEditor = SignatureEditorRequest(
                        person: store.persons.first ?? Person(), kind: .signature, placeAfterSave: false)
                }
            }

            CommandGroup(replacing: .help) {}
        }
    }

    /// Text fields, sheets and popovers keep their own undo; the document's
    /// undo only applies while the document window itself is key.
    @MainActor
    private static func undo(redo: Bool) {
        if NSApp.keyWindow?.firstResponder is NSText || NSApp.keyWindow !== NSApp.mainWindow {
            NSApp.sendAction(Selector(redo ? "redo:" : "undo:"), to: nil, from: nil)
        } else if redo {
            DocumentModel.shared.redo()
        } else {
            DocumentModel.shared.undo()
        }
    }
}
