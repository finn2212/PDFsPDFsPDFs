import SwiftUI
import UniformTypeIdentifiers

enum AssetKind {
    case signature
    case initials

    var drawTitle: String {
        switch self {
        case .signature: return loc("draw.title.signature")
        case .initials: return loc("draw.title.initials")
        }
    }
}

struct SignatureDrawingSheet: View {
    let kind: AssetKind
    let onSave: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var strokes: [[CGPoint]] = []
    @State private var currentStroke: [CGPoint] = []

    private let canvasSize = CGSize(width: 560, height: 220)

    var body: some View {
        VStack(spacing: 14) {
            Text(kind.drawTitle)
                .font(.headline)
            Text(loc("draw.hint"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Canvas { ctx, _ in
                let all = currentStroke.isEmpty ? strokes : strokes + [currentStroke]
                for stroke in all {
                    guard let first = stroke.first else { continue }
                    var path = Path()
                    path.move(to: first)
                    if stroke.count == 1 {
                        path.addLine(to: CGPoint(x: first.x + 0.1, y: first.y))
                    }
                    for p in stroke.dropFirst() { path.addLine(to: p) }
                    ctx.stroke(path, with: .color(.black),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .background(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let p = value.location
                        guard p.x >= 0, p.y >= 0,
                              p.x <= canvasSize.width, p.y <= canvasSize.height else { return }
                        currentStroke.append(p)
                    }
                    .onEnded { _ in
                        if !currentStroke.isEmpty {
                            strokes.append(currentStroke)
                            currentStroke = []
                        }
                    }
            )

            HStack {
                Button(loc("draw.clear")) {
                    strokes = []
                    currentStroke = []
                }
                .disabled(strokes.isEmpty && currentStroke.isEmpty)

                Spacer()

                Button(loc("draw.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button(loc("draw.save")) {
                    if let png = ImageUtils.renderStrokes(strokes, canvasSize: canvasSize) {
                        onSave(png)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(strokes.isEmpty)
            }
        }
        .padding(20)
    }
}

enum SignatureImport {
    /// Shows an open panel for an image file and returns PNG data,
    /// optionally with the white background removed.
    @MainActor
    static func importImage(removeWhite: Bool) -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .gif, .bmp]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return nil }

        if removeWhite, let cleaned = ImageUtils.removeWhiteBackground(from: data) {
            return cleaned
        }
        guard let image = NSImage(data: data) else { return nil }
        return ImageUtils.pngData(from: image)
    }
}
