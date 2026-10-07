import SwiftUI

/// Shown when no document is open: the three jobs that start without a
/// document, recent files, and the whole window as a drop zone.
@MainActor
struct StartView: View {
    @EnvironmentObject var doc: DocumentModel
    @State private var isTargeted = false

    var body: some View {
        GeometryReader { proxy in
        ScrollView {
            VStack(spacing: 30) {
                header

                HStack(alignment: .top, spacing: 14) {
                    StartCard(icon: "doc.text.fill",
                              title: loc("start.open.title"),
                              subtitle: loc("start.open.subtitle"),
                              shortcut: "⌘O",
                              prominent: true) { doc.requestOpenPanel() }
                    StartCard(icon: "square.stack.3d.up.fill",
                              title: loc("start.merge.title"),
                              subtitle: loc("start.merge.subtitle")) { doc.requestMergePanel() }
                    StartCard(icon: "photo.on.rectangle.angled",
                              title: loc("start.images.title"),
                              subtitle: loc("start.images.subtitle")) { doc.requestImagesPanel() }
                }
                .frame(maxWidth: 780)

                Label(loc("start.dropHint"), systemImage: "arrow.down.doc")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                RecentFilesList()
                    .frame(maxWidth: 780)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, minHeight: proxy.size.height)
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if isTargeted {
                DropHighlight().padding(14)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            DropLoader.load(providers) { doc.handleDrop($0) }
            return true
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            AppLogoView(size: 84)
            Text(loc("app.name"))
                .font(.system(size: 28, weight: .bold))
            Text(loc("start.tagline"))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

@MainActor
private struct StartCard: View {
    let icon: String
    let title: String
    let subtitle: String
    var shortcut: String?
    var prominent = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(prominent ? Color.white : Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(prominent ? Color.accentColor : Color.accentColor.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 4)
                        if let shortcut {
                            Text(shortcut)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(hovering ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.09),
                                  lineWidth: hovering ? 1.5 : 1)
            )
            .shadow(color: .black.opacity(hovering ? 0.08 : 0.03), radius: hovering ? 10 : 4, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

@MainActor
private struct RecentFilesList: View {
    @EnvironmentObject var doc: DocumentModel

    var body: some View {
        let recents = Array(RecentsStore.urls.prefix(6))
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(loc("placeholder.recent"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                VStack(spacing: 0) {
                    ForEach(Array(recents.enumerated()), id: \.element) { index, url in
                        if index > 0 { Divider().padding(.leading, 44) }
                        RecentRow(url: url) { doc.open(url: url) }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09))
                )
            }
        }
    }
}

@MainActor
private struct RecentRow: View {
    let url: URL
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(red: 0.86, green: 0.27, blue: 0.22))
                    .frame(width: 20)
                Text(url.lastPathComponent)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Text(folderLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(hovering ? Color.primary.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var folderLabel: String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}
