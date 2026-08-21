import SwiftUI

/// 会话状态徽章：紧凑态为圆形图标，展开态为带文字的药丸。
struct PillBadge: View {
    let session: AgentSession
    var compact: Bool = false

    @Environment(ThemeManager.self) private var themeManager

    private var scheme: ColorScheme { themeManager.resolvedScheme }

    var body: some View {
        if compact {
            compactPill
        } else {
            fullPill
        }
    }

    // MARK: - 状态色

    private var statusTint: Color {
        switch session.status {
        case .active, .thinking: .blue
        case .idle, .completed: .green
        case .waitingPermission, .waitingAnswer, .waitingPlanReview: .orange
        case .error: .red
        case .compacting: .yellow
        }
    }

    private var showsAlertDot: Bool {
        session.status == .waitingPermission || session.status == .waitingAnswer
    }

    // MARK: - 紧凑态

    private var compactPill: some View {
        ZStack {
            Circle()
                .fill(session.agentType.color.opacity(0.15))
                .frame(width: 24, height: 24)
                .overlay {
                    Circle().strokeBorder(statusTint.opacity(0.8), lineWidth: 1.5)
                }

            Image(systemName: session.agentType.iconSymbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(session.agentType.color)

            if showsAlertDot {
                alertDot
            }
        }
    }

    private var alertDot: some View {
        Circle()
            .fill(.orange)
            .frame(width: 7, height: 7)
            .overlay {
                Circle().strokeBorder(.black, lineWidth: 1.5)
            }
            .offset(x: 8, y: -8)
    }

    // MARK: - 展开态

    private var fullPill: some View {
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
