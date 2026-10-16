import XCTest
import DIShared
@testable import DIBridge

final class WorkBuddyHookAdapterTests: XCTestCase {
    private func message(_ event: String, _ fields: [String: Any] = [:]) throws -> DIMessage {
        var data: [String: Any] = ["session_id": "parent-session", "cwd": "/tmp/project", "hook_event_name": event]
        data.merge(fields) { _, new in new }
        return try DIBridge.makeMessage(agentType: "workbuddy", hookType: event, sessionId: "ignored", stdinData: data, adapter: "workbuddy_5_7_6")
    }

    func testStopReplyDoesNotFinishTurnBeforeFinalStop() throws {
        let stop = try message("Stop", ["last_assistant_message": "回复"])
        XCTAssertEqual(stop.status, "回复")
        XCTAssertEqual(stop.statusIsAssistantReply, true)
        XCTAssertEqual(stop.observedState, "completionUnconfirmed")
        XCTAssertEqual(try message("FinalStop", ["final_stop_reason": "completed"]).observedState, "idle")
        XCTAssertEqual(try message("FinalStop", ["final_stop_reason": "failed"]).observedState, "error")
        XCTAssertNil(try message("FinalStop", ["final_stop_reason": "future-value"]).observedState)
    }

    func testChildAndSessionEndNotificationsNeverCloseParent() throws {
        for event in ["SubagentStart", "SubagentStop", "SessionEnd"] {
            let value = try message(event, ["agent_id": "child", "reason": "other"])
            XCTAssertEqual(value.type, .statusUpdate)
            XCTAssertNil(value.observedState)
        }
        XCTAssertNoThrow(try message("SubagentStart"))
    }

    func testToolIDsAreOptionalButConflictsAreRejected() throws {
        let fields: [String: Any] = ["tool_name": "Read", "tool_input": ["path": "fixture"], "tool_response": "output"]
        XCTAssertEqual(try message("PreToolUse", fields).type, .statusUpdate)
        let withoutID = try message("PostToolUse", fields)
        XCTAssertEqual(withoutID.type, .toolComplete)
        XCTAssertNil(withoutID.toolCallId)
        var identified = fields
        identified["call_id"] = "call-1"; identified["tool_use_id"] = "call-1"
        XCTAssertEqual(try message("PostToolUse", identified).toolCallId, "call-1")
        identified["tool_use_id"] = "different"
        XCTAssertThrowsError(try message("PostToolUse", identified))
    }

    func testExplicitIdentityAndObservationOnlyResponses() throws {
        let value = try message("UserPromptSubmit", ["prompt": "fixture"])
        XCTAssertEqual(value.agentType, "workbuddy")
        XCTAssertTrue(value.sessionId.hasPrefix("workbuddy-"))
        XCTAssertEqual(value.terminal, "WorkBuddy")
        XCTAssertThrowsError(try DIBridge.makeMessage(agentType: "workbuddy", hookType: "SessionStart", sessionId: "fallback", stdinData: [:]))
        XCTAssertThrowsError(try message("PermissionRequest"))
        for event in ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"] {
            XCTAssertFalse(DIBridge.needsJsonOutput(event, agentType: "workbuddy"))
        }
    }
}
