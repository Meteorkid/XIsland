import Foundation
import DIShared

/// 审批上下文地图的用户开关。
/// 默认开启；关闭后审批卡片不再渲染地图，偏好沿用 `AppPreferences` 隔离存储。
enum ApprovalContextMapSettings {
    static let enabledKey = "approvalContextMapEnabled"

    static func isEnabled(defaults: UserDefaults = AppPreferences.defaults) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return true }
        return defaults.bool(forKey: enabledKey)
    }
}

/// 审批上下文地图：从会话现有数据聚合出「任务 → 计划 → 变更 → 待审批」四层节点。
///
/// 设计约束：
/// - 纯本地派生，只消费 `AgentSession` 已有数据，不产生额外 AI 调用；
/// - 解析保持保守：无法确定文件路径或操作类型时返回空，不猜测；
/// - 文件操作是启发式归类（Write→新建、Edit→修改、Delete→删除），
///   仅用于审批前的结构速览，不作为变更审计证据。
struct ApprovalContextMap: Equatable {
    struct TaskNode: Equatable {
        let title: String
    }

    struct PlanNode: Equatable {
        let title: String
        /// Markdown 标题层级：1 为最高层。
        let depth: Int
    }

    struct ChangeNode: Equatable {
        enum Kind: String, Codable, Equatable {
            case created
            case modified
            case deleted
        }

        let path: String
        let kind: Kind
    }

    struct PendingNode: Equatable {
        enum Kind: Equatable {
            case permission
            case question
            case planReview
        }

        let kind: Kind
        let title: String
        let detail: String?
    }

    var task: TaskNode?
    var plan: [PlanNode]
    var changes: [ChangeNode]
    var pending: PendingNode?
    /// 「原因/范围」摘要：优先取权限描述或待审计划的第一个正文段落。
    var reason: String?

    var createdCount: Int { changes.filter { $0.kind == .created }.count }
    var modifiedCount: Int { changes.filter { $0.kind == .modified }.count }
    var deletedCount: Int { changes.filter { $0.kind == .deleted }.count }

    var hasContent: Bool {
        task != nil || !plan.isEmpty || !changes.isEmpty || pending != nil
    }

    static let empty = ApprovalContextMap(task: nil, plan: [], changes: [], pending: nil, reason: nil)
}

/// 某一轮完成时的地图快照，用于和下一轮做节点变化对比。
struct ApprovalContextMapSnapshot: Codable, Equatable {
    struct FileChange: Codable, Equatable {
        let path: String
        let kind: ApprovalContextMap.ChangeNode.Kind
    }

    struct GraphNodeSnapshot: Codable, Equatable {
        let id: String
        let parentID: String?
        let title: String
        let status: ApprovalGraphNodeStatus
    }

    let capturedAt: Date
    let taskTitle: String?
    let planTitles: [String]
    let changes: [FileChange]
    /// 只记录用户已保留的显式节点；待处理提案不能冒充已完成事实。
    let graphNodes: [GraphNodeSnapshot]?

    init(map: ApprovalContextMap, graph: ApprovalGraphDocument? = nil, capturedAt: Date = Date()) {
        self.capturedAt = capturedAt
        self.taskTitle = map.task?.title
        self.planTitles = map.plan.map(\.title)
        self.changes = map.changes.map { FileChange(path: $0.path, kind: $0.kind) }
        self.graphNodes = graph?.acceptedNodes.map {
            GraphNodeSnapshot(id: $0.id, parentID: $0.parentID, title: $0.title, status: $0.status)
        }
    }
}

/// 上一轮快照与当前地图的差异：文件增删、类型变化与计划标题变化。
struct ApprovalContextMapDelta: Equatable {
    struct KindChange: Equatable {
        let path: String
        let from: ApprovalContextMap.ChangeNode.Kind
        let to: ApprovalContextMap.ChangeNode.Kind
    }

    var addedFiles: [String] = []
    var removedFiles: [String] = []
    var kindChangedFiles: [KindChange] = []
    var addedPlanTitles: [String] = []
    var removedPlanTitles: [String] = []

