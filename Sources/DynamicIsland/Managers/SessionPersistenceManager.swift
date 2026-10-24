import Foundation
import Observation
import SwiftData

struct SessionHistoryState {
    let id: String
    let agentType: AgentType
    let status: SessionStatus
    let sourceNamespace: String?
    let sourceInstanceId: String?
    let nativeTaskId: String?
}

struct HistoryPage {
    let sessions: [StoredSession]
    let totalCount: Int
}

enum HistoryReadError: LocalizedError {
    case storageUnavailable
    case invalidPage
    case historyChanged

    var errorDescription: String? {
        switch self {
        case .storageUnavailable: return L10n.isChinese ? "历史存储不可用，请重试。" : "History storage is unavailable. Please retry."
        case .invalidPage: return L10n.isChinese ? "历史分页参数无效。" : "Invalid history page parameters."
        case .historyChanged: return L10n.isChinese ? "历史已发生变化，请重新读取。" : "History changed. Please read it again."
        }
    }
}

@Observable
@MainActor
final class SessionPersistenceManager {
    var modelContainer: ModelContainer? { didSet {
        invalidateHistoryJobs()
        containerGeneration &+= 1
        containerWriteToken.invalidate()
        containerWriteToken = HistoryJobToken(serializedCommit: true)
        mutationStore = nil
        backgroundStore = nil
        historyContext = nil
        childSnapshots = [:]
        childSnapshotOrder = []
    } }
    @ObservationIgnored private var historyContext: ModelContext?
    private(set) var lastSaveError: String?
    private(set) var lastReadError: String?
    private(set) var revision = 0
    let usesBackgroundWrites: Bool
    @ObservationIgnored private var childSnapshots: [String: SessionChildSnapshot] = [:]
    @ObservationIgnored private var childSnapshotOrder: [String] = []
    @ObservationIgnored private var backgroundStore: HistoryBackgroundStore?
    @ObservationIgnored private var mutationStore: HistoryBackgroundStore?
    @ObservationIgnored private let historyJobs = HistoryJobRegistry()
    @ObservationIgnored private var containerGeneration: UInt = 0
    @ObservationIgnored private var containerWriteToken = HistoryJobToken(serializedCommit: true)
    @ObservationIgnored private var mutationTail: Task<Void, Never>?
    @ObservationIgnored private var mutationSequence: UInt = 0
    @ObservationIgnored private let beforeBackgroundCommit: @Sendable () throws -> Void
    private(set) var pendingWriteCount = 0

    init(usesBackgroundWrites: Bool = false, beforeBackgroundCommit: @escaping @Sendable () throws -> Void = {}) {
        self.usesBackgroundWrites = usesBackgroundWrites
        self.beforeBackgroundCommit = beforeBackgroundCommit
    }

    @ObservationIgnored private(set) var lastChildWriteCount = 0

