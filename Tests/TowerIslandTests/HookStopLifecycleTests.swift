import XCTest
import DIShared
@testable import XIsland
@testable import DIBridge

@MainActor
final class HookStopLifecycleTests: XCTestCase {
    func testTraeStopLoopRetainsRunningStateUntilNativeIdleNotification() throws {
        let manager = SessionManager()
        func event(_ hook: String, fields: [String: Any] = [:]) throws -> DIMessage {
            var payload: [String: Any] = ["hook_event_name": hook, "session_id": "stop-loop", "cwd": "/tmp/project"]
            payload.merge(fields) { _, new in new }
            return try TraeHookAdapter.normalize(hookType: hook, stdinData: payload)
        }
        manager.handleMessage(try event("SessionStart"))
        let session = try XCTUnwrap(manager.sessions.first)
        for alreadyBlocked in [false, true] {
            manager.handleMessage(try event("Stop", fields: ["last_assistant_message": "检查结果",
                "stop_hook_active": alreadyBlocked, "loop_count": alreadyBlocked ? 1 : 0]))
            XCTAssertEqual(session.status, .completionUnconfirmed)
            XCTAssertEqual(session.agentResponse, "检查结果")
            XCTAssertNil(session.completedAt)
        }
        manager.handleMessage(try event("Notification", fields: ["notification_type": "idle_prompt", "message": "原应用报告完成"]))
        XCTAssertEqual(session.status, .idle)
        XCTAssertNil(session.completedAt)
    }

    func testCopilotStopAndBackgroundIdleDoNotFinishMainSession() throws {
        let manager = SessionManager()
        func event(_ hook: String, fields: [String: Any] = [:]) throws -> DIMessage {
            var payload: [String: Any] = ["sessionId": "stop-loop", "cwd": "/tmp/project",
                                        "timestamp": Date().timeIntervalSince1970 * 1000]
            payload.merge(fields) { _, new in new }
            return try CopilotCliHookAdapter.normalize(hookType: hook, stdinData: payload)
        }
        manager.handleMessage(try event("sessionStart"))
        let session = try XCTUnwrap(manager.sessions.first)
        for alreadyBlocked in [false, true] {
            manager.handleMessage(try event("agentStop", fields: ["stopReason": "end_turn", "stop_hook_active": alreadyBlocked,
                "transcriptPath": "/tmp/unused"]))
            XCTAssertEqual(session.status, .completionUnconfirmed)
            XCTAssertNil(session.completedAt)
        }
        manager.handleMessage(try event("notification", fields: ["notification_type": "agent_idle", "message": "Background agent idle"]))
        XCTAssertEqual(session.status, .completionUnconfirmed)
        manager.handleMessage(try event("sessionEnd", fields: ["reason": "complete"]))
        XCTAssertEqual(session.status, .completed)
        XCTAssertNotNil(session.completedAt)
    }
}
