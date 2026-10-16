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

@Observable
@MainActor
final class SessionPersistenceManager {
    var modelContainer: ModelContainer? { didSet { historyContext = nil } }
    @ObservationIgnored private var historyContext: ModelContext?
    private(set) var lastSaveError: String?
    private(set) var revision = 0

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
        guard let modelContainer else {
            lastSaveError = "History storage is unavailable."
            return false
        }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let sessionId = session.id
        let descriptor = FetchDescriptor<StoredSession>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        do {
            let orphan = try kimiApprovalOrphan(sessionId: sessionId, in: context)
            var approvalObservation = session.kimiCodeApprovalObservation
            if let orphan {
                let facts = try KimiCodeApprovalObservation.decode(orphan.observationData)
                if approvalObservation == nil { approvalObservation = facts }
                else { approvalObservation?.merge(facts) }
            }
            let approvalData = try approvalObservation.map { try JSONEncoder().encode($0) }
            let canProjectApproval = !session.hasPendingInteraction && session.status != .completed && session.status != .observationUnavailable
            let storedStatus = canProjectApproval ? approvalObservation?.displayedStatus ?? approvalObservation?.baseStatus ?? session.status : session.status
            if let existing = try context.fetch(descriptor).first {
                let observed = session.sourceInstanceId != nil
                existing.agentTypeRaw = session.agentType.rawValue
                existing.startTime = observed ? min(existing.startTime, session.startTime) : session.startTime
                existing.completedAt = session.completedAt
                existing.sourceNamespace = session.sourceNamespace
                existing.sourceInstanceId = session.sourceInstanceId
                existing.nativeTaskId = session.nativeTaskId
                existing.observationEndedAt = session.observationEndedAt
                existing.kimiCodeApprovalObservationData = approvalData
                existing.historyDate = session.completedAt ?? session.observationEndedAt ?? session.startTime
                existing.prompt = session.prompt
                existing.workingDirectory = session.workingDirectory
                existing.terminal = session.terminal
                existing.statusRaw = storedStatus.rawValue
                existing.recapText = session.recapText
                existing.inputTokens = observed ? max(existing.inputTokens, session.tokenUsage.inputTokens) : session.tokenUsage.inputTokens
                existing.outputTokens = observed ? max(existing.outputTokens, session.tokenUsage.outputTokens) : session.tokenUsage.outputTokens
                existing.totalTokens = observed ? max(existing.totalTokens, session.tokenUsage.totalTokens) : session.tokenUsage.totalTokens
                existing.estimatedCostUSD = observed ? max(existing.estimatedCostUSD, session.tokenUsage.estimatedCostUSD) : session.tokenUsage.estimatedCostUSD
                existing.model = session.tokenUsage.model
                updateChildren(of: existing, from: session)
            } else {
                let stored = StoredSession(from: session)
                stored.kimiCodeApprovalObservationData = approvalData
                stored.statusRaw = storedStatus.rawValue
                context.insert(stored)
            }
            if let orphan { context.delete(orphan) }
            try context.save()
            session.kimiCodeApprovalObservation = approvalObservation
            session.status = storedStatus
            if canProjectApproval, let approvalObservation {
                session.statusText = approvalObservation.displayedText ?? approvalObservation.baseStatusText
            }
            historyContext = nil
            revision += 1
            lastSaveError = nil
            return true
        } catch {
            // 内存会话仍保留原数据供重试，历史列表不应展示未落盘的变更。
            context.rollback()
            lastSaveError = error.localizedDescription
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

    private func updateChildren(of stored: StoredSession, from session: AgentSession) {
        var eventsById: [UUID: StoredToolEvent] = [:]
        for event in stored.toolEvents {
            let id = event.eventId ?? UUID()
            event.eventId = id
            eventsById[id] = event
        }
        for event in session.events {
            if let existing = eventsById[event.id] {
                existing.update(from: event)
            } else {
                let child = StoredToolEvent(from: event)
                stored.toolEvents.append(child)
                eventsById[event.id] = child
            }
        }

        var messagesById: [UUID: StoredChatMessage] = [:]
        for message in stored.chatMessages {
            let id = message.messageId ?? UUID()
            message.messageId = id
            messagesById[id] = message
        }
        for message in session.chatHistory {
            if let existing = messagesById[message.id] {
                existing.update(from: message)
            } else {
                let child = StoredChatMessage(from: message)
                stored.chatMessages.append(child)
                messagesById[message.id] = child
            }
        }
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
        guard let modelContainer else { return [] }
        var descriptor = FetchDescriptor<StoredSession>(
            sortBy: [SortDescriptor(\.historyDate, order: .reverse), SortDescriptor(\.sessionId)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        if historyContext == nil {
            historyContext = ModelContext(modelContainer)
            historyContext?.autosaveEnabled = false
        }
        return (try? historyContext?.fetch(descriptor)) ?? []
    }

    func deleteSession(_ stored: StoredSession) {
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
        guard let modelContainer else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            // 部分 SwiftData 存储不支持可选 Date 的强制解包谓词，沿用显式日期判断。
            var descriptor = FetchDescriptor<StoredSession>(sortBy: [SortDescriptor(\.historyDate, order: .reverse)])
            descriptor.fetchLimit = 10_000
            let expired = try context.fetch(descriptor).filter {
                guard let completedAt = $0.completedAt ?? $0.observationEndedAt else { return false }
                return completedAt < cutoff
            }
            let orphanDescriptor = FetchDescriptor<StoredKimiCodeApprovalOrphan>()
            let expiredIDs = Set(expired.map(\.sessionId))
            let expiredOrphans = try context.fetch(orphanDescriptor).filter {
                $0.updatedAt < cutoff || expiredIDs.contains($0.sessionId)
            }
            guard !expired.isEmpty || !expiredOrphans.isEmpty else { return }
            for record in expired { context.delete(record) }
            for record in expiredOrphans { context.delete(record) }
            try context.save()
            historyContext = nil
            revision += 1
        } catch {
            context.rollback()
            lastSaveError = error.localizedDescription
        }
    }

    func totalCount() -> Int {
        guard let modelContainer else { return 0 }
        return (try? ModelContext(modelContainer).fetchCount(FetchDescriptor<StoredSession>())) ?? 0
    }
}
