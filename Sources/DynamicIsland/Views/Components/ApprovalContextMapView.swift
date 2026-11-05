import SwiftUI
import AppKit

/// 审批上下文地图：把会话中的任务、计划、文件变更与当前待审批请求
/// 聚合成可折叠的节点列表，帮助在批准/拒绝前快速浏览结构。
///
/// 设计约束：
/// - 只消费 ApprovalContextMapBuilder 的派生数据，不在 View 内重复业务判定；
/// - 折叠态只显示一行变更摘要，展开态才渲染节点列表，保持灵动岛紧凑；
/// - 变更节点沿用 Midmap 式标记：绿色新建、橙色修改、红色删除；
/// - 节点批注通过「复制预填消息 + 跳转会话」实现近似闭环，不改 agent 协议。
struct ApprovalContextMapView: View {
    let session: AgentSession
    let pendingKind: ApprovalContextMap.PendingNode.Kind
    let snapshotStore: ApprovalContextMapSnapshotStore?

    @Environment(ThemeManager.self) private var themeManager
    @Environment(SessionManager.self) private var manager
    @State private var isExpanded = false
    @State private var expandedSections: Set<SectionKind>
    @State private var changeFilter: ApprovalContextMap.ChangeNode.Kind?
    @State private var deltaExpanded = false
    @State private var previousSnapshot: ApprovalContextMapSnapshot?
    @State private var jumpState = SessionJumpState()
    @State private var annotationTarget: AnnotationTarget?
    @State private var annotationKind: AnnotationKind = .question
    @State private var annotationText = ""
    @State private var copiedHint = false
    @State private var hintDismissal: DispatchWorkItem?
    @AppStorage(ApprovalContextMapSettings.enabledKey) private var isEnabled = true

    /// 展开后变更节点的展示上限，超出部分折叠成「还有 N 个」。
    static let visibleChangeLimit = 6
    /// 上一轮差异的展示上限。
    static let visibleDeltaLimit = 4

    /// 可折叠分组：默认只展开待审批，其余显示一行摘要。
    enum SectionKind: Hashable, CaseIterable {
        case task
        case plan
        case changes
        case pending
    }

    static let defaultExpandedSections: Set<SectionKind> = [.pending]

    struct AnnotationTarget: Equatable {
        let label: String
        let title: String
    }

    enum AnnotationKind: Equatable {
        case question
        case command
    }

    init(
        session: AgentSession,
        pendingKind: ApprovalContextMap.PendingNode.Kind,
        initiallyExpanded: Bool = false,
        initiallyDeltaExpanded: Bool = false,
        initiallyExpandedSections: Set<SectionKind>? = nil,
        snapshotStore: ApprovalContextMapSnapshotStore? = nil
    ) {
        self.session = session
        self.pendingKind = pendingKind
        self.snapshotStore = snapshotStore
        _isExpanded = State(initialValue: initiallyExpanded)
        _deltaExpanded = State(initialValue: initiallyDeltaExpanded)
        _expandedSections = State(initialValue: initiallyExpandedSections ?? Self.defaultExpandedSections)
        let store = snapshotStore ?? ApprovalContextMapSnapshotStore.defaultStore()
        _previousSnapshot = State(initialValue: store?.latest(sessionID: session.id))
    }

    private var scheme: ColorScheme { themeManager.resolvedScheme }

    var body: some View {
        let map = ApprovalContextMapBuilder.build(session: session, pendingKind: pendingKind)
        let delta = previousSnapshot.map {
            ApprovalContextMapDelta.between(previous: $0, current: ApprovalContextMapSnapshot(map: map))
        }
        if Self.shouldShow(map: map, enabled: isEnabled) {
            VStack(alignment: .leading, spacing: 6) {
                toggleRow(map)
                if isExpanded {
                    nodeList(map, delta: delta)
                    if let target = annotationTarget {
                        annotationComposer(target)
                    }
                }
            }
            .padding(8)
            .background(IslandStyle.insetFill(for: scheme).opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .modifier(SessionJumpFeedback(state: jumpState))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(TestAccessibility.approvalContextMap)
        }
    }

    // MARK: - 折叠摘要与筛选

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
                    expandedSections.insert(.changes)
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
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
    }

    // MARK: - 展开节点列表

