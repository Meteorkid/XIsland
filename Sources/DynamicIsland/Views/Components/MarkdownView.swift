import SwiftUI

struct MarkdownView: View {
    let markdown: String
    @Environment(ThemeManager.self) private var themeManager
    private let blocks: [Block]

    private var scheme: ColorScheme { themeManager.resolvedScheme }

    init(markdown: String) {
        self.markdown = markdown
        self.blocks = Self.parseBlocks(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks, id: \.self) { block in
                renderBlock(block)
            }
        }
    }

    private enum Block: Hashable {
        case heading(Int, String)
        case paragraph(String)
        case code(String)
        case listItem(String)
        case divider
    }

    private static func parseBlocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var inCodeBlock = false
        var codeLines: [String] = []

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let str = String(line)

            if str.hasPrefix("```") {
                if inCodeBlock {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(str)
                continue
            }

            if str.hasPrefix("### ") {
                blocks.append(.heading(3, String(str.dropFirst(4))))
            } else if str.hasPrefix("## ") {
                blocks.append(.heading(2, String(str.dropFirst(3))))
            } else if str.hasPrefix("# ") {
                blocks.append(.heading(1, String(str.dropFirst(2))))
            } else if str.hasPrefix("- ") || str.hasPrefix("* ") {
                blocks.append(.listItem(String(str.dropFirst(2))))
            } else if str.hasPrefix("---") || str.hasPrefix("***") {
                blocks.append(.divider)
            } else if !str.trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(.paragraph(str))
            }
        }

        if !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }

        return blocks
    }

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(.system(size: headingSize(level), weight: .bold))
                .foregroundStyle(IslandStyle.primaryText)

        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(.system(size: 11))
                .foregroundStyle(IslandStyle.secondaryText)

        case .code(let code):
            Text(code)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.green.opacity(0.8))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(IslandStyle.codeWell(for: scheme))
                .clipShape(RoundedRectangle(cornerRadius: 4))

        case .listItem(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.system(size: 11))
                    .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
                Text(inlineMarkdown(text))
                    .font(.system(size: 11))
                    .foregroundStyle(IslandStyle.secondaryText)
            }

        case .divider:
            Divider().background(IslandStyle.divider(for: scheme).opacity(IslandStyle.dividerOpacity(for: scheme)))
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 15
        case 2: return 13
        default: return 12
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
