import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

final class PiHookAdapterTests: XCTestCase {
    func testAgentEndWaitsForSettledAndShutdownClosesSession() throws {
        let end = try normalize("agent_end", hook: "notification", event: "AgentEnd")
        XCTAssertEqual(end.type, .statusUpdate)
        XCTAssertNil(end.observedState)
        XCTAssertNil(end.status)
        let settled = try normalize("agent_settled", hook: "notification", event: "Stop")
        XCTAssertEqual(settled.observedState, "idle")
        XCTAssertEqual(settled.statusIsAssistantReply, false)
        let shutdown = try normalize("session_shutdown", hook: "session_end", event: "SessionEnd")
        XCTAssertEqual(shutdown.type, .sessionEnd)
        XCTAssertEqual(shutdown.observedState, "completed")
    }

    func testNativeToolIDsAndErrorsSurvivePipeline() throws {
        let result = try normalize("tool_execution_end", hook: "toolcomplete", event: "PostToolUse", extra: [
            "tool_use_id": "call", "tool_name": "bash", "native_status": "error", "tool_response": ["content": ["fixture"]],
        ])
        XCTAssertEqual(result.sessionId, "pi-native-session")
        XCTAssertEqual(result.workingDir, "/tmp/project")
        XCTAssertEqual(result.toolCallId, "call")
        XCTAssertEqual(result.observedState, "error")
        XCTAssertEqual(result.type, .toolComplete)
        XCTAssertTrue(result.toolResult?.contains("fixture") == true)
    }

    func testUnknownOrMismatchedEventCannotCreatePermissionRequest() {
        XCTAssertThrowsError(try normalize("tool_call", hook: "PermissionRequest", event: "PermissionRequest"))
        XCTAssertThrowsError(try normalize("agent_end", hook: "session_end", event: "SessionEnd"))
        XCTAssertThrowsError(try normalize("tool_execution_start", hook: "toolstart", event: "PreToolUse"))
    }

    private func normalize(_ nativeEvent: String, hook: String, event: String, extra: [String: Any] = [:]) throws -> DIMessage {
        var data: [String: Any] = ["session_id": "native-session", "native_event": nativeEvent,
                                   "hook_event_name": event, "cwd": "/tmp/project"]
        data.merge(extra) { _, new in new }
        return try DIBridge.makeMessage(agentType: "pi", hookType: hook, sessionId: "fallback", stdinData: data)
    }
}

@MainActor
final class PiLifecycleTests: XCTestCase {
    func testRetryReactivatesErrorAndOnlySettledEndsTurn() throws {
        let manager = SessionManager()
        func send(_ native: String, _ event: String) throws {
            manager.handleMessage(try PiHookAdapter.normalize(hookType: "notification", stdinData: [
                "session_id": "retry", "native_event": native, "hook_event_name": event,
            ]))
        }
        try send("agent_start", "AgentStart")
        var failure = DIMessage(type: .statusUpdate, sessionId: "pi-retry")
        failure.agentType = "pi"
        failure.observedState = "error"
        failure.statusIsAssistantReply = false
        manager.handleMessage(failure)
        XCTAssertEqual(manager.sessions.first?.status, .error)
        try send("agent_start", "AgentStart")
        try send("agent_end", "AgentEnd")
        XCTAssertEqual(manager.sessions.first?.status, .active)
        try send("agent_settled", "Stop")
        XCTAssertEqual(manager.sessions.first?.status, .idle)
        try send("agent_start", "AgentStart")
        XCTAssertEqual(manager.sessions.first?.status, .active)
    }
}
