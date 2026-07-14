import SwiftUI

/// Agent Flow 区域：以工作目录为单位聚合展示阻塞会话，提供一键跳转恢复。
///
/// 设计原则：
/// - 纯展示层，只消费 `AgentFlowProject` 数据，不在 View 内重复业务判定。
/// - 仅在存在阻塞时展示项目卡片；无阻塞时显示正向空状态文案。
/// - 复用 `TerminalJumpManager.jump(to:)` 跳转能力，安全降级。
/// - 保持 macOS 灵动岛紧凑层级：卡片可折叠，阻塞行单行紧凑。
struct AgentFlowRegion: View {
    /// 已按阻塞优先级 + 最近活动时间排序的项目列表（由调用方通过 `AgentFlowAggregator.group` 生成）。
    let projects: [AgentFlowProject]
    /// 跳转完成后回调（与 SessionListView 的 onJump 一致，用于父视图保持面板状态）。
    var onJump: (() -> Void)?

    @Environment(ThemeManager.self) private var themeManager
    @State private var expandedProjectIds: Set<String> = []

    private var scheme: ColorScheme { themeManager.resolvedScheme }

    /// 仅展示有阻塞的项目，保持面板紧凑。
    private var blockedProjects: [AgentFlowProject] {
        Self.blockedProjects(from: projects)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            regionHeader

            if blockedProjects.isEmpty {
                emptyState
            } else {
                VStack(spacing: 6) {
                    ForEach(blockedProjects) { project in
                        AgentFlowProjectCard(
                            project: project,
                            isExpanded: expandedProjectIds.contains(project.id),
                            onToggle: { toggle(project.id) },
                            onJump: { handleJump() }
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityIdentifier(TestAccessibility.agentFlowRegion)
    }

    // MARK: - Header

    private var regionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.hexagonpath")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(IslandStyle.accent(for: scheme))
            Text(L10n.agentFlow)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(IslandStyle.primaryText)

            if Self.hasAnyBlocker(projects) {
                Text("\(Self.blockedProjectsCount(projects))·\(Self.totalBlockersCount(projects))")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green.opacity(0.7))
            Text(L10n.agentFlowEmpty)
                .font(.system(size: 10))
                .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(IslandStyle.insetFill(for: scheme))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Actions

    private func toggle(_ id: String) {
        if expandedProjectIds.contains(id) {
            expandedProjectIds.remove(id)
        } else {
            expandedProjectIds.insert(id)
        }
    }

    private func handleJump() {
        onJump?()
    }

    // MARK: - Pure Helpers (for testability)

    /// 是否任意项目存在阻塞。
    static func hasAnyBlocker(_ projects: [AgentFlowProject]) -> Bool {
        projects.contains { $0.hasBlockers }
    }

    /// 仅返回有阻塞的项目，保持原排序（由聚合器保证阻塞优先）。
    static func blockedProjects(from projects: [AgentFlowProject]) -> [AgentFlowProject] {
        projects.filter { $0.hasBlockers }
    }

    /// 有阻塞的项目数。
    static func blockedProjectsCount(_ projects: [AgentFlowProject]) -> Int {
        blockedProjects(from: projects).count
    }

    /// 所有项目阻塞会话总数。
    static func totalBlockersCount(_ projects: [AgentFlowProject]) -> Int {
        projects.reduce(0) { $0 + $1.blockedCount }
    }
}

// MARK: - AgentFlowProjectCard

/// 可展开的项目卡片：折叠态显示项目名 + 阻塞/活跃计数 + 最紧急状态；展开后列出阻塞会话。
struct AgentFlowProjectCard: View {
    let project: AgentFlowProject
    let isExpanded: Bool
    var onToggle: () -> Void
    var onJump: () -> Void

    @Environment(ThemeManager.self) private var themeManager

    private var scheme: ColorScheme { themeManager.resolvedScheme }

    /// 最紧急阻塞类型（blockers 已按优先级排序，取首个）。
    private var mostUrgentKind: AgentFlowBlockerKind? {
        project.blockers.first?.kind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                Divider()
                    .background(IslandStyle.divider(for: scheme).opacity(IslandStyle.dividerOpacity(for: scheme)))
                    .padding(.horizontal, 10)

                VStack(spacing: 4) {
                    ForEach(project.blockers) { blocker in
                        AgentFlowBlockerRow(blocker: blocker, onJump: onJump)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(IslandStyle.cardRest(for: scheme))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    IslandStyle.cardStrokeColor(for: scheme)
                        .opacity(IslandStyle.cardStrokeRest(for: scheme)),
                    lineWidth: 0.5
                )
        )
        .accessibilityIdentifier(TestAccessibility.agentFlowProjectCard(id: project.id))
    }

    private var header: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(IslandStyle.secondaryText)

                Text(project.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IslandStyle.primaryText)
                    .lineLimit(1)

                Spacer()

                // 阻塞 / 活跃 计数
                HStack(spacing: 4) {
                    if project.blockedCount > 0 {
                        Text("\(project.blockedCount)\(L10n.agentFlowBlockedUnit)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                    if project.activeCount > 0 {
                        Text("\(project.activeCount)\(L10n.agentFlowActiveUnit)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
                    }
                }

                // 最紧急状态徽标
                if let kind = mostUrgentKind {
                    kindBadge(kind)
                }

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func kindBadge(_ kind: AgentFlowBlockerKind) -> some View {
        Text(kind.displayName)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(badgeColor(kind))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(badgeColor(kind).opacity(0.15))
            .clipShape(Capsule())
    }

    private func badgeColor(_ kind: AgentFlowBlockerKind) -> Color {
        switch kind {
        case .waitingHumanInput: .blue
        case .waitingPermission: .orange
        case .toolFailure: .red
        case .none: .gray
        }
    }
}

// MARK: - AgentFlowBlockerRow

/// 阻塞会话行：Agent 类型 + 会话标题 + 阻塞原因 + 相对状态 + 前往处理按钮。
struct AgentFlowBlockerRow: View {
    let blocker: AgentFlowBlocker
    var onJump: () -> Void

    @Environment(ThemeManager.self) private var themeManager

    private var scheme: ColorScheme { themeManager.resolvedScheme }
    private var session: AgentSession { blocker.session }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AgentIcon(agentType: session.agentType, size: 18, status: session.status)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.agentType.shortName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(session.agentType.color)
                    Text(session.displayTitle)
                        .font(.system(size: 10))
                        .foregroundStyle(IslandStyle.primaryText)
                        .lineLimit(1)
                }

                if !blocker.reason.isEmpty {
                    Text(blocker.reason)
                        .font(.system(size: 9))
                        .foregroundStyle(IslandStyle.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 4) {
                    Text(blocker.kind.displayName)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(badgeColor)
                    Text("·")
                        .font(.system(size: 8))
                        .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
                    Text(session.lastActivity)
                        .font(.system(size: 8))
                        .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                TerminalJumpManager.jump(to: session)
                onJump()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 9))
                    Text(L10n.agentFlowGoHandle)
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(IslandStyle.primaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(IslandStyle.insetFill(for: scheme))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(TestAccessibility.agentFlowJumpButton(id: session.id))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(IslandStyle.insetFill(for: scheme).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityIdentifier(TestAccessibility.agentFlowBlockerRow(id: session.id))
    }

    private var badgeColor: Color {
        switch blocker.kind {
        case .waitingHumanInput: .blue
        case .waitingPermission: .orange
        case .toolFailure: .red
        case .none: .gray
        }
    }
}
