import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// Thread-safe cancel flag shared with the background conversion.
final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}

enum ConvertDirection: String, CaseIterable, Identifiable {
    case imagesToPDF
    case pdfToImages

    var id: String { rawValue }
    var title: String { loc("convert.direction.\(rawValue)") }
}

@MainActor
final class ConvertModel: ObservableObject {
    @Published var direction: ConvertDirection = .imagesToPDF
    @Published var files: [URL] = []
    @Published var imageOptions = ImageToPDFOptions()
    @Published var pdfOptions = PDFToImageOptions()

    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var warnings: [ConvertWarning] = []
    @Published var errorText: String?

    private var cancelBox: CancelBox?

    func cancel() {
        cancelBox?.cancel()
    }

    func addImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, UTType("public.svg-image")].compactMap { $0 }
        guard panel.runModal() == .OK else { return }
        files.append(contentsOf: panel.urls.filter(ConvertSupport.isConvertibleImage))
    }

    func runImagesToPDF(statusHandler: @escaping (String) -> Void, openHandler: @escaping (URL) -> Void) {
        guard !files.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = loc("convert.defaultName") + ".pdf"
        panel.directoryURL = files.first?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let sources = files
        let options = imageOptions
        start { box, report in
            try ImageToPDF.convert(inputs: sources, to: destination, options: options,
                                   progress: report, isCancelled: { box.isCancelled })
        } completion: { [weak self] result in
            statusHandler(loc("convert.doneToPDF", result.pageCount, destination.lastPathComponent))
            self?.files = []
            openHandler(destination)
        }
    }

    func runPDFToImages(document: PDFDocument,
                        baseName: String,
                        statusHandler: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = loc("split.chooseFolder")
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let options = pdfOptions
        start { box, report in
            try PDFToImage.convert(document: document, baseName: baseName, into: folder,
                                   options: options, progress: report,
                                   isCancelled: { box.isCancelled })
        } completion: { result in
            statusHandler(loc("convert.doneToImages", result.pageCount, folder.lastPathComponent))
        }
    }

    private func start(_ work: @escaping (CancelBox, @escaping (Double) -> Void) throws -> ConvertResult,
                       completion: @escaping (ConvertResult) -> Void) {
        let box = CancelBox()
        cancelBox = box
        isRunning = true
        progress = 0
        warnings = []
        errorText = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The engines report fractional progress from the background thread;
            // hop each update to the main actor so the bar animates instead of spinning.
            let report: (Double) -> Void = { value in
                DispatchQueue.main.async { self?.progress = value }
            }
            let outcome = Result { try work(box, report) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                self.cancelBox = nil
                switch outcome {
                case .success(let result):
                    self.warnings = result.warnings
                    completion(result)
                case .failure(let error):
                    if case ConvertError.cancelled = error { return }
                    self.errorText = error.localizedDescription
                }
            }
        }
    }
}

