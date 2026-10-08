import AppKit
import PDFKit

/// Page operations on sets of pages, as used by the page grid. Every operation
/// is one undo step; pages are tracked by identity so the selection and cut
/// marks survive reordering.
extension DocumentModel {
    func id(of page: PDFPage) -> ObjectIdentifier { ObjectIdentifier(page) }

    /// Indices of the selected pages in document order.
    var selectedIndices: [Int] {
        pages.enumerated().filter { selectedPages.contains(id(of: $0.element)) }.map(\.offset)
    }

    // MARK: - Selection

    /// Click / ⌘-click / ⇧-click semantics of the page grid.
    func selectPage(at index: Int, extend: Bool, range: Bool) {
        let all = pages
        guard all.indices.contains(index) else { return }
        let pageID = id(of: all[index])
        if range, let anchor = selectionAnchor(in: all) {
            let bounds = min(anchor, index)...max(anchor, index)
            selectedPages.formUnion(bounds.map { id(of: all[$0]) })
        } else if extend {
            if selectedPages.contains(pageID) {
                selectedPages.remove(pageID)
            } else {
                selectedPages.insert(pageID)
            }
        } else {
            selectedPages = [pageID]
        }
        lastClickedPage = pageID
    }

    private func selectionAnchor(in all: [PDFPage]) -> Int? {
        if let last = lastClickedPage, let index = all.firstIndex(where: { id(of: $0) == last }) {
            return index
        }
        return selectedIndices.first
    }

    func selectAllPages() {
        selectedPages = Set(pages.map(id(of:)))
    }

    func clearPageSelection() {
        selectedPages = []
    }

    // MARK: - Delete / rotate

    /// Deletes the given pages; at least one page always remains.
    func deletePages(_ indices: [Int]) {
        guard !indices.isEmpty, indices.count < pageCount else { return }
        undoManager.beginUndoGrouping()
        // Highest index first so the remaining indices stay valid.
        for index in indices.sorted(by: >) {
            deletePage(index)
        }
        undoManager.endUndoGrouping()
        undoManager.setActionName(loc("undo.deletePages"))
    }

    func rotatePages(_ indices: [Int], clockwise: Bool) {
        guard !indices.isEmpty else { return }
        undoManager.beginUndoGrouping()
        for index in indices {
            rotatePage(index, clockwise: clockwise)
        }
        undoManager.endUndoGrouping()
        undoManager.setActionName(loc("undo.rotatePages"))
    }

    // MARK: - Reorder

    /// Moves the pages at `indices` (as one block, in document order) so they
    /// land before the page that is at `destination` now; `pageCount` = end.
    func movePages(_ indices: [Int], to destination: Int) {
        let all = pages
        let moving = Set(indices)
        guard !moving.isEmpty else { return }
        let block = all.enumerated().filter { moving.contains($0.offset) }.map(\.element)
        var rest = all.enumerated().filter { !moving.contains($0.offset) }.map(\.element)
        let insertAt = destination - indices.filter { $0 < destination }.count
        rest.insert(contentsOf: block, at: max(0, min(insertAt, rest.count)))
        reorderPages(rest)
    }

