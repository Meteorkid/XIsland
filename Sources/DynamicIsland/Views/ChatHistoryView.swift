import SwiftUI

struct ChatHistoryView: View {
    let session: AgentSession
    @Environment(ThemeManager.self) private var themeManager

    private var scheme: ColorScheme { themeManager.resolvedScheme }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(session.chatHistory) { message in
                    chatBubble(message)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func chatBubble(_ message: ChatMessage) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
            HStack(spacing: 4) {
                if message.role == .user {
                    Spacer()
                }
                Image(systemName: message.role == .user ? "person.fill" : "sparkles")
                    .font(.system(size: 8))
                    .foregroundStyle(message.role == .user ? session.agentType.color.opacity(0.6) : IslandStyle.tertiaryText(for: scheme))
                Text(message.role == .user ? "You" : session.agentType.shortName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
                Text(message.timestamp, style: .time)
                    .font(.system(size: 8))
                    .foregroundStyle(IslandStyle.tertiaryText(for: scheme).opacity(0.6))
                if message.role != .user {
                    Spacer()
                }
            }

            Text(message.content)
                .font(.system(size: 11))
                .foregroundStyle(message.role == .user ? IslandStyle.primaryText : IslandStyle.secondaryText)

                .lineLimit(message.role == .user ? 3 : 10)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(message.role == .user
                              ? session.agentType.color.opacity(0.1)
                              : IslandStyle.insetFill(for: scheme))
                )
                .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        }
    }
}
