import SwiftUI

struct MarkdownView: View {
    let markdown: String

    private var blocks: [Block] { parseBlocks() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    private enum Block {
        case heading(Int, String)
        case paragraph(String)
        case code(String)
        case listItem(String)
        case divider
    }

    private func parseBlocks() -> [Block] {
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
                .foregroundStyle(.white)

        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))

        case .code(let code):
            Text(code)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.green.opacity(0.8))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(IslandStyle.codeWell)
                .clipShape(RoundedRectangle(cornerRadius: 4))

        case .listItem(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                Text(inlineMarkdown(text))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
            }

        case .divider:
            Divider().background(.white.opacity(0.1))
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