    var isEmpty: Bool {
        addedFiles.isEmpty && removedFiles.isEmpty && kindChangedFiles.isEmpty
            && addedPlanTitles.isEmpty && removedPlanTitles.isEmpty
    }

    static func between(
        previous: ApprovalContextMapSnapshot,
        current: ApprovalContextMapSnapshot
    ) -> ApprovalContextMapDelta {
        let previousByPath = Dictionary(
            previous.changes.map { ($0.path, $0.kind) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentByPath = Dictionary(
            current.changes.map { ($0.path, $0.kind) },
            uniquingKeysWith: { first, _ in first }
        )

        var addedFiles: [String] = []
        var removedFiles: [String] = []
        var kindChangedFiles: [KindChange] = []
        for change in current.changes where previousByPath[change.path] == nil {
            addedFiles.append(change.path)
        }
        for change in previous.changes where currentByPath[change.path] == nil {
            removedFiles.append(change.path)
        }
        for change in current.changes {
            guard let previousKind = previousByPath[change.path], previousKind != change.kind else { continue }
            kindChangedFiles.append(KindChange(path: change.path, from: previousKind, to: change.kind))
        }

        let previousPlans = Set(previous.planTitles)
        let currentPlans = Set(current.planTitles)
        return ApprovalContextMapDelta(
            addedFiles: addedFiles,
            removedFiles: removedFiles,
            kindChangedFiles: kindChangedFiles,
            addedPlanTitles: current.planTitles.filter { !previousPlans.contains($0) },
            removedPlanTitles: previous.planTitles.filter { !currentPlans.contains($0) }
        )
    }
}

/// 地图快照的轻量 JSON 存储：按会话保留最近 N 轮，写入失败不影响审批主流程。
struct ApprovalContextMapSnapshotStore {
    private struct Payload: Codable {
        var sessions: [String: [ApprovalContextMapSnapshot]] = [:]
    }

    let url: URL
    let limitPerSession: Int
    let maxSessions: Int

    init(url: URL, limitPerSession: Int = 20, maxSessions: Int = 300) {
        self.url = url
        self.limitPerSession = limitPerSession
        self.maxSessions = maxSessions
    }

    /// 正式运行使用 `~/.xisland/approval-map-history.json`；测试隔离时默认不落盘。
    static func defaultStore() -> ApprovalContextMapSnapshotStore? {
        guard !AppPreferences.isIsolated else { return nil }
        let url = URL(fileURLWithPath: DISocketConfig.socketDir, isDirectory: true)
            .appendingPathComponent("approval-map-history.json")
        return ApprovalContextMapSnapshotStore(url: url)
    }

    func history(sessionID: String) -> [ApprovalContextMapSnapshot] {
        load().sessions[sessionID] ?? []
    }

    func latest(sessionID: String) -> ApprovalContextMapSnapshot? {
        history(sessionID: sessionID).last
    }

    func append(_ snapshot: ApprovalContextMapSnapshot, sessionID: String) {
        var payload = load()
        var entries = payload.sessions[sessionID] ?? []
        entries.append(snapshot)
        if entries.count > limitPerSession {
            entries.removeFirst(entries.count - limitPerSession)
        }
        payload.sessions[sessionID] = entries
        trimSessions(&payload)
        save(payload)
    }

    private func load() -> Payload {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return Payload()
        }
        return payload
    }

    private func save(_ payload: Payload) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            // 快照为可选增强；写入失败时保持审批流程可用。
        }
    }

    private func trimSessions(_ payload: inout Payload) {
        guard payload.sessions.count > maxSessions else { return }
        let overflow = payload.sessions.count - maxSessions
        let oldest = payload.sessions
            .map { (id: $0.key, last: $0.value.last?.capturedAt ?? .distantPast) }
            .sorted { $0.last < $1.last }
            .prefix(overflow)
        for entry in oldest {
            payload.sessions.removeValue(forKey: entry.id)
        }
    }
}

/// 地图构建器：把会话数据转换成地图节点。
enum ApprovalContextMapBuilder {
    /// 计划节点的数量上限，保持展开列表紧凑。
    static let maxPlanNodes = 4

