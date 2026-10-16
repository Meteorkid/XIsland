import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

@MainActor
final class CodexLifecycleIdentityTests: XCTestCase {
    private func event(_ hook: String, fields: [String: Any] = [:]) throws -> DIMessage {
        var payload: [String: Any] = ["hook_event_name": hook, "session_id": "parent", "cwd": "/tmp/project"]
        payload.merge(fields) { _, new in new }
        return try DIBridge.makeMessage(agentType: "codex", hookType: hook, sessionId: "codex-parent", stdinData: payload)
    }

    func testCodexStopCanContinueAndSessionEndIsSeparate() throws {
        let manager = SessionManager()
        manager.handleMessage(try event("SessionStart"))
        let parent = try XCTUnwrap(manager.sessions.first)
        for active in [false, true] {
            let stop = try event("Stop", fields: ["last_assistant_message": "Review ready", "stop_hook_active": active])
            XCTAssertEqual(stop.observedState, "completionUnconfirmed")
            manager.handleMessage(stop)
            XCTAssertEqual(parent.status, .completionUnconfirmed)
            XCTAssertEqual(parent.agentResponse, "Review ready")
        }
        manager.handleMessage(try event("SessionEnd", fields: ["reason": "other"]))
        XCTAssertEqual(parent.status, .completed)
    }

    func testNativeAgentIDIsStableAndSubagentStopIsProvisional() throws {
        let manager = SessionManager()
        manager.handleMessage(try event("SessionStart"))
        let parent = try XCTUnwrap(manager.sessions.first)
        let start = try event("SubagentStart", fields: ["agent_id": "child", "agent_type": "reviewer",
                                                       "parent_session_id": "not-the-native-parent"])
        XCTAssertEqual(start.parentSessionId, "codex-parent")
        XCTAssertEqual(start.subagentId, "codex-child")
        XCTAssertEqual(start.prompt, "reviewer")
        manager.handleMessage(start)
        manager.handleMessage(try event("SubagentStart", fields: ["agent_id": "child", "agent_type": "reviewer"]))
        XCTAssertEqual(parent.events.count, 1)
        let stop = try event("SubagentStop", fields: ["agent_id": "child", "agent_type": "reviewer", "stop_hook_active": true])
        XCTAssertEqual(stop.subagentId, start.subagentId)
        XCTAssertEqual(stop.subagentEndIsProvisional, true)
        manager.handleMessage(stop)
        XCTAssertEqual(parent.subagentIds, ["codex-child"])
        XCTAssertEqual(parent.events.first?.completionUnconfirmed, true)
        XCTAssertEqual(parent.events.first?.isComplete, false)
    }

    func testSubagentIdentityCannotFallBackToRandomIDOrLegacyField() {
        for hook in ["SubagentStart", "SubagentStop"] {
            XCTAssertThrowsError(try event(hook, fields: ["subagent_id": "legacy", "agent_type": "reviewer"]))
            XCTAssertThrowsError(try event(hook, fields: ["agent_id": "", "agent_type": "reviewer"]))
            XCTAssertThrowsError(try event(hook, fields: ["agent_id": "child\0suffix", "agent_type": "reviewer"]))
            XCTAssertThrowsError(try event(hook, fields: ["agent_id": "child", "agent_type": true]))
        }
    }
}
