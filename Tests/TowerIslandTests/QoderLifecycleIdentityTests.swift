import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

@MainActor
final class QoderLifecycleIdentityTests: XCTestCase {
    private func event(_ name: String, session: String = "current", fields: [String: Any] = [:]) throws -> DIMessage {
        var payload: [String: Any] = ["session_id": session, "hook_event_name": name, "cwd": "/tmp/project"]
        payload.merge(fields) { _, new in new }
        let aliases = ["SubagentStart": "subagent_start", "SubagentStop": "subagent_end", "Stop": "notification"]
        return try DIBridge.makeMessage(agentType: "qoder", hookType: aliases[name] ?? name,
                                       sessionId: "qoder-\(session)", stdinData: payload)
    }

    func testNativeIDsAreScopedByReportedSessionWithoutInventingParentMetadata() throws {
        let manager = SessionManager()
        manager.handleMessage(try event("SessionStart"))
        manager.handleMessage(try event("SessionStart", session: "other"))
        for session in ["current", "other"] {
            let start = try event("SubagentStart", session: session, fields: [
                "agent_id": "child", "agent_type": "task", "parent_session_id": "unverified-other-session",
            ])
            XCTAssertNil(start.parentSessionId)
            XCTAssertEqual(start.subagentId, "qoder-child")
            manager.handleMessage(start)
        }
        let stop = try event("SubagentStop", fields: ["agent_id": "child", "agent_type": "task", "stop_hook_active": true])
        XCTAssertNil(stop.parentSessionId)
        XCTAssertEqual(stop.subagentEndIsProvisional, true)
        manager.handleMessage(stop)
        let current = try XCTUnwrap(manager.sessions.first { $0.id == "qoder-current" })
        let other = try XCTUnwrap(manager.sessions.first { $0.id == "qoder-other" })
        XCTAssertEqual(current.events.count, 1)
        XCTAssertEqual(current.events.first?.completionUnconfirmed, true)
        XCTAssertEqual(current.events.first?.isComplete, false)
        XCTAssertEqual(other.events.first?.isRunning, true)
    }

    func testDisplayTypeCanBeAbsentOrEmptyButNativeIdentityCannot() throws {
        for name in ["SubagentStart", "SubagentStop"] {
            let missingType = try event(name, fields: ["agent_id": "child"])
            XCTAssertEqual(missingType.subagentId, "qoder-child")
            XCTAssertNil(missingType.prompt)
            let emptyType = try event(name, fields: ["agent_id": "child", "agent_type": ""])
            XCTAssertEqual(emptyType.subagentId, missingType.subagentId)
            XCTAssertThrowsError(try event(name, fields: ["subagent_id": "legacy", "agent_type": "task"]))
            XCTAssertThrowsError(try event(name, fields: ["agent_id": "", "agent_type": "task"]))
            XCTAssertThrowsError(try event(name, fields: ["agent_id": "child\0suffix"]))
            XCTAssertThrowsError(try event(name, fields: ["agent_id": "child", "agent_type": false]))
        }
    }

    func testStopPreservesReplyWithoutClaimingIdleWhileOtherHooksMayContinue() throws {
        let manager = SessionManager()
        manager.handleMessage(try event("SessionStart"))
        let session = try XCTUnwrap(manager.sessions.first)
        for continuing in [false, true] {
            let stop = try event("Stop", fields: ["last_assistant_message": "Review ready", "stop_hook_active": continuing])
            XCTAssertEqual(stop.observedState, "completionUnconfirmed")
            manager.handleMessage(stop)
            XCTAssertEqual(session.status, .completionUnconfirmed)
            XCTAssertEqual(session.agentResponse, "Review ready")
            XCTAssertNil(session.completedAt)
        }
    }
}
