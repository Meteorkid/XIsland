import SwiftUI

/// 轻量 Markdown 渲染器：仅支持计划/说明中会用到的标题、段落、代码块、
/// 列表项与分隔线，行内文本交给 `AttributedString(markdown:)` 处理。
struct MarkdownView: View {
    let markdown: String

    @Environment(ThemeManager.self) private var themeManager

    private let elements: [MarkdownBlock]

    private var scheme: ColorScheme { themeManager.resolvedScheme }

    init(markdown: String) {
        self.markdown = markdown
        self.elements = Self.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(elements, id: \.self) { element in
                render(element)
            }
        }
    }

    // MARK: - 块模型

    private enum MarkdownBlock: Hashable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case code(String)
        case listItem(String)
        case divider
    }

    // MARK: - 解析

    private static func parse(_ markdown: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var inFence = false
        var codeBuffer: [String] = []

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if line.hasPrefix("```") {
                if inFence {
                    result.append(.code(codeBuffer.joined(separator: "\n")))
                    codeBuffer.removeAll(keepingCapacity: true)
                    inFence = false
                } else {
                    inFence = true
                }
                continue
            }

            if inFence {
                codeBuffer.append(line)
                continue
            }

            if let block = classify(line) {
                result.append(block)
            }
        }

        // 未闭合的围栏：把剩余缓冲行整体收作一个代码块（为空则忽略，保持与原行为一致）。
        if !codeBuffer.isEmpty {
            result.append(.code(codeBuffer.joined(separator: "\n")))
        }

        return result
    }

    /// 将一行普通文本归类为对应块；空行 / 纯空白行返回 nil 表示跳过。
    private static func classify(_ line: String) -> MarkdownBlock? {
        if line.hasPrefix("### ") { return .heading(level: 3, text: String(line.dropFirst(4))) }
        if line.hasPrefix("## ")  { return .heading(level: 2, text: String(line.dropFirst(3))) }
        if line.hasPrefix("# ")   { return .heading(level: 1, text: String(line.dropFirst(2))) }
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return .listItem(String(line.dropFirst(2)))
        }
        if line.hasPrefix("---") || line.hasPrefix("***") { return .divider }
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        return .paragraph(line)
    }

    // MARK: - 渲染

    @ViewBuilder
    private func render(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(.system(size: headingFontSize(level), weight: .bold))
                .foregroundStyle(IslandStyle.primaryText)

        case .paragraph(let text):
            Text(inlineText(text))
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
                Text(inlineText(text))
                    .font(.system(size: 11))
                    .foregroundStyle(IslandStyle.secondaryText)
            }

        case .divider:
            Divider()
                .background(IslandStyle.divider(for: scheme).opacity(IslandStyle.dividerOpacity(for: scheme)))
        }
    }

    private func headingFontSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 15
        case 2: return 13
        default: return 12
        }
    }

    private func inlineText(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