struct ConvertPanel: View {
    @EnvironmentObject var doc: DocumentModel
    @StateObject private var model = ConvertModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $model.direction) {
                    ForEach(ConvertDirection.allCases) { direction in
                        Text(direction.title).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if model.direction == .imagesToPDF {
                    imagesToPDFSection
                } else {
                    pdfToImagesSection
                }

                if model.isRunning {
                    ProgressView(value: model.progress).progressViewStyle(.linear)
                    Button(loc("convert.cancel")) { model.cancel() }
                }

                if let errorText = model.errorText {
                    Text(errorText).foregroundStyle(.red).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !model.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.warnings) { warning in
                            Label(warning.message, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: - Images → PDF

    private var imagesToPDFSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if model.files.isEmpty {
                    Text(loc("convert.dropHint"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(8)
                        .frame(maxWidth: .infinity, minHeight: 110)
                } else {
                    List {
                        ForEach(Array(model.files.enumerated()), id: \.offset) { index, url in
                            HStack(spacing: 6) {
                                Image(systemName: "photo")
                                    .foregroundStyle(.blue)
                                Text("\(index + 1). \(url.lastPathComponent)")
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Button {
                                    model.files.swapAt(index, index - 1)
                                } label: { Image(systemName: "arrow.up") }
                                    .buttonStyle(.borderless)
                                    .disabled(index == 0)
                                Button {
                                    model.files.swapAt(index, index + 1)
                                } label: { Image(systemName: "arrow.down") }
                                    .buttonStyle(.borderless)
                                    .disabled(index == model.files.count - 1)
                                Button {
                                    model.files.remove(at: index)
                                } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .frame(minHeight: 120, maxHeight: 200)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                load(providers)
                return true
            }

            Button(loc("convert.addImages")) { model.addImages() }

            Picker(loc("convert.pagesize"), selection: $model.imageOptions.pageSize) {
                ForEach(PageSizeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Picker(loc("convert.quality"), selection: $model.imageOptions.quality) {
                ForEach(ImageQualityMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            if model.imageOptions.quality == .smaller {
                HStack {
                    Text(loc("convert.jpegQuality"))
                    Slider(value: $model.imageOptions.jpegQuality, in: 0.3...1.0)
                    Text("\(Int(model.imageOptions.jpegQuality * 100)) %")
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
                .font(.callout)
            }

            Toggle(loc("convert.expandFrames"), isOn: $model.imageOptions.expandFrames)
                .font(.callout)
            Text(loc("convert.expandFramesHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(loc("convert.noTextHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(loc("convert.runToPDF")) {
                model.runImagesToPDF(statusHandler: { doc.statusMessage = $0 },
                                     openHandler: { doc.open(url: $0) })
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.files.isEmpty || model.isRunning)
        }
    }

    // MARK: - PDF → Images

    private var pdfToImagesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if doc.document == nil {
                Text(loc("convert.noDoc"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(loc("convert.pageCount", doc.pageCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker(loc("convert.format"), selection: $model.pdfOptions.format) {
                    ForEach(RasterFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }

                Picker(loc("convert.resolution"), selection: $model.pdfOptions.dpi) {
                    Text(loc("convert.dpi.screen")).tag(150)
                    Text(loc("convert.dpi.print")).tag(300)
                    Text(loc("convert.dpi.high")).tag(600)
                }

                if model.pdfOptions.format.supportsQuality {
                    HStack {
                        Text(loc("convert.jpegQuality"))
                        Slider(value: $model.pdfOptions.quality, in: 0.3...1.0)
                        Text("\(Int(model.pdfOptions.quality * 100)) %")
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                    .font(.callout)
                }

                Button(loc("convert.runToImages")) {
                    exportPDFToImages()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunning)
            }
        }
    }

    /// Renders a flattened, deselected snapshot rather than the live document.
    /// PDFKit is not thread-safe: the editor stays interactive during the background
    /// export, so drawing the live document off-thread produces blank pages or a hard
    /// crash if the user edits a page mid-export. exportCurrentState also bakes in
    /// stamps and deselects, so no selection chrome ends up in the exported images.
    private func exportPDFToImages() {
        guard doc.document != nil else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("convert-snapshot-\(UUID().uuidString).pdf")
        do {
            try doc.exportCurrentState(to: tmp)
        } catch {
            model.errorText = error.localizedDescription
            return
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Load from data so the render does not depend on the temp file staying on disk.
        guard let data = try? Data(contentsOf: tmp), let snapshot = PDFDocument(data: data) else {
            model.errorText = loc("convert.error.noInput")
            return
        }
        model.runPDFToImages(document: snapshot,
                             baseName: baseName,
                             statusHandler: { doc.statusMessage = $0 })
    }

    private var baseName: String {
        doc.fileURL?.deletingPathExtension().lastPathComponent ?? loc("convert.defaultName")
    }

    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, ConvertSupport.isConvertibleImage(url) else { return }
                DispatchQueue.main.async {
                    model.files.append(url)
                }
            }
        }
    }
}
