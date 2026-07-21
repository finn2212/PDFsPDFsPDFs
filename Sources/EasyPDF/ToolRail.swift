import SwiftUI

enum SideTool: String, CaseIterable, Identifiable {
    case people
    case pages
    case merge
    case split
    case text
    case convert

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .people: return "signature"
        case .pages: return "square.grid.2x2"
        case .merge: return "plus.rectangle.on.rectangle"
        case .split: return "scissors"
        case .text: return "textformat"
        case .convert: return "arrow.left.arrow.right.square"
        }
    }

    var title: String { loc("tool.\(rawValue)") }
}

struct ToolRail: View {
    @Binding var selection: SideTool?

    var body: some View {
        VStack(spacing: 6) {
            ForEach(SideTool.allCases) { tool in
                Button {
                    selection = (selection == tool) ? nil : tool
                } label: {
                    Image(systemName: tool.icon)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 42, height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(selection == tool ? Color.accentColor.opacity(0.18) : .clear)
                        )
                        .foregroundStyle(selection == tool ? Color.accentColor : Color.primary.opacity(0.72))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .help(tool.title)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .frame(width: 56)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ToolPanelView: View {
    let tool: SideTool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tool.title)
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            switch tool {
            case .people:
                PeopleSidebar()
            case .pages:
                ThumbnailSidebar()
            case .merge:
                MergePanel()
            case .split:
                SplitPanel()
            case .text:
                TextPanel()
            case .convert:
                ConvertPanel()
            }
        }
        .frame(width: 300)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
