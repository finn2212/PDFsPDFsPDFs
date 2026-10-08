import Foundation
import PDFKit

enum PDFTools {
    enum ToolError: LocalizedError {
        case cantOpen(String)
        case writeFailed
        case emptySelection

        var errorDescription: String? {
            switch self {
            case .cantOpen(let name): return loc("error.cantOpen", name)
            case .writeFailed: return loc("error.writeFailed")
            case .emptySelection: return loc("error.emptySelection")
            }
        }
    }

    static func merge(urls: [URL], to destination: URL) throws {
        let out = PDFDocument()
        for url in urls {
            guard let doc = PDFDocument(url: url) else {
                throw ToolError.cantOpen(url.lastPathComponent)
            }
            for i in 0..<doc.pageCount {
                // Copy: PDFKit re-parents inserted pages, which would mutate the source.
                if let page = doc.page(at: i)?.copy() as? PDFPage {
                    out.insert(page, at: out.pageCount)
                }
            }
        }
        guard out.pageCount > 0 else { throw ToolError.emptySelection }
        guard out.write(to: destination) else { throw ToolError.writeFailed }
    }

    /// Parses "1-3, 5, 7-9" into ordered 0-based page indices. Returns nil on invalid input.
    static func parsePageRanges(_ input: String, pageCount: Int) -> [Int]? {
        var result: [Int] = []
        for part in input.split(separator: ",") {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }
            if let dash = token.firstIndex(of: "-") {
                let left = token[..<dash].trimmingCharacters(in: .whitespaces)
                let right = token[token.index(after: dash)...].trimmingCharacters(in: .whitespaces)
                guard let a = Int(left), let b = Int(right),
                      a >= 1, b >= a, b <= pageCount else { return nil }
                result.append(contentsOf: (a - 1)...(b - 1))
            } else {
                guard let n = Int(token), n >= 1, n <= pageCount else { return nil }
                result.append(n - 1)
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Formats 0-based indices as a compact 1-based label: [0,1,2,4] → "1–3, 5".
    static func rangeLabel(_ indices: [Int]) -> String {
        let sorted = Array(Set(indices)).sorted()
        var parts: [String] = []
        var start: Int?
        var previous: Int?
        for index in sorted + [Int.min] {
            if let p = previous, index == p + 1 {
                previous = index
                continue
            }
            if let s = start, let p = previous {
                parts.append(s == p ? "\(s + 1)" : "\(s + 1)–\(p + 1)")
            }
            start = index
            previous = index
        }
        return parts.joined(separator: ", ")
    }

    static func extract(from document: PDFDocument, pageIndices: [Int], to destination: URL) throws {
        let out = PDFDocument()
        for index in pageIndices {
            guard let page = document.page(at: index)?.copy() as? PDFPage else {
                throw ToolError.emptySelection
            }
            out.insert(page, at: out.pageCount)
        }
        guard out.pageCount > 0 else { throw ToolError.emptySelection }
        guard out.write(to: destination) else { throw ToolError.writeFailed }
    }

    /// Writes every page as its own PDF into `folder`. Returns the number of files written.
    static func splitIntoSinglePages(document: PDFDocument, baseName: String, folder: URL) throws -> Int {
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i)?.copy() as? PDFPage else { continue }
            let out = PDFDocument()
            out.insert(page, at: 0)
            let name = String(format: "%@ – %@ %02d.pdf", baseName, loc("split.pageWord"), i + 1)
            guard out.write(to: folder.appendingPathComponent(name)) else {
                throw ToolError.writeFailed
            }
        }
        return document.pageCount
    }
}
