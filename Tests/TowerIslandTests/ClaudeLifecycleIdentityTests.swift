import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

@MainActor
final class ClaudeLifecycleIdentityTests: XCTestCase {
    private func event(_ native: String, hook: String? = nil, fields: [String: Any] = [:]) throws -> DIMessage {
        var payload: [String: Any] = ["hook_event_name": native, "session_id": "parent", "cwd": "/tmp/project"]
        payload.merge(fields) { _, new in new }
        return try DIBridge.makeMessage(agentType: "claude_code", hookType: hook ?? native,
                                       sessionId: "claude_code-parent", stdinData: payload)
    }

    func testStopDoesNotFinishBeforeOtherHooksDecideWhetherToContinue() throws {
        let manager = SessionManager()
        manager.handleMessage(try event("SessionStart"))
        let parent = try XCTUnwrap(manager.sessions.first)
        for continuing in [false, true] {
            let stop = try event("Stop", hook: "notification", fields: [
                "stop_hook_active": continuing, "last_assistant_message": "Review ready",
            ])
            XCTAssertEqual(stop.observedState, "completionUnconfirmed")
            manager.handleMessage(stop)
            XCTAssertEqual(parent.status, .completionUnconfirmed)
            XCTAssertNil(parent.completedAt)
            XCTAssertEqual(parent.agentResponse, "Review ready")
        }
        manager.handleMessage(try event("Notification", fields: ["notification_type": "idle_prompt", "message": "Awaiting input"]))
        XCTAssertEqual(parent.status, .idle)
        manager.handleMessage(try event("SessionEnd"))
        XCTAssertEqual(parent.status, .completed)
    }

    func testParallelNativeChildrenKeepIdentityThroughLegacyHookAliases() throws {
        let manager = SessionManager()
        manager.handleMessage(try event("SessionStart"))
        let parent = try XCTUnwrap(manager.sessions.first)
        let originalReply = parent.agentResponse
        for child in ["first", "second", "first"] {
            let start = try event("SubagentStart", hook: "subagent_start", fields: [
                "agent_id": child, "agent_type": "Explore", "parent_session_id": "unrelated",
            ])
            XCTAssertEqual(start.parentSessionId, parent.id)
            XCTAssertEqual(start.subagentId, "claude_code-\(child)")
            XCTAssertEqual(start.prompt, "Explore")
            manager.handleMessage(start)
        }
        XCTAssertEqual(parent.events.count, 2)
        let stop = try event("SubagentStop", hook: "subagent_end", fields: [
            "agent_id": "first", "agent_type": "Explore", "stop_hook_active": true,
            "last_assistant_message": "Child reply", "tokens_in": 500,
        ])
        XCTAssertEqual(stop.subagentId, "claude_code-first")
        XCTAssertEqual(stop.subagentEndIsProvisional, true)
        manager.handleMessage(stop)
        XCTAssertEqual(parent.subagentIds, ["claude_code-first", "claude_code-second"])
        XCTAssertEqual(parent.events.map(\.completionUnconfirmed), [true, false])
        XCTAssertTrue(parent.events.allSatisfy { !$0.isComplete })
        XCTAssertEqual(parent.agentResponse, originalReply)
        XCTAssertEqual(parent.tokenUsage.inputTokens, 0)
    }

    func testInternalStopWithEmptyTypeCannotFinishAnUnrelatedChild() throws {
        let manager = SessionManager()
        manager.handleMessage(try event("SessionStart"))
        let parent = try XCTUnwrap(manager.sessions.first)
        manager.handleMessage(try event("SubagentStart", fields: ["agent_id": "known", "agent_type": "Explore"]))
        let stop = try event("SubagentStop", fields: ["agent_id": "internal", "agent_type": ""])
        XCTAssertEqual(stop.subagentId, "claude_code-internal")
        XCTAssertEqual(stop.subagentEndIsProvisional, true)
        manager.handleMessage(stop)
        XCTAssertEqual(parent.events.count, 1)
        XCTAssertTrue(parent.events[0].isRunning)
    }

    func testResumedNativeChildRunsAgainWithoutCreatingADuplicateEvent() throws {
        let manager = SessionManager()
        manager.handleMessage(try event("SessionStart"))
        let parent = try XCTUnwrap(manager.sessions.first)
        let start = try event("SubagentStart", fields: ["agent_id": "same-child", "agent_type": "Explore"])
        manager.handleMessage(start)
        let eventID = try XCTUnwrap(parent.events.first?.id)
        manager.handleMessage(try event("SubagentStop", fields: ["agent_id": "same-child", "agent_type": "Explore"]))
        XCTAssertTrue(parent.events[0].completionUnconfirmed)
        manager.handleMessage(start)
        XCTAssertFalse(parent.events[0].completionUnconfirmed)
        XCTAssertTrue(parent.events[0].isRunning)
        XCTAssertEqual(parent.events[0].id, eventID)
        XCTAssertEqual(parent.events.count, 1)
        let resumedActivity = parent.lastActivityTime
        manager.handleMessage(start)
        XCTAssertEqual(parent.lastActivityTime, resumedActivity)
        XCTAssertEqual(parent.subagentIds, ["claude_code-same-child"])
    }

    func testMalformedNativeIdentityIsRejectedInsteadOfUsingLegacyFallback() {
        for name in ["SubagentStart", "SubagentStop"] {
            for fields: [String: Any] in [
                ["subagent_id": "legacy", "agent_type": "Explore"],
                ["agent_id": "", "agent_type": "Explore"],
                ["agent_id": "child\0suffix", "agent_type": "Explore"],
                ["agent_id": "child", "agent_type": false],
            ] {
                XCTAssertThrowsError(try event(name, fields: fields))
            }
        }
    }
}
