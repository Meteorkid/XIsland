import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

@MainActor
final class DroidLifecycleBoundaryTests: XCTestCase {
    private func event(_ name: String, hook: String, fields: [String: Any] = [:]) throws -> DIMessage {
        var payload: [String: Any] = ["hook_event_name": name, "session_id": "parent", "cwd": "/tmp/project"]
        payload.merge(fields) { _, new in new }
        return try DIBridge.makeMessage(agentType: "droid", hookType: hook,
                                       sessionId: "droid-parent", stdinData: payload)
    }

    func testUnidentifiedSubagentStopNeverCompletesOrChargesAnExistingChild() throws {
        let manager = SessionManager()
        let parent = AgentSession(id: "droid-parent", agentType: .droid)
        parent.subagentIds = ["existing"]
        parent.events = [ToolEvent(tool: "Subagent", input: "Review", toolCallId: "existing")]
        manager.sessions = [parent]
        for extra: [String: Any] in [[:], ["subagent_id": "existing", "parent_session_id": parent.id]] {
            var fields: [String: Any] = ["task_name": "Review", "task_result": "Ready", "stop_hook_active": true, "tokens_in": 50]
            fields.merge(extra) { _, new in new }
            let stop = try event("SubagentStop", hook: "subagent_end", fields: fields)
            XCTAssertEqual(stop.subagentEndIsProvisional, true)
            XCTAssertNil(stop.subagentId)
            XCTAssertNil(stop.parentSessionId)
            let activity = parent.lastActivityTime
            manager.handleMessage(stop)
            XCTAssertEqual(parent.subagentIds, ["existing"])
            XCTAssertTrue(parent.events[0].isRunning)
            XCTAssertEqual(parent.tokenUsage.inputTokens, 0)
            XCTAssertEqual(parent.lastActivityTime, activity)
        }
    }

    func testStopCanContinueAndIdleNotificationDoesNotClaimSuccess() throws {
        let manager = SessionManager()
        manager.handleMessage(try event("SessionStart", hook: "session_start"))
        let parent = try XCTUnwrap(manager.sessions.first)
        let originalReply = parent.agentResponse
        for continuing in [false, true] {
            let stop = try event("Stop", hook: "notification", fields: ["stop_hook_active": continuing])
            XCTAssertEqual(stop.observedState, "completionUnconfirmed")
            manager.handleMessage(stop)
            XCTAssertEqual(parent.status, .completionUnconfirmed)
        }
        manager.handleMessage(try event("Notification", hook: "Notification", fields: [
            "notification_type": "idle_prompt", "message": "User cancelled the turn",
        ]))
        XCTAssertEqual(parent.status, .idle)
        XCTAssertNil(parent.completedAt)
        XCTAssertEqual(parent.agentResponse, originalReply)
    }
}
