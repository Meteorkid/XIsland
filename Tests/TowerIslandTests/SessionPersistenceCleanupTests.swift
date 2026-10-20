import XCTest
import SwiftData
@testable import XIsland

@MainActor
final class SessionPersistenceCleanupTests: XCTestCase {
    private func makeManager() throws -> SessionPersistenceManager {
        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self, StoredKimiCodeApprovalOrphan.self])
        let manager = SessionPersistenceManager()
        manager.modelContainer = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return manager
    }

    @discardableResult
    private func insertSession(_ id: String, completedAt: Date? = nil, observationEndedAt: Date? = nil,
                               status: SessionStatus = .completed, in context: ModelContext) -> StoredSession {
        let session = StoredSession(sessionId: id, agentTypeRaw: AgentType.kimi.rawValue,
            startTime: Date(timeIntervalSinceNow: -100 * 86400), completedAt: completedAt,
            prompt: id, workingDirectory: "", terminal: "", statusRaw: status.rawValue)
        session.observationEndedAt = observationEndedAt
        session.historyDate = completedAt ?? observationEndedAt ?? session.startTime
        context.insert(session)
        return session
    }

    private func insertOrphan(_ id: String, updatedAt: Date, in context: ModelContext) throws {
        context.insert(StoredKimiCodeApprovalOrphan(sessionId: id,
            observationData: try JSONEncoder().encode(KimiCodeApprovalObservation()), updatedAt: updatedAt))
    }

    private func orphanIDs(in container: ModelContainer) throws -> Set<String> {
        Set(try ModelContext(container).fetch(FetchDescriptor<StoredKimiCodeApprovalOrphan>()).map(\.sessionId))
    }

    func testCleanupReachesExpiredSessionsBeyondNewestTenThousandAcrossDeletionBatches() throws {
        let manager = try makeManager()
        let context = try XCTUnwrap(manager.modelContainer).mainContext
        context.autosaveEnabled = false
        let recent = Date(timeIntervalSinceNow: -3600)
        let expired = Date(timeIntervalSinceNow: -90 * 86400)
        for index in 0..<10_000 {
            insertSession(String(format: "recent-%05d", index), completedAt: recent, in: context)
        }
        // 相同日期跨越多页；删除第一页后不能让 offset 跳过后续过期记录。
        for index in 0..<1_201 {
            insertSession(String(format: "expired-%05d", index), completedAt: expired, in: context)
        }
        try context.save()

        manager.cleanup(olderThanDays: 30)

        XCTAssertNil(manager.lastSaveError)
        XCTAssertEqual(manager.totalCount(), 10_000)
        XCTAssertNil(try manager.sessionState(sessionId: "expired-00000"))
        XCTAssertNil(try manager.sessionState(sessionId: "expired-01200"))
        XCTAssertNotNil(try manager.sessionState(sessionId: "recent-00000"))
        XCTAssertEqual(manager.revision, 1)
    }

    func testNeverRetentionPreservesSessionsAndOrphansWithoutARevision() throws {
        let manager = try makeManager()
        let container = try XCTUnwrap(manager.modelContainer)
        let expired = Date(timeIntervalSinceNow: -90 * 86400)
        insertSession("old", completedAt: expired, in: container.mainContext)
        try insertOrphan("old-orphan", updatedAt: expired, in: container.mainContext)
        try container.mainContext.save()

        manager.cleanup(olderThanDays: .max)

        XCTAssertEqual(manager.totalCount(), 1)
        XCTAssertEqual(try orphanIDs(in: container), ["old-orphan"])
        XCTAssertEqual(manager.revision, 0)
        XCTAssertNil(manager.lastSaveError)
    }

    func testNegativeRetentionIsRejectedWithoutDeletingHistory() throws {
        let manager = try makeManager()
        let container = try XCTUnwrap(manager.modelContainer)
        insertSession("old", completedAt: Date(timeIntervalSinceNow: -90 * 86400), in: container.mainContext)
        try container.mainContext.save()

        manager.cleanup(olderThanDays: -1)

        XCTAssertEqual(manager.totalCount(), 1)
        XCTAssertEqual(manager.revision, 0)
        XCTAssertNotNil(manager.lastSaveError)
    }

    func testClearHistoryRemovesEndedSessionsAndChildrenButKeepsUnfinishedSessions() throws {
        let manager = try makeManager()
        let container = try XCTUnwrap(manager.modelContainer)
        let context = container.mainContext
        let old = Date(timeIntervalSinceNow: -90 * 86400)
        let completed = insertSession("completed", completedAt: old, in: context)
        completed.toolEvents = [StoredToolEvent(from: ToolEvent(tool: "read"))]
        completed.chatMessages = [StoredChatMessage(from: ChatMessage(timestamp: old, role: .user, content: "old"))]
        insertSession("future-clock", completedAt: Date(timeIntervalSinceNow: 86400), in: context)
        insertSession("interrupted", observationEndedAt: old, status: .observationUnavailable, in: context)
        insertSession("active", status: .active, in: context)
        insertSession("pending", status: .waitingPermission, in: context)
        insertSession("missing-end", in: context)
        try insertOrphan("active", updatedAt: old, in: context)
        try insertOrphan("completed", updatedAt: Date(), in: context)
        try insertOrphan("unbound", updatedAt: Date(timeIntervalSinceNow: 86400), in: context)
        try context.save()

        manager.cleanup(olderThanDays: 0)

        XCTAssertNil(manager.lastSaveError)
        XCTAssertEqual(Set(manager.fetchHistory().map(\.sessionId)), ["active", "pending", "missing-end"])
        XCTAssertEqual(try orphanIDs(in: container), ["active"])
        let freshContext = ModelContext(container)
        XCTAssertEqual(try freshContext.fetchCount(FetchDescriptor<StoredToolEvent>()), 0)
        XCTAssertEqual(try freshContext.fetchCount(FetchDescriptor<StoredChatMessage>()), 0)
    }

    func testCleanupPreservesActiveSessionsWithLegacyEndDatesAndTheirOldOrphans() throws {
        let manager = try makeManager()
        let container = try XCTUnwrap(manager.modelContainer)
        let old = Date(timeIntervalSinceNow: -90 * 86400)
        insertSession("active", completedAt: old, status: .active, in: container.mainContext)
        try insertOrphan("active", updatedAt: old, in: container.mainContext)
        try container.mainContext.save()

        manager.cleanup(olderThanDays: 30)

        XCTAssertEqual(manager.totalCount(), 1)
        XCTAssertEqual(try orphanIDs(in: container), ["active"])
        XCTAssertEqual(manager.revision, 0)
    }

    func testCleanupOrphansFollowTheirRetainedOrExpiredParentsBeforeAge() throws {
        let manager = try makeManager()
        let container = try XCTUnwrap(manager.modelContainer)
        let context = container.mainContext
        let old = Date(timeIntervalSinceNow: -90 * 86400)
        insertSession("recent-parent", completedAt: Date(), in: context)
        insertSession("expired-parent", completedAt: old, in: context)
        try insertOrphan("recent-parent", updatedAt: old, in: context)
        try insertOrphan("expired-parent", updatedAt: Date(), in: context)
        try insertOrphan("old-unbound", updatedAt: old, in: context)
        try insertOrphan("recent-unbound", updatedAt: Date(), in: context)
        try context.save()

        manager.cleanup(olderThanDays: 30)

        XCTAssertNil(manager.lastSaveError)
        XCTAssertEqual(try orphanIDs(in: container), ["recent-parent", "recent-unbound"])
    }

    func testSuccessfulCleanupClearsAnEarlierSaveError() throws {
        let manager = try makeManager()
        let container = try XCTUnwrap(manager.modelContainer)
        insertSession("expired", completedAt: Date(timeIntervalSinceNow: -90 * 86400), in: container.mainContext)
        try container.mainContext.save()
        manager.modelContainer = nil
        XCTAssertFalse(manager.save(session: AgentSession(id: "unavailable", agentType: .kimi)))
        XCTAssertNotNil(manager.lastSaveError)
        manager.modelContainer = container

        manager.cleanup(olderThanDays: 30)

        XCTAssertEqual(manager.totalCount(), 0)
        XCTAssertNil(manager.lastSaveError)
    }
}
