import PDFKit
import SwiftUI

/// The "Document" view: sign and fill in. Tool strip on top, optional page
/// strip for navigation on the left, the page canvas, and a context bar.
struct DocumentWorkspace: View {
    @EnvironmentObject var doc: DocumentModel
    @AppStorage("showsPageStrip") private var showsPageStrip = true
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            DocumentToolStrip(showsPageStrip: $showsPageStrip)
            HStack(spacing: 0) {
                if showsPageStrip && doc.pageCount > 1 {
                    PageStrip()
                    Divider()
                }
                PDFKitView(model: doc)
                .overlay {
                    if isTargeted { DropHighlight(cornerRadius: 12).padding(10) }
                }
                .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                    DropLoader.load(providers) { doc.handleDrop($0) }
                    return true
                }
            }
        }
    }
}

// MARK: - Tool strip

private struct DocumentToolStrip: View {
    @EnvironmentObject var doc: DocumentModel
    @EnvironmentObject var store: ProfileStore
    @Binding var showsPageStrip: Bool

    var body: some View {
        ToolStrip { _ in
            Button {
                showsPageStrip.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(ToolButtonStyle(isOn: false))
            .help(loc("view.togglePageStrip"))
            .accessibilityLabel(loc("view.togglePageStrip"))
            .disabled(doc.pageCount < 2)

            StripDivider()

            Button {
                if store.persons.contains(where: { $0.signatureImage != nil }) {
                    doc.showSignaturePicker.toggle()
                } else {
                    // Nothing to choose from yet: go straight to creating one.
                    doc.signatureEditor = SignatureEditorRequest(person: Person(), kind: .signature)
                }
            } label: {
                Label(loc("tool.sign"), systemImage: "signature")
            }
            .buttonStyle(ToolButtonStyle(isOn: doc.pendingStamp != nil && doc.pendingStamp?.text == nil))
            .popover(isPresented: $doc.showSignaturePicker, arrowEdge: .bottom) {
                SignaturePicker()
                    .environmentObject(doc)
                    .environmentObject(store)
            }
            .help(loc("tool.sign.help"))

            Button {
                doc.textToolActive.toggle()
            } label: {
                Label(loc("tool.text"), systemImage: "character.cursor.ibeam")
            }
            .buttonStyle(ToolButtonStyle(isOn: doc.textToolActive))
            .help(loc("tool.text.help"))
            .uiTestTarget("tool.text")

            Button {
                doc.startPlacingToday(fontSize: doc.textToolFontSize)
            } label: {
                Label(loc("tool.date"), systemImage: "calendar")
            }
            .buttonStyle(ToolButtonStyle(isOn: doc.pendingStamp?.text == doc.todayString))
            .help(loc("tool.date.help", doc.todayString))

            HStack(spacing: 0) {
                Button {
                    doc.startPlacingMark("✓")
                } label: {
                    Label(loc("tool.check"), systemImage: "checkmark")
                }
                .buttonStyle(ToolButtonStyle(isOn: doc.pendingStamp?.text == "✓"))
                .help(loc("tool.check.help"))

                Menu {
                    Button(loc("tool.check.tick")) { doc.startPlacingMark("✓") }
                    Button(loc("tool.check.cross")) { doc.startPlacingMark("✗") }
                    Button(loc("tool.check.dot")) { doc.startPlacingMark("●") }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 4)
                .help(loc("tool.check.more"))
            }
        } trailing: { _ in
            BarIconButton(systemImage: "minus.magnifyingglass", help: loc("menu.zoomOut")) {
                doc.pdfView?.zoomOut(nil)
            }
            BarIconButton(systemImage: "plus.magnifyingglass", help: loc("menu.zoomIn")) {
                doc.pdfView?.zoomIn(nil)
            }
            Button {
                doc.pdfView?.autoScales = true
            } label: {
                Label(loc("menu.zoomFit"), systemImage: "arrow.up.left.and.down.right.magnifyingglass")
            }
            .buttonStyle(ToolButtonStyle())
            .help(loc("menu.zoomFit"))
        }
    }
}

// MARK: - Context bar

/// Hosted on top of the PDF view by `PDFCanvasView`, not as a SwiftUI overlay.
struct DocumentContextBar: View {
    @EnvironmentObject var doc: DocumentModel

