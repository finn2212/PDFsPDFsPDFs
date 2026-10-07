import SwiftUI
import UniformTypeIdentifiers

enum AssetKind: Hashable {
    case signature
    case initials

    var drawTitle: String {
        switch self {
        case .signature: return loc("draw.title.signature")
        case .initials: return loc("draw.title.initials")
        }
    }
}

/// Drawing surface for signatures. Shows the existing asset until the first
/// new stroke replaces it.
@MainActor
struct SignatureCanvas: View {
    @Binding var strokes: [[CGPoint]]
    let existing: NSImage?
    let size: CGSize
    let hint: String

    @State private var currentStroke: [CGPoint] = []

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.white
            // Signing line, like on paper.
            HStack(spacing: 8) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                Rectangle().frame(height: 1)
            }
            .foregroundStyle(Color.black.opacity(0.25))
            .padding(.horizontal, 24)
            .padding(.bottom, 44)

            if strokes.isEmpty && currentStroke.isEmpty {
                if let existing {
                    Image(nsImage: existing)
                        .resizable()
                        .scaledToFit()
                        .padding(24)
                        .frame(width: size.width, height: size.height)
                } else {
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(Color.black.opacity(0.35))
                        .frame(width: size.width, height: size.height)
                }
            }

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
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.15)))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let p = value.location
                    guard p.x >= 0, p.y >= 0, p.x <= size.width, p.y <= size.height else { return }
                    currentStroke.append(p)
                }
                .onEnded { _ in
                    if !currentStroke.isEmpty {
                        strokes.append(currentStroke)
                        currentStroke = []
                    }
                }
        )
        .onHover { inside in
            if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
        }
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
