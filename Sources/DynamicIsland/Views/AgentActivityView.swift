import SwiftUI

struct AgentActivityView: View {
    @Environment(ThemeManager.self) private var themeManager
    let event: ToolEvent

    private var scheme: ColorScheme { themeManager.resolvedScheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 10))
                    .foregroundStyle(iconColor)
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(event.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(IslandStyle.primaryText)

                        if event.isComplete {
                            Image(systemName: "checkmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.green.opacity(0.7))
                        }
                    }

                    Text(event.summary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
                        .lineLimit(2)
                }

                Spacer()

                if let added = event.linesAdded, let removed = event.linesRemoved {
                    HStack(spacing: 4) {
                        Text("+\(added)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.green.opacity(0.7))
                        Text("-\(removed)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.red.opacity(0.7))
                    }
                } else if let lines = event.linesRead, lines > 0 {
                    Text("\(lines) lines")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.blue.opacity(0.6))
                }
            }

            // Test result details
            if let tr = event.testResults, tr.total > 0 {
                HStack(spacing: 6) {
                    if tr.passed > 0 {
                        Label("\(tr.passed) passed", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green.opacity(0.7))
                    }
                    if tr.failed > 0 {
                        Label("\(tr.failed) failed", systemImage: "xmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    if tr.skipped > 0 {
                        Label("\(tr.skipped) skipped", systemImage: "minus.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow.opacity(0.6))
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }

    private var iconName: String {
        switch event.tool.lowercased() {
        case "read", "readfile": return "doc.text"
        case "write", "writefile": return "doc.text.fill"
        case "edit", "editfile", "str_replace": return "pencil"
        case "bash", "shell", "terminal": return "terminal"
        case "search", "grep", "ripgrep": return "magnifyingglass"
        case "glob", "find", "ls", "list": return "folder"
        default: return "gearshape"
        }
    }

    private var iconColor: Color {
        switch event.tool.lowercased() {
        case "read", "readfile": return .blue.opacity(0.7)
        case "write", "writefile": return .orange.opacity(0.7)
        case "edit", "editfile", "str_replace": return .yellow.opacity(0.7)
        case "bash", "shell", "terminal": return .green.opacity(0.7)
        case "search", "grep", "ripgrep": return .purple.opacity(0.7)
        default: return IslandStyle.secondaryText
        }
    }
}
