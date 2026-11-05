import SwiftUI

/// 审批上下文地图：把会话中的任务、计划、文件变更与当前待审批请求
/// 聚合成可折叠的节点列表，帮助在批准/拒绝前快速浏览结构。
///
/// 设计约束：
/// - 只消费 `ApprovalContextMapBuilder` 的派生数据，不在 View 内重复业务判定；
/// - 折叠态只显示一行变更摘要，展开态才渲染节点列表，保持灵动岛紧凑；
/// - 变更节点沿用 Midmap 式标记：绿色新建、橙色修改、红色删除。
struct ApprovalContextMapView: View {
    let session: AgentSession
    let pendingKind: ApprovalContextMap.PendingNode.Kind

    @Environment(ThemeManager.self) private var themeManager
    @State private var isExpanded = false
    @State private var changeFilter: ApprovalContextMap.ChangeNode.Kind?
    @AppStorage(ApprovalContextMapSettings.enabledKey) private var isEnabled = true

    /// 展开后变更节点的展示上限，超出部分折叠成「还有 N 个」。
    static let visibleChangeLimit = 8

    init(
        session: AgentSession,
        pendingKind: ApprovalContextMap.PendingNode.Kind,
        initiallyExpanded: Bool = false
    ) {
        self.session = session
        self.pendingKind = pendingKind
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var scheme: ColorScheme { themeManager.resolvedScheme }

    var body: some View {
        let map = ApprovalContextMapBuilder.build(session: session, pendingKind: pendingKind)
        if Self.shouldShow(map: map, enabled: isEnabled) {
            VStack(alignment: .leading, spacing: 6) {
                toggleRow(map)
                if isExpanded { nodeList(map) }
            }
            .padding(8)
            .background(IslandStyle.insetFill(for: scheme).opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(TestAccessibility.approvalContextMap)
        }
    }

    // MARK: - 折叠摘要行

    private func toggleRow(_ map: ApprovalContextMap) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IslandStyle.accent(for: scheme))
                    Text(L10n.approvalContextMap)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IslandStyle.primaryText)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(TestAccessibility.approvalContextMapToggle)
            .accessibilityLabel(L10n.approvalContextMap)
            .accessibilityValue(Self.summaryText(for: map))

            Spacer(minLength: 6)

