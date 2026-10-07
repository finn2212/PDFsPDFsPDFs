import SwiftUI

/// Window root: start screen without a document, otherwise the document in
/// one of its two views. Owns every sheet and dialog, so only one is ever up.
struct ContentView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var doc: DocumentModel

    var body: some View {
        Group {
            if doc.document == nil {
                StartView()
            } else if doc.mode == .document {
                DocumentWorkspace()
            } else {
                PagesView()
            }
        }
        .navigationTitle(doc.document == nil ? "" : doc.displayName)
        .navigationSubtitle(subtitle)
        .toolbar { WindowToolbar() }
        .sheet(item: $doc.signatureEditor) { request in
            SignatureEditorSheet(request: request)
                .environmentObject(store)
                .environmentObject(doc)
        }
        .sheet(item: $doc.imagesRequest) { request in
            ImagesToPDFSheet(initialFiles: request.urls)
                .environmentObject(doc)
        }
        .sheet(isPresented: $doc.exportImagesRequested) {
            ExportImagesSheet()
                .environmentObject(doc)
        }
        .confirmationDialog(dropTitle,
                            isPresented: Binding(get: { doc.pendingDrop != nil },
                                                 set: { if !$0 { doc.pendingDrop = nil } }),
                            presenting: doc.pendingDrop) { drop in
            Button(loc("drop.append")) { doc.appendDropped(drop.urls) }
            Button(drop.urls.count == 1 && FileImport.isPDF(drop.urls[0])
                   ? loc("drop.open") : loc("drop.openNew")) { doc.openAsNew(drop.urls) }
            Button(loc("action.cancel"), role: .cancel) {}
        } message: { _ in
            Text(loc("drop.message", doc.displayName))
        }
        .alert(doc.errorTitle,
               isPresented: Binding(
                   get: { doc.saveErrorMessage != nil },
                   set: { if !$0 { doc.saveErrorMessage = nil } })) {
            Button(loc("alert.ok"), role: .cancel) {}
        } message: {
            Text(doc.saveErrorMessage ?? "")
        }
    }

    private var subtitle: String {
        guard doc.document != nil else { return "" }
        let pages = doc.pageCount == 1 ? loc("subtitle.page") : loc("subtitle.pages", doc.pageCount)
        return doc.hasChanges ? pages + " · " + loc("subtitle.edited") : pages
    }

    private var dropTitle: String {
        guard let drop = doc.pendingDrop else { return "" }
        return drop.urls.count == 1
            ? loc("drop.titleOne", drop.urls[0].lastPathComponent)
            : loc("drop.titleMany", drop.urls.count)
    }
}

/// Window toolbar: view switch in the middle, Save and Share on the right.
private struct WindowToolbar: ToolbarContent {
    @EnvironmentObject var doc: DocumentModel

    var body: some ToolbarContent {
        if doc.document != nil {
            ToolbarItem(placement: .navigation) {
                Picker(loc("mode.label"), selection: $doc.mode) {
                    ForEach(WorkspaceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.icon)
                            .labelStyle(.titleAndIcon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
                .help(loc("mode.help"))
            }
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    doc.saveInPlace()
                } label: {
                    Label(loc("toolbar.save"), systemImage: "square.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .help(doc.fileURL == nil ? loc("toolbar.save.helpNew") : loc("toolbar.save.help"))
                // Form edits are not always reported, so forms can always be saved.
                .disabled(!doc.hasChanges && doc.formFieldCount == 0)

                ShareLink(item: SharedPDF(), preview: SharePreview(doc.exportFileName)) {
                    Label(loc("toolbar.share"), systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .help(loc("toolbar.share.help"))
            }
        }
    }
}
