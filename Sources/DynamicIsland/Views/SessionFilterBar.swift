import SwiftUI

struct SessionFilterBar: View {
    @Environment(SessionManager.self) private var manager

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // 搜索框
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                    TextField(L10n.searchSessions, text: Binding(
                        get: { manager.searchText },
                        set: { manager.searchText = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .onSubmit {
                        // 键盘收起，立即过滤
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.08))
                )

                // 分组选择器
                Menu {
                    ForEach(SessionGrouping.allCases) { grouping in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                manager.grouping = grouping
                            }
                        } label: {
                            HStack {
                                Text(grouping.displayName)
                                if manager.grouping == grouping {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle\(manager.grouping == .none ? "" : ".fill")")
                        .font(.system(size: 12))
                        .foregroundStyle(manager.grouping == .none ? .white.opacity(0.5) : .cyan)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20, height: 20)
            }
            .padding(.horizontal, 12)

            // 过滤标签行
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(
                        title: L10n.filterAll,
                        isSelected: manager.activeFilter == .all,
                        action: { manager.activeFilter = .all }
                    )
                    ForEach(agentTypeFilters, id: \.rawValue) { type in
                        FilterChip(
                            title: type.shortName,
                            isSelected: manager.activeFilter == .agentType(type),
                            color: type.color,
                            action: { manager.activeFilter = .agentType(type) }
                        )
                    }
                    ForEach(statusFilters, id: \.rawValue) { status in
                        FilterChip(
                            title: status.displayName,
                            isSelected: manager.activeFilter == .status(status),
                            action: { manager.activeFilter = .status(status) }
                        )
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(IslandStyle.cardRest)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 12)
        .frame(height: 68)
    }

    /// 只显示活跃会话中实际出现的 AgentType
    private var agentTypeFilters: [AgentType] {
        let activeTypes = Set(manager.visibleSessions.map(\.agentType))
        return AgentType.allCases.filter { activeTypes.contains($0) }
    }

    /// 只显示活跃会话中实际出现的 SessionStatus
    private var statusFilters: [SessionStatus] {
        let activeStatuses = Set(manager.visibleSessions.map(\.status))
        return [.active, .thinking, .idle, .completed, .error, .compacting,
                .waitingPermission, .waitingAnswer, .waitingPlanReview]
            .filter { activeStatuses.contains($0) }
    }
}

// MARK: - FilterChip

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    var color: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isSelected ? .white.opacity(0.9) : color.opacity(0.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? color.opacity(0.25) : .white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? color.opacity(0.4) : .clear, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}