    static func build(
        session: AgentSession,
        pendingKind: ApprovalContextMap.PendingNode.Kind? = nil
    ) -> ApprovalContextMap {
        ApprovalContextMap(
            task: taskNode(for: session),
            plan: planNodes(for: session),
            changes: changeNodes(for: session),
            pending: pendingNode(for: session, preferring: pendingKind),
            reason: reasonText(for: session, preferring: pendingKind)
        )
    }

    // MARK: - 任务节点

    /// 优先使用最近一条用户消息；没有聊天记录时回退到会话 prompt。
    static func taskNode(for session: AgentSession) -> ApprovalContextMap.TaskNode? {
        let latestUserMessage = session.chatHistory.last { $0.role == .user }?.content
        let title = (latestUserMessage ?? session.prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return ApprovalContextMap.TaskNode(title: title)
    }

    // MARK: - 计划节点

    /// 优先使用待审计划的 Markdown 标题；没有待审计划时使用最近回复的结构标题。
    static func planNodes(for session: AgentSession) -> [ApprovalContextMap.PlanNode] {
        if let plan = session.pendingPlanReview,
           !plan.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MarkdownHeadingParser.headings(in: plan.markdown, limit: maxPlanNodes)
        }
        return MarkdownHeadingParser.headings(in: session.agentResponse, limit: maxPlanNodes)
    }

    // MARK: - 变更节点

    /// 遍历工具事件，按路径去重合并，保留首次出现顺序。
    static func changeNodes(for session: AgentSession) -> [ApprovalContextMap.ChangeNode] {
        var order: [String] = []
        var kinds: [String: ApprovalContextMap.ChangeNode.Kind] = [:]
        for event in session.events {
            for operation in FileOperationParser.operations(tool: event.tool, input: event.input) {
                if kinds[operation.path] == nil { order.append(operation.path) }
                kinds[operation.path] = mergedKind(previous: kinds[operation.path], next: operation.kind)
            }
        }
        return order.compactMap { path in
            kinds[path].map { ApprovalContextMap.ChangeNode(path: path, kind: $0) }
        }
    }

    /// 同一路径多次操作时的合并规则：删除优先；其次保留“新建”；
    /// 删除后又出现写入/修改时按当前修改展示。
    static func mergedKind(
        previous: ApprovalContextMap.ChangeNode.Kind?,
        next: ApprovalContextMap.ChangeNode.Kind
    ) -> ApprovalContextMap.ChangeNode.Kind {
        guard let previous else { return next }
        switch next {
        case .deleted:
            return .deleted
        case .created:
            return .created
        case .modified:
            if previous == .deleted { return .modified }
            return previous == .created ? .created : .modified
        }
    }

    // MARK: - 待审批节点

    /// 修改原因/范围：权限取描述首行，计划取第一个正文段落，提问取问题首行。
    /// 只做截断与去格式，不推测内容；无可提取文本时返回 nil。
    static func reasonText(
        for session: AgentSession,
        preferring kind: ApprovalContextMap.PendingNode.Kind?
    ) -> String? {
        switch kind {
        case .permission:
            return cleanedReason(session.pendingPermission?.description)
        case .question:
            return cleanedReason(session.pendingQuestion?.text)
        case .planReview:
            return planReason(session.pendingPlanReview?.markdown)
        case nil:
            if let permission = session.pendingPermission { return cleanedReason(permission.description) }
            if let question = session.pendingQuestion { return cleanedReason(question.text) }
            if let plan = session.pendingPlanReview { return planReason(plan.markdown) }
            return nil
        }
    }

