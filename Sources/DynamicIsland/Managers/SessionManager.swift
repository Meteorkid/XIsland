import Foundation
import Observation
import AppKit
import DIShared
import CryptoKit

// MARK: - Session Grouping & Filtering

enum SessionGrouping: String, CaseIterable, Identifiable {
    case none
    case agentType
    case workspace
    case status
    case date

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return L10n.groupNone
        case .agentType: return L10n.groupAgentType
        case .workspace: return L10n.groupWorkspace
        case .status: return L10n.groupStatus
        case .date: return L10n.groupDate
        }
    }
}

enum SessionFilter: Equatable {
    case all
    case agentType(AgentType)
    case status(SessionStatus)
    case text(String)

    static func == (lhs: SessionFilter, rhs: SessionFilter) -> Bool {
        switch (lhs, rhs) {
        case (.all, .all): return true
        case (.agentType(let a), .agentType(let b)): return a == b
        case (.status(let a), .status(let b)): return a == b
        case (.text(let a), .text(let b)): return a == b
        default: return false
        }
    }
}

struct SessionGroup: Identifiable {
    let id: String
    let title: String
    let sessions: [AgentSession]
}

// MARK: - SessionManager

@Observable
@MainActor
final class SessionManager {
    var sessions: [AgentSession] = []
    var selectedSessionId: String?
    var focusedInteraction: InteractionFocus?
    /// O(1) 查找索引：session ID → sessions 数组下标
    private var sessionIndex: [String: Int] = [:]
    /// 缓存 mirrored session 后缀，避免重复字符串解析
    private var suffixCache: [String: String] = [:]
    /// 预计算 subagent 关系：parentId → [childSession]
    private var subagentMap: [String: [AgentSession]] = [:]
    /// 原生后台 hook 可能在退出后迟到；关闭记录必须比 UI 会话存活更久。
    private var closedDeepSeekSessionIDs: Set<String> = []
    private var closedAmazonQWrapperIDs: Set<String> = []
    var audioEngine: AudioEngine?
    var persistenceManager: SessionPersistenceManager?
    @ObservationIgnored var onIntegrationActivity: ((AgentType) -> Void)?
    private(set) var unsavedSessionIDs: Set<String> = []
    @ObservationIgnored private var unsavedKimiBackgroundTasks: [String: [String: DINativeBackgroundTask]] = [:]
    /// 诊断回执计数；包含被忽略的消息，只在处理和真实持久化完成后递增。
    @ObservationIgnored private(set) var handledMessageCount: UInt64 = 0
    private struct PersistenceCommand {
        let write: @MainActor () async -> Bool
        let complete: @MainActor (Bool) -> Void
    }
    private struct PersistenceOperation {
        let reduce: @MainActor () -> Void
        let complete: (@MainActor () -> Void)?
    }
    @ObservationIgnored private var persistenceOperations: [PersistenceOperation?] = []
    @ObservationIgnored private var persistenceOperationHead = 0
    @ObservationIgnored private var persistenceOperationTask: Task<Void, Never>?
    @ObservationIgnored private var collectedPersistenceCommands: [PersistenceCommand]?
    @ObservationIgnored private var pendingCheckpointCounts: [String: Int] = [:]
    @ObservationIgnored private var acceptsPersistenceOperations = true
    @ObservationIgnored private var inFlightInteractionDeliveries = 0
    @ObservationIgnored private var persistenceWaiters: [CheckedContinuation<Void, Never>] = []

    /// reducer 不跨挂起点；只有提交完成后才执行依赖耐久结果的回调。
    private func performPersistedOperation(
        allowAfterStop: Bool = false,
        onRejected: (() -> Void)? = nil,
        completion: (@MainActor () -> Void)? = nil,
        _ reduce: @escaping @MainActor () -> Void
    ) {
        if collectedPersistenceCommands != nil {
            reduce()
            completion?()
            return
        }
        guard acceptsPersistenceOperations || allowAfterStop else { onRejected?(); return }
        guard persistenceManager?.usesBackgroundWrites == true else {
            reduce()
            completion?()
            return
        }
        persistenceOperations.append(PersistenceOperation(reduce: reduce, complete: completion))
        guard persistenceOperationTask == nil else { return }
        persistenceOperationTask = Task { [self] in
            while persistenceOperationHead < persistenceOperations.count {
                let operation = persistenceOperations[persistenceOperationHead]!
                persistenceOperations[persistenceOperationHead] = nil
                persistenceOperationHead += 1
                // UI 删除和保留期清理也使用持久化队列；恢复读取不能越过它们。
                _ = await persistenceManager?.flushPendingWrites()
                collectedPersistenceCommands = []
                operation.reduce()
                let commands = collectedPersistenceCommands ?? []
                collectedPersistenceCommands = nil
                for command in commands {
                    let saved = await command.write()
                    command.complete(saved)
                }
                operation.complete?()
                // 无写入的回放也分批让出执行器，避免突发消息独占界面线程。
                if persistenceOperationHead.isMultiple(of: 32) { await Task.yield() }
            }
            persistenceOperations.removeAll()
            persistenceOperationHead = 0
            persistenceOperationTask = nil
            notifyPersistenceWaiters()
        }
    }

    func stopAcceptingPersistenceOperations() {
        acceptsPersistenceOperations = false
    }

    func resumeAcceptingPersistenceOperations() {
        acceptsPersistenceOperations = true
    }

    /// 停止接收后，已发出的 socket 审批回执仍须进入队列并落盘。
    func drainPersistenceOperations() async -> Bool {
        while persistenceOperationTask != nil || inFlightInteractionDeliveries > 0 {
            if let task = persistenceOperationTask { await task.value }
            else { await withCheckedContinuation { persistenceWaiters.append($0) } }
        }
        let flushed = await persistenceManager?.flushPendingWrites() ?? true
        return flushed && unsavedSessionIDs.isEmpty && kimiCodeOrphanObservations.isEmpty
            && unsavedKimiBackgroundTasks.isEmpty
    }

