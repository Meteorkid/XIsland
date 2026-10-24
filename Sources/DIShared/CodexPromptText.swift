import Foundation

/// Codex 原生问答回复的可读正文；不把问题 ID 等内部元数据当成用户消息。
public enum CodexPromptText {
    private static let opening = "<send_user_message_question_reply>"
    private static let closing = "</send_user_message_question_reply>"

    private struct Reply: Decodable {
        let answer: String
    }

    public static func normalized(_ raw: String) -> String {
        var text = raw
        // 桥接、旧桥接入站与历史标题都可调用；有界展开保证保留包装不会再次露出。
        // 仅解释精确的顶层保留标签，普通 XML、行内提及和代码围栏保持原样。
        for _ in 0..<8 {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(opening) else { return text }
            guard let end = trimmed.range(of: closing, options: .backwards) else { return "" }
            let body = trimmed[trimmed.index(trimmed.startIndex, offsetBy: opening.count)..<end.lowerBound]
            do {
                let replies = try JSONDecoder().decode([Reply].self, from: Data(body.utf8))
                let suffix = String(trimmed[end.upperBound...])
                text = (replies.map(\.answer) + [suffix])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            } catch {
                // 空或损坏的回复不能用包装内容覆盖已有任务标题。
                return ""
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(opening) ? "" : text
    }
}