            if map.changes.isEmpty {
                Text(L10n.approvalContextMapNoChanges)
                    .font(.system(size: 10))
                    .foregroundStyle(IslandStyle.secondaryText)
                    .lineLimit(1)
            } else {
                filterChips(map)
            }
        }
    }

    // MARK: - 展开节点列表

    private func nodeList(_ map: ApprovalContextMap) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = map.reason, !reason.isEmpty {
                reasonRow(reason)
            }
            if let task = map.task {
                section(L10n.approvalContextMapTask) { taskRow(task) }
            }
            if !map.plan.isEmpty {
                section(L10n.approvalContextMapPlan) { planRows(map.plan) }
            }
            if !map.changes.isEmpty {
                let filtered = Self.filteredChanges(map.changes, filter: changeFilter)
                if !filtered.isEmpty {
                    section(L10n.approvalContextMapChanges) { changeRows(filtered) }
                }
            }
            if let pending = map.pending {
                section(L10n.approvalContextMapPending) { pendingRow(pending) }
            }
        }
    }

    private func reasonRow(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(L10n.approvalContextMapReasonScope)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
            Text(reason)
                .font(.system(size: 10))
                .foregroundStyle(IslandStyle.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 按类型筛选

    private func filterChips(_ map: ApprovalContextMap) -> some View {
        HStack(spacing: 4) {
            if map.createdCount > 0 {
                filterChip(.created, count: map.createdCount)
            }
            if map.modifiedCount > 0 {
                filterChip(.modified, count: map.modifiedCount)
            }
            if map.deletedCount > 0 {
                filterChip(.deleted, count: map.deletedCount)
            }
        }
    }

    private func filterChip(_ kind: ApprovalContextMap.ChangeNode.Kind, count: Int) -> some View {
        let color = Self.changeColor(for: kind)
        let selected = changeFilter == kind
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if selected {
                    changeFilter = nil
                } else {
                    changeFilter = kind
                    isExpanded = true
                }
            }
        } label: {
            Text(Self.filterLabel(for: kind, count: count))
                .font(.system(size: 9, weight: selected ? .semibold : .regular))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(selected ? 0.22 : 0.10))
                .clipShape(Capsule())
                .overlay {
                    Capsule().strokeBorder(color.opacity(selected ? 0.55 : 0), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.filterLabel(for: kind, count: count))
        .accessibilityIdentifier(TestAccessibility.approvalContextMapFilter(Self.kindKey(kind)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
            content()
        }
    }

    private func taskRow(_ task: ApprovalContextMap.TaskNode) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "scope")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(IslandStyle.accent(for: scheme))
                .padding(.top, 1)
            Text(task.title)
                .font(.system(size: 11))
                .foregroundStyle(IslandStyle.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(L10n.approvalContextMapTask): \(task.title)")
    }

    private func planRows(_ nodes: [ApprovalContextMap.PlanNode]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                        .font(.system(size: 10))
                        .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
                    Text(node.title)
                        .font(.system(size: 11))
                        .foregroundStyle(IslandStyle.primaryText)
                        .lineLimit(1)
                }
                .padding(.leading, CGFloat(max(0, node.depth - 1)) * 10)
            }
        }
    }

    private func changeRows(_ changes: [ApprovalContextMap.ChangeNode]) -> some View {
        let visible = Array(changes.prefix(Self.visibleChangeLimit))
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, change in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Self.changeColor(for: change.kind))
                        .frame(width: 6, height: 6)
                    Text(change.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(IslandStyle.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(change.path)
                    Spacer(minLength: 4)
                    Text(Self.changeLabel(for: change.kind))
                        .font(.system(size: 9))
                        .foregroundStyle(Self.changeColor(for: change.kind).opacity(0.9))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Self.changeLabel(for: change.kind)): \(change.path)")
            }
            if changes.count > Self.visibleChangeLimit {
                Text(L10n.approvalContextMapMore(changes.count - Self.visibleChangeLimit))
                    .font(.system(size: 9))
                    .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
            }
        }
    }

    private func pendingRow(_ pending: ApprovalContextMap.PendingNode) -> some View {
        let color = Self.pendingColor(for: pending.kind)
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: Self.pendingIcon(for: pending.kind))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.pendingTitle(for: pending))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IslandStyle.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = pending.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            Text(Self.pendingLabel(for: pending.kind))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.14))
                .clipShape(Capsule())
        }
        .padding(6)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(color.opacity(0.35), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.pendingLabel(for: pending.kind)): \(Self.pendingTitle(for: pending))")
    }

    // MARK: - 纯函数（供测试与复用）

    /// 按类型筛选变更节点；nil 表示全部。
    static func filteredChanges(
        _ changes: [ApprovalContextMap.ChangeNode],
        filter: ApprovalContextMap.ChangeNode.Kind?
    ) -> [ApprovalContextMap.ChangeNode] {
        guard let filter else { return changes }
        return changes.filter { $0.kind == filter }
    }

    static func filterLabel(for kind: ApprovalContextMap.ChangeNode.Kind, count: Int) -> String {
        switch kind {
        case .created: return L10n.approvalContextMapCreated(count)
        case .modified: return L10n.approvalContextMapModified(count)
        case .deleted: return L10n.approvalContextMapDeleted(count)
        }
    }

    static func kindKey(_ kind: ApprovalContextMap.ChangeNode.Kind) -> String {
        switch kind {
        case .created: return "created"
        case .modified: return "modified"
        case .deleted: return "deleted"
        }
    }

    /// 开关关闭或没有可展示内容时隐藏整个地图。
    static func shouldShow(map: ApprovalContextMap, enabled: Bool) -> Bool {
        enabled && map.hasContent
    }

    /// 折叠摘要，例如 “3 新建 · 2 修改 · 1 删除”；没有文件变更时显示占位文案。
    static func summaryText(for map: ApprovalContextMap) -> String {
        var parts: [String] = []
        if map.createdCount > 0 { parts.append(L10n.approvalContextMapCreated(map.createdCount)) }
        if map.modifiedCount > 0 { parts.append(L10n.approvalContextMapModified(map.modifiedCount)) }
        if map.deletedCount > 0 { parts.append(L10n.approvalContextMapDeleted(map.deletedCount)) }
        return parts.isEmpty ? L10n.approvalContextMapNoChanges : parts.joined(separator: " · ")
    }

    static func changeColor(for kind: ApprovalContextMap.ChangeNode.Kind) -> Color {
        switch kind {
        case .created: return .green
        case .modified: return .orange
        case .deleted: return .red
        }
    }

    static func changeLabel(for kind: ApprovalContextMap.ChangeNode.Kind) -> String {
        switch kind {
        case .created: return L10n.approvalContextMapCreatedLabel
        case .modified: return L10n.approvalContextMapModifiedLabel
        case .deleted: return L10n.approvalContextMapDeletedLabel
        }
    }

    static func pendingIcon(for kind: ApprovalContextMap.PendingNode.Kind) -> String {
        switch kind {
        case .permission: return "exclamationmark.triangle.fill"
        case .question: return "questionmark.bubble"
        case .planReview: return "doc.text.magnifyingglass"
        }
    }

    static func pendingColor(for kind: ApprovalContextMap.PendingNode.Kind) -> Color {
        switch kind {
        case .permission: return .orange
        case .question: return .blue
        case .planReview: return .purple
        }
    }

    static func pendingLabel(for kind: ApprovalContextMap.PendingNode.Kind) -> String {
        switch kind {
        case .permission: return L10n.permission
        case .question: return L10n.question
        case .planReview: return L10n.review
        }
    }

    /// 计划审阅没有标题时回退到本地化名称，避免出现空节点。
    static func pendingTitle(for pending: ApprovalContextMap.PendingNode) -> String {
        let title = pending.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? pendingLabel(for: pending.kind) : title
    }
}