    @discardableResult
    func setupContainer(isStoredInMemoryOnly: Bool = false, storeURL: URL? = nil) -> Bool {
        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self, StoredKimiCodeApprovalOrphan.self])
        let config: ModelConfiguration
        if let storeURL, !isStoredInMemoryOnly {
            config = ModelConfiguration(schema: schema, url: storeURL)
        } else {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isStoredInMemoryOnly)
        }
        do {
            // ModelContainer 打开磁盘库时即可迁移 schema，恢复点必须在此之前完成。
            if !isStoredInMemoryOnly {
                try HistoryStoreBackup.prepareBackupIfNeeded(storeURL: config.url)
            }
            let container = try ModelContainer(for: schema, configurations: [config])
            try backfillLegacyIdentifiers(in: container.mainContext)
            modelContainer = container
            lastSaveError = nil
            print("[Persistence] Container setup complete")
            return true
        } catch {
            modelContainer = nil
            lastSaveError = error.localizedDescription
            print("[Persistence] Container setup failed")
            return false
        }
    }

    @discardableResult
    func save(session: AgentSession) -> Bool {
        // 同步兼容入口不能越过已排队的事务；生产使用后台入口。
        guard pendingWriteCount == 0 else {
            lastSaveError = "History writes are still pending."
            return false
        }
        invalidateHistoryJobs(destructiveOnly: true)
        guard let modelContainer else { lastSaveError = "History storage is unavailable."; return false }
        let snapshot = SessionSaveSnapshot(session: session), registry = historyJobs
        let lease = HistoryCommitLease(registry: registry)
        defer { lease.end() }
        do {
            let result = try SessionSaveWorker.save(snapshot: snapshot, previousChildren: childSnapshots[session.id],
                container: modelContainer, beforeCommit: { lease.begin() })
            acknowledge(result, snapshot: snapshot, session: session)
            return true
        } catch {
            lastChildWriteCount = 0
            lastSaveError = error.localizedDescription
            return false
        }
    }

    /// 在reducer内冻结值，稍后执行时不能把新的会话状态冒充早先的检查点。
    func makeSaveOperation(session: AgentSession) -> @MainActor () async -> Bool {
        let snapshot = SessionSaveSnapshot(session: session)
        let generation = containerGeneration
        invalidateHistoryJobs(destructiveOnly: true)
        return { [self, session] in
            guard generation == containerGeneration else { return false }
            guard let container = modelContainer else { lastSaveError = "History storage is unavailable."; return false }
            do {
                return try await enqueueMutation { [self] in
                    guard generation == containerGeneration else { throw HistoryReadError.historyChanged }
                    let store = mutationStore ?? HistoryBackgroundStore(container: container)
                    mutationStore = store
                    let registry = historyJobs, token = containerWriteToken, beforeCommit = beforeBackgroundCommit
                    let result = try await store.save(snapshot: snapshot, previousChildren: childSnapshots[snapshot.id], registry: registry) {
                        try token.check()
                        try beforeCommit()
                        try token.check()
                        registry.invalidate()
                    }
                    guard generation == containerGeneration else { throw HistoryReadError.historyChanged }
                    acknowledge(result, snapshot: snapshot, session: session)
                    return true
                }
            } catch {
                if generation == containerGeneration {
                    lastChildWriteCount = 0
                    lastSaveError = error.localizedDescription
                }
                return false
            }
        }
    }

    func saveAsync(session: AgentSession) async -> Bool {
        await makeSaveOperation(session: session)()
    }

    private func acknowledge(_ result: SessionSaveWorker.Result, snapshot: SessionSaveSnapshot, session: AgentSession) {
        childSnapshots[snapshot.id] = result.committedChildren
        childSnapshotOrder.removeAll { $0 == snapshot.id }
        childSnapshotOrder.append(snapshot.id)
        while childSnapshotOrder.count > 32 { childSnapshots.removeValue(forKey: childSnapshotOrder.removeFirst()) }
        session.markChildrenPersisted(ifUnchangedSince: snapshot.childRevision)
        if session.status == snapshot.status, session.statusText == snapshot.statusText,
           session.completionNeedsReview == snapshot.completionNeedsReview,
           session.kimiCodeApprovalObservation == snapshot.kimiCodeApprovalObservation,
           session.hasPendingInteraction == snapshot.hasPendingInteraction {
            session.kimiCodeApprovalObservation = result.mergedApprovalObservation
            session.status = result.storedStatus
            session.completionNeedsReview = result.completionNeedsReview
            if let text = result.projectedStatusText { session.statusText = text }
        } else if let orphan = result.mergedOrphanObservation {
            // 已消费的孤儿事实不能丢；只合并身份事实，不覆盖更新后的基础状态。
            var current = session.kimiCodeApprovalObservation
                ?? KimiCodeApprovalObservation(baseStatus: session.status, baseStatusText: session.statusText)
            let previousDisplayedStatus = current.displayedStatus
            current.merge(orphan)
            if session.status == .completed {
                current.endSession()
            } else if session.status == .observationUnavailable {
                current.markBackgroundTasksUnconfirmed()
            } else if !session.hasPendingInteraction, let previousDisplayedStatus,
                      session.status == previousDisplayedStatus {
                session.status = current.displayedStatus ?? current.baseStatus
                session.statusText = current.displayedText ?? current.baseStatusText
            }
            session.kimiCodeApprovalObservation = current
        }
        if result.changed {
            invalidateHistoryJobs()
            historyContext = nil
            revision += 1
        }
        lastChildWriteCount = result.childWriteCount
        lastSaveError = nil
    }

    private func enqueueMutation<T: Sendable>(cancelable: Bool = false,
        _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = mutationTail
        mutationSequence &+= 1
        let sequence = mutationSequence
        pendingWriteCount += 1
        let task = Task { @MainActor in
            await previous?.value
            if cancelable { try Task.checkCancellation() }
            return try await work()
        }
        mutationTail = Task { _ = try? await task.value }
        defer {
            pendingWriteCount -= 1
            if sequence == mutationSequence { mutationTail = nil }
        }
        if cancelable {
            return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        }
        // 已接受的检查点不会因等待者取消而丢弃；退出会等待真实提交结果。
        return try await task.value
    }

    func flushPendingWrites() async -> Bool {
        while let tail = mutationTail { await tail.value; await Task.yield() }
        return lastSaveError == nil
    }

    func saveKimiCodeApprovalOrphanAsync(sessionId: String, observation: KimiCodeApprovalObservation) async -> Bool {
        let generation = containerGeneration
        guard let container = modelContainer else { lastSaveError = "History storage is unavailable."; return false }
        invalidateHistoryJobs(destructiveOnly: true)
        do {
            try await enqueueMutation { [self] in
                guard generation == containerGeneration else { throw HistoryReadError.historyChanged }
                let store = mutationStore ?? HistoryBackgroundStore(container: container)
                mutationStore = store
                let registry = historyJobs, token = containerWriteToken
                try await store.saveOrphan(sessionID: sessionId, observation: observation, registry: registry) {
                    try token.check(); registry.invalidate()
                }
                guard generation == containerGeneration else { throw HistoryReadError.historyChanged }
                invalidateHistoryJobs()
                historyContext = nil
                revision += 1
                lastSaveError = nil
            }
            return true
        } catch {
            if generation == containerGeneration { lastSaveError = error.localizedDescription }
            return false
        }
    }

    /// 被动迟到消息只需父记录；避免每次丢弃消息前加载完整工具和聊天历史。
    func sessionState(sessionId: String) throws -> SessionHistoryState? {
        do {
            guard let modelContainer else { throw CocoaError(.fileReadUnknown) }
            var descriptor = FetchDescriptor<StoredSession>(predicate: #Predicate { $0.sessionId == sessionId })
            descriptor.fetchLimit = 1
            let context = ModelContext(modelContainer)
            context.autosaveEnabled = false
            guard let stored = try context.fetch(descriptor).first else { return nil }
            return SessionHistoryState(id: stored.sessionId, agentType: stored.agentType, status: stored.status,
                sourceNamespace: stored.sourceNamespace, sourceInstanceId: stored.sourceInstanceId, nativeTaskId: stored.nativeTaskId)
        } catch {
            lastSaveError = error.localizedDescription
            throw error
        }
    }

    /// 按唯一会话 ID 读取；读取失败必须与没有历史记录区分，不能用空壳覆盖旧历史。
    func restoreSession(sessionId: String) throws -> AgentSession? {
        do {
            guard let modelContainer else { throw CocoaError(.fileReadUnknown) }
            var descriptor = FetchDescriptor<StoredSession>(predicate: #Predicate { $0.sessionId == sessionId })
            descriptor.fetchLimit = 1
            let context = ModelContext(modelContainer)
            context.autosaveEnabled = false
            guard let stored = try context.fetch(descriptor).first else { return nil }
            let session = AgentSession(id: stored.sessionId, agentType: stored.agentType,
                terminal: stored.terminal, workingDirectory: stored.workingDirectory,
                prompt: stored.prompt, startTime: stored.startTime)
            session.status = stored.status
            session.completedAt = stored.completedAt
            session.completionNeedsReview = stored.completionNeedsReview ?? false
            session.observationEndedAt = stored.observationEndedAt
            session.sourceNamespace = stored.sourceNamespace
            session.sourceInstanceId = stored.sourceInstanceId
            session.nativeTaskId = stored.nativeTaskId
            if let data = stored.kimiCodeApprovalObservationData {
                session.kimiCodeApprovalObservation = try KimiCodeApprovalObservation.decode(data)
            } else if stored.agentType == .kimi, stored.sessionId.hasPrefix("kimi_code-"), stored.status == .waitingPermission {
                // 旧记录只有 waiting，缺少请求身份时不能把任意 Result 当作清除证明。
                session.kimiCodeApprovalObservation = KimiCodeApprovalObservation(unidentified: true)
            }
            if stored.status != .completed, stored.status != .observationUnavailable,
               let observation = session.kimiCodeApprovalObservation {
                session.status = observation.displayedStatus ?? observation.baseStatus
                session.statusText = observation.displayedText ?? observation.baseStatusText
            }
            session.recapText = stored.recapText
            session.tokenUsage = TokenUsage(inputTokens: stored.inputTokens, outputTokens: stored.outputTokens,
                totalTokens: stored.totalTokens, estimatedCostUSD: stored.estimatedCostUSD, model: stored.model)
            session.events = stored.toolEvents.sorted { $0.timestamp < $1.timestamp }.map { event in
                let total = event.testPassed + event.testFailed + event.testSkipped
                return ToolEvent(tool: event.tool, input: event.input, result: event.result,
                    linesAdded: event.linesAdded, linesRemoved: event.linesRemoved, isComplete: event.isComplete,
                    linesRead: event.linesRead, testResults: total > 0 ? ToolEvent.TestResults(
                        passed: event.testPassed, failed: event.testFailed, skipped: event.testSkipped, total: total) : nil,
                    toolCallId: event.toolCallId, completionUnconfirmed: event.completionUnconfirmed,
                    nativeCompletionStatus: event.nativeCompletionStatus,
                    id: event.eventId ?? UUID(), timestamp: event.timestamp)
            }
            session.chatHistory = stored.chatMessages.sorted { $0.timestamp < $1.timestamp }.compactMap { message in
                guard let role = ChatMessage.ChatRole(rawValue: message.role) else { return nil }
                return ChatMessage(id: message.messageId ?? UUID(), timestamp: message.timestamp,
                    role: role, content: message.content)
            }
            session.agentResponse = session.chatHistory.last { $0.role == .assistant }?.content ?? ""
            // 不恢复历史交互回调、窗口句柄或 socket；它们属于已经结束的进程。
            return session
        } catch {
            lastSaveError = error.localizedDescription
            throw error
        }
    }

    func observationStartTime(sessionId: String, namespace: String, instance: String) -> Date? {
        guard let modelContainer else { return nil }
        var descriptor = FetchDescriptor<StoredSession>(predicate: #Predicate { $0.sessionId == sessionId })
        descriptor.fetchLimit = 1
        do {
            guard let stored = try ModelContext(modelContainer).fetch(descriptor).first,
                  stored.sourceNamespace == namespace, stored.sourceInstanceId == instance else { return nil }
            return stored.startTime
        } catch {
            lastSaveError = error.localizedDescription
            return nil
        }
    }

    func kimiCodeApprovalOrphan(sessionId: String) throws -> KimiCodeApprovalObservation? {
        do {
            guard let modelContainer else { throw CocoaError(.fileReadUnknown) }
            let context = ModelContext(modelContainer)
            context.autosaveEnabled = false
            guard let orphan = try kimiApprovalOrphan(sessionId: sessionId, in: context) else { return nil }
            return try KimiCodeApprovalObservation.decode(orphan.observationData)
        } catch {
            lastSaveError = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func saveKimiCodeApprovalOrphan(sessionId: String, observation: KimiCodeApprovalObservation) -> Bool {
        guard pendingWriteCount == 0 else { lastSaveError = "History writes are still pending."; return false }
        invalidateHistoryJobs()
        guard let modelContainer else { lastSaveError = "History storage is unavailable."; return false }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            if let existing = try kimiApprovalOrphan(sessionId: sessionId, in: context) {
                var merged = try KimiCodeApprovalObservation.decode(existing.observationData)
                merged.merge(observation)
                if merged.baseStatus == .completed || observation.baseStatus == .completed { merged.endSession() }
                existing.observationData = try JSONEncoder().encode(merged)
                existing.updatedAt = Date()
            } else {
                context.insert(StoredKimiCodeApprovalOrphan(sessionId: sessionId,
                    observationData: try JSONEncoder().encode(observation)))
            }
            try context.save()
            lastSaveError = nil
            return true
        } catch {
            context.rollback()
            lastSaveError = error.localizedDescription
            return false
        }
    }

    private func kimiApprovalOrphan(sessionId: String, in context: ModelContext) throws -> StoredKimiCodeApprovalOrphan? {
        var descriptor = FetchDescriptor<StoredKimiCodeApprovalOrphan>(predicate: #Predicate { $0.sessionId == sessionId })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func backfillLegacyIdentifiers(in context: ModelContext) throws {
        let sessions = try context.fetch(FetchDescriptor<StoredSession>(
            predicate: #Predicate { $0.historyDate == nil }
        ))
        let events = try context.fetch(FetchDescriptor<StoredToolEvent>(
            predicate: #Predicate { $0.eventId == nil }
        ))
        let messages = try context.fetch(FetchDescriptor<StoredChatMessage>(
            predicate: #Predicate { $0.messageId == nil }
        ))
        for event in events { event.eventId = UUID() }
        for message in messages { message.messageId = UUID() }
        for session in sessions { session.historyDate = session.completedAt ?? session.observationEndedAt ?? session.startTime }
        if !events.isEmpty || !messages.isEmpty || !sessions.isEmpty {
            try context.save()
        }
    }

    func fetchHistory(limit: Int = 100, offset: Int = 0) -> [StoredSession] {
        // 兼容旧调用方；用户界面使用抛错的分页入口，不能把读取失败显示为空历史。
        (try? readHistoryPage(limit: limit, offset: offset).sessions) ?? []
    }

    func readHistoryPage(limit: Int = 100, offset: Int = 0, search: String = "") throws -> HistoryPage {
        try performHistoryRead {
            guard limit > 0, offset >= 0 else { throw HistoryReadError.invalidPage }
            let context = try historyReadContext()
            var descriptor = FetchDescriptor<StoredSession>(
                sortBy: [SortDescriptor(\.historyDate, order: .reverse), SortDescriptor(\.sessionId, comparator: .lexical)]
            )
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                let agentQuery = query.replacingOccurrences(of: " ", with: "_")
                let matchingAgents = AgentType.allCases.filter {
                    $0.rawValue.localizedStandardContains(agentQuery)
                        || $0.displayName.localizedStandardContains(query)
                        || $0.shortName.localizedStandardContains(query)
                }.map(\.rawValue)
                descriptor.predicate = #Predicate {
                    $0.prompt.localizedStandardContains(query)
                        || $0.workingDirectory.localizedStandardContains(query)
                        || matchingAgents.contains($0.agentTypeRaw)
                        || $0.model.localizedStandardContains(query)
                        || $0.sessionId.localizedStandardContains(query)
                }
            }
            let count = try context.fetchCount(FetchDescriptor<StoredSession>(predicate: descriptor.predicate))
            descriptor.fetchLimit = limit
            descriptor.fetchOffset = offset
            return HistoryPage(sessions: try context.fetch(descriptor), totalCount: count)
        }
    }

    /// 完整读取不复用UI分页上限；回调必须在本次主线程读取期间消费模型，不能修改历史。
    func forEachHistoryBatch(batchSize: Int = 500, _ visit: ([StoredSession]) throws -> Void) throws {
        guard batchSize > 0 else { throw HistoryReadError.invalidPage }
        let context = try performHistoryRead { try historyReadContext() }
        let expectedRevision = revision
        var cursor: String?
        while true {
            guard revision == expectedRevision else { throw HistoryReadError.historyChanged }
            // 与 > 游标谓词使用同一词法顺序；自然排序会跳过 x2/x10 等ID。
            var descriptor = FetchDescriptor<StoredSession>(sortBy: [SortDescriptor(\.sessionId, comparator: .lexical)])
            if let after = cursor { descriptor.predicate = #Predicate { $0.sessionId > after } }
            descriptor.fetchLimit = batchSize
            let batch = try performHistoryRead { try context.fetch(descriptor) }
            guard let last = batch.last else { return }
            cursor = last.sessionId
            // 导出写入错误由调用方处理，不能误记成数据库读取失败。
            try visit(batch)
        }
    }

    private func historyReadContext() throws -> ModelContext {
        guard let modelContainer else { throw HistoryReadError.storageUnavailable }
        if let historyContext { return historyContext }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        historyContext = context
        return context
    }

    private func performHistoryRead<T>(_ read: () throws -> T) throws -> T {
        do {
            let result = try read()
            lastReadError = nil
            return result
        } catch {
            lastReadError = error.localizedDescription
            throw error
        }
    }

    func deleteSession(_ stored: StoredSession) {
        guard pendingWriteCount == 0 else { lastSaveError = "History writes are still pending."; return }
        invalidateHistoryJobs()
        guard let modelContainer else { return }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let id = stored.sessionId
        do {
            let descriptor = FetchDescriptor<StoredSession>(predicate: #Predicate { $0.sessionId == id })
            for record in try context.fetch(descriptor) { context.delete(record) }
            if let orphan = try kimiApprovalOrphan(sessionId: id, in: context) { context.delete(orphan) }
            try context.save()
            historyContext = nil
            revision += 1
            lastSaveError = nil
        } catch {
            context.rollback()
            lastSaveError = error.localizedDescription
        }
    }

    func cleanup(olderThanDays days: Int = 30) {
        guard pendingWriteCount == 0 else { lastSaveError = "History writes are still pending."; return }
        invalidateHistoryJobs()
        guard let modelContainer else { return }
        guard days != .max else { return }
        guard days >= 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else {
            lastSaveError = "Invalid history retention period."
            return
        }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            var cursor: String?
            var expiredIDs = Set<String>()
            var retainedIDs = Set<String>()
            // 唯一键游标不受待删除对象影响；不能在删除后用 offset，也不能只过滤最新一批。
            while true {
                var descriptor = FetchDescriptor<StoredSession>(sortBy: [SortDescriptor(\.sessionId, comparator: .lexical)])
                if let after = cursor { descriptor.predicate = #Predicate { $0.sessionId > after } }
                descriptor.fetchLimit = 500
                let batch = try context.fetch(descriptor)
                guard let last = batch.last else { break }
                cursor = last.sessionId
                for record in batch {
                    let ended = record.statusRaw == SessionStatus.completed.rawValue
                        || record.statusRaw == SessionStatus.observationUnavailable.rawValue
                    // 可选日期在 Swift 中判断，兼容不支持可选 Date 解包谓词的旧存储。
                    if ended, let endDate = record.completedAt ?? record.observationEndedAt,
                       days == 0 || endDate < cutoff {
                        expiredIDs.insert(record.sessionId)
                        context.delete(record)
                    } else {
                        retainedIDs.insert(record.sessionId)
                    }
                }
            }
            let orphanDescriptor = FetchDescriptor<StoredKimiCodeApprovalOrphan>()
            let expiredOrphans = try context.fetch(orphanDescriptor).filter {
                if expiredIDs.contains($0.sessionId) { return true }
                if retainedIDs.contains($0.sessionId) { return false }
                return days == 0 || $0.updatedAt < cutoff
            }
            guard !expiredIDs.isEmpty || !expiredOrphans.isEmpty else {
                lastSaveError = nil
                return
            }
            for record in expiredOrphans { context.delete(record) }
            try context.save()
            historyContext = nil
            revision += 1
            lastSaveError = nil
        } catch {
            context.rollback()
            lastSaveError = error.localizedDescription
        }
    }

    func totalCount() -> Int {
        guard let modelContainer else { return 0 }
        return (try? ModelContext(modelContainer).fetchCount(FetchDescriptor<StoredSession>())) ?? 0
    }

    private func invalidateHistoryJobs(destructiveOnly: Bool = false) {
        historyJobs.invalidate(destructiveOnly: destructiveOnly)
    }

    func runHistoryJob<T: Sendable>(validateReadResult: Bool = true, writesHistory: Bool = false,
        _ work: (HistoryBackgroundStore, HistoryJobToken) async throws -> T
    ) async throws -> T {
        guard let modelContainer else { throw HistoryReadError.storageUnavailable }
        let store = (writesHistory ? mutationStore : backgroundStore) ?? HistoryBackgroundStore(container: modelContainer)
        if writesHistory { mutationStore = store } else { backgroundStore = store }
        let id = UUID(), token = HistoryJobToken(serializedCommit: writesHistory,
                                                commitRegistry: writesHistory ? historyJobs : nil)
        historyJobs.insert(token, id: id, destructive: writesHistory)
        defer { historyJobs.remove(id) }
        let result = try await work(store, token)
        // Worker返回后主线程可能先处理新写入；读取结果发布前再复核一次。
        // 写事务以withCommit为线性化点，提交之后的新写入不能把已完成操作误报成失败。
        if validateReadResult { try token.check() }
        return result
    }

    func readHistoryPageAsync(limit: Int = 100, offset: Int = 0, search: String = "") async throws -> HistoryPageSnapshot {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentQuery = query.replacingOccurrences(of: " ", with: "_")
        let agents = AgentType.allCases.filter {
            $0.rawValue.localizedStandardContains(agentQuery) || $0.displayName.localizedStandardContains(query)
                || $0.shortName.localizedStandardContains(query)
        }.map(\.rawValue)
        return try await runHistoryJob { store, token in
            try await store.page(limit: limit, offset: offset, search: query, matchingAgents: agents, token: token)
        }
    }

    func statisticsAsync(timeRange: HistoryStatistics.TimeRange, now: Date = Date(), calendar: Calendar = .current) async throws -> HistoryStatistics {
        try await runHistoryJob { store, token in
            try await store.statistics(timeRange: timeRange, now: now, calendar: calendar, token: token)
        }
    }

    func exportHistoryAsync(to url: URL) async throws -> Int {
        try await runHistoryJob(validateReadResult: false) { store, token in try await store.export(to: url, token: token) }
    }

    func cleanupAsync(olderThanDays days: Int) async throws {
        guard days != .max else { return }
        let generation = containerGeneration
        do {
            try await enqueueMutation(cancelable: true) { [self] in
                guard generation == containerGeneration else { throw HistoryReadError.historyChanged }
                invalidateHistoryJobs()
                let changed = try await runHistoryJob(validateReadResult: false, writesHistory: true) { store, token in
                    try await store.cleanup(olderThanDays: days, token: token)
                }
                if changed, generation == containerGeneration { didModifyHistoryInBackground() }
            }
        } catch is CancellationError { throw CancellationError() }
        catch HistoryReadError.historyChanged { throw HistoryReadError.historyChanged }
        catch { lastSaveError = error.localizedDescription; throw error }
    }

    func markHistoryCompletionReviewedAsync(sessionID: String, completedAt: Date?) async throws {
        let generation = containerGeneration
        do {
            try await enqueueMutation(cancelable: true) { [self] in
                guard generation == containerGeneration else { throw HistoryReadError.historyChanged }
                invalidateHistoryJobs()
                let changed = try await runHistoryJob(validateReadResult: false, writesHistory: true) { store, token in
                    try await store.markCompletionReviewed(sessionID: sessionID, completedAt: completedAt, token: token)
                }
                if changed, generation == containerGeneration { didModifyHistoryInBackground() }
            }
        } catch is CancellationError { throw CancellationError() }
        catch HistoryReadError.historyChanged { throw HistoryReadError.historyChanged }
        catch { lastSaveError = error.localizedDescription; throw error }
    }

    func deleteHistoryAsync(sessionID: String) async throws {
        let generation = containerGeneration
        try await enqueueMutation(cancelable: true) { [self] in
            guard generation == containerGeneration else { throw HistoryReadError.historyChanged }
            invalidateHistoryJobs()
            let changed = try await runHistoryJob(validateReadResult: false, writesHistory: true) { store, token in
                try await store.delete(sessionID: sessionID, token: token)
            }
            if changed, generation == containerGeneration { didModifyHistoryInBackground() }
        }
    }

    func deleteSession(_ row: HistorySessionRow) {
        // 兼容测试/非UI调用；UI删除通过后台入口完成。
        guard let modelContainer else { return }
        let context = ModelContext(modelContainer), id = row.sessionId
        if let stored = try? context.fetch(FetchDescriptor<StoredSession>(predicate: #Predicate { $0.sessionId == id })).first {
            deleteSession(stored)
        }
    }

    private func didModifyHistoryInBackground() {
        invalidateHistoryJobs()
        historyContext = nil
        childSnapshots = [:]
        childSnapshotOrder = []
        revision += 1
        lastSaveError = nil
    }
}
