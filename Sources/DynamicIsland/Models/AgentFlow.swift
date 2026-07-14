import Foundation

// MARK: - AgentFlowBlockerKind

/// Agent Flow 阻塞类型：rawValue 越小优先级越高。
///
/// 优先级定义（依据 Agent Flow 创意提案）：
/// - `.waitingHumanInput` 最高：等待人工回答（问题 / 计划审核）
/// - `.waitingPermission` 次之：等待权限批准
/// - `.toolFailure` 再次：工具执行失败或错误状态
/// - `.none`：无阻塞（正常运行 / 已完成 / 压缩中等）
enum AgentFlowBlockerKind: Int, Comparable, Sendable {
    case waitingHumanInput = 0
    case waitingPermission = 1
    case toolFailure = 2
    case none = 3

    static func < (lhs: AgentFlowBlockerKind, rhs: AgentFlowBlockerKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .waitingHumanInput: return L10n.agentFlowWaitingHumanInput
        case .waitingPermission: return L10n.agentFlowWaitingPermission
        case .toolFailure: return L10n.agentFlowToolFailure
        case .none: return L10n.agentFlowNoBlocker
        }
    }

    /// 根据会话当前状态识别阻塞类型，不修改入参会话。
    static func classify(_ session: AgentSession) -> AgentFlowBlockerKind {
        switch session.status {
        case .waitingAnswer, .waitingPlanReview:
            return .waitingHumanInput
        case .waitingPermission:
            return .waitingPermission
        case .error:
            return .toolFailure
        case .active, .idle, .thinking, .compacting, .completed:
            return .none
        }
    }

    /// 生成可读的阻塞原因描述（用于 UI 阻塞清单展示）。
    /// 仅读取已有字段，不触发任何副作用。
    static func reason(for session: AgentSession) -> String {
        switch session.status {
        case .waitingAnswer:
            return L10n.agentFlowWaitingAnswerReason(session.pendingQuestion?.text)

        case .waitingPlanReview:
            return L10n.agentFlowWaitingPlanReview

        case .waitingPermission:
            return L10n.agentFlowWaitingApprovalReason(session.pendingPermission?.tool)

        case .error:
            return L10n.agentFlowToolFailureReason(session.statusText)

        default:
            return ""
        }
    }
}

// MARK: - AgentFlowBlocker

/// 单个阻塞事项：聚合会话引用 + 阻塞类型 + 可读原因。
/// 持有 session 引用以便 UI 直接读取 agentType / prompt / workspaceName 等展示字段。
struct AgentFlowBlocker: Identifiable {
    let id: String          // 等于 session.id，用于 SwiftUI ForEach 稳定标识
    let sessionId: String
    let session: AgentSession
    let kind: AgentFlowBlockerKind
    let reason: String

    /// 排序：先按阻塞类型优先级，再按会话最近活动时间倒序（最新优先）。
    /// 与 AgentFlowAggregator 内部排序保持一致，便于 UI 局部重排。
    /// 不实现 Comparable（AgentSession 引用类型无法合成 Equatable），改用 sorted(by:)。
    static func isBefore(_ lhs: AgentFlowBlocker, _ rhs: AgentFlowBlocker) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind < rhs.kind
        }
        return lhs.session.lastActivityTime > rhs.session.lastActivityTime
    }
}

// MARK: - AgentFlowProject

/// 以工作目录聚合的项目组：包含会话清单、各类计数与阻塞清单。
///
/// 计数关系（互斥三分，与 UI 徽标语义一致）：
/// - `totalSessions` = `activeCount` + `completedCount` + `blockedCount`
/// - `activeCount`：无阻塞且未完成的会话（正在运行 / 思考 / 压缩中 / 空闲）
/// - `completedCount`：已完成的会话
/// - `blockedCount`：被识别为阻塞的会话（等待人工输入 / 等待权限 / 工具失败）
/// - 三者互斥：阻塞会话不计入"活跃"，避免徽标把等待回答/权限/工具失败误标为活跃
struct AgentFlowProject: Identifiable {
    /// 稳定 id：使用规范化后的工作目录；兜底分组使用 `AgentFlowAggregator.ungroupedId`。
    let id: String
    /// 项目显示名（工作目录末尾段 / 兜底分组名）。
    let name: String
    /// 原始工作目录；兜底分组为空字符串。
    let workingDirectory: String
    /// 该项目下所有会话（主 Agent 与同目录子 Agent），按阻塞优先级 + 最近活动时间排序。
    let sessions: [AgentSession]
    /// 按优先级排序的阻塞清单（不含 `.none` 类型）。
    let blockers: [AgentFlowBlocker]

