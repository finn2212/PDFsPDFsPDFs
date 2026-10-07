import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The "Pages" view: one place for every page operation — select, reorder by
/// drag, rotate, delete, save a selection, split at cut marks, insert files.
@MainActor
struct PagesView: View {
    @EnvironmentObject var doc: DocumentModel

    var body: some View {
        VStack(spacing: 0) {
            PagesToolStrip()
            PagesContextRow()
            PageGrid()
        }
    }
}

// MARK: - Tool strip

@MainActor
private struct PagesToolStrip: View {
    @EnvironmentObject var doc: DocumentModel

    var body: some View {
        let selection = doc.selectedIndices
        let hasSelection = !selection.isEmpty
        ToolStrip { _ in
            Button {
                doc.rotatePages(selection, clockwise: false)
            } label: {
                Label(loc("pages.rotateLeft"), systemImage: "rotate.left")
            }
            .buttonStyle(ToolButtonStyle())
            .disabled(!hasSelection)
            .help(loc("pages.rotateLeft.help"))

            Button {
                doc.rotatePages(selection, clockwise: true)
            } label: {
                Label(loc("pages.rotateRight"), systemImage: "rotate.right")
            }
            .buttonStyle(ToolButtonStyle())
            .disabled(!hasSelection)
            .help(loc("pages.rotateRight.help"))

            Button {
                doc.deletePages(selection)
            } label: {
                Label(loc("pages.delete"), systemImage: "trash")
            }
            .buttonStyle(ToolButtonStyle())
            .disabled(!hasSelection || selection.count >= doc.pageCount)
            .help(loc("pages.delete.help"))

            StripDivider()

            Button {
                doc.saveSelectionAsPDF()
            } label: {
                Label(loc("pages.extract"), systemImage: "doc.badge.arrow.up")
            }
            .buttonStyle(ToolButtonStyle())
            .disabled(!hasSelection)
            .help(loc("pages.extract.help"))

            Menu {
                Button(doc.parts.count > 1
                       ? loc("pages.split.atCuts", doc.parts.count)
                       : loc("pages.split.atCutsNone")) {
                    doc.splitAtCutMarksWithPanel()
                }
                .disabled(doc.parts.count < 2)
                Button(loc("pages.split.singles")) { doc.splitIntoSinglesWithPanel() }
                if !doc.cutMarks.isEmpty {
                    Divider()
                    Button(loc("pages.split.clearCuts")) { doc.cutMarks = [] }
                }
            } label: {
                Label(loc("pages.split"), systemImage: "scissors")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 8)
            .help(loc("pages.split.help"))

            StripDivider()

            Button {
                doc.insertPDFWithPanel()
            } label: {
                Label(loc("pages.insert"), systemImage: "plus.rectangle.on.rectangle")
            }
            .buttonStyle(ToolButtonStyle())
            .help(loc("pages.insert.help"))
        } trailing: { compact in
            if !compact {
                Text(hasSelection
                 ? loc("pages.selectedCount", selection.count, doc.pageCount)
                     : locCount("pages.count", doc.pageCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button(hasSelection ? loc("pages.selectNone") : loc("pages.selectAll")) {
                if hasSelection { doc.clearPageSelection() } else { doc.selectAllPages() }
            }
            .buttonStyle(ToolButtonStyle())
        }
    }
}

// MARK: - Grid

@MainActor
private struct PageGrid: View {
    @EnvironmentObject var doc: DocumentModel
    /// Insertion index shown while something is dragged over the grid.
    @State private var dropIndex: Int?
    @State private var isTargeted = false
    @FocusState private var focused: Bool

    /// No column spacing: each cell spans its whole column, so a drop
    /// anywhere between two pages hits one of them.
    private let columns = [GridItem(.adaptive(minimum: 206, maximum: 264), spacing: 0, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .center, spacing: 30) {
                ForEach(Array(doc.pages.enumerated()), id: \.element) { index, page in
                    PageCell(page: page, index: index, dropIndex: $dropIndex)
                        // Earlier cells on top: their scissors reach into the next cell.
                        .zIndex(Double(doc.pageCount - index))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
            // Clicks between the pages clear the selection; clicks on a page
            // never reach this layer.
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        doc.clearPageSelection()
                        focused = true
                    }
            )
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .modifier(NoFocusRing())
        .focused($focused)
        .onDeleteCommand { doc.deletePages(doc.selectedIndices) }
        .onExitCommand { doc.clearPageSelection() }
        .onCommand(#selector(NSResponder.selectAll(_:))) { doc.selectAllPages() }
        // Drops on empty space append at the end.
        .onDrop(of: [.fileURL, .plainText], delegate: PageDropDelegate(
            targetIndex: { _ in doc.pageCount }, doc: doc, dropIndex: $dropIndex))
        .onAppear { focused = true }
    }
}

@MainActor
private struct PageCell: View {
    @EnvironmentObject var doc: DocumentModel
    let page: PDFPage
    let index: Int
    @Binding var dropIndex: Int?
    @State private var cellWidth: CGFloat = 206

    private let thumbSize = CGSize(width: 160, height: 206)

    var body: some View {
        let selected = doc.selectedPages.contains(doc.id(of: page))
        VStack(spacing: 8) {
            PageThumbnail(page: page, revision: doc.docRevision, maxSize: thumbSize)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.16) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5)
                )
                .frame(width: thumbSize.width + 12, height: thumbSize.height + 12)
            Text("\(index + 1)")
                .font(.callout.weight(selected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .background(Capsule().fill(selected ? Color.accentColor : .clear))
        }
        .frame(maxWidth: .infinity)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { cellWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { cellWidth = $0 }
        })
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc("pages.a11y.page", index + 1))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { doc.selectPage(at: index, extend: true, range: false) }
        .overlay(alignment: .leading) {
            if dropIndex == index { insertionBar.offset(x: -2) }
        }
        .overlay(alignment: .trailing) {
            if dropIndex == index + 1, index == doc.pageCount - 1 { insertionBar.offset(x: 2) }
        }
        .overlay(alignment: .trailing) {
            if index < doc.pageCount - 1 {
                CutMark(isCut: doc.cutMarks.contains(doc.id(of: page))) {
                    doc.toggleCut(after: page)
                }
                .offset(x: 12)
                .padding(.bottom, 26)
            }
        }
        .gesture(TapGesture(count: 2).onEnded { openInDocument() })
        .simultaneousGesture(TapGesture().onEnded {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            doc.selectPage(at: index, extend: flags.contains(.command), range: flags.contains(.shift))
        })
        .onDrag {
            if !doc.selectedPages.contains(doc.id(of: page)) {
                doc.selectPage(at: index, extend: false, range: false)
            }
            let provider = NSItemProvider()
            let token = UUID().uuidString
            doc.pageDragToken = token
            // The payload is only a token; drops elsewhere get a harmless string.
            provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier,
                                                visibility: .all) { completion in
                completion(Data(token.utf8), nil)
                return nil
            }
            return provider
        }
        .onDrop(of: [.fileURL, .plainText], delegate: PageDropDelegate(
            targetIndex: { location in location.x < cellWidth / 2 ? index : index + 1 },
            doc: doc, dropIndex: $dropIndex))
        .contextMenu {
            Button(loc("pages.rotateLeft")) { doc.rotatePages(targets, clockwise: false) }
            Button(loc("pages.rotateRight")) { doc.rotatePages(targets, clockwise: true) }
            Divider()
            Button(loc("pages.extract")) {
                if !doc.selectedPages.contains(doc.id(of: page)) {
                    doc.selectPage(at: index, extend: false, range: false)
                }
                doc.saveSelectionAsPDF()
            }
            Button(loc("pages.showInDocument")) { openInDocument() }
            Divider()
            Button(loc("pages.delete"), role: .destructive) { doc.deletePages(targets) }
                .disabled(targets.count >= doc.pageCount)
        }
    }

