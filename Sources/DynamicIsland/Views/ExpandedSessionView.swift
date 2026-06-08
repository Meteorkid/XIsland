import SwiftUI

struct ExpandedSessionView: View {
    let session: AgentSession
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sessionHeader
            Divider().background(.white.opacity(0.08))
            promptSection
            Divider().background(.white.opacity(0.08))
            activityFeed
        }
    }

    private var sessionHeader: some View {
        HStack(spacing: 10) {
            AgentIcon(agentType: session.agentType, size: 28, status: session.status)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.agentType.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    Text(session.terminal.isEmpty ? session.agentType.shortName : session.terminal)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                    Text(session.formattedDuration)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }

            Spacer()

            statusBadge

            Button {
                TerminalJumpManager.jump(to: session)
                onDismiss?()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                    Text(L10n.jumpTitle)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(IslandStyle.insetFill)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You:")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
            Text(session.prompt)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var activityFeed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(session.events.suffix(20)) { event in
                    AgentActivityView(event: event)
                }
                if let tool = session.currentTool {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                        Text("Running \(tool)...")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 200)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch session.status {
        case .active:
            badgeLabel(L10n.running, color: .blue)
        case .thinking:
            badgeLabel(L10n.thinking, color: .blue)
        case .compacting:
            badgeLabel(L10n.compacting, color: .yellow)
        case .waitingPermission:
            badgeLabel(L10n.permission, color: .orange)
        case .waitingAnswer:
            badgeLabel(L10n.question, color: .blue)
        case .waitingPlanReview:
            badgeLabel(L10n.review, color: .purple)
        case .idle:
            badgeLabel(L10n.idle, color: .green)
        case .completed:
            badgeLabel(L10n.done, color: .green)
        case .error:
            badgeLabel(L10n.error, color: .red)
        }
    }

    private func badgeLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}