    /// Puts the document's pages into `newOrder` (same pages, new order).
    func reorderPages(_ newOrder: [PDFPage]) {
        guard let doc = document else { return }
        let old = pages
        guard old.count == newOrder.count,
              zip(old, newOrder).contains(where: { $0 !== $1 }) else { return }
        finishInlineEditing?(true)
        select(nil)
        // Selection-sort style moves keep the document non-empty throughout.
        for (target, page) in newOrder.enumerated() {
            let current = doc.index(for: page)
            guard current != target, current != NSNotFound else { continue }
            doc.removePage(at: current)
            doc.insert(page, at: target)
        }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.reorderPages(old) }
        }
        undoManager.setActionName(loc("undo.movePages"))
        changed()
    }

    // MARK: - Insert (merge)

    /// Inserts `newPages` before `index`. Inverse of `removeInsertedPages`.
    func insertPages(_ newPages: [PDFPage], at index: Int) {
        guard let doc = document, !newPages.isEmpty else { return }
        finishInlineEditing?(true)
        var position = max(0, min(index, doc.pageCount))
        for page in newPages {
            doc.insert(page, at: position)
            position += 1
        }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.removeInsertedPages(newPages) }
        }
        undoManager.setActionName(loc("undo.insertPages"))
        changed()
    }

    private func removeInsertedPages(_ removed: [PDFPage]) {
        guard let doc = document else { return }
        let first = removed.map { doc.index(for: $0) }.filter { $0 != NSNotFound }.min() ?? doc.pageCount
        select(nil)
        for page in removed {
            let index = doc.index(for: page)
            guard index != NSNotFound, doc.pageCount > 1 else { continue }
            stamps.removeAll { $0.page === page }
            selectedPages.remove(id(of: page))
            cutMarks.remove(id(of: page))
            doc.removePage(at: index)
        }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.insertPages(removed, at: first) }
        }
        changed()
    }

    /// Inserts PDFs and images (converted with default options) before `index`
    /// and selects what was inserted. Returns false if nothing could be read.
    @discardableResult
    func insertFiles(_ urls: [URL], at index: Int) -> Bool {
        do {
            let newPages = try FileImport.pages(from: urls)
            guard !newPages.isEmpty else { return false }
            insertPages(newPages, at: index)
            selectedPages = Set(newPages.map(id(of:)))
            statusMessage = locCount("status.pagesInserted", newPages.count)
            return true
        } catch {
            showError(error.localizedDescription, title: loc("alert.openError"))
            return false
        }
    }

    // MARK: - Cut marks / split

    func toggleCut(after page: PDFPage) {
        let pageID = id(of: page)
        if cutMarks.contains(pageID) {
            cutMarks.remove(pageID)
        } else {
            cutMarks.insert(pageID)
        }
    }

    /// Page indices of each part defined by the cut marks.
    var parts: [[Int]] {
        var result: [[Int]] = [[]]
        for (index, page) in pages.enumerated() {
            result[result.count - 1].append(index)
            if cutMarks.contains(id(of: page)), index < pageCount - 1 {
                result.append([])
            }
        }
        return result.filter { !$0.isEmpty }
    }

    /// Writes one PDF per part into `folder`. Returns the number of files.
    func splitAtCutMarks(folder: URL) throws -> Int {
        let parts = parts
        for (number, indices) in parts.enumerated() {
            let name = String(format: "%@ – %@ %d.pdf", baseName, loc("split.partWord"), number + 1)
            try extractPages(indices, to: folder.appendingPathComponent(name))
        }
        return parts.count
    }
}

/// Reads PDFs and images into detached pages that can be inserted elsewhere.
enum FileImport {
    static func isPDF(_ url: URL) -> Bool {
        ConvertSupport.contentType(of: url)?.conforms(to: .pdf) == true
            || url.pathExtension.lowercased() == "pdf"
    }

    static func pages(from urls: [URL]) throws -> [PDFPage] {
        var result: [PDFPage] = []
        for url in urls {
            if isPDF(url) {
                guard let doc = PDFDocument(url: url) else {
                    throw PDFTools.ToolError.cantOpen(url.lastPathComponent)
                }
                result += copies(of: doc)
            } else if ConvertSupport.isConvertibleImage(url) {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("import-\(UUID().uuidString).pdf")
                defer { try? FileManager.default.removeItem(at: tmp) }
                _ = try ImageToPDF.convert(inputs: [url], to: tmp, options: ImageToPDFOptions())
                // Load from data so the pages don't depend on the temp file.
                guard let data = try? Data(contentsOf: tmp), let doc = PDFDocument(data: data) else {
                    throw PDFTools.ToolError.cantOpen(url.lastPathComponent)
                }
                result += copies(of: doc)
            }
        }
        return result
    }

    /// Copies: PDFKit re-parents inserted pages, which would mutate the source.
    private static func copies(of doc: PDFDocument) -> [PDFPage] {
        (0..<doc.pageCount).compactMap { doc.page(at: $0)?.copy() as? PDFPage }
    }

    /// One in-memory document from several files, in the given order.
    static func document(from urls: [URL]) throws -> PDFDocument {
        let out = PDFDocument()
        for page in try pages(from: urls) {
            out.insert(page, at: out.pageCount)
        }
        guard out.pageCount > 0 else { throw PDFTools.ToolError.emptySelection }
        return out
    }
}
