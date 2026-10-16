import DIShared
import XCTest
@testable import DIBridge
@testable import XIsland

@MainActor
final class ClaudeToolFinalityTests: XCTestCase {
    private func event(_ name: String, fields: [String: Any] = [:]) throws -> DIMessage {
        var payload: [String: Any] = ["hook_event_name": name, "session_id": "denied-tool", "cwd": "/tmp/fixture"]
        payload.merge(fields) { _, new in new }
        return try DIBridge.makeMessage(agentType: "claude_code", hookType: name,
            sessionId: "claude_code-denied-tool", stdinData: payload)
    }

    func testNativeSessionEndPreservesUnknownToolOutcomeInsteadOfRunningOrSuccess() throws {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        manager.handleMessage(try event("UserPromptSubmit", fields: ["prompt": "Fixture write"]))
        let input: [String: Any] = ["file_path": "/tmp/fixture/canary", "content": "must not write"]
        manager.handleMessage(try event("PreToolUse", fields: ["tool_name": "Write", "tool_use_id": "denied", "tool_input": input]))
        let session = try XCTUnwrap(manager.sessions.first)
        let eventID = try XCTUnwrap(session.events.first?.id)
        manager.handlePermissionRequest(try event("PermissionRequest", fields: ["tool_name": "Write", "tool_input": input])) {
            XCTAssertFalse($0)
        }
        manager.denyPermission(session: session)
        // 原生拒绝没有 PostToolUseFailure，也没有可唯一匹配调用的权限请求 ID。
        manager.handleMessage(try event("Stop"))
        XCTAssertTrue(session.events[0].isRunning)
        XCTAssertFalse(session.events[0].isComplete)
        manager.handleMessage(try event("SessionEnd"))
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(session.events[0].id, eventID)
        XCTAssertFalse(session.events[0].isRunning)
        XCTAssertFalse(session.events[0].isComplete)
        XCTAssertTrue(session.events[0].completionUnconfirmed)
        XCTAssertNil(session.events[0].result)
        XCTAssertEqual(AgentActivityView(event: session.events[0]).completionSymbol, "questionmark.circle")
        let restored = try XCTUnwrap(persistence.restoreSession(sessionId: session.id))
        XCTAssertEqual(restored.events[0].id, eventID)
        XCTAssertTrue(restored.events[0].completionUnconfirmed)
        XCTAssertFalse(restored.events[0].isRunning)
    }

    func testIdentifiedLateToolResultClearsUnknownOutcomeWithoutReopeningClosedSession() throws {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        manager.handleMessage(try event("PreToolUse", fields: ["tool_name": "Read", "tool_use_id": "late", "tool_input": [:]]))
        manager.handleMessage(try event("SessionEnd"))
        let session = try XCTUnwrap(manager.sessions.first)
        let ended = try XCTUnwrap(session.completedAt)
        let eventID = session.events[0].id
        manager.handleMessage(try event("PostToolUse", fields: ["tool_name": "Read", "tool_use_id": "other", "tool_response": "Other result"]))
        XCTAssertTrue(session.events[0].completionUnconfirmed)
        manager.handleMessage(try event("PostToolUse", fields: ["tool_name": "Read", "tool_use_id": "late", "tool_response": "Confirmed result"]))
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(session.completedAt, ended)
        XCTAssertNil(session.currentTool)
        XCTAssertEqual(session.events[0].id, eventID)
        XCTAssertTrue(session.events[0].isComplete)
        XCTAssertFalse(session.events[0].completionUnconfirmed)
        let restored = try XCTUnwrap(persistence.restoreSession(sessionId: session.id))
        XCTAssertEqual(restored.status, .completed)
        XCTAssertEqual(restored.completedAt, ended)
        XCTAssertTrue(restored.events[0].isComplete)
        XCTAssertFalse(restored.events[0].completionUnconfirmed)
        XCTAssertEqual(restored.events[0].result, "Confirmed result")
    }
}
