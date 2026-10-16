import DIShared
import XCTest
@testable import DIBridge
@testable import XIsland

@MainActor
final class ClaudeHistoryCheckpointTests: XCTestCase {
    private func event(_ name: String, fields: [String: Any] = [:]) throws -> DIMessage {
        var payload: [String: Any] = ["hook_event_name": name, "session_id": "live-history", "cwd": "/tmp/fixture"]
        payload.merge(fields) { _, new in new }
        return try DIBridge.makeMessage(agentType: "claude_code", hookType: name,
            sessionId: "claude_code-live-history", stdinData: payload)
    }

    func testSessionStartAndFirstPromptAreSavedBeforeAnyStop() throws {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        manager.handleMessage(try event("SessionStart"))
        let session = try XCTUnwrap(manager.sessions.first)
        let initial = try XCTUnwrap(persistence.restoreSession(sessionId: session.id))
        XCTAssertEqual(initial.agentType, .claudeCode)
        XCTAssertEqual(initial.status, .active)
        XCTAssertEqual(initial.workingDirectory, "/tmp/fixture")
        XCTAssertTrue(initial.chatHistory.isEmpty)
        XCTAssertNil(initial.completedAt)

        manager.handleMessage(try event("UserPromptSubmit", fields: ["prompt": "Keep my current work"]))
        let saved = try XCTUnwrap(persistence.restoreSession(sessionId: session.id))
        XCTAssertEqual(saved.status, .active)
        XCTAssertEqual(saved.prompt, "Keep my current work")
        XCTAssertEqual(saved.chatHistory.map(\.content), ["Keep my current work"])
        XCTAssertEqual(saved.chatHistory.map(\.id), session.chatHistory.map(\.id))
        XCTAssertNil(saved.completedAt)
        XCTAssertEqual(persistence.totalCount(), 1)
    }

    func testPromptSurvivesReopeningDiskStoreAndSubsequentActivity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-claude-history-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("history.store")
        var originalMessageID: UUID?
        try autoreleasepool {
            let persistence = SessionPersistenceManager()
            XCTAssertTrue(persistence.setupContainer(storeURL: store))
            let manager = SessionManager()
            manager.persistenceManager = persistence
            manager.handleMessage(try event("UserPromptSubmit", fields: ["prompt": "First prompt"]))
            originalMessageID = try XCTUnwrap(manager.sessions.first?.chatHistory.first?.id)
        }

        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(storeURL: store))
        let restored = try XCTUnwrap(persistence.restoreSession(sessionId: "claude_code-live-history"))
        XCTAssertEqual(restored.chatHistory.first?.id, originalMessageID)
        XCTAssertEqual(restored.chatHistory.first?.content, "First prompt")

        let manager = SessionManager()
        manager.persistenceManager = persistence
        manager.handleMessage(try event("UserPromptSubmit", fields: ["prompt": "Continue the same work"]))
        let saved = try XCTUnwrap(persistence.restoreSession(sessionId: restored.id))
        XCTAssertEqual(saved.chatHistory.map(\.content), ["First prompt", "Continue the same work"])
        XCTAssertEqual(saved.chatHistory.first?.id, originalMessageID)
        XCTAssertEqual(saved.status, .active)
        XCTAssertNil(saved.completedAt)
        XCTAssertEqual(persistence.totalCount(), 1)
    }

    func testFailedPromptCheckpointRetainsMemoryAndCanRetry() throws {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        manager.handleMessage(try event("SessionStart"))
        persistence.modelContainer = nil
        manager.handleMessage(try event("UserPromptSubmit", fields: ["prompt": "Recover after storage failure"]))
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.chatHistory.map(\.content), ["Recover after storage failure"])
        XCTAssertEqual(manager.unsavedSessionIDs, [session.id])
        XCTAssertNotNil(persistence.lastSaveError)

        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        manager.retryPendingHistorySaves()
        let saved = try XCTUnwrap(persistence.restoreSession(sessionId: session.id))
        XCTAssertEqual(saved.chatHistory.map(\.content), ["Recover after storage failure"])
        XCTAssertEqual(saved.chatHistory.map(\.id), session.chatHistory.map(\.id))
        XCTAssertTrue(manager.unsavedSessionIDs.isEmpty)
        XCTAssertNil(persistence.lastSaveError)
    }
}
