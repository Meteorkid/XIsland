import Foundation
import SwiftData

@MainActor
final class SessionPersistenceManager {
    var modelContainer: ModelContainer?

    func setupContainer() {
        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
            print("[Persistence] Container setup complete")
        } catch {
            print("[Persistence] Container setup failed: \(error)")
        }
    }

    func save(session: AgentSession) {
        guard let modelContainer else { return }
        let context = modelContainer.mainContext

        // 检查是否已存在相同 sessionId 的记录，避免重复插入
        let sessionId = session.id
        let descriptor = FetchDescriptor<StoredSession>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        if let existing = try? context.fetch(descriptor).first {
            // 更新已有记录
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
        } else {
            let stored = StoredSession(from: session)
            context.insert(stored)
        }

        try? context.save()
    }

    func fetchHistory(limit: Int = 100, offset: Int = 0) -> [StoredSession] {
        guard let modelContainer else { return [] }
        var descriptor = FetchDescriptor<StoredSession>(
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        return (try? modelContainer.mainContext.fetch(descriptor)) ?? []
    }

    func deleteSession(_ stored: StoredSession) {
        guard let modelContainer else { return }
        modelContainer.mainContext.delete(stored)
        try? modelContainer.mainContext.save()
    }

    func cleanup(olderThanDays days: Int = 30) {
        guard let modelContainer else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let all = fetchHistory(limit: 10000)
        let toDelete = all.filter { session in
            guard let completed = session.completedAt else { return false }
            return completed < cutoff
        }
        for session in toDelete {
            modelContainer.mainContext.delete(session)
        }
        if !toDelete.isEmpty {
            try? modelContainer.mainContext.save()
        }
    }

    func totalCount() -> Int {
        guard let modelContainer else { return 0 }
        return (try? modelContainer.mainContext.fetchCount(FetchDescriptor<StoredSession>())) ?? 0
    }
}
