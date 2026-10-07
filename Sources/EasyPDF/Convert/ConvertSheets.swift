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

@MainActor
final class ConvertModel: ObservableObject {
    @Published var files: [URL] = []
    @Published var imageOptions = ImageToPDFOptions()
    @Published var pdfOptions = PDFToImageOptions()

    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var warnings: [ConvertWarning] = []
    @Published var errorText: String?
    /// Set once a conversion completed successfully.
    @Published var didFinish = false

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
        didFinish = false

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
                    self.didFinish = true
                    completion(result)
                case .failure(let error):
                    if case ConvertError.cancelled = error { return }
                    self.errorText = error.localizedDescription
                }
            }
        }
    }
}

/// Images → PDF as a sheet: file list (drag to sort), page size and quality.
/// The result is saved and opened as the current document.
@MainActor
struct ImagesToPDFSheet: View {
    @EnvironmentObject var doc: DocumentModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ConvertModel()
    let initialFiles: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(loc("start.images.title"))
                .font(.title2.bold())

            fileList

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(loc("convert.pagesize")).foregroundStyle(.secondary)
                    Picker("", selection: $model.imageOptions.pageSize) {
                        ForEach(PageSizeMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
                GridRow {
                    Text(loc("convert.quality")).foregroundStyle(.secondary)
                    Picker("", selection: $model.imageOptions.quality) {
                        ForEach(ImageQualityMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                }
                if model.imageOptions.quality == .smaller {
                    GridRow {
                        Text(loc("convert.jpegQuality")).foregroundStyle(.secondary)
                        HStack {
                            Slider(value: $model.imageOptions.jpegQuality, in: 0.3...1.0)
                            Text("\(Int(model.imageOptions.jpegQuality * 100)) %")
                                .monospacedDigit()
                                .frame(width: 46, alignment: .trailing)
                        }
                        .frame(width: 240)
                    }
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Toggle(loc("convert.expandFrames"), isOn: $model.imageOptions.expandFrames)
                        .help(loc("convert.expandFramesHint"))
                }
            }
            .font(.callout)

            ConvertFeedback(model: model)

            HStack {
                Text(loc("convert.noTextHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                if model.didFinish {
                    Button(loc("action.done")) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(loc("editor.cancel")) {
                        model.cancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(loc("convert.runToPDF")) {
                        model.runImagesToPDF(statusHandler: { doc.statusMessage = $0 },
                                             openHandler: { url in
                                                 doc.open(url: url)
                                                 if model.warnings.isEmpty { dismiss() }
                                             })
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.files.isEmpty || model.isRunning)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            if model.files.isEmpty { model.files = initialFiles }
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach(Array(model.files.enumerated()), id: \.offset) { index, url in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 22, alignment: .trailing)
                        Image(systemName: "photo")
                            .foregroundStyle(Color.accentColor)
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button {
                            model.files.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.borderless)
                        .help(loc("convert.removeFile"))
                    }
                }
                .onMove { model.files.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 170)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                DropLoader.load(providers) { urls in
                    model.files.append(contentsOf: urls.filter(ConvertSupport.isConvertibleImage))
                }
                return true
            }
            HStack {
                Button(loc("convert.addImages")) { model.addImages() }
                Spacer()
                Text(loc("convert.sortHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// PDF → images as a sheet (File › Export as images).
@MainActor
struct ExportImagesSheet: View {
    @EnvironmentObject var doc: DocumentModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ConvertModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(loc("export.images.title"))
                .font(.title2.bold())
            Text(locCount("convert.pageCount", doc.pageCount))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(loc("convert.format")).foregroundStyle(.secondary)
                    Picker("", selection: $model.pdfOptions.format) {
                        ForEach(RasterFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                GridRow {
                    Text(loc("convert.resolution")).foregroundStyle(.secondary)
                    Picker("", selection: $model.pdfOptions.dpi) {
                        Text(loc("convert.dpi.screen")).tag(150)
                        Text(loc("convert.dpi.print")).tag(300)
                        Text(loc("convert.dpi.high")).tag(600)
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                if model.pdfOptions.format.supportsQuality {
                    GridRow {
                        Text(loc("convert.jpegQuality")).foregroundStyle(.secondary)
                        HStack {
                            Slider(value: $model.pdfOptions.quality, in: 0.3...1.0)
                            Text("\(Int(model.pdfOptions.quality * 100)) %")
                                .monospacedDigit()
                                .frame(width: 46, alignment: .trailing)
                        }
                        .frame(width: 220)
                    }
                }
            }
            .font(.callout)

            ConvertFeedback(model: model)

            HStack {
                Spacer()
                if model.didFinish {
                    Button(loc("action.done")) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(loc("editor.cancel")) {
                        model.cancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(loc("convert.runToImages")) { export() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRunning || doc.document == nil)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    /// Renders a flattened, deselected snapshot rather than the live document.
    /// PDFKit is not thread-safe: the editor stays interactive during the background
    /// export, so drawing the live document off-thread produces blank pages or a hard
    /// crash if the user edits a page mid-export. exportCurrentState also bakes in
    /// stamps and deselects, so no selection chrome ends up in the exported images.
    private func export() {
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
                             baseName: doc.baseName,
                             statusHandler: { doc.statusMessage = $0 })
    }
}

/// Progress, error and warnings of a running or finished conversion.
@MainActor
private struct ConvertFeedback: View {
    @ObservedObject var model: ConvertModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isRunning {
                HStack {
                    ProgressView(value: model.progress).progressViewStyle(.linear)
                    Button(loc("convert.cancel")) { model.cancel() }
                        .controlSize(.small)
                }
            }
            if let errorText = model.errorText {
                Label(errorText, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.warnings) { warning in
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