    /// 计划原因：跳过标题、代码围栏与空行，取第一个正文段落。
    static func planReason(_ markdown: String?) -> String? {
        guard let markdown, !markdown.isEmpty else { return nil }
        var inCodeFence = false
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inCodeFence.toggle()
                continue
            }
            guard !inCodeFence, !line.isEmpty, !line.hasPrefix("#") else { continue }
            let cleaned = line
                .replacingOccurrences(of: "^[-*+]\\s+", with: "", options: .regularExpression)
            return cleanedReason(cleaned)
        }
        return nil
    }

    /// 取首行、去掉 Markdown 行内标记，并限制展示长度。
    static func cleanedReason(_ text: String?) -> String? {
        guard let text else { return nil }
        let firstLine = text.components(separatedBy: .newlines).first ?? text
        let cleaned = MarkdownHeadingParser.stripInlineFormatting(firstLine)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let limit = 140
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit)) + "…"
    }

    static func pendingNode(
        for session: AgentSession,
        preferring kind: ApprovalContextMap.PendingNode.Kind?
    ) -> ApprovalContextMap.PendingNode? {
        switch kind {
        case .permission:
            return session.pendingPermission.map(permissionNode)
        case .question:
            return session.pendingQuestion.map(questionNode)
        case .planReview:
            return session.pendingPlanReview.map(planNode)
        case nil:
            if let permission = session.pendingPermission { return permissionNode(permission) }
            if let question = session.pendingQuestion { return questionNode(question) }
            if let plan = session.pendingPlanReview { return planNode(plan) }
            return nil
        }
    }

    private static func permissionNode(_ permission: PendingPermission) -> ApprovalContextMap.PendingNode {
        let tool = permission.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = permission.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = permission.filePath ?? (description.isEmpty ? nil : description)
        return ApprovalContextMap.PendingNode(kind: .permission, title: tool, detail: detail)
    }

    private static func questionNode(_ question: PendingQuestion) -> ApprovalContextMap.PendingNode {
        let text = question.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ApprovalContextMap.PendingNode(kind: .question, title: text, detail: nil)
    }

    private static func planNode(_ plan: PendingPlanReview) -> ApprovalContextMap.PendingNode {
        let title = MarkdownHeadingParser.headings(in: plan.markdown, limit: 1).first?.title ?? ""
        return ApprovalContextMap.PendingNode(kind: .planReview, title: title, detail: nil)
    }
}

/// 从工具事件解析文件操作。
/// 仅识别已核对的常见工具名与 apply_patch 标记；不确定时返回空，不猜测。
enum FileOperationParser {
    struct Operation: Equatable {
        let path: String
        let kind: ApprovalContextMap.ChangeNode.Kind
    }

    private static let pathKeys = ["file_path", "filePath", "path", "notebook_path", "target_file", "file"]
    private static let maxPathLength = 1024

    private static let createdTools: Set<String> = [
        "write", "writefile", "create", "createfile", "newfile", "notebookwrite",
    ]
    private static let modifiedTools: Set<String> = [
        "edit", "editfile", "multiedit", "strreplace", "replace", "replacefile",
        "applypatch", "patch", "update", "updatefile", "insert", "notebookedit",
    ]
    private static let deletedTools: Set<String> = [
        "delete", "deletefile", "remove", "removefile", "rm", "unlink", "trash",
    ]

    /// 工具名归一化：小写并去掉分隔符，兼容 write_file / WriteFile / str-replace 等写法。
    static func normalizeToolName(_ tool: String) -> String {
        tool.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func operations(tool: String, input: String?) -> [Operation] {
        let normalized = normalizeToolName(tool)
        guard !normalized.isEmpty else { return [] }
        if let patchOperations = patchOperations(in: input), !patchOperations.isEmpty {
            return patchOperations
        }
        guard let kind = kind(forNormalizedTool: normalized),
              let path = firstPath(in: input) else { return [] }
        return [Operation(path: path, kind: kind)]
    }

    static func kind(forNormalizedTool tool: String) -> ApprovalContextMap.ChangeNode.Kind? {
        if createdTools.contains(tool) { return .created }
        if modifiedTools.contains(tool) { return .modified }
        if deletedTools.contains(tool) { return .deleted }
        return nil
    }

    // MARK: - apply_patch 标记解析

    /// 扫描 apply_patch 文本中的 `*** Add File:` / `*** Update File:` / `*** Delete File:` 标记。
    /// 同时兼容 JSON 包装（`{"input": "*** Begin Patch…"}`）与转义换行。
    private static func patchOperations(in input: String?) -> [Operation]? {
        guard let input, !input.isEmpty else { return nil }
        var texts: [String] = []
        if let data = input.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            collectStrings(object, into: &texts, depth: 0)
        }
        texts.append(input)
        texts.append(input.replacingOccurrences(of: "\\n", with: "\n"))
        for text in texts {
            let operations = parsePatchMarkers(in: text)
            if !operations.isEmpty { return operations }
        }
        return nil
    }

