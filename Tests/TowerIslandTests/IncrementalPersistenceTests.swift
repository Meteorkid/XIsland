import XCTest
import SwiftData
@testable import XIsland

@MainActor
final class IncrementalPersistenceTests: XCTestCase {
    private func makeManager() throws -> SessionPersistenceManager {
        let manager = SessionPersistenceManager()
        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self, StoredKimiCodeApprovalOrphan.self])
        manager.modelContainer = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return manager
    }

    func testAppendingOneEventDoesNotRewriteTenThousandStoredChildren() throws {
        let manager = try makeManager(), session = AgentSession(id: "large", agentType: .codex)
        session.events = (0..<10_000).map { ToolEvent(tool: "Read", input: "\($0)") }
        XCTAssertTrue(manager.save(session: session))
        let appended = ToolEvent(tool: "Write", input: "new")
        session.appendEvent(appended)
        XCTAssertTrue(manager.save(session: session))
        XCTAssertEqual(manager.lastChildWriteCount, 1)
        let restored = try XCTUnwrap(manager.restoreSession(sessionId: session.id))
        XCTAssertEqual(restored.events.count, 10_001)
        XCTAssertTrue(restored.events.contains { $0.id == appended.id })
    }

    func testOlderEventAndStreamingMessageUpdatesRemainDurableWithoutDuplicates() throws {
        let manager = try makeManager(), session = AgentSession(id: "updates", agentType: .claudeCode)
        let timestamp = Date()
        session.events = [ToolEvent(tool: "Read", timestamp: timestamp), ToolEvent(tool: "Write", timestamp: timestamp)]
        let message = ChatMessage(timestamp: Date(), role: .assistant, content: "part")
        session.chatHistory = [message]
        XCTAssertTrue(manager.save(session: session))
        session.events[0].result = "complete"; session.events[0].isComplete = true
        session.chatHistory[0] = ChatMessage(id: message.id, timestamp: message.timestamp, role: .assistant, content: "complete answer")
        XCTAssertTrue(manager.save(session: session))
        XCTAssertEqual(manager.lastChildWriteCount, 2)
        XCTAssertTrue(manager.save(session: session))
        XCTAssertEqual(manager.lastChildWriteCount, 0)
        let restored = try XCTUnwrap(manager.restoreSession(sessionId: session.id))
        XCTAssertEqual(restored.events.count, 2)
        XCTAssertEqual(restored.events.first { $0.id == session.events[0].id }?.result, "complete")
        XCTAssertEqual(restored.chatHistory.map(\.content), ["complete answer"])
    }

    func testReplacingContainerDoesNotReuseAStaleChildCheckpoint() throws {
        let manager = try makeManager(), session = AgentSession(id: "switch", agentType: .codex)
        session.events = [ToolEvent(tool: "Read")]
        XCTAssertTrue(manager.save(session: session))
        let other = try makeManager()
        manager.modelContainer = other.modelContainer
        XCTAssertTrue(manager.save(session: session))
        XCTAssertEqual(try manager.restoreSession(sessionId: session.id)?.events.count, 1)
    }

    func testMixedTrackedAndDirectMutationsFallBackWithoutLosingEarlierChanges() throws {
        let manager = try makeManager(), session = AgentSession(id: "mixed", agentType: .codex)
        session.events = [ToolEvent(tool: "Read")]
        XCTAssertTrue(manager.save(session: session))
        session.appendEvent(ToolEvent(tool: "Write"))
        XCTAssertEqual(session.pendingChildChanges?.events.count, 1)
        session.events[0].result = "direct update"
        session.appendEvent(ToolEvent(tool: "Bash"))
        XCTAssertNil(session.pendingChildChanges)
        XCTAssertTrue(manager.save(session: session))
        let restored = try XCTUnwrap(manager.restoreSession(sessionId: session.id))
        XCTAssertEqual(restored.events.count, 3)
        XCTAssertEqual(restored.events.first?.result, "direct update")
        XCTAssertEqual(session.pendingChildChanges?.events.count, 0)
        session.updateEvent(at: 0) { $0.result = "tracked update" }
        XCTAssertTrue(manager.save(session: session))
        XCTAssertEqual(manager.lastChildWriteCount, 1)
    }

    func testFailedSaveDoesNotClearTrackedChanges() throws {
        let manager = try makeManager(), session = AgentSession(id: "failure", agentType: .codex)
        XCTAssertTrue(manager.save(session: session))
        session.appendEvent(ToolEvent(tool: "Read"))
        let container = manager.modelContainer
        manager.modelContainer = nil
        XCTAssertFalse(manager.save(session: session))
        XCTAssertEqual(session.pendingChildChanges?.events.count, 1)
        manager.modelContainer = container
        XCTAssertTrue(manager.save(session: session))
        XCTAssertEqual(try manager.restoreSession(sessionId: session.id)?.events.count, 1)
    }

    func testReadResultIsRevalidatedAfterWorkerReturnsToMainActor() async throws {
        let manager = try makeManager()
        do {
            let _: Int = try await manager.runHistoryJob { _, _ in
                XCTAssertTrue(manager.save(session: AgentSession(id: "interleaved-write", agentType: .codex)))
                return 42
            }
            XCTFail("An older read result must not be published after a newer write")
        } catch HistoryReadError.historyChanged { }
        let committed: Int = try await manager.runHistoryJob(validateReadResult: false) { _, token in
            let result = try token.withCommit { 42 }
            XCTAssertTrue(manager.save(session: AgentSession(id: "after-commit", agentType: .codex)))
            return result
        }
        XCTAssertEqual(committed, 42)
    }

    func testUnchangedSaveDoesNotInvalidateAReadOrAdvanceRevision() async throws {
        let manager = try makeManager(), session = AgentSession(id: "unchanged", agentType: .codex)
        XCTAssertTrue(manager.save(session: session))
        let revision = manager.revision
        let result: Int = try await manager.runHistoryJob { _, _ in
            XCTAssertTrue(manager.save(session: session))
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(manager.revision, revision)
    }

    func testBackgroundPageAndStatisticsUseValueSnapshotsAndKeepMainActorResponsive() async throws {
        let manager = try makeManager(), session = AgentSession(id: "async", agentType: .codex)
        session.events = (0..<1000).map { ToolEvent(tool: "Read", input: "\($0)") }
        XCTAssertTrue(manager.save(session: session))
        var heartbeats = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled { heartbeats += 1; await Task.yield() }
        }
        let page = try await manager.readHistoryPageAsync()
        let stats = try await manager.statisticsAsync(timeRange: .all)
        heartbeat.cancel()
        XCTAssertEqual(page.sessions.map(\.sessionId), ["async"])
        XCTAssertEqual(stats.totalCount, 1)
        XCTAssertGreaterThan(heartbeats, 0)
        try await manager.deleteHistoryAsync(sessionID: "async")
        XCTAssertEqual(manager.totalCount(), 0)
    }
}
