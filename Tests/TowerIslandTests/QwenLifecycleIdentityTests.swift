import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

@MainActor
final class QwenLifecycleIdentityTests: XCTestCase {
    private func event(_ name: String, session: String = "runtime", fields: [String: Any] = [:]) throws -> DIMessage {
        var payload: [String: Any] = ["hook_event_name": name, "session_id": session, "cwd": "/tmp/project"]
        payload.merge(fields) { _, new in new }
        let aliases = ["SubagentStart": "subagent_start", "SubagentStop": "subagent_end", "Stop": "notification"]
        return try DIBridge.makeMessage(agentType: "qwen", hookType: aliases[name] ?? name,
                                       sessionId: "qwen-\(session)", stdinData: payload)
    }

    func testNativeChildIdentityIsStableWithinRuntimeSessionAndStopRemainsUnconfirmed() throws {
        let manager = SessionManager()
        for session in ["runtime", "other"] {
            manager.handleMessage(try event("SessionStart", session: session))
            let start = try event("SubagentStart", session: session, fields: [
                "agent_id": "child", "agent_type": "Explorer", "parent_session_id": "unverified",
            ])
            XCTAssertNil(start.parentSessionId)
            XCTAssertEqual(start.subagentId, "qwen-child")
            manager.handleMessage(start)
            manager.handleMessage(start)
        }
        let stop = try event("SubagentStop", fields: ["agent_id": "child", "agent_type": "Explorer",
                                                     "stop_hook_active": true, "last_assistant_message": "Child reply"])
        XCTAssertEqual(stop.subagentEndIsProvisional, true)
        manager.handleMessage(stop)
        let runtime = try XCTUnwrap(manager.sessions.first { $0.id == "qwen-runtime" })
        let other = try XCTUnwrap(manager.sessions.first { $0.id == "qwen-other" })
        XCTAssertEqual(runtime.events.count, 1)
        XCTAssertEqual(runtime.events.first?.completionUnconfirmed, true)
        XCTAssertEqual(runtime.events.first?.isComplete, false)
        XCTAssertEqual(other.events.first?.isRunning, true)
        XCTAssertFalse(runtime.agentResponse.contains("Child reply"))
    }

    func testPinnedSchemaRequiresStringIdentityAndTypeWithoutLegacyFallback() throws {
        for name in ["SubagentStart", "SubagentStop"] {
            for fields: [String: Any] in [
                ["subagent_id": "legacy", "agent_type": "Explorer"],
                ["agent_id": "child"],
                ["agent_id": "child", "agent_type": false],
                ["agent_id": "child\0suffix", "agent_type": "Explorer"],
            ] {
                XCTAssertThrowsError(try event(name, fields: fields))
            }
            let emptyType = try event(name, fields: ["agent_id": "child", "agent_type": ""])
            XCTAssertEqual(emptyType.subagentId, "qwen-child")
        }
    }

    func testStopDoesNotFinishBeforeOtherHooksHaveDecided() throws {
        let manager = SessionManager()
        manager.handleMessage(try event("SessionStart"))
        let session = try XCTUnwrap(manager.sessions.first)
        for continuing in [false, true] {
            let stop = try event("Stop", fields: ["stop_hook_active": continuing, "last_assistant_message": "Review ready"])
            XCTAssertEqual(stop.observedState, "completionUnconfirmed")
            manager.handleMessage(stop)
            XCTAssertEqual(session.status, .completionUnconfirmed)
            XCTAssertEqual(session.agentResponse, "Review ready")
            XCTAssertNil(session.completedAt)
        }
    }

    func testNativeStartAfterAStopRestoresTheSameChildRecord() throws {
        let manager = SessionManager()
        manager.handleMessage(try event("SessionStart"))
        let session = try XCTUnwrap(manager.sessions.first)
        let start = try event("SubagentStart", fields: ["agent_id": "resident", "agent_type": "Explorer"])
        manager.handleMessage(start)
        let eventID = try XCTUnwrap(session.events.first?.id)
        manager.handleMessage(try event("SubagentStop", fields: ["agent_id": "resident", "agent_type": "Explorer"]))
        XCTAssertTrue(session.events[0].completionUnconfirmed)
        manager.handleMessage(start)
        XCTAssertTrue(session.events[0].isRunning)
        XCTAssertEqual(session.events[0].id, eventID)
        XCTAssertEqual(session.events.count, 1)
        let activity = session.lastActivityTime
        manager.handleMessage(start)
        XCTAssertEqual(session.lastActivityTime, activity)
    }
}