    private func notifyPersistenceWaiters() {
        let waiters = persistenceWaiters
        persistenceWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    var currentIslandState: IslandState = .collapsed
    /// 会话分组模式，持久化到 UserDefaults
    var grouping: SessionGrouping {
        get {
            SessionGrouping(rawValue: AppPreferences.defaults.string(forKey: "sessionGrouping") ?? "") ?? .none
        }
        set {
            AppPreferences.defaults.set(newValue.rawValue, forKey: "sessionGrouping")
        }
    }
    var activeFilter: SessionFilter = .all
    var searchText: String = ""

    var bypassMode: Bool {
        get { AppPreferences.defaults.bool(forKey: "bypassMode") }
        set { AppPreferences.defaults.set(newValue, forKey: "bypassMode") }
    }

    private var approvalInterruption = ApprovalInterruptionState()
    private var kimiCodeOrphanObservations: [String: KimiCodeApprovalObservation] = [:]
    private var kimiCodeProjectionTransactions: [String: KimiCodeApprovalObservation] = [:]
    /// 与可见会话对象分离，隐藏再恢复不会丢失本次 App 已知的回合顺序。
    @ObservationIgnored private var codexTurns: [String: (current: String, observed: Set<String>)] = [:]

    /// Incremented to force SwiftUI to re-evaluate `visibleSessions` after linger expires.
    var visibleSessionsVersion: Int = 0
    private var cleanupTimer: Timer?
    private var workspaceObserver: Any?
    private let allowsExternalApplicationAccess: Bool
    private let captureWindowNumber: (AgentType, String) -> Int?
    private var observationLeases = ObservationLeaseLedger()
    nonisolated(unsafe) private var observationTimer: Timer?
    private let observationClock: () -> TimeInterval
    private let observationWallClock: () -> Date

    init(
        testConfiguration: AppTestConfiguration = .current(),
        captureWindowNumber: @escaping (AgentType, String) -> Int? = {
            TerminalJumpManager.captureFrontWindowNumber(for: $0, terminal: $1)
        },
        observationClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        observationWallClock: @escaping () -> Date = Date.init
    ) {
        allowsExternalApplicationAccess = !testConfiguration.isEnabled && !AppPreferences.isIsolated
        self.captureWindowNumber = captureWindowNumber
        self.observationClock = observationClock
        self.observationWallClock = observationWallClock
    }

    deinit { observationTimer?.invalidate() }

    /// Debounces the "Session complete" (`sessionEnd`) chime when assistant text arrives via `statusUpdate`
    /// (Notification hook) as well as `sessionEnd`, so streaming updates do not spam sounds.
    private var lastAssistantReplySoundAt: [String: TimeInterval] = [:]
    private let assistantReplySoundMinInterval: TimeInterval = 1.8

    var completedLingerDuration: TimeInterval {
        let val = AppPreferences.defaults.double(forKey: "completedLingerDuration")
        if val == 0 || val < 0 { return .infinity }  // 「永久」选项（兼容旧版 -1.0）
        return val
    }

    var activeSessions: [AgentSession] {
        sessions.filter { $0.status != .completed && $0.status != .observationUnavailable }
    }

    /// 主会话运行中，或主回复未确认但仍观察到子代理在运行。
    var trulyActiveSessions: [AgentSession] {
        sessions.filter { $0.status == .active || $0.status == .thinking || $0.status == .compacting
            || ($0.status == .completionUnconfirmed && $0.hasRunningSubagents) }
    }

    /// 获取指定会话的 subagent 列表（O(1) 查询）
    func subagents(of session: AgentSession) -> [AgentSession] {
        subagentMap[session.id] ?? []
    }

    /// Among sessions shown in the expanded list (`visibleSessions`), the one that most recently received a message/activity (notch-obscured island leading icon).
    var latestMessagedVisibleSession: AgentSession? {
        visibleSessions.max(by: { $0.lastActivityTime < $1.lastActivityTime })
    }

    /// 展开列表显示所有会话（含已完成），提供全局视角
    var visibleSessions: [AgentSession] {
        _ = visibleSessionsVersion
        return sessions
    }

    /// 过滤后的会话列表：基于 activeFilter 和 searchText
    var filteredSessions: [AgentSession] {
        var result = visibleSessions

        // 应用 activeFilter
        switch activeFilter {
        case .all:
            break
        case .agentType(let type):
            result = result.filter { $0.agentType == type || (type == .glm && $0.usesGLMModel) }
        case .status(let status):
            result = result.filter { $0.status == status }
        case .text(let text):
            let lower = text.lowercased()
            result = result.filter { session in
                session.prompt.lowercased().contains(lower)
                    || session.workspaceName.lowercased().contains(lower)
                    || session.terminal.lowercased().contains(lower)
                    || session.tokenUsage.model.lowercased().contains(lower)
            }
        }

        // 应用搜索文本（与 filter 交叉）
        if !searchText.isEmpty {
            let lower = searchText.lowercased()
            result = result.filter { session in
                session.prompt.lowercased().contains(lower)
                    || session.workspaceName.lowercased().contains(lower)
                    || session.terminal.lowercased().contains(lower)
                    || session.tokenUsage.model.lowercased().contains(lower)
            }
        }

        // 按状态优先级排序，同优先级按最近活动时间降序
        result.sort { a, b in
            if a.status.statusPriority != b.status.statusPriority {
                return a.status.statusPriority < b.status.statusPriority
            }
            return a.lastActivityTime > b.lastActivityTime
        }

        return result
    }

    /// 按当前 grouping 分组后的会话
    var groupedSessions: [SessionGroup] {
        let sessions = filteredSessions
        switch grouping {
        case .none:
            return [SessionGroup(id: "__all__", title: "", sessions: sessions)]
        case .agentType:
            let grouped = Dictionary(grouping: sessions) { $0.agentType.rawValue }
            return grouped
                .sorted { $0.key < $1.key }
                .map { SessionGroup(id: $0.key, title: AgentType(rawValue: $0.key)?.shortName ?? $0.key, sessions: $0.value) }
        case .workspace:
            let grouped = Dictionary(grouping: sessions) { $0.workspaceName }
            return grouped
                .sorted { $0.key < $1.key }
                .map { SessionGroup(id: $0.key, title: $0.key, sessions: $0.value) }
        case .status:
            let grouped = Dictionary(grouping: sessions) { $0.status.rawValue }
            let order: [SessionStatus] = [.active, .thinking, .compacting, .waitingPermission, .waitingAnswer, .waitingPlanReview, .idle, .completionUnconfirmed, .completed, .error, .observationUnavailable]
            return order.compactMap { status in
                guard let items = grouped[status.rawValue], !items.isEmpty else { return nil }
                return SessionGroup(id: status.rawValue, title: status.displayName, sessions: items)
            }
        case .date:
            let calendar = Calendar.current
            let now = Date()
            let today = calendar.startOfDay(for: now)
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
            let weekAgo = calendar.date(byAdding: .day, value: -7, to: today)!

            var todaySessions: [AgentSession] = []
            var yesterdaySessions: [AgentSession] = []
            var weekSessions: [AgentSession] = []
            var olderSessions: [AgentSession] = []

            for session in sessions {
                let start = calendar.startOfDay(for: session.startTime)
                if calendar.compare(start, to: today, toGranularity: .day) == .orderedSame {
                    todaySessions.append(session)
                } else if calendar.compare(start, to: yesterday, toGranularity: .day) == .orderedSame {
                    yesterdaySessions.append(session)
                } else if start >= weekAgo {
                    weekSessions.append(session)
                } else {
                    olderSessions.append(session)
                }
            }

            var groups: [SessionGroup] = []
            if !todaySessions.isEmpty {
                groups.append(SessionGroup(id: "today", title: L10n.dateGroupToday, sessions: todaySessions))
            }
            if !yesterdaySessions.isEmpty {
                groups.append(SessionGroup(id: "yesterday", title: L10n.dateGroupYesterday, sessions: yesterdaySessions))
            }
            if !weekSessions.isEmpty {
                groups.append(SessionGroup(id: "thisWeek", title: L10n.dateGroupThisWeek, sessions: weekSessions))
            }
            if !olderSessions.isEmpty {
                groups.append(SessionGroup(id: "older", title: L10n.dateGroupOlder, sessions: olderSessions))
            }
            return groups
        }
    }

    func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cleanupStaleSessions()
                self?.checkProcessesAlive()
            }
        }
        observeAppTermination()
    }

    // MARK: - Desktop App Termination

    private func observeAppTermination() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleId = app.bundleIdentifier else { return }
            Task { @MainActor in
                self?.handleAppTerminated(bundleId: bundleId)
            }
        }
    }

    func handleAppTerminated(bundleId: String) {
        guard let agentType = AgentType.fromBundleId(bundleId) else { return }
        handleDeadAgents([agentType])
    }

    // MARK: - CLI Process Checking

    private func checkProcessesAlive() {
        let checks = cliProcessChecks()
        guard !checks.isEmpty else { return }

        Task.detached(priority: .utility) { [checks] in
            let deadAgents = checks.compactMap { check -> AgentType? in
                let (agentType, names) = check
                guard Self.isAnyProcessRunning(names: names) == false else { return nil }
                return agentType
            }
            guard !deadAgents.isEmpty else { return }
            await MainActor.run {
                AppDelegate.shared?.sessionManager.handleDeadAgents(deadAgents)
            }
        }
    }

    @MainActor
    func checkProcessesAlive(processStatus: @escaping @Sendable ([String]) -> Bool?) {
        let checks = cliProcessChecks()
        let deadAgents = checks.compactMap { check -> AgentType? in
            let (agentType, names) = check
            return processStatus(names) == false ? agentType : nil
        }
        handleDeadAgents(deadAgents)
    }

    private func cliProcessChecks() -> [(AgentType, [String])] {
        activeSessions
            .filter { !$0.agentType.isDesktopApp && !$0.agentType.processNames.isEmpty }
            .reduce(into: [(AgentType, [String])]()) { result, session in
                if !result.contains(where: { $0.0 == session.agentType }) {
                    result.append((session.agentType, session.agentType.processNames))
                }
            }
    }

    private func handleDeadAgents(_ deadAgents: [AgentType]) {
        performPersistedOperation { [self] in handleDeadAgentsImmediately(deadAgents) }
    }

    private func handleDeadAgentsImmediately(_ deadAgents: [AgentType]) {
        guard !deadAgents.isEmpty else { return }

        for agentType in deadAgents {
            for session in activeSessions where session.agentType == agentType {
                markObservationUnavailable(session)
            }
        }

        selectNextInteraction()
        reSelectIfCurrentCompleted()
        scheduleLingerCleanup()
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
    }

    /// If the currently selected session has been completed, pick the next active session.
    private func reSelectIfCurrentCompleted() {
        guard let sid = selectedSessionId,
              let status = sessions.first(where: { $0.id == sid })?.status,
              status == .completed || status == .observationUnavailable
        else { return }
        selectedSessionId = activeSessions.first?.id
    }

    /// 检测失败时返回 nil，不能把无法查询进程当成确认退出。
    private nonisolated static func isAnyProcessRunning(names: [String]) -> Bool? {
        var detectionFailed = false
        for name in names {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            task.arguments = ["-x", name]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                guard task.terminationReason == .exit else {
                    detectionFailed = true
                    continue
                }
                if task.terminationStatus == 0 { return true }
                if task.terminationStatus != 1 { detectionFailed = true }
            } catch {
                detectionFailed = true
            }
        }
        return detectionFailed ? nil : false
    }

    func cleanupStaleSessions() {
        performPersistedOperation { [self] in cleanupStaleSessionsImmediately() }
    }

    private func cleanupStaleSessionsImmediately() {
        expireObservationSources()
        reSelectIfCurrentCompleted()
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
        purgeOrphanedCacheEntries()
    }

    var selectedSession: AgentSession? {
        guard let id = selectedSessionId else { return activeSessions.first }
        return sessions.first { $0.id == id }
    }

    var pendingInteractionSessions: [AgentSession] {
        sessions.filter(\.hasPendingInteraction).sorted {
            if $0.status.statusPriority != $1.status.statusPriority {
                return $0.status.statusPriority < $1.status.statusPriority
            }
            if $0.lastActivityTime != $1.lastActivityTime { return $0.lastActivityTime < $1.lastActivityTime }
            return $0.id < $1.id
        }
    }

    var hasInteraction: Bool { sessions.contains(where: \.hasPendingInteraction) }

    private struct ActivityRevision: Equatable {
        let instance: ObjectIdentifier
        let revision: UInt
    }
    @ObservationIgnored private var activityRevisions: [ActivityRevision] = []
    @ObservationIgnored private var activityCache: [(session: AgentSession, event: ToolEvent)] = []
    @ObservationIgnored private(set) var activitySelectionCount = 0

    var recentActivityEvents: [(session: AgentSession, event: ToolEvent)] {
        let current = sessions.map { ActivityRevision(instance: ObjectIdentifier($0), revision: $0.activityRevision) }
        if current != activityRevisions {
            activityCache = RecentActivitySelection.latest(in: sessions)
            activityRevisions = current
            activitySelectionCount += 1
        }
        return activityCache
    }

    var protectsInteraction: Bool { hasInteraction }

    var prioritizedInteractionSession: AgentSession? {
        if let focus = focusedInteraction,
           let session = sessions.first(where: { $0.id == focus.sessionID }),
           requestID(in: session, kind: focus.kind) == focus.requestID { return session }
        return pendingInteractionSessions.first
    }

    func focusInteraction(session: AgentSession, kind: InteractionKind, requestID: UUID? = nil) {
        guard let id = self.requestID(in: session, kind: kind), requestID == nil || requestID == id else { return }
        focusedInteraction = InteractionFocus(sessionID: session.id, kind: kind, requestID: id)
        selectedSessionId = session.id
        switch kind {
        case .permission: currentIslandState = .permission(session.id)
        case .question: currentIslandState = .question(session.id)
        case .plan: currentIslandState = .planReview(session.id)
        }
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
    }

    private func requestID(in session: AgentSession, kind: InteractionKind) -> UUID? {
        switch kind {
        case .permission: return session.pendingPermission?.id
        case .question: return session.pendingQuestion?.id
        case .plan: return session.pendingPlanReview?.id
        }
    }

    @discardableResult
    func handleInteractionShortcut(_ key: String) -> Bool {
        selectNextInteraction()
        guard let focus = focusedInteraction,
              let session = sessions.first(where: { $0.id == focus.sessionID }) else { return false }
        switch (focus.kind, key) {
        case (.permission, "y"), (.permission, "n"):
            submitPermission(session: session, approved: key == "y", requestID: focus.requestID)
        case (.plan, "y"), (.plan, "n"):
            let draft = session.pendingPlanReview?.state.draftFeedback ?? ""
            respondToPlan(session: session, approved: key == "y", feedback: draft.isEmpty ? nil : draft,
                          requestID: focus.requestID)
        case (.question, "1"), (.question, "2"), (.question, "3"):
            guard let digit = Int(key), let question = session.pendingQuestion,
                  question.options.indices.contains(digit - 1) else { return false }
            if question.allowsMultipleAnswers {
                guard question.state.canSubmit else { return false }
                let option = question.options[digit - 1]
                if question.state.selectedAnswers.contains(option) { question.state.selectedAnswers.remove(option) }
                else { question.state.selectedAnswers.insert(option) }
            } else {
                answerQuestion(session: session, answer: question.options[digit - 1], requestID: focus.requestID)
            }
        default: return false
        }
        return true
    }

    func collapseFocusedInteractionDetail() -> Bool {
        guard let focus = focusedInteraction,
              let session = sessions.first(where: { $0.id == focus.sessionID }) else { return false }
        let state: InteractionRequestState?
        switch focus.kind {
        case .permission: state = session.pendingPermission?.state
        case .question: state = session.pendingQuestion?.state
        case .plan: state = session.pendingPlanReview?.state
        }
        guard let state, state.isExpanded else { return false }
        state.isExpanded = false
        return true
    }

    private func selectNextInteraction() {
        if let focus = focusedInteraction,
           let session = sessions.first(where: { $0.id == focus.sessionID }),
           requestID(in: session, kind: focus.kind) == focus.requestID { return }
        focusedInteraction = nil
        guard let session = pendingInteractionSessions.first else { return }
        let kind: InteractionKind = session.pendingPermission != nil ? .permission
            : session.pendingQuestion != nil ? .question : .plan
        focusInteraction(session: session, kind: kind)
    }

    var diagnosticsIslandState: String {
        NotchContentView
            .diagnosticsIslandState(for: self, currentState: currentIslandState)
            .diagnosticsValue
    }

    func handleMessage(_ message: DIMessage) {
        performPersistedOperation(completion: { [self] in
            handledMessageCount += 1
            AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
        }) { [self] in handleMessageImmediately(message) }
    }

    private func handleMessageImmediately(_ message: DIMessage) {
        // 历史结束事件不能关闭新一轮活动或重新制造待查看完成。
        if message.type == .sessionEnd, message.nativeMessageReplay == true { return }
        if !message.hasObservationMetadata, sessionById(message.sessionId)?.sourceInstanceId != nil { return }
        if !message.hasObservationMetadata, message.type == .subagentStart || message.type == .subagentEnd,
           let parent = message.parentSessionId, sessionById(parent)?.sourceInstanceId != nil { return }
        let sourceAgent = resolvedAgentType(for: message)
        var message = message
        if sourceAgent == .codex, message.type == .sessionStart, let prompt = message.prompt {
            // 兼容仍发送原始包装的旧桥接；在创建会话、追加历史和保存之前处理。
            message.prompt = CodexPromptText.normalized(prompt)
        }
        if sourceAgent == .amazonQ, message.sessionId.hasPrefix("amazonq-wrapper-") {
            if closedAmazonQWrapperIDs.contains(message.sessionId) { return }
            if message.nativeEvent == "amazonq_wrapper_end" { closedAmazonQWrapperIDs.insert(message.sessionId) }
        }
        if ZeroConfigManager.usesCompanionExtension(sourceAgent) || ZeroConfigManager.usesACPBridge(sourceAgent) || ZeroConfigManager.usesStateObserver(sourceAgent) || ZeroConfigManager.usesCodyBridge(sourceAgent) || ZeroConfigManager.usesAmazonQWrapper(sourceAgent) || ZeroConfigManager.usesWorkBuddyPlugin(sourceAgent),
           !ZeroConfigManager.isAutoConfigEnabled(for: sourceAgent) { return }
        if message.hasObservationMetadata {
            expireObservationSources()
            switch observationLeases.accept(message, now: observationClock(), wallTime: observationWallClock()) {
            case .rejected: return
            case .ended(let source):
                endObservation(source)
                return
            case .heartbeat:
                startObservationTimerIfNeeded()
                return
            case .event:
                startObservationTimerIfNeeded()
            }
        }
        if resolvedAgentType(for: message) == .deepseek, let nativeEvent = message.nativeEvent {
            if nativeEvent == "session_start" {
                closedDeepSeekSessionIDs.remove(message.sessionId)
            } else if nativeEvent == "session_end" {
                closedDeepSeekSessionIDs.insert(message.sessionId)
            } else if closedDeepSeekSessionIDs.contains(message.sessionId) {
                return
            }
        }

        if handleKimiCodeBackgroundTask(message) || handleKimiCodeApprovalObservation(message) {
            AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
            return
        }

        if resolvedAgentType(for: message) == .codex,
           message.nativeEvent == "UserPromptSubmit", let turnID = message.nativeTurnId,
           let known = codexTurns[message.sessionId],
           known.current != turnID, known.observed.contains(turnID) { return }

        if isCodexTurnObservation(message) {
            // 结果观察不能重建历史会话；未见当前回合时也不猜测事件归属。
            guard let session = sessionById(message.sessionId), let turnID = message.nativeTurnId,
                  !session.hasPendingInteraction,
                  ![SessionStatus.completed, .observationUnavailable, .error,
                    .waitingPermission, .waitingAnswer, .waitingPlanReview].contains(session.status) else { return }
            if message.nativeEvent == "PreCompact" {
                // 压缩开始本身就是活动证据，不要求伪造一个先行的用户提示。
                // 只拒绝本次运行已见过且被新回合取代的 ID；跨重启的未知 ID 无法排序。
                if let known = codexTurns[session.id], known.current != turnID,
                   known.observed.contains(turnID) { return }
            } else if codexTurns[session.id]?.current != turnID { return }
        }

        guard restoreArchivedSessionIfNeeded(message) else {
            AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
            return
        }
        if shouldIgnoreMirroredSession(message) {
            return
        }

        let tracksKimiApproval = isKimiCodeMessage(message)
            || sessionById(message.sessionId)?.kimiCodeApprovalObservation != nil
        if tracksKimiApproval, !beginKimiCodeProjection(message) { return }
        defer {
            if tracksKimiApproval { finishKimiCodeProjection(message) }
        }

        switch message.type {
        case .sessionStart:
            startSession(message)
        case .sessionEnd:
            endSession(message)
        case .toolStart:
            handleToolStart(message)
        case .toolComplete:
            handleToolComplete(message)
        case .statusUpdate, .progress:
            handleStatus(message)
        case .subagentStart:
            handleSubagentStart(message)
        case .subagentEnd:
            handleSubagentEnd(message)
        case .contextCompact:
            handleContextCompact(message)
        case .recap:
            handleRecap(message)
        case .interactionResolved:
            handleInteractionResolved(message)
        default:
            break
        }

        if let session = sessionById(message.sessionId) { rememberCodexTurn(message, session: session) }

        if message.hasObservationMetadata, let session = sessionById(message.sessionId) {
            session.sourceNamespace = message.sourceNamespace
            session.sourceInstanceId = message.sourceInstanceId
            session.nativeTaskId = message.nativeTaskId
        }

        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
    }

    private func isKimiCodeMessage(_ message: DIMessage) -> Bool {
        resolvedAgentType(for: message) == .kimi && message.nativeEvent?.hasPrefix("kimi_code.") == true
    }

    /// 只由消息的接受分支调用；历史加载和默认来源推断不能证明客户端已接通。
    private func reportIntegrationActivity(_ message: DIMessage, session: AgentSession) {
        guard message.nativeMessageReplay != true, session.status != .observationUnavailable else { return }
        let identifiers = [message.sessionId, message.nativeTurnId, message.nativeMessageId, message.nativeAgentId,
                           message.nativeRequestId].compactMap { $0 }
        guard identifiers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { return }
        let source: AgentType?
        if let explicit = message.agentType { source = AgentType.from(explicit) }
        else {
            source = message.sessionId.split(separator: "-", maxSplits: 1).first
                .flatMap { AgentType(rawValue: String($0)) }
        }
        guard let source, source.isSupported, source != .glm else { return }
        let agent = resolvedAgentType(for: message)
        guard agent == session.agentType else { return }
        if agent == .codex, let turn = message.nativeTurnId, let known = codexTurns[session.id],
           known.current != turn {
            let beginsNewTurn = ["UserPromptSubmit", "PreCompact"].contains(message.nativeEvent ?? "")
                && !known.observed.contains(turn)
            guard beginsNewTurn else { return }
        }
        onIntegrationActivity?(agent)
    }

    private func isCodexTurnObservation(_ message: DIMessage) -> Bool {
        resolvedAgentType(for: message) == .codex
            && ["Interrupt", "PreCompact", "PostCompact"].contains(message.nativeEvent ?? "")
    }

    private func rememberCodexTurn(_ message: DIMessage, session: AgentSession) {
        guard session.agentType == .codex, resolvedAgentType(for: message) == .codex,
              let turnID = message.nativeTurnId,
              ["UserPromptSubmit", "PreCompact", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop"].contains(message.nativeEvent ?? ""),
              message.nativeMessageReplay != true else { return }
        // 新提示或压缩开始确认活动；工具、审批或结果仅补齐首次观测。
        if message.nativeEvent == "UserPromptSubmit" || message.nativeEvent == "PreCompact" || codexTurns[session.id] == nil {
            var known = codexTurns[session.id] ?? (current: turnID, observed: [])
            known.current = turnID
            known.observed.insert(turnID)
            codexTurns[session.id] = known
        }
    }

    private func kimiCodeRequest(_ message: DIMessage) -> KimiCodeApprovalObservation.Request? {
        KimiCodeApprovalObservation.Request(id: message.nativeRequestId, agentID: message.nativeAgentId,
            turnID: message.nativeTurnId, toolCallID: message.toolCallId)
    }

    /// TaskStarted 和通知以任务 ID 关联，不借用模型工具 ID 或名称型子代理身份。
    private func handleKimiCodeBackgroundTask(_ message: DIMessage) -> Bool {
        guard isKimiCodeMessage(message), let task = message.nativeBackgroundTask,
              ["kimi_code.TaskStarted", "kimi_code.Notification"].contains(message.nativeEvent ?? "") else { return false }
        do {
            let visible = sessionById(message.sessionId)
            let stored = visible == nil ? try persistenceManager?.restoreSession(sessionId: message.sessionId) : nil
            let existing = visible ?? stored
            if existing == nil, persistenceManager != nil {
                unsavedKimiBackgroundTasks.removeValue(forKey: message.sessionId)
                unsavedSessionIDs.remove(message.sessionId)
            }
            if let existing {
                guard existing.agentType == .kimi, existing.sourceNamespace == message.sourceNamespace,
                      existing.sourceInstanceId == message.sourceInstanceId, existing.nativeTaskId == message.nativeTaskId else { return true }
            }
            var observation = existing?.kimiCodeApprovalObservation
                ?? KimiCodeApprovalObservation(baseStatus: existing?.status ?? .idle, baseStatusText: existing?.statusText ?? "")
            if let orphan = try loadKimiCodeOrphan(message.sessionId) {
                observation.merge(orphan)
                if existing == nil, orphan.baseStatus == .completed { observation.endSession() }
            }
            mergeUnsavedKimiBackgroundTasks(into: &observation, sessionID: message.sessionId)
            let previousTask = observation.backgroundTasks?[task.id]
            observation.observeBackgroundTask(task)
            guard let recorded = observation.backgroundTasks?[task.id] else { return true }
            if let existing {
                let closed = existing.status == .completed || existing.status == .observationUnavailable
                if closed { observation.markBackgroundTasksUnconfirmed() }
                existing.kimiCodeApprovalObservation = observation
                synchronizeKimiCodeBackgroundTasks(existing)
                applyKimiCodeProjection(existing)
                // 已在历史中的结束事实只更新历史；正在运行的新任务才能重新显示会话。
                if visible == nil, !closed, recorded.kind == "agent", recorded.status == "running" {
                    sessions.append(existing)
                    updateIndexForAppend(existing, at: sessions.count - 1)
                }
                persistSession(existing) { [self, existing] saved in
                    if !saved, visible == nil {
                        // 命令持有隐藏对象直到提交结束，失败事实随后保留供重试。
                        unsavedKimiBackgroundTasks[existing.id] = existing.kimiCodeApprovalObservation?.backgroundTasks ?? [:]
                    }
                }
                let handled = recorded.kind == "agent" || visible == nil || closed
                if handled, !closed, sessionById(existing.id) != nil, previousTask != recorded {
                    reportIntegrationActivity(message, session: existing)
                }
                return handled
            }
            if recorded.status != "running" || observation.baseStatus == .completed {
                persistKimiCodeOrphan(observation, sessionID: message.sessionId)
                return true
            }
            if recorded.kind != "agent" {
                persistKimiCodeOrphan(observation, sessionID: message.sessionId)
                return false
            }
            let session = findOrCreateSession(message)
            observation.baseStatus = session.status
            session.kimiCodeApprovalObservation = observation
            synchronizeKimiCodeBackgroundTasks(session)
            applyKimiCodeProjection(session)
            persistSession(session)
            reportIntegrationActivity(message, session: session)
        } catch {
            print("[SessionManager] Kimi background task facts could not be loaded: \(error.localizedDescription)")
        }
        return true
    }

    private func synchronizeKimiCodeBackgroundTasks(_ session: AgentSession) {
        let tasks = session.kimiCodeApprovalObservation?.backgroundTasks ?? [:]
        for task in tasks.values.sorted(by: { ($0.startedAtMilliseconds ?? 0, $0.id) < ($1.startedAtMilliseconds ?? 0, $1.id) }) {
            guard task.kind == "agent" else { continue }
            let eventID = KimiCodeApprovalObservation.backgroundTaskEventID(sessionID: session.id, taskID: task.id)
            let index = session.events.firstIndex { $0.id == eventID }
            let timestamp = task.startedAtMilliseconds.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date()
            // 不设置 toolCallId：它属于模型可选择的命名空间，不能用字符串前缀隔离。
            var event = index.map { session.events[$0] } ?? ToolEvent(tool: "Subagent", id: eventID, timestamp: timestamp)
            event.input = task.description
            event.isComplete = ["completed", "failed", "timed_out", "killed"].contains(task.status)
            event.completionUnconfirmed = ["lost", "unconfirmed"].contains(task.status)
            event.result = task.result ?? (event.isComplete ? "Background task: " + task.status : nil)
            if let index {
                let previous = session.events[index]
                if previous.input == event.input, previous.isComplete == event.isComplete,
                   previous.completionUnconfirmed == event.completionUnconfirmed, previous.result == event.result { continue }
                session.replaceEvent(at: index, with: event)
            }
            else { session.appendEvent(event) }
        }
        if !tasks.isEmpty, session.currentTool == "Subagent", !session.hasRunningSubagents {
            session.currentTool = session.events.last(where: { $0.isRunning })?.tool
        }
    }

    private func mergeUnsavedKimiBackgroundTasks(into observation: inout KimiCodeApprovalObservation, sessionID: String) {
        for task in (unsavedKimiBackgroundTasks[sessionID] ?? [:]).values {
            observation.observeBackgroundTask(task)
        }
    }

    /// 被动结果只更新已知事实；即使历史已归档，也不能借此恢复可见活动。
    private func handleKimiCodeApprovalObservation(_ message: DIMessage) -> Bool {
        guard isKimiCodeMessage(message), let event = message.nativeEvent else { return false }
        if event == "kimi_code.SessionHeartbeat" { return true }
        if event == "kimi_code.UserPromptSubmit", let session = sessionById(message.sessionId),
           session.status == .completed || session.status == .observationUnavailable { return true }
        let isRequest = event == "kimi_code.PermissionRequest"
        let isResult = event == "kimi_code.PermissionResult"
        let isArchivedEnd = event == "kimi_code.SessionEnd" && sessionById(message.sessionId) == nil
        guard isRequest || isResult || isArchivedEnd else { return false }
        guard message.nativeMessageReplay != true else { return true }
        do {
            let visible = sessionById(message.sessionId)
            let stored: AgentSession?
            if visible == nil { stored = try persistenceManager?.restoreSession(sessionId: message.sessionId) }
            else { stored = nil }
            let existing = visible ?? stored
            if let existing {
                guard existing.agentType == .kimi, existing.sourceNamespace == message.sourceNamespace,
                      existing.sourceInstanceId == message.sourceInstanceId, existing.nativeTaskId == message.nativeTaskId else { return true }
                let closed = existing.status == .completed || existing.status == .observationUnavailable
                if isRequest, closed { return true }
                if isArchivedEnd {
                    existing.kimiCodeApprovalObservation?.endSession()
                    synchronizeKimiCodeBackgroundTasks(existing)
                    if existing.status != .completed { existing.completionNeedsReview = true }
                    existing.status = .completed
                    existing.completedAt = existing.completedAt ?? Date()
                    persistSession(existing)
                    return true
                }
                var observation = existing.kimiCodeApprovalObservation
                    ?? KimiCodeApprovalObservation(baseStatus: existing.status, baseStatusText: existing.statusText)
                let previous = observation
                if isRequest { observation.observeRequest(kimiCodeRequest(message)) }
                else { observation.observeResult(kimiCodeRequest(message)) }
                existing.kimiCodeApprovalObservation = observation
                applyKimiCodeProjection(existing)
                if isRequest, visible == nil, observation.hasPendingApproval {
                    sessions.append(existing)
                    updateIndexForAppend(existing, at: sessions.count - 1)
                }
                persistSession(existing)
                if !closed, sessionById(existing.id) != nil, let request = kimiCodeRequest(message) {
                    let acceptedRequest = isRequest && observation.pending[request.id] == request
                        && previous.pending[request.id] != request
                    let acceptedResult = isResult && previous.pending[request.id] == request
                        && observation.resolved[request.id] == request
                    if acceptedRequest || acceptedResult { reportIntegrationActivity(message, session: existing) }
                }
                return true
            }
            var observation = try loadKimiCodeOrphan(message.sessionId)
                ?? KimiCodeApprovalObservation(baseStatus: .idle)
            if isArchivedEnd {
                observation.endSession()
                persistKimiCodeOrphan(observation, sessionID: message.sessionId)
                return true
            }
            if isResult {
                guard let request = kimiCodeRequest(message) else { return true }
                observation.observeResult(request)
                persistKimiCodeOrphan(observation, sessionID: message.sessionId)
                return true
            }
            guard observation.baseStatus != .completed else { return true }
            observation.observeRequest(kimiCodeRequest(message))
            // 已结束 ID 的迟到 Request 只读事实，不新建等待会话。
            guard observation.hasPendingApproval else { return true }
            let session = findOrCreateSession(message)
            session.kimiCodeApprovalObservation = observation
            applyKimiCodeProjection(session)
            persistSession(session)
            if let request = kimiCodeRequest(message), observation.pending[request.id] == request {
                reportIntegrationActivity(message, session: session)
            }
        } catch {
            // 历史/ledger 读取失败时保留磁盘事实，不能退回空状态继续处理。
            print("[SessionManager] Kimi approval observation could not be restored: \(error.localizedDescription)")
        }
        return true
    }

    private func loadKimiCodeOrphan(_ sessionID: String) throws -> KimiCodeApprovalObservation? {
        var observation = try persistenceManager?.kimiCodeApprovalOrphan(sessionId: sessionID)
        if let cached = kimiCodeOrphanObservations[sessionID] {
            if observation == nil { observation = cached }
            else {
                observation?.merge(cached)
                if cached.baseStatus == .completed { observation?.endSession() }
            }
        }
        return observation
    }

    private func persistKimiCodeOrphan(_ observation: KimiCodeApprovalObservation, sessionID: String) {
        kimiCodeOrphanObservations[sessionID] = observation
        guard let persistenceManager else { return }
        let complete: @MainActor (Bool) -> Void = { [self] saved in
            // 较早命令不能清除本 reducer 随后记录的更新事实。
            if saved, kimiCodeOrphanObservations[sessionID] == observation {
                kimiCodeOrphanObservations.removeValue(forKey: sessionID)
            }
        }
        if collectedPersistenceCommands != nil {
            collectedPersistenceCommands?.append(PersistenceCommand(write: {
                await persistenceManager.saveKimiCodeApprovalOrphanAsync(sessionId: sessionID, observation: observation)
            }, complete: complete))
        } else {
            complete(persistenceManager.saveKimiCodeApprovalOrphan(sessionId: sessionID, observation: observation))
        }
    }

    private func beginKimiCodeProjection(_ message: DIMessage) -> Bool {
        do {
            let session = sessionById(message.sessionId)
            var observation = session?.kimiCodeApprovalObservation
                ?? KimiCodeApprovalObservation(baseStatus: session?.status ?? .idle, baseStatusText: session?.statusText ?? "")
            if let orphan = try loadKimiCodeOrphan(message.sessionId) {
                if session == nil, orphan.baseStatus == .completed {
                    // 没有历史父记录的关闭事实也需要恢复门禁；结果或通知不算新活动。
                    guard message.nativeEvent == "kimi_code.SessionStart" || message.nativeEvent == "kimi_code.TurnStarted"
                        || message.type == .toolStart || message.type == .contextCompact else { return false }
                }
                observation.merge(orphan)
            }
            mergeUnsavedKimiBackgroundTasks(into: &observation, sessionID: message.sessionId)
            kimiCodeProjectionTransactions[message.sessionId] = observation
            if let session {
                session.kimiCodeApprovalObservation = observation
                if !session.hasPendingInteraction, session.status != .completed, session.status != .observationUnavailable {
                    session.status = observation.baseStatus
                    session.statusText = observation.baseStatusText
                }
            }
            return true
        } catch {
            print("[SessionManager] Kimi approval facts could not be loaded: \(error.localizedDescription)")
            return false
        }
    }

    private func finishKimiCodeProjection(_ message: DIMessage) {
        guard var observation = kimiCodeProjectionTransactions.removeValue(forKey: message.sessionId),
              let session = sessionById(message.sessionId) else { return }
        if let current = session.kimiCodeApprovalObservation { observation.merge(current) }
        if message.nativeEvent == "kimi_code.SessionEnd" { observation.endSession() }
        if message.nativeEvent == "kimi_code.Interrupt" { observation.observeInterrupt() }
        // 提交可被其他 hook 阻断；只有 TurnStarted 等执行证据改变基础状态。
        if message.nativeEvent != "kimi_code.UserPromptSubmit", message.type != .interactionResolved {
            if !session.hasPendingInteraction {
                observation.baseStatus = session.status
                observation.baseStatusText = session.statusText
            } else if message.type == .toolStart {
                observation.baseStatus = .active
            } else if message.type == .contextCompact {
                observation.baseStatus = .compacting
            } else if let raw = message.observedState, let state = SessionStatus(rawValue: raw),
                      [.active, .idle, .completionUnconfirmed, .error].contains(state) {
                observation.baseStatus = state
                observation.baseStatusText = message.status ?? observation.baseStatusText
            }
        }
        session.kimiCodeApprovalObservation = observation
        synchronizeKimiCodeBackgroundTasks(session)
        applyKimiCodeProjection(session)
        persistSession(session)
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
    }

    private func applyKimiCodeProjection(_ session: AgentSession) {
        guard let observation = session.kimiCodeApprovalObservation,
              session.status != .completed, session.status != .observationUnavailable else { return }
        if session.hasPendingInteraction {
            session.status = session.pendingPermission != nil ? .waitingPermission
                : session.pendingQuestion != nil ? .waitingAnswer : .waitingPlanReview
            return
        }
        session.status = observation.displayedStatus ?? observation.baseStatus
        session.statusText = observation.displayedText ?? observation.baseStatusText
    }

    private func startObservationTimerIfNeeded() {
        guard observationTimer == nil, observationLeases.hasLiveSources else { return }
        observationTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.expireObservationSources() }
        }
    }

    func expireObservationSources() {
        performPersistedOperation { [self] in expireObservationSourcesImmediately() }
    }

    private func expireObservationSourcesImmediately() {
        for source in observationLeases.expire(now: observationClock()) { endObservation(source) }
        if !observationLeases.hasLiveSources {
            observationTimer?.invalidate()
            observationTimer = nil
        }
    }

    private func endObservation(_ source: ObservationSource) {
        for session in sessions where session.agentType.rawValue == source.agent
            && session.sourceNamespace == source.namespace && session.sourceInstanceId == source.instance
            && session.status != .completed {
            markObservationUnavailable(session)
        }
        selectNextInteraction()
        reSelectIfCurrentCompleted()
        scheduleLingerCleanup()
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
    }

    private func markObservationUnavailable(_ session: AgentSession) {
        cancelPendingInteractions(session)
        session.status = .observationUnavailable
        session.statusText = L10n.observationInterrupted
        session.currentTool = nil
        session.observationEndedAt = session.observationEndedAt ?? observationWallClock()
        session.kimiCodeApprovalObservation?.markBackgroundTasksUnconfirmed()
        synchronizeKimiCodeBackgroundTasks(session)
        persistSession(session)
    }

    private func shouldIgnoreMirroredSession(_ message: DIMessage) -> Bool {
        guard message.type == .sessionStart || message.type == .sessionEnd,
              mirrorSource(for: message) == .claudeCode,
              let session = sessionById(message.sessionId) ?? sessionMatchingMirror(of: message) else { return false }
        return isCursorFamily(session.agentType)
    }

    /// 保留已有 IDE 与 Claude hook 的镜像兼容；IDE 之间不能仅凭相同后缀合并。
    private func isCursorFamily(_ agentType: AgentType) -> Bool {
        agentType == .cursor || agentType == .trae || agentType == .windsurf
    }

    private func mirroredSessionSuffix(from sessionId: String) -> String? {
        guard let separator = sessionId.firstIndex(of: "-") else {
            return nil
        }
        let suffix = String(sessionId[sessionId.index(after: separator)...])
        return suffix.isEmpty ? nil : suffix
    }

    private func resolvedAgentType(for message: DIMessage) -> AgentType {
        if mirrorSource(for: message) == .claudeCode,
           let mirrored = sessionById(message.sessionId) ?? sessionMatchingMirror(of: message),
           isCursorFamily(mirrored.agentType) {
            return mirrored.agentType
        }

        if let explicit = AgentType.from(message.agentType) {
            return explicit
        }

        if let prefix = message.sessionId.split(separator: "-", maxSplits: 1).first,
           let inferred = AgentType.from(String(prefix)) {
            return inferred
        }

        if let terminal = message.terminal, let app = TerminalApp.detect(from: terminal) {
            switch app {
            case .cursor:
                return .cursor
            case .windsurf:
                return .windsurf
            case .trae, .traeCn, .traeWorkCn:
                return .trae
            case .codex:
                return .codex
            default:
                break
            }
        }

        if let existing = sessions.first(where: { $0.id == message.sessionId }) {
            return existing.agentType
        }

        return .claudeCode
    }

    private func mirrorSource(for message: DIMessage) -> AgentType? {
        guard let prefix = message.sessionId.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first,
              let source = AgentType(rawValue: String(prefix)),
              source == .claudeCode || isCursorFamily(source),
              message.agentType == nil || AgentType.from(message.agentType) == source else { return nil }
        return source
    }

    /// 只有来源明确的 Claude/IDE 配对才共享后缀；Claude 先到时记录已绑定的 IDE。
    private func sessionMatchingMirror(of message: DIMessage) -> AgentSession? {
        guard let source = mirrorSource(for: message),
              let suffix = mirroredSessionSuffix(from: message.sessionId),
              sessionById(message.sessionId) == nil else { return nil }
        let matchingSuffix = sessions.filter { suffixCache[$0.id] == suffix }
        let candidates = matchingSuffix.filter { session in
            if source == .claudeCode {
                return isCursorFamily(session.agentType)
                    && session.id.hasPrefix(session.agentType.rawValue + "-")
            }
            return session.id.hasPrefix("claude_code-")
                && (session.agentType == .claudeCode || session.agentType == source)
        }
        guard candidates.count == 1, let session = candidates.first else { return nil }
        if source != .claudeCode {
            if session.agentType == .claudeCode,
               matchingSuffix.contains(where: { isCursorFamily($0.agentType) && $0.agentType != source }) {
                return nil
            }
            session.agentType = source
        }
        return session
    }

    func handlePermissionRequest(_ message: DIMessage, delivery: InteractionDelivery? = nil, cancel: (@Sendable () -> Void)? = nil, respond: @escaping @Sendable (Bool) -> Void) {
        performPersistedOperation(onRejected: cancel) { [self] in
            handlePermissionRequestImmediately(message, delivery: delivery, cancel: cancel, respond: respond)
        }
    }

    private func handlePermissionRequestImmediately(_ message: DIMessage, delivery: InteractionDelivery? = nil, cancel: (@Sendable () -> Void)? = nil, respond: @escaping @Sendable (Bool) -> Void) {
        guard message.nativeMessageReplay != true, !message.hasObservationMetadata,
              sessionById(message.sessionId)?.sourceInstanceId == nil,
              restoreArchivedSessionIfNeeded(message, activate: !bypassMode) else { cancel?(); return }
        if bypassMode {
            respond(true)
            return
        }

        let realAgent = resolvedAgentType(for: message)

        let session = findOrCreateSessionForInteraction(message)
        rememberCodexTurn(message, session: session)
        let refreshCheckpoint = resumeSession(session, as: .waitingPermission)
        session.pendingPermission?.cancel?()
        session.pendingPermission = PendingPermission(
            requestingAgent: realAgent,
            tool: message.tool ?? "unknown",
            description: message.permDescription ?? "",
            diff: message.diff,
            filePath: message.filePath,
            respond: respond,
            delivery: delivery,
            cancel: cancel,
            nativeRequestId: message.nativeRequestId,
            toolInput: message.toolInput
        )
        if refreshCheckpoint { persistSession(session) }
        selectNextInteraction()
        audioEngine?.play(.permissionRequest, session: session)
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)

        // 有审批时强制置顶显示
        forceToShowForApproval()
        if message.type == .permissionRequest,
           [message.tool, message.permDescription, message.nativeRequestId].compactMap({ $0 })
            .contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            reportIntegrationActivity(message, session: session)
        }
    }

    func handleQuestionRequest(_ message: DIMessage, delivery: InteractionDelivery? = nil, respond: @escaping @Sendable (String) -> Void, cancel: (@Sendable () -> Void)? = nil) {
        performPersistedOperation(onRejected: cancel) { [self] in
            handleQuestionRequestImmediately(message, delivery: delivery, respond: respond, cancel: cancel)
        }
    }

    private func handleQuestionRequestImmediately(_ message: DIMessage, delivery: InteractionDelivery? = nil, respond: @escaping @Sendable (String) -> Void, cancel: (@Sendable () -> Void)? = nil) {
        guard message.nativeMessageReplay != true, !message.hasObservationMetadata,
              sessionById(message.sessionId)?.sourceInstanceId == nil else { cancel?(); return }
        let text = message.questionText ?? ""
        let options = message.options ?? []
        // Skip stub events (e.g. OpenCode fires a placeholder "Question" with no options
        // before the real question arrives). Close the fd so the di-bridge exits cleanly.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && !(trimmed == "Question" && options.isEmpty
            && message.nativeRequestId == nil && message.allowsCustomAnswer != true) else {
            cancel?()
            return
        }
        let bypassesQuestion = bypassMode && message.allowsMultipleAnswers != true && options.first != nil
        guard restoreArchivedSessionIfNeeded(message, activate: !bypassesQuestion) else { cancel?(); return }
        if bypassMode, message.allowsMultipleAnswers != true, let firstOption = message.options?.first {
            respond(firstOption)
            return
        }
        let realAgent = resolvedAgentType(for: message)
        let session = findOrCreateSessionForInteraction(message)

        // 相同文本不能证明是同一原生请求；缺少请求身份时也必须等待新的用户回答。
        // Close the previous question's fd when superseded by a newer event.
        session.pendingQuestion?.cancel?()
        let refreshCheckpoint = resumeSession(session, as: .waitingAnswer)
        session.pendingQuestion = PendingQuestion(
            requestingAgent: realAgent,
            text: text,
            options: options,
            respond: respond,
            cancel: cancel,
            delivery: delivery,
            nativeRequestId: message.nativeRequestId,
            allowsCustomAnswer: message.allowsCustomAnswer == true,
            allowsMultipleAnswers: message.allowsMultipleAnswers == true
        )
        if refreshCheckpoint { persistSession(session) }
        selectNextInteraction()
        audioEngine?.play(.question, session: session)
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)

        // 有交互时强制置顶显示
        forceToShowForApproval()
        if message.type == .question { reportIntegrationActivity(message, session: session) }
    }

    func handlePlanReview(_ message: DIMessage, delivery: InteractionDelivery? = nil, cancel: (@Sendable () -> Void)? = nil, respond: @escaping @Sendable (Bool, String?) -> Void) {
        performPersistedOperation(onRejected: cancel) { [self] in
            handlePlanReviewImmediately(message, delivery: delivery, cancel: cancel, respond: respond)
        }
    }

    private func handlePlanReviewImmediately(_ message: DIMessage, delivery: InteractionDelivery? = nil, cancel: (@Sendable () -> Void)? = nil, respond: @escaping @Sendable (Bool, String?) -> Void) {
        guard message.nativeMessageReplay != true, !message.hasObservationMetadata,
              sessionById(message.sessionId)?.sourceInstanceId == nil,
              restoreArchivedSessionIfNeeded(message, activate: !bypassMode) else { cancel?(); return }
        if bypassMode {
            respond(true, nil)
            return
        }

        let realAgent = resolvedAgentType(for: message)
        let session = findOrCreateSessionForInteraction(message)
        let refreshCheckpoint = resumeSession(session, as: .waitingPlanReview)
        session.pendingPlanReview?.cancel?()
        session.pendingPlanReview = PendingPlanReview(
            requestingAgent: realAgent,
            markdown: message.planMarkdown ?? "",
            respond: respond,
            delivery: delivery,
            cancel: cancel
        )
        if refreshCheckpoint { persistSession(session) }
        selectNextInteraction()
        audioEngine?.play(.planReview, session: session)
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)

        // 有审批时强制置顶显示
        forceToShowForApproval()
        if message.type == .planReview,
           !(message.planMarkdown ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reportIntegrationActivity(message, session: session)
        }
    }

    private func handleInteractionResolved(_ message: DIMessage) {
        guard let nativeRequestId = message.nativeRequestId,
              !nativeRequestId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let session = sessionById(message.sessionId) else { return }

        switch message.nativeRequestKind {
        case "permission":
            guard let request = session.pendingPermission, request.nativeRequestId == nativeRequestId else { return }
            request.cancel?()
            session.pendingPermission = nil
        case "question":
            guard let request = session.pendingQuestion, request.nativeRequestId == nativeRequestId else { return }
            request.cancel?()
            session.pendingQuestion = nil
        default:
            return
        }

        session.status = session.pendingPermission != nil ? .waitingPermission
            : session.pendingQuestion != nil ? .waitingAnswer
            : session.pendingPlanReview != nil ? .waitingPlanReview : .active
        applyKimiCodeProjection(session)
        selectNextInteraction()
        if !hasInteraction {
            switch currentIslandState {
            case .permission, .question, .planReview: currentIslandState = .collapsed
            default: break
            }
        }
        // 原端已处理的请求不再占用显示权，也不触发本地审批后的窗口切换。
        approvalInterruption.cancelIfFinished(hasPendingInteractions: hasInteraction)
        reportIntegrationActivity(message, session: session)
    }

    func approvePermission(session: AgentSession, requestID: UUID? = nil) {
        submitPermission(session: session, approved: true, requestID: requestID)
    }

    func denyPermission(session: AgentSession, requestID: UUID? = nil) {
        submitPermission(session: session, approved: false, requestID: requestID)
    }

    private func submitPermission(session: AgentSession, approved: Bool, requestID: UUID?) {
        guard let request = session.pendingPermission, requestID == nil || request.id == requestID else { return }
        submitInteraction(session: session, kind: .permission, requestID: request.id,
                          state: request.state, delivery: request.delivery,
                          decision: .permission(approved), sound: approved ? .approved : .denied) {
            request.respond(approved)
        }
    }

    func answerQuestion(session: AgentSession, answer: String, requestID: UUID? = nil) {
        guard let request = session.pendingQuestion, requestID == nil || request.id == requestID,
              !request.allowsMultipleAnswers,
              !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.acceptsAnswer(answer) else { return }
        submitInteraction(session: session, kind: .question, requestID: request.id,
                          state: request.state, delivery: request.delivery,
                          decision: .question(answer), sound: .answered) {
            request.respond(answer)
        }
    }

    func answerQuestion(session: AgentSession, answers: [String], requestID: UUID) {
        guard let request = session.pendingQuestion, request.id == requestID,
              !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.acceptsAnswers(answers), request.delivery != nil || request.respondMultiple != nil else { return }
        submitInteraction(session: session, kind: .question, requestID: request.id,
                          state: request.state, delivery: request.delivery,
                          decision: .questionSelections(answers), sound: .answered, onSuccess: {}) {
            request.respondMultiple?(answers)
        }
    }

    func respondToPlan(session: AgentSession, approved: Bool, feedback: String?, requestID: UUID? = nil) {
        guard let request = session.pendingPlanReview, requestID == nil || request.id == requestID else { return }
        submitInteraction(session: session, kind: .plan, requestID: request.id,
                          state: request.state, delivery: request.delivery,
                          decision: .plan(approved, feedback), sound: approved ? .approved : .denied) {
            request.respond(approved, feedback)
        }
    }

    private func submitInteraction(
        session: AgentSession, kind: InteractionKind, requestID: UUID,
        state: InteractionRequestState, delivery: InteractionDelivery?,
        decision: InteractionDecision, sound: SoundEvent,
        onSuccess: @escaping () -> Void = {}, legacyResponse: @escaping () -> Void
    ) {
        guard acceptsPersistenceOperations || collectedPersistenceCommands != nil,
              state.canSubmit, sessions.contains(where: { $0 === session }),
              self.requestID(in: session, kind: kind) == requestID else { return }
        // 立即预占当前请求，让排队保存期间的点击有反馈且不能重复发送。
        focusInteraction(session: session, kind: kind)
        state.phase = .sending
        performPersistedOperation { [self, session] in
            guard sessions.contains(where: { $0 === session }),
                  self.requestID(in: session, kind: kind) == requestID else { return }
            submitInteractionImmediately(session: session, kind: kind, requestID: requestID,
                state: state, delivery: delivery, decision: decision, sound: sound,
                onSuccess: onSuccess, legacyResponse: legacyResponse)
        }
    }

    private func submitInteractionImmediately(
        session: AgentSession, kind: InteractionKind, requestID: UUID,
        state: InteractionRequestState, delivery: InteractionDelivery?,
        decision: InteractionDecision, sound: SoundEvent,
        onSuccess: @escaping () -> Void, legacyResponse: () -> Void
    ) {
        guard state.phase == .sending else { return }
        let finish: @MainActor (Bool) -> Void = { [weak self, weak session] success in
            guard let self, let session,
                  self.sessions.contains(where: { $0 === session }),
                  self.requestID(in: session, kind: kind) == requestID else { return }
            state.phase = success ? .sent : .failed
            guard success else {
                AppDelegate.shared?.refreshDiagnostics(islandState: self.diagnosticsIslandState)
                return
            }
            onSuccess()
            switch kind {
            case .permission: session.pendingPermission = nil
            case .question: session.pendingQuestion = nil
            case .plan: session.pendingPlanReview = nil
            }
            session.status = session.pendingPermission != nil ? .waitingPermission
                : session.pendingQuestion != nil ? .waitingAnswer
                : session.pendingPlanReview != nil ? .waitingPlanReview : .active
            self.applyKimiCodeProjection(session)
            if session.kimiCodeApprovalObservation != nil { self.persistSession(session) }
            self.audioEngine?.play(sound, session: session)
            self.selectNextInteraction()
            AppDelegate.shared?.refreshDiagnostics(islandState: self.diagnosticsIslandState)
            if !self.hasInteraction { self.restoreToXnookIfNeeded() }
        }
        if let delivery {
            inFlightInteractionDeliveries += 1
            Task { [self] in
                let sent = await delivery(decision)
                performPersistedOperation(allowAfterStop: true) { finish(sent) }
                inFlightInteractionDeliveries -= 1
                notifyPersistenceWaiters()
            }
        } else {
            // 测试fixture/进程内回调同步完成；真实socket必须提供异步delivery。
            legacyResponse()
            finish(true)
        }
    }

    func dismissSession(_ session: AgentSession) {
        performPersistedOperation { [self, session] in
            guard !session.hasPendingInteraction, sessions.contains(where: { $0 === session }) else { return }
            persistSession(session) { [self, session] saved in
                guard saved, !session.hasPendingInteraction, sessions.contains(where: { $0 === session }) else { return }
                sessions.removeAll { $0.id == session.id }
                rebuildSessionIndex()
                lastAssistantReplySoundAt.removeValue(forKey: session.id)
                if selectedSessionId == session.id { selectedSessionId = activeSessions.first?.id }
                AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
            }
        }
    }

    @MainActor
    func markCompletionReviewed(sessionID: String) {
        guard let session = sessionById(sessionID), session.status == .completed,
              !session.hasPendingInteraction, session.completionNeedsReview else { return }
        let completedAt = session.completedAt
        performPersistedOperation { [self, session] in
            // 排队期间可能开始并完成另一轮，旧详情的查看动作不能确认新结果。
            guard sessionById(sessionID) === session, session.status == .completed,
                  session.completedAt == completedAt, !session.hasPendingInteraction,
                  session.completionNeedsReview else { return }
            session.completionNeedsReview = false
            persistSession(session)
        }
    }

    // MARK: - Private

    private func startSession(_ message: DIMessage) {
        let session = sessionById(message.sessionId)
            ?? sessionMatchingMirror(of: message)
            ?? createNewSession(from: message)

        let duplicatePrompt = nativeChatID(message, role: .user).map { id in
            session.chatHistory.contains { $0.id == id }
        } ?? false
        let acceptsActivity = message.nativeMessageReplay != true && !duplicatePrompt
        var refreshCheckpoint = false
        if acceptsActivity {
            if !isKimiCodeMessage(message) || !session.hasPendingInteraction { cancelPendingInteractions(session) }
            session.lastActivityTime = Date()
            refreshCheckpoint = resumeSession(session)
            session.statusText = message.status ?? ""
        }
        if let t = message.terminal, !t.isEmpty { session.terminal = t }
        if let w = message.workingDir, !w.isEmpty { session.workingDirectory = w }
        if let p = message.prompt, !p.isEmpty {
            session.prompt = p
            if let id = nativeChatID(message, role: .user), let index = session.chatHistory.firstIndex(where: { $0.id == id }) {
                session.replaceChatMessage(at: index, with: ChatMessage(id: id, timestamp: session.chatHistory[index].timestamp, role: .user, content: p))
            } else {
                if acceptsActivity { session.agentResponse = "" }
                session.appendChatMessage(ChatMessage(id: nativeChatID(message, role: .user) ?? UUID(), timestamp: Date(), role: .user, content: p))
                if acceptsActivity { audioEngine?.play(.sessionStart, session: session) }
            }
        }
        if let ts = message.termSessionId, !ts.isEmpty { session.termSessionId = ts }
        if allowsExternalApplicationAccess, session.sourceInstanceId == nil, session.windowNumber == nil {
            session.windowNumber = captureWindowNumber(session.agentType, session.terminal)
        }
        updateTokenUsage(session: session, message: message)
        if refreshCheckpoint || [.claudeCode, .codex].contains(resolvedAgentType(for: message)) { persistSession(session) }
        if acceptsActivity {
            selectedSessionId = session.id
            selectNextInteraction()
            reportIntegrationActivity(message, session: session)
        }
    }

    private func endSession(_ message: DIMessage) {
        let agentType = resolvedAgentType(for: message)

        guard let session = sessionForEndMessage(message) else { return }
        let alreadyCompleted = session.status == .completed
        let wasUnavailable = session.status == .observationUnavailable
        cancelPendingInteractions(session)
        selectNextInteraction()
        updateTokenUsage(session: session, message: message)

        if let responseText = message.status, !responseText.isEmpty {
            if message.statusIsAssistantReply != false { session.agentResponse = responseText }
            session.statusText = responseText
        }

        if message.statusIsAssistantReply != false, !session.agentResponse.isEmpty {
            if let lastIdx = session.chatHistory.indices.last, session.chatHistory[lastIdx].role == .assistant {
                session.replaceChatMessage(at: lastIdx, with: ChatMessage(
                    id: session.chatHistory[lastIdx].id, timestamp: Date(), role: .assistant, content: session.agentResponse
                ))
            } else {
                session.appendChatMessage(
                    ChatMessage(timestamp: Date(), role: .assistant, content: session.agentResponse)
                )
            }
        }

        if message.observedState == "completed" {
            if agentType == .claudeCode {
                // 拒绝权限可能不产生后置工具事件；会话关闭后不能继续显示这些调用在运行。
                // 权限请求没有调用 ID，不能把缺失的结果伪造成具体工具的成功或拒绝。
                for index in session.events.indices where session.events[index].isRunning {
                    session.updateEvent(at: index) { $0.completionUnconfirmed = true }
                }
            }
            markCompleted(session)
        } else if !agentType.processNames.isEmpty {
            session.status = .idle
            session.currentTool = nil
            if session.statusText.isEmpty {
                session.statusText = "Done"
            }
            session.lastActivityTime = Date()
        } else {
            markCompleted(session)
        }
        if !alreadyCompleted, message.statusIsAssistantReply != false {
            playAssistantReplySoundDebounced(sessionId: session.id)
        }

        if session.status == .completed, selectedSessionId == session.id {
            selectedSessionId = activeSessions.first?.id
        }
        if !alreadyCompleted, !wasUnavailable { reportIntegrationActivity(message, session: session) }
    }

    private func cancelPendingInteractions(_ session: AgentSession) {
        session.pendingPermission?.cancel?()
        session.pendingQuestion?.cancel?()
        session.pendingPlanReview?.cancel?()
        session.pendingPermission = nil
        session.pendingQuestion = nil
        session.pendingPlanReview = nil
        if focusedInteraction?.sessionID == session.id { focusedInteraction = nil }
        approvalInterruption.cancelIfFinished(hasPendingInteractions: hasInteraction)
    }

    private func markCompleted(_ session: AgentSession) {
        // 进程结束后旧连接不能继续审批，也不能阻止面板收起。
        cancelPendingInteractions(session)
        if session.status != .completed {
            session.completionNeedsReview = true
            session.completedAt = Date()
        }
        session.status = .completed
        session.currentTool = nil
        persistSession(session)
        selectNextInteraction()
        scheduleLingerCleanup()
    }

    /// 仅在接受新的活动后调用；历史重放、迟到结果和查找会话不能清除结束时间。
    private func resumeSession(_ session: AgentSession, as status: SessionStatus = .active) -> Bool {
        let refreshCheckpoint = session.completedAt != nil || session.observationEndedAt != nil
            || session.status == .completionUnconfirmed || session.completionNeedsReview
        session.completedAt = nil
        session.completionNeedsReview = false
        session.observationEndedAt = nil
        session.status = status
        return refreshCheckpoint
    }

    private func persistSession(_ session: AgentSession, completion: (@MainActor (Bool) -> Void)? = nil) {
        // Kimi 普通事件先更新基础状态，再投影审批显示；只保存最终状态。
        if kimiCodeProjectionTransactions[session.id] != nil { return }
        if unsavedKimiBackgroundTasks[session.id] != nil {
            var observation = session.kimiCodeApprovalObservation
                ?? KimiCodeApprovalObservation(baseStatus: session.status, baseStatusText: session.statusText)
            mergeUnsavedKimiBackgroundTasks(into: &observation, sessionID: session.id)
            session.kimiCodeApprovalObservation = observation
            synchronizeKimiCodeBackgroundTasks(session)
        }
        guard let persistenceManager else { completion?(true); return }
        let complete: @MainActor (Bool) -> Void = { [self, session] saved in
            if saved {
                kimiCodeOrphanObservations.removeValue(forKey: session.id)
                unsavedKimiBackgroundTasks.removeValue(forKey: session.id)
                unsavedSessionIDs.remove(session.id)
            } else {
                unsavedSessionIDs.insert(session.id)
            }
            completion?(saved)
        }
        if collectedPersistenceCommands != nil {
            let write = persistenceManager.makeSaveOperation(session: session)
            pendingCheckpointCounts[session.id, default: 0] += 1
            collectedPersistenceCommands?.append(PersistenceCommand(write: write, complete: { [self] saved in
                if let count = pendingCheckpointCounts[session.id], count > 1 {
                    pendingCheckpointCounts[session.id] = count - 1
                } else { pendingCheckpointCounts.removeValue(forKey: session.id) }
                complete(saved)
            }))
        } else {
            complete(persistenceManager.save(session: session))
        }
    }

    func retryPendingHistorySaves() {
        performPersistedOperation { [self] in retryPendingHistorySavesImmediately() }
    }

    private func retryPendingHistorySavesImmediately() {
        for session in sessions where unsavedSessionIDs.contains(session.id) {
            persistSession(session)
        }
        if let persistenceManager {
            for id in Array(unsavedKimiBackgroundTasks.keys) where sessionById(id) == nil {
                do {
                    guard let stored = try persistenceManager.restoreSession(sessionId: id) else {
                        // 已删除或过期的历史不由内存缓存重建。
                        unsavedKimiBackgroundTasks.removeValue(forKey: id)
                        unsavedSessionIDs.remove(id)
                        continue
                    }
                    persistSession(stored)
                } catch {
                    print("[SessionManager] Kimi background task save retry could not read history: \(error.localizedDescription)")
                }
            }
        }
        for sessionID in Array(kimiCodeOrphanObservations.keys) {
            if let observation = kimiCodeOrphanObservations[sessionID] {
                persistKimiCodeOrphan(observation, sessionID: sessionID)
            }
        }
    }

    private var hasPendingLingerCleanup = false

    private func scheduleLingerCleanup() {
        guard completedLingerDuration != .infinity else { return }
        guard !hasPendingLingerCleanup else { return }
        hasPendingLingerCleanup = true
        let linger = completedLingerDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + linger + 0.1) { [weak self] in
            guard let self else { return }
            self.hasPendingLingerCleanup = false
            self.visibleSessionsVersion += 1
            self.cleanupLingeredSessions()
        }
    }

    func cleanupLingeredSessions() {
        performPersistedOperation { [self] in cleanupLingeredSessionsImmediately() }
    }

    private func cleanupLingeredSessionsImmediately() {
        // 永久模式（.infinity）不清理任何已完成会话
        guard completedLingerDuration != .infinity else {
            rebuildSessionIndex()
            return
        }
        let now = Date()
        let completedSessions = sessions
            .filter { ($0.status == .completed || $0.status == .observationUnavailable) && !unsavedSessionIDs.contains($0.id) && pendingCheckpointCounts[$0.id] == nil }
            .sorted { ($0.completedAt ?? $0.observationEndedAt ?? .distantPast) > ($1.completedAt ?? $1.observationEndedAt ?? .distantPast) }
        let expiredIds = completedSessions.compactMap { session -> String? in
            guard let completedAt = session.completedAt ?? session.observationEndedAt else { return nil }
            return now.timeIntervalSince(completedAt) > completedLingerDuration ? session.id : nil
        }
        var toRemove = Set(expiredIds)
        // 保留最近的已完成会话，超出上限的按时间淘汰
        if completedSessions.count > 20 {
            toRemove.formUnion(completedSessions[20...].map(\.id))
        }
        if !toRemove.isEmpty {
            sessions.removeAll { toRemove.contains($0.id) }
        }
        rebuildSessionIndex()
        if let selectedSessionId, !sessions.contains(where: { $0.id == selectedSessionId }) {
            self.selectedSessionId = activeSessions.first?.id
        }
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
        purgeOrphanedCacheEntries()
    }

    /// 移除已不存在于 sessions 中的缓存条目，防止内存泄漏。
    private func purgeOrphanedCacheEntries() {
        let activeIds = Set(sessions.map(\.id))
        lastAssistantReplySoundAt = lastAssistantReplySoundAt.filter { activeIds.contains($0.key) }
    }

    private func handleToolStart(_ message: DIMessage) {
        let session = findOrCreateSession(message)
        if let id = message.toolCallId, let index = session.events.firstIndex(where: { $0.toolCallId == id }) {
            if message.nativeEvent == "acp" || message.nativeEvent == "continue_snapshot" {
                session.updateEvent(at: index) { $0.tool = message.tool ?? session.events[index].tool }
                session.updateEvent(at: index) { $0.input = message.toolInput }
                if message.nativeMessageReplay != true, session.status != .completed, session.status != .observationUnavailable {
                    session.updateEvent(at: index) { $0.isComplete = false }
                    if index == session.events.lastIndex(where: { $0.isRunning }) { session.currentTool = session.events[index].tool }
                    reportIntegrationActivity(message, session: session)
                }
            }
            return
        }
        guard message.nativeMessageReplay != true else { return }
        let refreshCheckpoint = resumeSession(session, as: session.hasPendingInteraction ? session.status : .active)
        clearStaleInteraction(session)
        if !session.hasPendingInteraction { session.status = .active }
        let event = ToolEvent(tool: message.tool ?? "unknown", input: message.toolInput, toolCallId: message.toolCallId)
        session.appendEvent(event)
        session.currentTool = message.tool
        if refreshCheckpoint { persistSession(session) }
        audioEngine?.play(.toolStart, session: session)
        reportIntegrationActivity(message, session: session)
    }

    private func handleToolComplete(_ message: DIMessage) {
        let session = findOrCreateSession(message)
        let preservesTerminalState = session.status == .completed || session.status == .observationUnavailable
        clearStaleInteraction(session)
        let matchingIndex = session.events.lastIndex {
            if let id = message.toolCallId { return $0.toolCallId == id }
            return $0.toolCallId == nil && $0.tool == (message.tool ?? "") && !$0.isComplete
        }
        if let idx = matchingIndex {
            if message.nativeEvent == "acp" || message.nativeEvent == "continue_snapshot" {
                session.updateEvent(at: idx) { $0.tool = message.tool ?? session.events[idx].tool }
                session.updateEvent(at: idx) { $0.input = message.toolInput }
            }
            session.updateEvent(at: idx) { $0.result = message.toolResult }
            session.updateEvent(at: idx) { $0.linesAdded = message.linesAdded }
            session.updateEvent(at: idx) { $0.linesRemoved = message.linesRemoved }
            session.updateEvent(at: idx) { $0.isComplete = true }
            if resolvedAgentType(for: message) == .claudeCode, session.events[idx].tool != "Subagent" {
                session.updateEvent(at: idx) { $0.completionUnconfirmed = false }
            }
            session.updateEvent(at: idx) { $0.linesRead = ToolEvent.estimateLinesRead(from: message.toolResult) }
            session.updateEvent(at: idx) { $0.testResults = ToolEvent.parseTestResults(from: message.toolResult) }
        } else {
            // Amp 等接口只提供结果；也可能在应用启动前已发出开始事件。
            session.appendEvent(ToolEvent(tool: message.tool ?? "unknown", input: message.toolInput,
                result: message.toolResult, linesAdded: message.linesAdded, linesRemoved: message.linesRemoved,
                isComplete: true, linesRead: ToolEvent.estimateLinesRead(from: message.toolResult),
                testResults: ToolEvent.parseTestResults(from: message.toolResult), toolCallId: message.toolCallId))
        }
        if !preservesTerminalState { session.currentTool = session.events.last(where: { $0.isRunning })?.tool }
        if message.observedState == "error", message.nativeMessageReplay != true, !preservesTerminalState {
            if !session.hasPendingInteraction { session.status = .error }
            audioEngine?.play(.error, session: session)
        }
        updateTokenUsage(session: session, message: message)
        if preservesTerminalState, resolvedAgentType(for: message) == .claudeCode {
            persistSession(session)
        }
        if !preservesTerminalState { reportIntegrationActivity(message, session: session) }
    }

    private func handleStatus(_ message: DIMessage) {
        let session = findOrCreateSession(message)
        let previousStatus = session.status
        let wasClosed = previousStatus == .completed || previousStatus == .observationUnavailable
        let completionUnconfirmed = message.observedState == SessionStatus.completionUnconfirmed.rawValue
        let informational = message.statusIsAssistantReply == false && message.observedState == nil
        let preserveExistingState = (completionUnconfirmed || informational) && (session.hasPendingInteraction
            || [.completed, .error, .observationUnavailable, .waitingPermission, .waitingAnswer, .waitingPlanReview].contains(session.status))
        if let prompt = message.prompt, let id = nativeChatID(message, role: .user) {
            let wasCurrentPrompt = session.chatHistory.last(where: { $0.role == .user })?.id == id
            if let index = session.chatHistory.firstIndex(where: { $0.id == id }) {
                if prompt.isEmpty { session.chatHistory.remove(at: index) }
                else { session.replaceChatMessage(at: index, with: ChatMessage(id: id, timestamp: session.chatHistory[index].timestamp, role: .user, content: prompt)) }
            } else if !prompt.isEmpty {
                session.appendChatMessage(ChatMessage(id: id, timestamp: message.timestamp, role: .user, content: prompt))
            }
            if session.chatHistory.last(where: { $0.role == .user })?.id == id { session.prompt = prompt }
            else if wasCurrentPrompt { session.prompt = session.chatHistory.last(where: { $0.role == .user })?.content ?? "" }
        }
        let text = message.status ?? ""
        var latestMessage = true
        defer {
            let resumed = session.status != .completed && session.status != .observationUnavailable
            let knownState = message.observedState.flatMap(SessionStatus.init(rawValue:)) != nil
            if latestMessage, (!wasClosed || resumed), knownState || !text.isEmpty || !(message.prompt ?? "").isEmpty {
                reportIntegrationActivity(message, session: session)
            }
        }
        if message.status == "", message.statusIsAssistantReply == true,
           let id = nativeChatID(message, role: .assistant), let index = session.chatHistory.firstIndex(where: { $0.id == id }) {
            let wasLatest = index == session.chatHistory.indices.last
            session.chatHistory.remove(at: index)
            if wasLatest { session.agentResponse = session.chatHistory.last(where: { $0.role == .assistant })?.content ?? "" }
            latestMessage = wasLatest
        }
        if !text.isEmpty, message.statusIsAssistantReply != false {
            if let id = nativeChatID(message, role: .assistant) {
                if let index = session.chatHistory.firstIndex(where: { $0.id == id }) {
                    session.replaceChatMessage(at: index, with: ChatMessage(id: id, timestamp: session.chatHistory[index].timestamp, role: .assistant, content: text))
                    latestMessage = index == session.chatHistory.indices.last
                } else {
                    session.appendChatMessage(ChatMessage(id: id, timestamp: message.timestamp, role: .assistant, content: text))
                }
            } else if let lastIdx = session.chatHistory.indices.last, session.chatHistory[lastIdx].role == .assistant {
                session.replaceChatMessage(at: lastIdx, with: ChatMessage(
                    id: session.chatHistory[lastIdx].id, timestamp: Date(), role: .assistant, content: text
                ))
            } else {
                session.appendChatMessage(
                    ChatMessage(timestamp: Date(), role: .assistant, content: text)
                )
            }
            if latestMessage { session.agentResponse = text }
        }
        if latestMessage, !preserveExistingState, message.status != nil || message.observedState != nil { session.statusText = text }

        if completionUnconfirmed {
            // 准备停止不是最终结果，也不能替代仍在等待的用户交互或已知错误。
            if !preserveExistingState {
                session.status = .completionUnconfirmed
                session.currentTool = nil
            }
            // 保留既有的助手回复提示音；收到回复不等于确认整个会话完成。
            if message.statusIsAssistantReply == true, !text.isEmpty, message.nativeMessagePartial != true,
               message.nativeMessageReplay != true, latestMessage {
                playAssistantReplySoundDebounced(sessionId: session.id)
            }
            updateTokenUsage(session: session, message: message)
            persistSession(session)
            return
        }

        if message.nativeMessageReplay == true {
            updateTokenUsage(session: session, message: message)
            return
        }

        if let rawState = message.observedState,
           let observed = SessionStatus(rawValue: rawState),
           [.active, .idle, .waitingPermission, .waitingAnswer, .waitingPlanReview, .error].contains(observed) {
            if observed == .idle {
                if !isKimiCodeMessage(message) || !session.hasPendingInteraction { cancelPendingInteractions(session) }
                session.currentTool = nil
                selectNextInteraction()
            }
            let refreshCheckpoint: Bool
            if observed == .error {
                refreshCheckpoint = false
                if session.status != .completed && session.status != .observationUnavailable { session.status = observed }
            } else {
                refreshCheckpoint = resumeSession(session, as: observed)
            }
            if observed == .error { audioEngine?.play(.error, session: session) }
            else if observed == .idle, message.statusIsAssistantReply != false, !text.isEmpty,
                    message.nativeMessagePartial != true, message.nativeMessageReplay != true, latestMessage {
                playAssistantReplySoundDebounced(sessionId: session.id)
            }
            updateTokenUsage(session: session, message: message)
            if refreshCheckpoint || previousStatus == .completionUnconfirmed { persistSession(session) }
            return
        }

        if message.statusIsAssistantReply != nil {
            if message.statusIsAssistantReply == true, !text.isEmpty, message.nativeMessagePartial != true,
               message.nativeMessageReplay != true, latestMessage {
                playAssistantReplySoundDebounced(sessionId: session.id)
            }
            updateTokenUsage(session: session, message: message)
            return
        }
        let lower = text.lowercased()
        if lower.contains("compact") || lower.contains("context window") {
            audioEngine?.play(.contextCompacting, session: session)
        } else if lower.contains("error") || lower.contains("failed") || lower.contains("fatal") {
            if session.status != .completed && session.status != .observationUnavailable {
                session.status = .error
                audioEngine?.play(.error, session: session)
            }
        } else if !text.isEmpty, message.statusIsAssistantReply != false {
            // Assistant reply via Notification / progress — same chime as session end (user preference: "Session complete").
            playAssistantReplySoundDebounced(sessionId: session.id)
        }
        updateTokenUsage(session: session, message: message)
    }

    /// 原生消息 ID 派生为已有 UUID 字段，无需迁移历史库；重连更新也能定位同一条记录。
    private func nativeChatID(_ message: DIMessage, role: ChatMessage.ChatRole) -> UUID? {
        guard let id = message.nativeMessageId, !id.isEmpty, id.utf8.count <= 512, !id.utf8.contains(0) else { return nil }
        let key = message.sessionId + "\0" + role.rawValue + "\0" + id
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Resolves the session for `sessionEnd` when hooks use `cursor-*` vs `claude_code-*` ids for the same run.
    private func sessionForEndMessage(_ message: DIMessage) -> AgentSession? {
        if let s = sessions.first(where: { $0.id == message.sessionId }) {
            return s
        }
        return sessionMatchingMirror(of: message)
    }

    private func playAssistantReplySoundDebounced(sessionId: String) {
        let now = Date().timeIntervalSince1970
        let last = lastAssistantReplySoundAt[sessionId] ?? 0
        guard now - last >= assistantReplySoundMinInterval else { return }
        lastAssistantReplySoundAt[sessionId] = now
        audioEngine?.play(.sessionEnd)
    }

    private func handleSubagentStart(_ message: DIMessage) {
        let parentId = message.parentSessionId ?? message.sessionId
        guard let parent = sessions.first(where: { $0.id == parentId && $0.status != .completed })
        else { return }
        if let subId = message.subagentId,
           let index = parent.events.firstIndex(where: { $0.tool == "Subagent" && $0.toolCallId == subId }) {
            // 已核实 Claude/Qwen 恢复同一子代理时重发 Start；连续重复仍只保留一条记录。
            if [AgentType.claudeCode.rawValue, AgentType.qwen.rawValue].contains(message.agentType ?? ""),
               message.nativeEvent == "SubagentStart",
               parent.events[index].completionUnconfirmed, !parent.events[index].isComplete {
                parent.updateEvent(at: index) { $0.completionUnconfirmed = false }
                parent.lastActivityTime = Date()
                reportIntegrationActivity(message, session: parent)
            }
            return
        }
        let subId = message.subagentId ?? UUID().uuidString
        if !parent.subagentIds.contains(subId) {
            parent.subagentIds.append(subId)
        }
        parent.lastActivityTime = Date()
        let event = ToolEvent(tool: "Subagent", input: message.prompt, toolCallId: message.subagentId)
        parent.appendEvent(event)
        reportIntegrationActivity(message, session: parent)
    }

    private func handleSubagentEnd(_ message: DIMessage) {
        let parentId = message.parentSessionId ?? message.sessionId
        guard let parent = sessions.first(where: { $0.id == parentId && $0.status != .completed })
        else { return }
        let provisional = message.subagentEndIsProvisional == true
        // 未确认的结束不能用旧协议的“最后一个子代理”兜底匹配。
        if provisional && message.subagentId == nil { return }
        let matchingIndex: Int?
        if let subId = message.subagentId {
            guard let index = parent.events.lastIndex(where: {
                $0.tool == "Subagent" && $0.toolCallId == subId && !$0.isComplete
            }) else { return }
            matchingIndex = index
            if !provisional { parent.subagentIds.removeAll { $0 == subId } }
        } else {
            matchingIndex = parent.events.lastIndex(where: { $0.tool == "Subagent" && !$0.isComplete })
        }
        if provisional, let idx = matchingIndex {
            guard !parent.events[idx].completionUnconfirmed else { return }
            parent.updateEvent(at: idx) { $0.completionUnconfirmed = true }
            parent.lastActivityTime = Date()
            if parent.currentTool == "Subagent" {
                parent.currentTool = parent.events.last(where: { $0.isRunning })?.tool
            }
            reportIntegrationActivity(message, session: parent)
            return
        }
        parent.lastActivityTime = Date()
        updateTokenUsage(session: parent, message: message)
        if let idx = matchingIndex {
            parent.updateEvent(at: idx) { $0.isComplete = true }
            parent.updateEvent(at: idx) { $0.completionUnconfirmed = false }
            let hasCodewhaleOutcome = resolvedAgentType(for: message) == .deepseek && message.nativeEvent == "subagent_complete"
            if hasCodewhaleOutcome {
                parent.updateEvent(at: idx) { $0.result = message.toolResult }
                parent.updateEvent(at: idx) { $0.nativeCompletionStatus = message.status }
            } else {
                parent.updateEvent(at: idx) { $0.result = "Completed" }
            }
            if parent.currentTool == "Subagent" {
                parent.currentTool = parent.events.last(where: { $0.isRunning })?.tool
            }
            if hasCodewhaleOutcome { persistSession(parent) }
            reportIntegrationActivity(message, session: parent)
        }
    }

    private func handleContextCompact(_ message: DIMessage) {
        let session = findOrCreateSession(message)
        guard message.nativeMessageReplay != true else { return }
        let refreshCheckpoint = resumeSession(session, as: .compacting)
        session.statusText = message.status ?? "Context compacting..."
        audioEngine?.play(.contextCompacting, session: session)
        updateTokenUsage(session: session, message: message)
        if refreshCheckpoint || isCodexTurnObservation(message) { persistSession(session) }
        reportIntegrationActivity(message, session: session)
        // 有原生压缩结果的入口等待事实，不用旧客户端的计时器推断恢复。
        if isKimiCodeMessage(message), message.nativeEvent == "kimi_code.PreCompact" { return }
        if isCodexTurnObservation(message), message.nativeEvent == "PreCompact" { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak session] in
            self?.performPersistedOperation { [weak self, weak session] in
                // 只在 session 仍存在且仍处于 compacting 时恢复。
                guard let self, let session, self.sessions.contains(where: { $0 === session }) else { return }
                if var observation = session.kimiCodeApprovalObservation {
                    guard observation.baseStatus == .compacting,
                          session.status != .completed, session.status != .observationUnavailable else { return }
                    observation.baseStatus = .active
                    session.kimiCodeApprovalObservation = observation
                    self.applyKimiCodeProjection(session)
                    self.persistSession(session)
                } else if session.status == .compacting {
                    session.status = .active
                }
            }
        }
    }

    private func handleRecap(_ message: DIMessage) {
        let session = findOrCreateSession(message)
        session.recapText = message.recapText
        if session.status != .completed, session.status != .observationUnavailable,
           !(message.recapText ?? "").isEmpty { reportIntegrationActivity(message, session: session) }
    }

    /// Legacy activity may imply an external response; native requests require
    /// their matching resolution because unrelated tools can run concurrently.
    private func clearStaleInteraction(_ session: AgentSession) {
        if session.kimiCodeApprovalObservation != nil, session.hasPendingInteraction { return }
        var clearedInteraction = false

        switch session.status {
        case .waitingPermission where session.pendingPermission?.nativeRequestId == nil:
            session.pendingPermission?.cancel?()
            session.pendingPermission = nil
            session.status = .active
            clearedInteraction = true
        case .waitingAnswer where session.pendingQuestion?.nativeRequestId == nil:
            session.pendingQuestion?.cancel?()
            session.pendingQuestion = nil
            session.status = .active
            clearedInteraction = true
        case .waitingPlanReview:
            session.pendingPlanReview?.cancel?()
            session.pendingPlanReview = nil
            session.status = .active
            clearedInteraction = true
        default:
            break
        }

        if session.hasPendingInteraction {
            session.status = session.pendingPermission != nil ? .waitingPermission
                : session.pendingQuestion != nil ? .waitingAnswer : .waitingPlanReview
        }

        // 最后一个交互被外部清除时取消恢复；其他待办仍保留本轮显示权。
        if clearedInteraction {
            selectNextInteraction()
            approvalInterruption.cancelIfFinished(hasPendingInteractions: hasInteraction)
        }
    }

    private func updateTokenUsage(session: AgentSession, message: DIMessage) {
        if message.usageIsCumulative == true {
            // 重复及乱序到达的会话快照都不能重复计费或回退已观测用量。
            if let t = message.tokensIn { session.tokenUsage.inputTokens = max(session.tokenUsage.inputTokens, t) }
            if let t = message.tokensOut { session.tokenUsage.outputTokens = max(session.tokenUsage.outputTokens, t) }
            if let t = message.totalTokens { session.tokenUsage.totalTokens = max(session.tokenUsage.totalTokens, t) }
            if let c = message.costUSD { session.tokenUsage.estimatedCostUSD = max(session.tokenUsage.estimatedCostUSD, c) }
        } else {
            if let t = message.tokensIn { session.tokenUsage.inputTokens += t }
            if let t = message.tokensOut { session.tokenUsage.outputTokens += t }
            if let t = message.totalTokens { session.tokenUsage.totalTokens = t }
            if let c = message.costUSD { session.tokenUsage.estimatedCostUSD += c }
        }
        if let m = message.model, !m.isEmpty { session.tokenUsage.model = m }
    }

    /// 内存缺失不等于新会话。只查询精确 ID；关闭历史不能被迟到事件重建为空壳。
    private func restoreArchivedSessionIfNeeded(_ message: DIMessage, activate: Bool = true) -> Bool {
        if sessionById(message.sessionId) != nil || sessionMatchingMirror(of: message) != nil { return true }
        guard let persistenceManager else { return true }
        do {
            var restored = try persistenceManager.sessionState(sessionId: message.sessionId)
            let source = mirrorSource(for: message)
            if restored == nil, let source, let suffix = mirroredSessionSuffix(from: message.sessionId) {
                let candidates: [AgentType] = source == .claudeCode ? [.cursor, .trae, .windsurf] : [.claudeCode]
                var matches: [SessionHistoryState] = []
                for candidate in candidates {
                    if let stored = try persistenceManager.sessionState(sessionId: candidate.rawValue + "-" + suffix),
                       source == .claudeCode ? stored.agentType == candidate : (stored.agentType == .claudeCode || stored.agentType == source) {
                        matches.append(stored)
                    }
                }
                guard matches.count <= 1 else { return false }
                restored = matches.first
            }
            guard let stored = restored else {
                codexTurns.removeValue(forKey: message.sessionId)
                if unsavedKimiBackgroundTasks.removeValue(forKey: message.sessionId) != nil {
                    unsavedSessionIDs.remove(message.sessionId)
                }
                return true
            }
            let incomingAgent = AgentType.from(message.agentType)
                ?? message.sessionId.split(separator: "-", maxSplits: 1).first.flatMap { AgentType(rawValue: String($0)) }
            let allowedMirror = source == .claudeCode && isCursorFamily(stored.agentType)
                || source.map { isCursorFamily($0) && stored.id.hasPrefix("claude_code-")
                    && (stored.agentType == .claudeCode || stored.agentType == $0) } == true
            guard incomingAgent == nil || incomingAgent == stored.agentType || allowedMirror,
                  stored.sourceNamespace == message.sourceNamespace,
                  stored.sourceInstanceId == message.sourceInstanceId,
                  stored.nativeTaskId == message.nativeTaskId else { return false }

            if source == .claudeCode, isCursorFamily(stored.agentType),
               message.type == .sessionStart || message.type == .sessionEnd { return false }
            if let source, isCursorFamily(source), stored.agentType == .claudeCode,
               let suffix = mirroredSessionSuffix(from: message.sessionId) {
                for other in [AgentType.cursor, .trae, .windsurf] where other != source {
                    if try persistenceManager.sessionState(sessionId: other.rawValue + "-" + suffix) != nil { return false }
                }
            }

            let isClosed = stored.status == .completed || stored.status == .observationUnavailable
            if isClosed {
                if isKimiCodeMessage(message), message.nativeEvent == "kimi_code.UserPromptSubmit" { return false }
                guard message.nativeMessageReplay != true else { return false }
                switch message.type {
                case .sessionStart, .toolStart, .contextCompact, .permissionRequest, .question, .planReview:
                    break
                case .statusUpdate, .progress:
                    guard let raw = message.observedState, let state = SessionStatus(rawValue: raw),
                          [.active, .idle, .waitingPermission, .waitingAnswer, .waitingPlanReview].contains(state) else { return false }
                default:
                    return false
                }
            }
            guard activate else { return true }
            guard let session = try persistenceManager.restoreSession(sessionId: stored.id) else { return false }
            if isClosed, message.type == .sessionStart {
                var canonical = message
                canonical.sessionId = session.id
                let ids = [nativeChatID(message, role: .user), nativeChatID(canonical, role: .user)].compactMap { $0 }
                guard !session.chatHistory.contains(where: { ids.contains($0.id) }) else { return false }
            }
            if isClosed, message.type == .toolStart, let id = message.toolCallId,
               session.events.contains(where: { $0.toolCallId == id }) { return false }
            if let source, isCursorFamily(source), session.agentType == .claudeCode { session.agentType = source }
            let index = sessions.count
            sessions.append(session)
            updateIndexForAppend(session, at: index)
            return true
        } catch {
            // 保留存储层错误，下一次消息可重试；不可把读取失败当成不存在。
            return false
        }
    }

    /// Interactive requests fold mirrored hook ids (`cursor-*` / `claude_code-*` same suffix) like `findOrCreateSession`.
    private func findOrCreateSessionForInteraction(_ message: DIMessage) -> AgentSession {
        let session = sessionById(message.sessionId)
            ?? sessionMatchingMirror(of: message)
            ?? createNewSession(from: message)

        session.lastActivityTime = Date()
        return session
    }

    private func findOrCreateSession(_ message: DIMessage) -> AgentSession {
        let session = sessionById(message.sessionId)
            ?? sessionMatchingMirror(of: message)
            ?? createNewSession(from: message)

        session.lastActivityTime = Date()
        return session
    }

    // MARK: - Session resolution helpers

    private func rebuildSessionIndex() {
        sessionIndex.removeAll()
        suffixCache.removeAll()
        subagentMap.removeAll()
        for (i, session) in sessions.enumerated() {
            sessionIndex[session.id] = i
            if let suffix = mirroredSessionSuffix(from: session.id) {
                suffixCache[session.id] = suffix
            }
            // 构建 subagent 关系
            for childId in session.subagentIds {
                if let child = sessions.first(where: { $0.id == childId }) {
                    subagentMap[session.id, default: []].append(child)
                }
            }
        }
    }

    private func updateIndexForAppend(_ session: AgentSession, at index: Int) {
        sessionIndex[session.id] = index
        if let suffix = mirroredSessionSuffix(from: session.id) {
            suffixCache[session.id] = suffix
        }
    }

    private func removeIndexForSession(_ sessionId: String) {
        sessionIndex.removeValue(forKey: sessionId)
        suffixCache.removeValue(forKey: sessionId)
    }

    private func sessionById(_ sessionId: String) -> AgentSession? {
        if sessionIndex.isEmpty && !sessions.isEmpty { rebuildSessionIndex() }
        guard let index = sessionIndex[sessionId] else { return nil }
        guard index < sessions.count, sessions[index].id == sessionId else {
            rebuildSessionIndex()
            guard let freshIndex = sessionIndex[sessionId] else { return nil }
            return sessions[freshIndex]
        }
        return sessions[index]
    }

    private func createNewSession(from message: DIMessage) -> AgentSession {
        let agentType = resolvedAgentType(for: message)
        var startTime = Date()
        if let namespace = message.sourceNamespace, let instance = message.sourceInstanceId {
            startTime = persistenceManager?.observationStartTime(sessionId: message.sessionId, namespace: namespace,
                instance: instance) ?? observationWallClock()
        }
        let session = AgentSession(
            id: message.sessionId,
            agentType: agentType,
            terminal: message.terminal ?? "",
            workingDirectory: message.workingDir ?? "",
            prompt: message.prompt ?? "",
            startTime: startTime
        )
        if message.hasObservationMetadata {
            session.sourceNamespace = message.sourceNamespace
            session.sourceInstanceId = message.sourceInstanceId
            session.nativeTaskId = message.nativeTaskId
            session.status = .observationUnavailable
        }
        let index = sessions.count
        sessions.append(session)
        updateIndexForAppend(session, at: index)
        return session
    }

    // MARK: - 审批置顶与恢复

    /// 有审批时强制置顶显示灵动岛（即使 xnook 在前台）
    private func forceToShowForApproval() {
        guard allowsExternalApplicationAccess else { return }
        // 精确检查 xnook 是否正在运行（而非任意其他灵动岛应用）
        if AppSwitcher.shared.isIslandRunning(named: "xnook") {
            approvalInterruption.markInterrupted()
        }

        // 强制显示灵动岛窗口（重新定位到当前主界面所在屏幕，避免多桌面/多显示器时展开到错误位置）
        if let window = AppDelegate.shared?.notchWindow {
            window.showAtActiveScreen()
        }
    }

    /// 审批完成后恢复到 xnook（如果之前是从 xnook 被中断的）
    private func restoreToXnookIfNeeded() {
        guard allowsExternalApplicationAccess else { return }
        guard approvalInterruption.takeRestorationIfReady(hasPendingInteractions: hasInteraction) else { return }

        // 精确检查 xnook 是否仍然运行
        guard AppSwitcher.shared.isIslandRunning(named: "xnook") else { return }

        // 切换回 xnook
        AppSwitcher.shared.switchToIsland(named: "xnook")
    }
}