    /// The clicked page, or the whole selection if the page is part of it.
    private var targets: [Int] {
        doc.selectedPages.contains(doc.id(of: page)) ? doc.selectedIndices : [index]
    }

    private var insertionBar: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 4, height: thumbSize.height)
            .padding(.bottom, 26)
    }

    private func openInDocument() {
        doc.mode = .document
        doc.resumePageIndex = index
    }
}

/// Scissors in the gutter between two pages; toggles a cut after the page.
@MainActor
private struct CutMark: View {
    let isCut: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            if isCut {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 2, height: 200)
                    .overlay(
                        Rectangle()
                            .stroke(Color.red, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    )
            }
            Button(action: action) {
                Image(systemName: "scissors")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isCut ? Color.white : (hovering ? Color.primary : Color.secondary))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(isCut ? Color.red : Color(nsColor: .controlBackgroundColor)))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(isCut ? 0 : 0.15)))
                    .opacity(isCut || hovering ? 1 : 0.55)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(isCut ? loc("pages.cut.remove") : loc("pages.cut.add"))
            .accessibilityLabel(isCut ? loc("pages.cut.remove") : loc("pages.cut.add"))
        }
    }
}

/// Handles both internal page drags (reorder) and files from Finder (insert).
private struct PageDropDelegate: DropDelegate {
    let targetIndex: (CGPoint) -> Int
    let doc: DocumentModel
    @Binding var dropIndex: Int?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL, .plainText])
    }

    func dropEntered(info: DropInfo) { dropIndex = targetIndex(info.location) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropIndex = targetIndex(info.location)
        return DropProposal(operation: info.hasItemsConforming(to: [.fileURL]) ? .copy : .move)
    }

    func dropExited(info: DropInfo) { dropIndex = nil }

    func performDrop(info: DropInfo) -> Bool {
        let index = targetIndex(info.location)
        dropIndex = nil
        if info.hasItemsConforming(to: [.fileURL]) {
            let providers = info.itemProviders(for: [.fileURL])
            Task { @MainActor in
                DropLoader.load(providers) { urls in
                    doc.insertFiles(urls, at: index)
                }
            }
            return true
        }
        // Only our own page drags reorder; text from other apps is ignored.
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
            let token = data.flatMap { String(data: $0, encoding: .utf8) }
            Task { @MainActor in
                guard let token, token == doc.pageDragToken else { return }
                doc.pageDragToken = nil
                doc.movePages(doc.selectedIndices, to: index)
            }
        }
        return true
    }
}

// MARK: - Context bar

@MainActor
private struct PagesContextRow: View {
    @EnvironmentObject var doc: DocumentModel

    var body: some View {
        ContextRow {
            if let status = doc.statusMessage {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(status)
                    .task(id: status) {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        if doc.statusMessage == status { doc.statusMessage = nil }
                    }
            } else if doc.parts.count > 1 {
                Image(systemName: "scissors").foregroundStyle(.red)
                Text(loc("pages.cutSummary", doc.parts.count))
                Button(loc("pages.split.run", doc.parts.count)) { doc.splitAtCutMarksWithPanel() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(loc("pages.split.clearCuts")) { doc.cutMarks = [] }
                    .controlSize(.small)
            } else {
                Image(systemName: "hand.tap").foregroundStyle(.secondary)
                Text(loc("pages.hint")).foregroundStyle(.secondary)
            }
        } trailing: {
            EmptyView()
        }
    }
}

/// The grid takes keyboard focus for ⌫ and ⌘A, but must not draw a focus
/// ring around the whole canvas.
private struct NoFocusRing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}