    var totalSessions: Int { sessions.count }

    /// 活跃数：正在运行且无阻塞的会话（不含已完成、不含阻塞中）。
    /// 与 `blockedCount` 互斥——等待回答 / 等待权限 / 工具失败的会话不计入活跃，
    /// 避免项目卡片徽标把阻塞会话误标为"活跃"。
    var activeCount: Int {
        sessions.filter { $0.status != .completed && AgentFlowBlockerKind.classify($0) == .none }.count
    }

    /// 完成数：状态为 `.completed` 的会话。
    var completedCount: Int {
        sessions.filter { $0.status == .completed }.count
    }

    /// 阻塞数：被识别为非 `.none` 阻塞类型的会话数。
    var blockedCount: Int { blockers.count }

    var hasBlockers: Bool { !blockers.isEmpty }
}

// MARK: - AgentFlowAggregator

/// Agent Flow 聚合服务：以工作目录为单位把会话分组，识别阻塞事项并按优先级排序。
///
/// 设计原则：
/// - 纯数据计算，不依赖 `SessionManager` 内部状态，不修改入参会话。
/// - 子 Agent 归属其自身工作目录；自身目录为空时沿 `parentSessionId` 链向上继承最近的有目录的祖先会话。
/// - 多层子 Agent 支持；使用 visited 集合防御循环引用。
/// - 空列表、未知状态、缺少工作目录且无法继承父目录时，归入兜底分组。
///
/// 使用方式（建议在 UI 层调用）：
/// ```swift
/// let projects = AgentFlowAggregator.group(sessions: manager.sessions)
/// ```
enum AgentFlowAggregator {

    /// 兜底分组使用的稳定 id（也用作显示名）。
    static let ungroupedId = "__xisland_ungrouped__"
    static var ungroupedDisplayName: String { L10n.agentFlowUngroupedSessions }

