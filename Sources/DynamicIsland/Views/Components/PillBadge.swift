import SwiftUI

struct PillBadge: View {
    let session: AgentSession
    var compact: Bool = false
    @Environment(ThemeManager.self) private var themeManager

    private var scheme: ColorScheme { themeManager.resolvedScheme }

    private var statusColor: Color {
        switch session.status {
        case .active, .thinking: .blue
        case .idle, .completed: .green
        case .waitingPermission, .waitingAnswer, .waitingPlanReview: .orange
        case .error: .red
        case .compacting: .yellow
        }
    }

    var body: some View {
        if compact {
            compactBadge
        } else {
            expandedBadge
        }
    }

    private var compactBadge: some View {
        ZStack {
            Circle()
                .fill(session.agentType.color.opacity(0.15))
                .frame(width: 24, height: 24)
                .overlay {
                    Circle().strokeBorder(statusColor.opacity(0.8), lineWidth: 1.5)
                }

            Image(systemName: session.agentType.iconSymbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(session.agentType.color)

            if session.status == .waitingPermission || session.status == .waitingAnswer {
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                    .overlay {
                        Circle().strokeBorder(.black, lineWidth: 1.5)
                    }
                    .offset(x: 8, y: -8)
            }
        }
    }

    private var expandedBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: session.agentType.iconSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(session.agentType.color)

            VStack(alignment: .leading, spacing: 0) {
                Text(session.agentType.shortName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IslandStyle.primaryText)
                Text(session.lastActivity)
                    .font(.system(size: 8))
                    .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(session.agentType.color.opacity(0.12))
        .clipShape(Capsule())
    }
}
