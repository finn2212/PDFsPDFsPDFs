import SwiftUI
import PDFKit

struct ThumbnailSidebar: View {
    @EnvironmentObject var doc: DocumentModel
    @State private var currentPage = 0

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<doc.pageCount, id: \.self) { index in
                    ThumbCell(index: index,
                              revision: doc.docRevision,
                              isCurrent: index == currentPage)
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .PDFViewPageChanged)) { _ in
            if let page = doc.pdfView?.currentPage, let d = doc.document {
                let idx = d.index(for: page)
                if (0..<d.pageCount).contains(idx) { currentPage = idx }
            }
        }
    }
}

private struct ThumbCell: View {
    @EnvironmentObject var doc: DocumentModel
    let index: Int
    let revision: Int
    let isCurrent: Bool
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.gray.opacity(0.12)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isCurrent ? Color.accentColor : Color.secondary.opacity(0.3),
                            lineWidth: isCurrent ? 2 : 1)
            )
            Text("\(index + 1)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let page = doc.document?.page(at: index) {
                doc.pdfView?.go(to: page)
            }
        }
        .contextMenu {
            Button(loc("page.rotateLeft")) { doc.rotatePage(index, clockwise: false) }
            Button(loc("page.rotateRight")) { doc.rotatePage(index, clockwise: true) }
            Divider()
            Button(loc("page.moveUp")) { doc.movePage(index, offset: -1) }
                .disabled(index == 0)
            Button(loc("page.moveDown")) { doc.movePage(index, offset: 1) }
                .disabled(index == doc.pageCount - 1)
            Divider()
            Button(loc("page.extract")) { doc.extractPage(index) }
            Button(loc("page.delete"), role: .destructive) { doc.deletePage(index) }
                .disabled(doc.pageCount <= 1)
        }
        .task(id: revision) {
            render()
        }
    }

    private func render() {
        guard let page = doc.document?.page(at: index) else { return }
        image = page.thumbnail(of: CGSize(width: 280, height: 320), for: .cropBox)
    }
}
