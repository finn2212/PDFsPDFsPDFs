import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var doc: DocumentModel

    @State private var stampWidth: CGFloat = 180
    @State private var resizeStartRect: CGRect?
    @AppStorage("selectedTool") private var selectedToolRaw = SideTool.people.rawValue

    private var selectedTool: Binding<SideTool?> {
        Binding(
            get: { SideTool(rawValue: selectedToolRaw) },
            set: { selectedToolRaw = $0?.rawValue ?? "" }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            ToolRail(selection: selectedTool)
            Divider()
            if let tool = selectedTool.wrappedValue {
                ToolPanelView(tool: tool)
                Divider()
            }
            detail
        }
        .navigationTitle(doc.fileURL?.lastPathComponent ?? loc("app.name"))
        .toolbar { toolbarContent }
        .onChange(of: doc.selectedStampID) { _ in
            if let stamp = doc.selectedStamp {
                stampWidth = stamp.rect.width
            }
        }
        .onReceive(doc.$stamps) { stamps in
            // Keep the toolbar slider in sync when resizing via the corner handles.
            if let id = doc.selectedStampID,
               let stamp = stamps.first(where: { $0.id == id }) {
                stampWidth = stamp.rect.width
            }
        }
        .alert(loc("alert.saveError"),
               isPresented: Binding(
                   get: { doc.saveErrorMessage != nil },
                   set: { if !$0 { doc.saveErrorMessage = nil } })) {
            Button(loc("alert.ok"), role: .cancel) {}
        } message: {
            Text(doc.saveErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if doc.document != nil {
            VStack(spacing: 0) {
                if doc.isEditingText {
                    banner(text: loc("hint.typing"), color: .blue)
                } else if let pending = doc.pendingStamp {
                    banner(text: loc("hint.placement", pending.label), color: .blue)
                } else if doc.textToolActive {
                    banner(text: loc("hint.textTool"), color: .blue)
                } else if doc.selectedStampID != nil {
                    banner(text: loc("hint.selected"), color: .secondary)
                } else if let status = doc.statusMessage {
                    banner(text: status, color: .green)
                }
                PDFKitView(model: doc)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { handleDrop($0) }
        } else {
            placeholder
        }
    }

    private func banner(text: String, color: Color) -> some View {
        HStack {
            Text(text)
                .font(.callout)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(color.opacity(0.12))
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            AppLogoView()
            Text(loc("placeholder.title")).font(.title2.bold())
            Text(loc("placeholder.subtitle")).foregroundStyle(.secondary)
            Button(loc("placeholder.open")) { doc.requestOpenPanel() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

            let recents = RecentsStore.urls
            if !recents.isEmpty {
                Divider().frame(width: 260).padding(.top, 8)
                Text(loc("placeholder.recent"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(recents.prefix(5), id: \.self) { url in
                    Button {
                        doc.open(url: url)
                    } label: {
                        Label(url.lastPathComponent, systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: nil) { handleDrop($0) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "pdf" else { return }
            Task { @MainActor in doc.open(url: url) }
        }
        return true
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                doc.requestOpenPanel()
            } label: {
                Label(loc("toolbar.open"), systemImage: "folder")
            }
            .help(loc("toolbar.open"))

            Button {
                doc.saveInPlace()
            } label: {
                Label(loc("toolbar.save"), systemImage: "square.and.arrow.down")
            }
            .help(loc("toolbar.save"))
            .disabled(doc.document == nil || !doc.hasChanges)

            Button {
                doc.printDocument()
            } label: {
                Label(loc("toolbar.print"), systemImage: "printer")
            }
            .help(loc("toolbar.print"))
            .disabled(doc.document == nil)

            Button {
                doc.undo()
            } label: {
                Label(loc("toolbar.undo"), systemImage: "arrow.uturn.backward")
            }
            .help(loc("toolbar.undo"))
            .disabled(!doc.canUndo)

            Button {
                doc.redo()
            } label: {
                Label(loc("toolbar.redo"), systemImage: "arrow.uturn.forward")
            }
            .help(loc("toolbar.redo"))
            .disabled(!doc.canRedo)

            if doc.isEditingText {
                // Live font size while typing inline.
                Slider(value: Binding(
                    get: { Double(doc.textToolFontSize) },
                    set: { doc.textToolFontSize = CGFloat($0) }
                ), in: 8...72)
                .frame(width: 140)
                .help(loc("text.size"))

                Text("\(Int(doc.textToolFontSize)) pt")
                    .monospacedDigit()
            } else if doc.selectedStampID != nil {
                Slider(
                    value: Binding(
                        get: { stampWidth },
                        set: { newValue in
                            stampWidth = newValue
                            doc.resizeSelected(width: newValue)
                        }
                    ),
                    in: 30...400,
                    onEditingChanged: { editing in
                        if editing {
                            resizeStartRect = doc.selectedStamp?.rect
                        } else if let start = resizeStartRect, let id = doc.selectedStampID {
                            doc.commitRectChange(id: id, from: start)
                            resizeStartRect = nil
                        }
                    }
                )
                .frame(width: 140)
                .help(loc("toolbar.size"))

                Button {
                    doc.rotateSelected(by: -15)
                } label: {
                    Label(loc("toolbar.rotateStampLeft"), systemImage: "rotate.left")
                }
                .help(loc("toolbar.rotateStampLeft"))

                Button {
                    doc.rotateSelected(by: 15)
                } label: {
                    Label(loc("toolbar.rotateStampRight"), systemImage: "rotate.right")
                }
                .help(loc("toolbar.rotateStampRight"))

                Button {
                    doc.removeSelected()
                } label: {
                    Label(loc("toolbar.deleteStamp"), systemImage: "trash")
                }
                .help(loc("toolbar.deleteStamp"))
            }
        }
    }
}

struct AppLogoView: View {
    var body: some View {
        if let url = Bundle.module.url(forResource: "AppLogo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        } else {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
        }
    }
}