    private func nodeList(_ map: ApprovalContextMap, delta: ApprovalContextMapDelta?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = map.reason, !reason.isEmpty {
                reasonRow(reason)
            }
            if let delta, !delta.isEmpty, let previous = previousSnapshot {
                deltaSection(delta, capturedAt: previous.capturedAt)
            }
            if let task = map.task {
                collapsibleSection(.task, title: L10n.approvalContextMapTask, summary: Self.taskSummary(task)) {
                    taskRow(task)
                }
            }
            if !map.plan.isEmpty {
                collapsibleSection(.plan, title: L10n.approvalContextMapPlan, summary: Self.planSummary(map.plan)) {
                    planRows(map.plan)
                }
            }
            if !map.changes.isEmpty {
                let filtered = Self.filteredChanges(map.changes, filter: changeFilter)
                if !filtered.isEmpty {
                    collapsibleSection(.changes, title: L10n.approvalContextMapChanges,
                                       summary: Self.changeSummary(filtered)) {
                        changeRows(filtered)
                    }
                }
            }
            if let pending = map.pending {
                collapsibleSection(.pending, title: L10n.approvalContextMapPending,
                                   summary: Self.pendingSummary(pending)) {
                    pendingRow(pending)
                }
            }
        }
    }

    private func collapsibleSection<Content: View>(
        _ section: SectionKind,
        title: String,
        summary: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let expanded = expandedSections.contains(section)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { toggle(section) }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
                    Spacer(minLength: 6)
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundStyle(IslandStyle.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(TestAccessibility.approvalContextMapSection(Self.sectionKey(section)))
            .accessibilityLabel(title)
            .accessibilityValue(summary)
            if expanded { content() }
        }
    }

    private func toggle(_ section: SectionKind) {
        if expandedSections.contains(section) {
            expandedSections.remove(section)
        } else {
            expandedSections.insert(section)
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
            Spacer(minLength: 4)
            annotateButton(AnnotationTarget(label: L10n.approvalContextMapTask, title: task.title))
        }
        .accessibilityElement(children: .contain)
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
                    Spacer(minLength: 4)
                    annotateButton(AnnotationTarget(label: L10n.approvalContextMapPlan, title: node.title))
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
                    annotateButton(AnnotationTarget(label: L10n.approvalContextMapFile, title: change.path))
                }
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

    // MARK: - 较上一轮的变化

    struct DeltaRow {
        let text: String
        let color: Color
    }

    private func deltaSection(_ delta: ApprovalContextMapDelta, capturedAt: Date) -> some View {
        let rows = Self.deltaRows(delta)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { deltaExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("\(L10n.approvalContextMapDeltaTitle) · \(capturedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
                    Spacer(minLength: 4)
                    Text(Self.deltaSummary(delta))
                        .font(.system(size: 9))
                        .foregroundStyle(IslandStyle.secondaryText)
                        .lineLimit(1)
                    Image(systemName: deltaExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(TestAccessibility.approvalContextMapDeltaToggle)
            .accessibilityLabel(L10n.approvalContextMapDeltaTitle)
            .accessibilityValue(Self.deltaSummary(delta))
            if deltaExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(rows.prefix(Self.visibleDeltaLimit).enumerated()), id: \.offset) { _, row in
                        Text(row.text)
                            .font(.system(size: 10))
                            .foregroundStyle(row.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if rows.count > Self.visibleDeltaLimit {
                        Text(L10n.approvalContextMapMore(rows.count - Self.visibleDeltaLimit))
                            .font(.system(size: 9))
                            .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
                    }
                }
            }
        }
    }

    /// 差异摘要，例如 “+2 · −1 · ~1 · Plan +1 −1”；默认只展示这一行。
    static func deltaSummary(_ delta: ApprovalContextMapDelta) -> String {
        var parts: [String] = []
        if !delta.addedFiles.isEmpty { parts.append("+\(delta.addedFiles.count)") }
        if !delta.removedFiles.isEmpty { parts.append("−\(delta.removedFiles.count)") }
        if !delta.kindChangedFiles.isEmpty { parts.append("~\(delta.kindChangedFiles.count)") }
        var planParts: [String] = []
        if !delta.addedPlanTitles.isEmpty { planParts.append("+\(delta.addedPlanTitles.count)") }
        if !delta.removedPlanTitles.isEmpty { planParts.append("−\(delta.removedPlanTitles.count)") }
        if !planParts.isEmpty {
            parts.append("\(L10n.approvalContextMapPlan) \(planParts.joined(separator: " "))")
        }
        return parts.joined(separator: " · ")
    }

    static func deltaRows(_ delta: ApprovalContextMapDelta) -> [DeltaRow] {
        var rows: [DeltaRow] = []
        for path in delta.addedFiles {
            rows.append(DeltaRow(text: "+ \(path)", color: .green))
        }
        for path in delta.removedFiles {
            rows.append(DeltaRow(text: "− \(path)", color: .red))
        }
        for change in delta.kindChangedFiles {
            rows.append(DeltaRow(
                text: "~ \(change.path)：\(changeLabel(for: change.from)) → \(changeLabel(for: change.to))",
                color: .orange
            ))
        }
        for title in delta.addedPlanTitles {
            rows.append(DeltaRow(text: "+ \(L10n.approvalContextMapPlan)：\(title)", color: .purple))
        }
        for title in delta.removedPlanTitles {
            rows.append(DeltaRow(text: "− \(L10n.approvalContextMapPlan)：\(title)", color: .secondary))
        }
        return rows
    }

    // MARK: - 节点批注

    private func annotateButton(_ target: AnnotationTarget) -> some View {
        Button {
            annotationTarget = target
            annotationKind = .question
            annotationText = ""
            copiedHint = false
        } label: {
            Image(systemName: "text.bubble")
                .font(.system(size: 9))
                .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.annotationButton)
        .accessibilityIdentifier(TestAccessibility.approvalContextMapAnnotate)
        .help(L10n.annotationButton)
    }

    private func annotationComposer(_ target: AnnotationTarget) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(target.label) · \(target.title)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(IslandStyle.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button { closeAnnotation() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(IslandStyle.tertiaryText(for: scheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.annotationCancel)
                .accessibilityIdentifier(TestAccessibility.approvalContextMapAnnotationCancel)
            }
            HStack(spacing: 4) {
                annotationKindButton(.question, title: L10n.annotationQuestion)
                annotationKindButton(.command, title: L10n.annotationCommand)
            }
            TextField(L10n.annotationPlaceholder, text: $annotationText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .lineLimit(2...4)
                .padding(6)
                .background(IslandStyle.codeWell(for: scheme))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier(TestAccessibility.approvalContextMapAnnotationField)
            HStack(spacing: 6) {
                if copiedHint {
                    Text(L10n.annotationCopied)
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                }
                Spacer(minLength: 4)
                Button(L10n.annotationCopyAndJump) { submitAnnotation(target) }
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(annotationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.08 : 0.25))
                    .clipShape(Capsule())
                    .disabled(annotationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier(TestAccessibility.approvalContextMapAnnotationSubmit)
            }
        }
        .padding(6)
        .background(IslandStyle.insetFill(for: scheme).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func annotationKindButton(_ kind: AnnotationKind, title: String) -> some View {
        let selected = annotationKind == kind
        return Button {
            annotationKind = kind
        } label: {
            Text(title)
                .font(.system(size: 9, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.accentColor : IslandStyle.secondaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func submitAnnotation(_ target: AnnotationTarget) {
        let text = annotationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let message = Self.annotationMessage(kind: annotationKind, nodeLabel: target.label, title: target.title, text: text)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message, forType: .string)
        copiedHint = true
        hintDismissal?.cancel()
        let work = DispatchWorkItem { copiedHint = false }
        hintDismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        jumpState.request(session, manager: manager)
    }

    private func closeAnnotation() {
        annotationTarget = nil
        annotationText = ""
        copiedHint = false
        hintDismissal?.cancel()
        hintDismissal = nil
    }

    /// 批注预填消息：引用节点标题与用户输入，提问/命令两种措辞。
    static func annotationMessage(
        kind: AnnotationKind,
        nodeLabel: String,
        title: String,
        text: String
    ) -> String {
        let reference = nodeLabel.isEmpty ? title : "\(nodeLabel) · \(title)"
        switch kind {
        case .question:
            return String(format: L10n.annotationQuestionMessageFormat, reference, text)
        case .command:
            return String(format: L10n.annotationCommandMessageFormat, reference, text)
        }
    }

    // MARK: - 纯函数（供测试与复用）

    /// 开关关闭或没有可展示内容时隐藏整个地图。
    static func shouldShow(map: ApprovalContextMap, enabled: Bool) -> Bool {
        enabled && map.hasContent
    }

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

    // MARK: - 分组摘要（供折叠标题与测试）

    static func taskSummary(_ task: ApprovalContextMap.TaskNode) -> String {
        task.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func planSummary(_ nodes: [ApprovalContextMap.PlanNode]) -> String {
        let count = L10n.approvalContextMapItemsCount(nodes.count)
        guard let first = nodes.first?.title, !first.isEmpty else { return count }
        return "\(count) · \(first)"
    }

    static func changeSummary(_ changes: [ApprovalContextMap.ChangeNode]) -> String {
        L10n.approvalContextMapFileCount(changes.count)
    }

    static func pendingSummary(_ pending: ApprovalContextMap.PendingNode) -> String {
        pendingTitle(for: pending)
    }

    static func sectionKey(_ section: SectionKind) -> String {
        switch section {
        case .task: return "task"
        case .plan: return "plan"
        case .changes: return "changes"
        case .pending: return "pending"
        }
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
