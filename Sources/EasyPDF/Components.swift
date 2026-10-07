import SwiftUI

/// Labelled tool button for the tool strip: icon + text, with an "on" state
/// for modal tools (text tool, placing).
struct ToolButtonStyle: ButtonStyle {
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        ToolButtonBody(configuration: configuration, isOn: isOn)
    }

    private struct ToolButtonBody: View {
        let configuration: Configuration
        let isOn: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 11)
                .frame(height: 30)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(fill)
                )
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if isOn { return .accentColor }
            if configuration.isPressed { return Color.primary.opacity(0.14) }
            if hovering && isEnabled { return Color.primary.opacity(0.07) }
            return .clear
        }
    }
}

/// Horizontal bar under the window toolbar that holds the tools of the
/// current view. Shows labels when they fit, icons only (with tooltips)
/// in narrow windows.
struct ToolStrip<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: (Bool) -> Leading
    @ViewBuilder var trailing: (Bool) -> Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: 4) {
            leading(compact)
            Spacer(minLength: 12)
            trailing(compact)
        }
        .labelStyle(StripLabelStyle(compact: compact))
    }
}

struct StripLabelStyle: LabelStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            if !compact { configuration.title }
        }
    }
}

struct StripDivider: View {
    var body: some View {
        Divider().frame(height: 18).padding(.horizontal, 6)
    }
}

/// Floating capsule at the bottom of the canvas: the current state in words
/// plus the controls that belong to it.
struct ContextBar<Content: View>: View {
    /// False when the host positions the bar itself (see PDFCanvasView).
    var floating = true
    @ViewBuilder var content: Content

    init(floating: Bool = true, @ViewBuilder content: () -> Content) {
        self.floating = floating
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        // Clicks on the bar itself (labels, gaps) must not fall through to
        // the page underneath, where they would start a text or deselect.
        .contentShape(Capsule())
        .onTapGesture {}
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        .padding(.bottom, floating ? 18 : 0)
        .padding(.horizontal, floating ? 24 : 0)
    }
}

/// Small borderless icon button for the context bar.
struct BarIconButton: View {
    let systemImage: String
    let help: String
    var role: ButtonRole?
    var id: String?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(id ?? systemImage)
    }
}

/// − 14 pt + stepper used for text size and stamp size.
struct SizeStepper: View {
    let label: String
    let value: String
    let decrease: () -> Void
    let increase: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            BarIconButton(systemImage: "minus", help: loc("size.smaller"), id: "size.smaller", action: decrease)
            Text(value)
                .monospacedDigit()
                .frame(minWidth: 44)
                .accessibilityLabel("\(label) \(value)")
            BarIconButton(systemImage: "plus", help: loc("size.larger"), id: "size.larger", action: increase)
        }
    }
}

struct AppLogoView: View {
    var size: CGFloat = 128

    var body: some View {
        if let url = Bundle.module.url(forResource: "AppLogo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: size * 0.08, y: size * 0.03)
        } else {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: size * 0.4))
                .foregroundStyle(.secondary)
        }
    }
}

/// Highlight shown while files are dragged over a drop target.
struct DropHighlight: View {
    var cornerRadius: CGFloat = 16

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.06))
            )
            .allowsHitTesting(false)
    }
}

/// Loads file URLs from drag providers and hands them over on the main actor.
enum DropLoader {
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [(Int, URL)] = []
        for (index, provider) in providers.enumerated() where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock()
                    urls.append((index, url))
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            // Keep the order the files were dragged in.
            let ordered = urls.sorted { $0.0 < $1.0 }.map(\.1)
            MainActor.assumeIsolated { completion(ordered) }
        }
    }
}

#if DEBUG
/// Where tagged controls are on screen, for the interaction test. Each
/// entry remembers which view instance wrote it, so a disappearing old
/// instance can't wipe the frame its replacement just registered.
@MainActor
enum UITestTargets {
    static var frames: [String: CGRect] = [:]
    static var owners: [String: UUID] = [:]

    static func set(_ id: String, _ frame: CGRect, owner: UUID) {
        frames[id] = frame
        owners[id] = owner
    }

    static func remove(_ id: String, owner: UUID) {
        guard owners[id] == owner else { return }
        frames[id] = nil
        owners[id] = nil
    }
}

private struct UITestTargetModifier: ViewModifier {
    let id: String
    let space: CoordinateSpace
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content.background(GeometryReader { proxy in
            Color.clear
                .onAppear { UITestTargets.set(id, proxy.frame(in: space), owner: owner) }
                .onChange(of: proxy.frame(in: space)) { UITestTargets.set(id, $0, owner: owner) }
                .onDisappear { UITestTargets.remove(id, owner: owner) }
        })
    }
}
#endif

extension View {
    /// Tags a control so the debug interaction test can find and click it.
    /// Frames are measured in the hosting view's own space (`.global`), or
    /// in a named space for views hosted separately. No effect in release.
    @ViewBuilder
    func uiTestTarget(_ id: String, in space: CoordinateSpace = .global) -> some View {
        #if DEBUG
        modifier(UITestTargetModifier(id: id, space: space))
        #else
        self
        #endif
    }
}
