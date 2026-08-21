import SwiftUI

/// 展开态会话详情：标题、用户提示词、以及最近的活动事件流。
struct ExpandedSessionView: View {
    let session: AgentSession
    var onDismiss: (() -> Void)?

    @Environment(ThemeManager.self) private var themeManager

    private var scheme: ColorScheme { themeManager.resolvedScheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            separator
            promptSection
            separator
            activityFeed
        }
    }

    private var separator: some View {
        Divider()
            .background(IslandStyle.divider(for: scheme).opacity(IslandStyle.dividerOpacity(for: scheme)))
    }

    // MARK: - 标题栏

    private var headerBar: some View {
        HStack(spacing: 10) {
            AgentIcon(agentType: session.agentType, size: 28, status: session.status)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.agentType.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IslandStyle.primaryText)
                HStack(spacing: 6) {
                    Text(session.terminal.isEmpty ? session.agentType.shortName : session.terminal)
                        .font(.system(size: 10))
                        .foregroundStyle(IslandStyle.secondaryText)
                    Text(session.formattedDuration)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
                }
            }

            Spacer()

            statusBadge

            jumpButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var jumpButton: some View {
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
            .foregroundStyle(IslandStyle.primaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(IslandStyle.insetFill(for: scheme))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 提示词

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You:")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(IslandStyle.secondaryText)
            Text(session.prompt)
                .font(.system(size: 12))
                .foregroundStyle(IslandStyle.primaryText)
                .lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - 活动流

    private var activityFeed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(session.events.suffix(20)) { event in
                    AgentActivityView(event: event)
                }
                if let tool = session.currentTool {
                    runningIndicator(tool)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 200)
    }

    private func runningIndicator(_ tool: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)
            Text("Running \(tool)...")
                .font(.system(size: 11))
                .foregroundStyle(IslandStyle.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }

    // MARK: - 状态徽章

    private var statusBadge: some View {
        let (label, tint) = statusDescriptor
        return badgeLabel(label, tint: tint)
    }

    /// 状态 → (文案, 颜色) 的映射。
    private var statusDescriptor: (text: String, tint: Color) {
        switch session.status {
        case .active:            (L10n.running, .blue)
        case .thinking:          (L10n.thinking, .blue)
        case .compacting:        (L10n.compacting, .yellow)
        case .waitingPermission: (L10n.permission, .orange)
        case .waitingAnswer:     (L10n.question, .blue)
        case .waitingPlanReview: (L10n.review, .purple)
        case .idle:              (L10n.idle, .green)
        case .completed:         (L10n.done, .green)
        case .error:             (L10n.error, .red)
        }
    }

    private func badgeLabel(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15))
            .clipShape(Capsule())
    }
}
