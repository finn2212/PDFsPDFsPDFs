import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct MergePanel: View {
    @EnvironmentObject var doc: DocumentModel

    @State private var files: [URL] = []
    @State private var openResult = true
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if files.isEmpty {
                    Text(loc("merge.empty"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    List {
                        ForEach(Array(files.enumerated()), id: \.offset) { index, url in
                            HStack(spacing: 6) {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(.red)
                                Text("\(index + 1). \(url.lastPathComponent)")
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Button {
                                    files.swapAt(index, index - 1)
                                } label: { Image(systemName: "arrow.up") }
                                    .buttonStyle(.borderless)
                                    .disabled(index == 0)
                                Button {
                                    files.swapAt(index, index + 1)
                                } label: { Image(systemName: "arrow.down") }
                                    .buttonStyle(.borderless)
                                    .disabled(index == files.count - 1)
                                Button {
                                    files.remove(at: index)
                                } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .frame(minHeight: 140, maxHeight: 240)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            Button(loc("merge.addFiles")) { addFiles() }

            Toggle(loc("merge.openResult"), isOn: $openResult)
                .font(.callout)

            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.callout)
            }

            Button(loc("merge.run")) { merge() }
                .buttonStyle(.borderedProminent)
                .disabled(files.count < 2)

            Spacer()
        }
        .padding(14)
        .onAppear {
            if files.isEmpty, let current = doc.fileURL {
                files = [current]
            }
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            files.append(contentsOf: panel.urls)
        }
    }

    private func merge() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = loc("merge.defaultName") + ".pdf"
        if let dir = files.first?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // The open document may have unsaved changes (stamps, rotations …);
            // merge must use what the user sees, not the stale file on disk.
            var sources = files
            if let current = doc.fileURL, doc.hasChanges,
               let idx = sources.firstIndex(of: current) {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("merge-current-\(UUID().uuidString).pdf")
                try doc.exportCurrentState(to: tmp)
                sources[idx] = tmp
            }
            try PDFTools.merge(urls: sources, to: url)
            errorText = nil
            doc.statusMessage = loc("status.saved", url.lastPathComponent)
            if openResult {
                doc.open(url: url)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct SplitPanel: View {
    @EnvironmentObject var doc: DocumentModel

    @State private var rangeText = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if doc.document == nil {
                Text(loc("split.noDoc"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(loc("split.subtitle", doc.pageCount))
                    .foregroundStyle(.secondary)
                    .font(.callout)

                Text(loc("split.rangeLabel"))
                    .font(.headline)
                TextField(loc("split.rangePlaceholder"), text: $rangeText)
                    .textFieldStyle(.roundedBorder)
                Button(loc("split.saveRange")) { saveRange() }
                    .buttonStyle(.borderedProminent)
                    .disabled(rangeText.trimmingCharacters(in: .whitespaces).isEmpty)

                Divider()

                Button(loc("split.singles")) { saveSingles() }

                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.callout)
                }
            }
            Spacer()
        }
        .padding(14)
    }

    private var baseName: String {
        doc.fileURL?.deletingPathExtension().lastPathComponent ?? "Dokument"
    }

    private func saveRange() {
        guard let document = doc.document else { return }
        guard let indices = PDFTools.parsePageRanges(rangeText, pageCount: document.pageCount) else {
            errorText = loc("split.rangeInvalid")
            return
        }
        errorText = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(baseName) (\(loc("split.pagesWord")) \(rangeText.replacingOccurrences(of: " ", with: ""))).pdf"
        if let dir = doc.fileURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try doc.extractPages(indices, to: url)
            doc.statusMessage = loc("status.saved", url.lastPathComponent)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveSingles() {
        guard doc.document != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = loc("split.chooseFolder")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let count = try doc.splitIntoSingles(folder: folder)
            errorText = nil
            doc.statusMessage = loc("split.done", count)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct TextPanel: View {
    @EnvironmentObject var doc: DocumentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(
                get: { doc.textToolActive },
                set: { doc.textToolActive = $0 }
            )) {
                Label(loc("text.tool"), systemImage: "character.cursor.ibeam")
            }
            .toggleStyle(.button)
            .controlSize(.large)
            .disabled(doc.document == nil)

            Text(loc("text.toolHint"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(loc("text.size"))
                Slider(value: Binding(
                    get: { Double(doc.textToolFontSize) },
                    set: { doc.textToolFontSize = CGFloat($0) }
                ), in: 8...72)
                Text("\(Int(doc.textToolFontSize)) pt")
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
            .font(.callout)

            Divider()

            Button {
                doc.startPlacingToday(fontSize: doc.textToolFontSize)
            } label: {
                Label(loc("tools.insertDate"), systemImage: "calendar")
            }
            .disabled(doc.document == nil)

            Text(loc("text.dateHint", doc.todayString))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text(loc("text.editHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(14)
    }
}