    /// 以工作目录为分组键聚合会话，返回按"阻塞优先级 → 最近活动时间"排序后的项目组列表。
    ///
    /// 子 Agent 工作目录解析规则：
    /// 1. 会话自身有非空 `workingDirectory` 时，始终优先使用自身目录。
    /// 2. 自身目录为空时，沿 `parentSessionId` 向上查找最近的有工作目录的父会话。
    /// 3. 支持多层子 Agent；使用已访问 ID 集合避免循环引用导致死循环。
    /// 4. 找不到父会话、父链全部没有目录或出现循环时，归入"未分组会话"。
    ///
    /// - Parameter sessions: 当前所有会话（主 Agent 与子 Agent 均包含，顺序不限）。
    /// - Returns: 排序后的项目组列表；入参为空时返回空数组。
    static func group(sessions: [AgentSession]) -> [AgentFlowProject] {
        guard !sessions.isEmpty else { return [] }

        // 0. 建立 ID → Session 索引，用于子 Agent 向上查找父会话
        let indexById: [String: AgentSession] = Dictionary(
            sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // 1. 按解析后的有效工作目录分桶
        struct Bucket {
            let key: String
            var name: String
            var originalDir: String
            var sessions: [AgentSession]
        }
        var buckets: [Bucket] = []
        var indexByKey: [String: Int] = [:]

        for session in sessions {
            let resolvedDir = resolveWorkingDirectory(for: session, indexById: indexById)
            let normalizedKey = normalizeKey(resolvedDir)
            if let idx = indexByKey[normalizedKey] {
                buckets[idx].sessions.append(session)
            } else {
                indexByKey[normalizedKey] = buckets.count
                buckets.append(Bucket(
                    key: normalizedKey,
                    name: projectDisplayName(for: resolvedDir),
                    originalDir: resolvedDir.trimmingCharacters(in: .whitespacesAndNewlines),
                    sessions: [session]
                ))
            }
        }

        // 2. 构造每个 project：sessions 排序 + 提取 blockers
        let projects: [AgentFlowProject] = buckets.map { bucket in
            let sortedSessions = bucket.sessions.sorted { a, b in
                let ka = AgentFlowBlockerKind.classify(a)
                let kb = AgentFlowBlockerKind.classify(b)
                if ka != kb { return ka < kb }
                return a.lastActivityTime > b.lastActivityTime
            }
            let blockers = sortedSessions.compactMap { session -> AgentFlowBlocker? in
                let kind = AgentFlowBlockerKind.classify(session)
                guard kind != .none else { return nil }
                return AgentFlowBlocker(
                    id: session.id,
                    sessionId: session.id,
                    session: session,
                    kind: kind,
                    reason: AgentFlowBlockerKind.reason(for: session)
                )
            }.sorted(by: AgentFlowBlocker.isBefore)
            return AgentFlowProject(
                id: bucket.key,
                name: bucket.name,
                workingDirectory: bucket.originalDir,
                sessions: sortedSessions,
                blockers: blockers
            )
        }

        // 3. 项目排序：有阻塞的在前（按最高阻塞优先级），其后按最近活动时间
        return projects.sorted { a, b in
            let aMaxKind = a.blockers.first?.kind ?? .none
            let bMaxKind = b.blockers.first?.kind ?? .none
            if aMaxKind != bMaxKind { return aMaxKind < bMaxKind }
            let aRecent = a.sessions.first?.lastActivityTime ?? .distantPast
            let bRecent = b.sessions.first?.lastActivityTime ?? .distantPast
            return aRecent > bRecent
        }
    }

    // MARK: - Private Helpers

    /// 解析会话的有效工作目录：
    /// - 自身目录非空 → 直接返回自身目录
    /// - 自身目录为空 → 沿 `parentSessionId` 向上递归查找最近的有目录的父会话
    /// - 父会话不存在 / 父链全部为空 / 检测到循环 → 返回空字符串（归入未分组）
    ///
    /// - Parameters:
    ///   - session: 待解析的会话。
    ///   - indexById: 完整的 ID → Session 查找表（由 `group` 一次性构建）。
    ///   - visited: 已访问的 session ID 集合，用于检测循环引用。调用方不应传该参数。
    /// - Returns: 解析后的有效工作目录；找不到时返回空字符串。
    private static func resolveWorkingDirectory(
        for session: AgentSession,
        indexById: [String: AgentSession],
        visited: Set<String> = []
    ) -> String {
        // 自身目录非空，直接返回（优先级最高）
        let ownDir = session.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ownDir.isEmpty { return session.workingDirectory }

        // 无父会话，归入未分组
        guard let parentId = session.parentSessionId,
              !parentId.isEmpty,
              let parent = indexById[parentId]
        else {
            return ""
        }

        // 循环引用检测：父 ID 已在访问路径中 → 终止递归
        var nextVisited = visited
        nextVisited.insert(session.id)
        if nextVisited.contains(parentId) {
            return ""
        }

        // 递归向上查找
        return resolveWorkingDirectory(for: parent, indexById: indexById, visited: nextVisited)
    }

    /// 规范化工作目录为分组键：去首尾空白、去尾部斜杠；空串归入兜底分组。
    /// 不做大小写归一化（macOS APFS 默认大小写不敏感，但保留原样更安全）。
    private static func normalizeKey(_ workingDirectory: String) -> String {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ungroupedId }
        if trimmed == "/" { return "/" }
        if trimmed.hasSuffix("/") {
            return String(trimmed.dropLast())
        }
        return trimmed
    }

    /// 项目显示名：工作目录的 `lastPathComponent`；空串使用兜底分组名。
    /// 注意：与 `AgentSession.workspaceName` 略有不同——
    /// - 项目级不剥离前导 "."（项目名优先保留完整路径段信息）
    /// - 项目级不回退到 `agentType.shortName`（避免兜底分组里出现多 Agent 混杂）
    private static func projectDisplayName(for workingDirectory: String) -> String {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ungroupedDisplayName }
        let last = (trimmed as NSString).lastPathComponent
        return last.isEmpty ? ungroupedDisplayName : last
    }
}