    var body: some View {
        Group {
            if doc.isEditingText {
                ContextBar(floating: false) {
                    Image(systemName: "keyboard").foregroundStyle(.secondary)
                    Text(loc("hint.typing"))
                    Divider().frame(height: 18)
                    textSize
                }
            } else if let pending = doc.pendingStamp {
                ContextBar(floating: false) {
                    Image(systemName: "hand.point.up.left").foregroundStyle(Color.accentColor)
                    Text(loc("hint.placement", pending.label))
                    Button(loc("action.cancel")) { doc.cancelPending() }
                        .keyboardShortcut(.cancelAction)
                }
            } else if let stamp = doc.selectedStamp {
                ContextBar(floating: false) {
                    if stamp.text != nil {
                        let size = stamp.effectiveFontSize.rounded()
                        SizeStepper(label: loc("text.size"),
                                    value: "\(Int(size)) pt",
                                    decrease: { doc.setSelectedTextSize(size - 2) },
                                    increase: { doc.setSelectedTextSize(size + 2) })
                    } else {
                        SizeStepper(label: loc("toolbar.size"),
                                    value: "\(Int(stamp.rect.width.rounded())) pt",
                                    decrease: { doc.scaleSelected(by: 1 / 1.12) },
                                    increase: { doc.scaleSelected(by: 1.12) })
                    }
                    Divider().frame(height: 18)
                    BarIconButton(systemImage: "rotate.left", help: loc("toolbar.rotateStampLeft")) {
                        doc.rotateSelected(by: 15)
                    }
                    BarIconButton(systemImage: "rotate.right", help: loc("toolbar.rotateStampRight")) {
                        doc.rotateSelected(by: -15)
                    }
                    Divider().frame(height: 18)
                    BarIconButton(systemImage: "trash", help: loc("toolbar.deleteStamp"), role: .destructive) {
                        doc.removeSelected()
                    }
                    if stamp.text != nil {
                        Text(loc("hint.editText"))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if doc.textToolActive {
                ContextBar(floating: false) {
                    Image(systemName: "character.cursor.ibeam").foregroundStyle(Color.accentColor)
                    Text(loc("hint.textTool"))
                    Divider().frame(height: 18)
                    textSize
                    Button(loc("action.done")) { doc.textToolActive = false }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            } else if let status = doc.statusMessage {
                ContextBar(floating: false) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(status)
                }
                .task(id: status) {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    if doc.statusMessage == status { doc.statusMessage = nil }
                }
            } else if doc.formFieldCount > 0 && !doc.formHintDismissed {
                ContextBar(floating: false) {
                    Image(systemName: "rectangle.and.pencil.and.ellipsis").foregroundStyle(Color.accentColor)
                    Text(locCount("hint.form", doc.formFieldCount))
                    BarIconButton(systemImage: "xmark", help: loc("action.dismiss")) {
                        doc.formHintDismissed = true
                    }
                }
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeOut(duration: 0.18), value: doc.isEditingText)
        .animation(.easeOut(duration: 0.18), value: doc.selectedStampID)
    }

    private var textSize: some View {
        SizeStepper(label: loc("text.size"),
                    value: "\(Int(doc.textToolFontSize)) pt",
                    decrease: { doc.textToolFontSize = max(8, doc.textToolFontSize - 2) },
                    increase: { doc.textToolFontSize = min(72, doc.textToolFontSize + 2) })
    }
}

// MARK: - Page strip (navigation only)

private struct PageStrip: View {
    @EnvironmentObject var doc: DocumentModel
    @State private var currentPage = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(Array(doc.pages.enumerated()), id: \.offset) { index, page in
                        Button {
                            doc.pdfView?.go(to: page)
                            currentPage = index
                        } label: {
                            VStack(spacing: 5) {
                                PageThumbnail(page: page, revision: doc.docRevision, maxSize: CGSize(width: 96, height: 124))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3)
                                            .strokeBorder(index == currentPage ? Color.accentColor : .clear, lineWidth: 2.5)
                                            .padding(-4)
                                    )
                                Text("\(index + 1)")
                                    .font(.caption)
                                    .foregroundStyle(index == currentPage ? Color.accentColor : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: currentPage) { page in
                withAnimation { proxy.scrollTo(page, anchor: .center) }
            }
        }
        .frame(width: 132)
        .background(Color(nsColor: .controlBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .PDFViewPageChanged)) { _ in
            if let page = doc.pdfView?.currentPage, let d = doc.document {
                let index = d.index(for: page)
                if (0..<d.pageCount).contains(index) { currentPage = index }
            }
        }
    }
}

/// Renders a page thumbnail (with its annotations) and re-renders when the
/// document revision changes.
struct PageThumbnail: View {
    let page: PDFPage
    let revision: Int
    let maxSize: CGSize
    @State private var image: NSImage?

    var body: some View {
        let size = fittedSize
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                Color.white
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .shadow(color: .black.opacity(0.18), radius: 2.5, y: 1)
        .task(id: Thumb(id: ObjectIdentifier(page), revision: revision)) {
            image = page.thumbnail(of: CGSize(width: maxSize.width * 2, height: maxSize.height * 2),
                                   for: .cropBox)
        }
    }

    private struct Thumb: Hashable {
        let id: ObjectIdentifier
        let revision: Int
    }

    /// Page aspect (respecting rotation) fitted into `maxSize`.
    private var fittedSize: CGSize {
        let box = page.bounds(for: .cropBox).size
        let rotated = page.rotation % 180 != 0
        let w = rotated ? box.height : box.width
        let h = rotated ? box.width : box.height
        guard w > 0, h > 0 else { return maxSize }
        let scale = min(maxSize.width / w, maxSize.height / h)
        return CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    }
}
