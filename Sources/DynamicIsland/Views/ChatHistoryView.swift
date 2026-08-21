import SwiftUI

/// 会话历史视图：按时间顺序渲染用户与代理之间的对话气泡。
struct ChatHistoryView: View {
    let session: AgentSession

    @Environment(ThemeManager.self) private var themeManager

    private var scheme: ColorScheme { themeManager.resolvedScheme }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(session.chatHistory) { message in
                    messageBubble(message)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - 单条消息气泡

    private func messageBubble(_ message: ChatMessage) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
            bubbleHeader(message)
            contentBubble(message)
        }
    }

    private func bubbleHeader(_ message: ChatMessage) -> some View {
        HStack(spacing: 4) {
            if message.role == .user {
                Spacer()
            }

            Image(systemName: message.role == .user ? "person.fill" : "sparkles")
                .font(.system(size: 8))
                .foregroundStyle(authorIconColor(for: message))

            Text(authorName(for: message))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(IslandStyle.tertiaryText(for: scheme))

            Text(message.timestamp, style: .time)
                .font(.system(size: 8))
                .foregroundStyle(IslandStyle.tertiaryText(for: scheme).opacity(0.6))

            if message.role != .user {
                Spacer()
            }
        }
    }

    private func contentBubble(_ message: ChatMessage) -> some View {
        Text(message.content)
            .font(.system(size: 11))
            .foregroundStyle(message.role == .user ? IslandStyle.primaryText : IslandStyle.secondaryText)
            .lineLimit(message.role == .user ? 3 : 10)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(bubbleFill(for: message))
            )
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private func authorName(for message: ChatMessage) -> String {
        message.role == .user ? "You" : session.agentType.shortName
    }

    private func authorIconColor(for message: ChatMessage) -> Color {
        message.role == .user
            ? session.agentType.color.opacity(0.6)
            : IslandStyle.tertiaryText(for: scheme)
    }

    private func bubbleFill(for message: ChatMessage) -> Color {
        message.role == .user
            ? session.agentType.color.opacity(0.1)
            : IslandStyle.insetFill(for: scheme)
    }
}
