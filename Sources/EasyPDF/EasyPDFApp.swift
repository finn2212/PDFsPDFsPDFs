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
            DocumentModel.shared.confirmDiscardIfNeeded() ? .terminateNow : .terminateCancel
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
                .frame(minWidth: 1080, minHeight: 640)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button(loc("menu.checkUpdates")) {
                    updaterController.checkForUpdates(nil)
                }
            }

            CommandGroup(replacing: .newItem) {
                Button(loc("menu.open")) {
                    DocumentModel.shared.requestOpenPanel()
                }
                .keyboardShortcut("o")

                Menu(loc("menu.recents")) {
                    ForEach(RecentsStore.urls, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            DocumentModel.shared.open(url: url)
                        }
                    }
                }

                Divider()

                Button(loc("menu.save")) {
                    DocumentModel.shared.saveInPlace()
                }
                .keyboardShortcut("s")

                Button(loc("menu.saveAs")) {
                    DocumentModel.shared.requestSaveAsPanel()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button(loc("menu.print")) {
                    DocumentModel.shared.printDocument()
                }
                .keyboardShortcut("p")
            }

            CommandGroup(after: .sidebar) {
                Button(loc("menu.zoomIn")) {
                    DocumentModel.shared.pdfView?.zoomIn(nil)
                }
                .keyboardShortcut("+")

                Button(loc("menu.zoomOut")) {
                    DocumentModel.shared.pdfView?.zoomOut(nil)
                }
                .keyboardShortcut("-")

                Button(loc("menu.zoomFit")) {
                    DocumentModel.shared.pdfView?.autoScales = true
                }
                .keyboardShortcut("0")
            }

            CommandGroup(replacing: .help) {}
        }
    }
}