    private static func collectStrings(_ value: Any, into texts: inout [String], depth: Int) {
        guard depth <= 2 else { return }
        switch value {
        case let string as String:
            texts.append(string)
        case let dictionary as [String: Any]:
            for nested in dictionary.values { collectStrings(nested, into: &texts, depth: depth + 1) }
        case let array as [Any]:
            for nested in array { collectStrings(nested, into: &texts, depth: depth + 1) }
        default:
            break
        }
    }

    private static func parsePatchMarkers(in text: String) -> [Operation] {
        var operations: [Operation] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let path = markerPath(in: line, marker: "*** Add File:") {
                operations.append(Operation(path: path, kind: .created))
            } else if let path = markerPath(in: line, marker: "*** Update File:") {
                operations.append(Operation(path: path, kind: .modified))
            } else if let path = markerPath(in: line, marker: "*** Delete File:") {
                operations.append(Operation(path: path, kind: .deleted))
            } else if let path = markerPath(in: line, marker: "*** Move to:") {
                operations.append(Operation(path: path, kind: .modified))
            }
        }
        return operations
    }

    private static func markerPath(in line: String, marker: String) -> String? {
        guard line.hasPrefix(marker) else { return nil }
        let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, path.utf8.count <= maxPathLength, !path.utf8.contains(0) else { return nil }
        return path
    }

    // MARK: - 路径提取

    static func firstPath(in input: String?) -> String? {
        guard let input, !input.isEmpty else { return nil }
        if let data = input.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in pathKeys {
                if let value = object[key] as? String, let path = sanitizedPath(value) { return path }
            }
        }
        // 非 JSON 或键位不同的载荷：做一次保守的键值扫描。
        for key in pathKeys {
            if let value = scanValue(forKey: key, in: input), let path = sanitizedPath(value) { return path }
        }
        return nil
    }

    private static func sanitizedPath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxPathLength, !trimmed.utf8.contains(0) else { return nil }
        return trimmed
    }

    private static func scanValue(forKey key: String, in text: String) -> String? {
        guard let keyRange = text.range(of: "\"" + key + "\"") else { return nil }
        let rest = text[keyRange.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let afterColon = rest[rest.index(after: colon)...]
        guard let openQuote = afterColon.firstIndex(of: "\"") else { return nil }
        let valueStart = afterColon.index(after: openQuote)
        guard let closeQuote = afterColon[valueStart...].firstIndex(of: "\"") else { return nil }
        return String(afterColon[valueStart..<closeQuote])
    }
}

/// 从 Markdown 提取标题层级，用于计划节点。
enum MarkdownHeadingParser {
    /// 最多提取三级标题，并限制数量；无法解析的标题安全跳过。
    static func headings(
        in markdown: String?,
        limit: Int = ApprovalContextMapBuilder.maxPlanNodes
    ) -> [ApprovalContextMap.PlanNode] {
        guard let markdown, !markdown.isEmpty, limit > 0 else { return [] }
        var nodes: [ApprovalContextMap.PlanNode] = []
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#") else { continue }
            let depth = line.prefix { $0 == "#" }.count
            guard (1...3).contains(depth) else { continue }
            let title = stripInlineFormatting(String(line.dropFirst(depth)))
            guard !title.isEmpty else { continue }
            nodes.append(ApprovalContextMap.PlanNode(title: title, depth: depth))
            if nodes.count >= limit { break }
        }
        return nodes
    }

    /// 去掉加粗、斜体与行内代码标记，只影响展示，不改动原始 Markdown。
    static func stripInlineFormatting(_ text: String) -> String {
        var result = text
        for token in ["**", "`", "*"] {
            result = result.replacingOccurrences(of: token, with: "")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
