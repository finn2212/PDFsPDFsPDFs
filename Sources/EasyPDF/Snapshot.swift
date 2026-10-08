#if DEBUG
import AppKit
import PDFKit
import SwiftUI

/// Debug-only: renders the main window in a series of UI states to PNG files,
/// so layout changes can be reviewed without driving the real app.
/// Usage: `.build/debug/EasyPDF --snapshot <out-dir> <sample.pdf> [second.pdf]`
///
/// Windows are placed far off-screen and captured from the window server, so
/// toolbar and title bar are included and nothing appears on the user's screen.
@MainActor
enum Snapshot {
    static var sample: URL?
    static var secondSample: URL?

    static func run(arguments: [String]) -> Never {
        guard let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 1 else {
            print("usage: --snapshot <out-dir> <sample.pdf> [second.pdf]")
            exit(2)
        }
        let outDir = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let rest = arguments.dropFirst(flag + 2).filter { !$0.hasPrefix("-") && !$0.hasPrefix("(") }
        sample = rest.first.map { URL(fileURLWithPath: $0) }
        secondSample = rest.dropFirst().first.map { URL(fileURLWithPath: $0) }
        let only = ProcessInfo.processInfo.environment["SNAPSHOT_ONLY"]

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("easypdf-snapshot-store-\(UUID().uuidString)", isDirectory: true)
        let store = ProfileStore(directory: storeDir)
        store.update(samplePerson())
        if let sample { RecentsStore.add(sample) }

        let doc = DocumentModel.shared
        for scenario in SnapshotScenario.all where only == nil || scenario.name.contains(only!) {
            doc.hasChanges = false
            scenario.prepare(doc, store)
            let url = outDir.appendingPathComponent("\(scenario.name).png")
            if let standalone = scenario.standalone {
                write(view: standalone(doc, store), to: url)
                continue
            }
            let window = makeWindow(store: store, doc: doc, size: scenario.size)
            settle(0.7)
            scenario.afterShow(doc, store)
            settle(0.9)
            // A visible window gets a display pass after every event; this
            // offscreen one only when asked.
            window.displayIfNeeded()
            settle(0.3)
            capture(window: window, to: url)
            window.orderOut(nil)
            window.close()
        }
        doc.hasChanges = false
        print("SNAPSHOT DONE → \(outDir.path)")
        exit(0)
    }

    static func makeWindow(store: ProfileStore, doc: DocumentModel, size: CGSize) -> NSWindow {
        let root = ContentView()
            .environmentObject(store)
            .environmentObject(doc)
            .environment(\.controlActiveState, .key)
        let window = OffscreenWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                     styleMask: [.titled, .closable, .resizable, .miniaturizable,
                                                 .fullSizeContentView],
                                     backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        let hosting = NSHostingView(rootView: root)
        if #available(macOS 14.0, *) {
            hosting.sceneBridgingOptions = [.toolbars, .title]
        }
        window.contentView = hosting
        window.setFrame(NSRect(x: -20000, y: -20000, width: size.width, height: size.height), display: true)
        window.orderFrontRegardless()
        return window
    }

    static func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Captures one of our own windows (no screen-recording permission needed).
    /// The API is unavailable in the current SDK, hence the dynamic lookup.
    static func capture(window: NSWindow, to url: URL) {
        guard let image = image(of: window) else {
            print("capture failed for \(url.lastPathComponent)")
            return
        }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.lastPathComponent)")
    }

    static func image(of window: NSWindow) -> CGImage? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // optionIncludingWindow = 1 << 3; boundsIgnoreFraming = 1, bestResolution = 1 << 3
        return create(.null, 1 << 3, UInt32(window.windowNumber), 1 | 1 << 3)?.takeRetainedValue()
    }

    /// Popovers and sheets are separate windows; render their SwiftUI content alone.
    private static func write(view: AnyView, to url: URL) {
        let hosting = NSHostingView(rootView: view
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = OffscreenWindow(contentRect: NSRect(x: -20000, y: -20000,
                                                         width: hosting.fittingSize.width,
                                                         height: hosting.fittingSize.height),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        settle(0.5)
        capture(window: window, to: url)
        window.orderOut(nil)
    }

    static func samplePerson() -> Person {
        var person = Person(name: "Finn Stolle")
        person.signaturePNG = ImageUtils.renderSignature("Finn Stolle",
                                                         fontName: ImageUtils.signatureFonts.first ?? "SnellRoundhand")
        person.initialsPNG = ImageUtils.renderSignature("FS",
                                                        fontName: ImageUtils.signatureFonts.first ?? "SnellRoundhand")
        return person
    }
}

/// Stays wherever it is put, also far outside every screen, and always draws
/// its controls in the active (key window) style.
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// One UI state to capture. `prepare` runs before the window exists,
/// `afterShow` once the view hierarchy (incl. the PDF view) is live.
/// `standalone` renders a view on its own instead of the main window.
struct SnapshotScenario {
    let name: String
    var size = CGSize(width: 1240, height: 800)
    var prepare: @MainActor (DocumentModel, ProfileStore) -> Void = { _, _ in }
    var afterShow: @MainActor (DocumentModel, ProfileStore) -> Void = { _, _ in }
    var standalone: (@MainActor (DocumentModel, ProfileStore) -> AnyView)?
}
#endif
