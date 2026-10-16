import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

@MainActor
final class KiroSessionTests: XCTestCase {
    func testV3SessionStartRestoresClosedHistoryWithSameIdentity() throws {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        func message(_ event: String, fields: [String: Any] = [:]) throws -> DIMessage {
            var payload: [String: Any] = ["hook_event_name": event, "session_id": "resumed", "cwd": "/tmp/project"]
            payload.merge(fields) { _, new in new }
            return try KiroHookAdapter.normalize(hookType: event, stdinData: payload)
        }
        manager.handleMessage(try message("SessionStart"))
        manager.handleMessage(try message("UserPromptSubmit", fields: ["prompt": "keep this history"]))
        let session = try XCTUnwrap(manager.sessions.first)
        let chatID = try XCTUnwrap(session.chatHistory.first?.id)
        manager.handleMessage(try message("SessionEnd"))
        manager.dismissSession(session)
        XCTAssertTrue(manager.sessions.isEmpty)
        manager.handleMessage(try message("agentSpawn"))
        XCTAssertTrue(manager.sessions.isEmpty)
        manager.handleMessage(try message("SessionStart"))
        let restored = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(restored.id, session.id)
        XCTAssertEqual(restored.status, .active)
        XCTAssertNil(restored.completedAt)
        XCTAssertEqual(restored.chatHistory.first?.id, chatID)
        XCTAssertEqual(restored.chatHistory.first?.content, "keep this history")
        XCTAssertNil(try persistence.restoreSession(sessionId: session.id)?.completedAt)
    }

    func testV3StopWithoutAnswerDoesNotEraseReplyAndSessionEndCloses() throws {
        let manager = SessionManager()
        func message(_ event: String, fields: [String: Any] = [:]) throws -> DIMessage {
            var data: [String: Any] = ["hook_event_name": event, "session_id": "v3-native", "cwd": "/tmp/project"]
            data.merge(fields) { _, new in new }
            return try KiroHookAdapter.normalize(hookType: event, stdinData: data)
        }
        manager.handleMessage(try message("UserPromptSubmit", fields: ["prompt": "read"]))
        manager.handleMessage(try message("Stop", fields: ["assistant_response": "earlier answer"]))
        let oldHistory = manager.sessions[0].chatHistory
        manager.handleMessage(try message("UserPromptSubmit", fields: ["prompt": "again"]))
        manager.handleMessage(try message("Stop"))
        XCTAssertEqual(manager.sessions[0].status, .completionUnconfirmed)
        XCTAssertEqual(manager.sessions[0].chatHistory.filter { $0.role == .assistant }.map(\.content),
                       oldHistory.filter { $0.role == .assistant }.map(\.content))
        XCTAssertFalse(manager.sessions[0].chatHistory.contains { $0.content == "Kiro 本轮结束待确认" })
        manager.handleMessage(try message("SessionEnd"))
        XCTAssertEqual(manager.sessions[0].status, .completed)
        XCTAssertNotNil(manager.sessions[0].completedAt)
        XCTAssertFalse(manager.sessions[0].chatHistory.contains { $0.content == "Kiro 会话已结束" })
    }

    func testSameNamedToolsStayIndependentAndStopKeepsSession() throws {
        let manager = SessionManager()
        func event(_ name: String, result: String = "") throws -> DIMessage {
            try KiroHookAdapter.normalize(hookType: name, stdinData: [
                "hook_event_name": name, "session_id": "native", "cwd": "/tmp/project",
                "tool_name": "read", "tool_input": ["path": result],
                "tool_response": ["success": true, "result": result], "assistant_response": "done"
            ])
        }
        manager.handleMessage(try event("preToolUse"))
        manager.handleMessage(try event("preToolUse"))
        XCTAssertTrue(manager.sessions[0].events.isEmpty)
        manager.handleMessage(try event("postToolUse", result: "one"))
        manager.handleMessage(try event("postToolUse", result: "two"))
        XCTAssertEqual(manager.sessions[0].events.count, 2)
        XCTAssertTrue(manager.sessions[0].events.allSatisfy { $0.isComplete && $0.toolCallId == nil })
        XCTAssertNotEqual(manager.sessions[0].events[0].result, manager.sessions[0].events[1].result)
        manager.handleMessage(try event("stop"))
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertNotEqual(manager.sessions[0].status, .completed)
        XCTAssertEqual(manager.sessions[0].agentResponse, "done")
    }

    func testStopPreservesErrorsAndCanContinueWithoutClosingHistory() throws {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        func message(_ event: String) throws -> DIMessage {
            try KiroHookAdapter.normalize(hookType: event, stdinData: [
                "hook_event_name": event, "session_id": "continuation", "cwd": "/tmp/project", "prompt": "continue"])
        }
        manager.handleMessage(try message("SessionStart"))
        let session = try XCTUnwrap(manager.sessions.first)
        manager.handleMessage(try message("Stop"))
        XCTAssertEqual(session.status, .completionUnconfirmed)
        XCTAssertNil(session.completedAt)
        XCTAssertEqual(try persistence.restoreSession(sessionId: session.id)?.status, .completionUnconfirmed)
        manager.handleMessage(try message("UserPromptSubmit"))
        XCTAssertEqual(session.status, .active)
        session.status = .error
        session.statusText = "Known tool failure"
        manager.handleMessage(try message("Stop"))
        XCTAssertEqual(session.status, .error)
        XCTAssertEqual(session.statusText, "Known tool failure")
        manager.handleMessage(try message("SessionEnd"))
        XCTAssertEqual(session.status, .completed)
    }
}
