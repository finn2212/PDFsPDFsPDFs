import AppKit
import CoreTransferable
import PDFKit
import UniformTypeIdentifiers

/// Opening, merging, dropping and sharing files.
extension DocumentModel {
    /// "Merge PDFs" on the start screen: choose files, show the result in the page grid.
    func requestMergePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = loc("merge.panelMessage")
        panel.prompt = loc("merge.panelPrompt")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        openAsNew(panel.urls)
    }

    /// "Images → PDF" on the start screen: choose images, then the options sheet.
    func requestImagesPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, UTType("public.svg-image")].compactMap { $0 }
        guard panel.runModal() == .OK else { return }
        let images = panel.urls.filter(ConvertSupport.isConvertibleImage)
        guard !images.isEmpty else { return }
        imagesRequest = ImagesRequest(urls: images)
    }

    /// Opens files as a new document: one PDF opens as is, several PDFs are
    /// merged, images go to the images → PDF sheet.
    func openAsNew(_ urls: [URL]) {
        let pdfs = urls.filter(FileImport.isPDF)
        let images = urls.filter { !FileImport.isPDF($0) && ConvertSupport.isConvertibleImage($0) }
        if pdfs.isEmpty {
            if !images.isEmpty { imagesRequest = ImagesRequest(urls: images) }
            return
        }
        if pdfs.count == 1, images.isEmpty {
            open(url: pdfs[0])
            return
        }
        do {
            let merged = try FileImport.document(from: urls)
            if openUntitled(merged, name: loc("merge.defaultName"), mode: .pages) {
                statusMessage = loc("status.merged", urls.count, merged.pageCount)
            }
        } catch {
            showError(error.localizedDescription, title: loc("alert.openError"))
        }
    }

    /// Files dropped somewhere outside the page grid.
    func handleDrop(_ urls: [URL]) {
        let usable = urls.filter { FileImport.isPDF($0) || ConvertSupport.isConvertibleImage($0) }
        guard !usable.isEmpty else { return }
        if document == nil {
            openAsNew(usable)
        } else {
            // Append or replace? Ambiguous with a document open, so ask.
            pendingDrop = PendingDrop(urls: usable)
        }
    }

    func appendDropped(_ urls: [URL]) {
        if insertFiles(urls, at: pageCount) {
            mode = .pages
        }
    }

    // MARK: - Share

    /// File name of the copy that gets shared or exported.
    var exportFileName: String {
        baseName + (stamps.isEmpty ? "" : loc("save.suffix")) + ".pdf"
    }

    /// Writes the current state (stamps flattened) to a fresh temp folder,
    /// under a clean file name for the recipient.
    func exportForSharing() throws -> URL {
        finishInlineEditing?(true)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(exportFileName)
        try exportCurrentState(to: url)
        return url
    }

    func saveCopy() {
        guard document != nil else { return }
        finishInlineEditing?(true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = exportFileName
        if let dir = fileURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportCurrentState(to: url)
            statusMessage = loc("status.saved", url.lastPathComponent)
        } catch {
            showError(error.localizedDescription, title: loc("alert.saveError"))
        }
    }

    // MARK: - Page grid actions with file dialogs

    func saveSelectionAsPDF() {
        let indices = selectedIndices
        guard !indices.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let label = indices.count == 1
            ? "\(loc("split.pageWord")) \(indices[0] + 1)"
            : "\(loc("split.pagesWord")) \(PDFTools.rangeLabel(indices))"
        panel.nameFieldStringValue = "\(baseName) (\(label)).pdf"
        if let dir = fileURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try extractPages(indices, to: url)
            statusMessage = loc("status.saved", url.lastPathComponent)
        } catch {
            showError(error.localizedDescription, title: loc("alert.saveError"))
        }
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = loc("split.chooseFolder")
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func splitAtCutMarksWithPanel() {
        guard parts.count > 1, let folder = chooseFolder() else { return }
        do {
            let count = try splitAtCutMarks(folder: folder)
            statusMessage = locCount("split.done", count)
        } catch {
            showError(error.localizedDescription, title: loc("alert.saveError"))
        }
    }

    func splitIntoSinglesWithPanel() {
        guard document != nil, let folder = chooseFolder() else { return }
        do {
            let count = try splitIntoSingles(folder: folder)
            statusMessage = locCount("split.done", count)
        } catch {
            showError(error.localizedDescription, title: loc("alert.saveError"))
        }
    }

    func insertPDFWithPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .image]
        panel.prompt = loc("pages.insertPrompt")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        // After the selection, or at the end.
        let index = (selectedIndices.last.map { $0 + 1 }) ?? pageCount
        insertFiles(panel.urls, at: index)
    }
}

/// The open document as something the system share menu can send.
struct SharedPDF: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { _ in
            let url = try await MainActor.run { try DocumentModel.shared.exportForSharing() }
            return SentTransferredFile(url)
        }
    }
}
