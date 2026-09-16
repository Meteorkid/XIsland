import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class SessionPersistenceManager {
    var modelContainer: ModelContainer? { didSet { historyContext = nil } }
    @ObservationIgnored private var historyContext: ModelContext?
    private(set) var lastSaveError: String?
    private(set) var revision = 0

    @discardableResult
    func setupContainer(isStoredInMemoryOnly: Bool = false, storeURL: URL? = nil) -> Bool {
        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self])
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
            if let existing = try context.fetch(descriptor).first {
                existing.agentTypeRaw = session.agentType.rawValue
                existing.startTime = session.startTime
                existing.completedAt = session.completedAt
                existing.prompt = session.prompt
                existing.workingDirectory = session.workingDirectory
                existing.terminal = session.terminal
                existing.statusRaw = session.status.rawValue
                existing.recapText = session.recapText
                existing.inputTokens = session.tokenUsage.inputTokens
                existing.outputTokens = session.tokenUsage.outputTokens
                existing.totalTokens = session.tokenUsage.totalTokens
                existing.estimatedCostUSD = session.tokenUsage.estimatedCostUSD
                existing.model = session.tokenUsage.model
                updateChildren(of: existing, from: session)
            } else {
                context.insert(StoredSession(from: session))
            }
            try context.save()
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
        let events = try context.fetch(FetchDescriptor<StoredToolEvent>(
            predicate: #Predicate { $0.eventId == nil }
        ))
        let messages = try context.fetch(FetchDescriptor<StoredChatMessage>(
            predicate: #Predicate { $0.messageId == nil }
        ))
        for event in events { event.eventId = UUID() }
        for message in messages { message.messageId = UUID() }
        if !events.isEmpty || !messages.isEmpty {
            try context.save()
        }
    }

    func fetchHistory(limit: Int = 100, offset: Int = 0) -> [StoredSession] {
        guard let modelContainer else { return [] }
        var descriptor = FetchDescriptor<StoredSession>(
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
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
            var descriptor = FetchDescriptor<StoredSession>(sortBy: [SortDescriptor(\.completedAt, order: .reverse)])
            descriptor.fetchLimit = 10_000
            let expired = try context.fetch(descriptor).filter {
                guard let completedAt = $0.completedAt else { return false }
                return completedAt < cutoff
            }
            guard !expired.isEmpty else { return }
            for record in expired { context.delete(record) }
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
