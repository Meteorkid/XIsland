import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

@MainActor
final class WorkBuddySessionTests: XCTestCase {
    private func message(_ event: String, fields: [String: Any] = [:]) throws -> DIMessage {
        var input: [String: Any] = ["hook_event_name": event, "session_id": "parent", "cwd": "/tmp/project"]
        input.merge(fields) { _, value in value }
        return try WorkBuddyHookAdapter.normalize(hookType: event, stdinData: input)
    }

    func testOnlyFinalStopChangesParentActivity() throws {
        let manager = SessionManager()
        manager.handleMessage(try message("UserPromptSubmit", fields: ["prompt": "fixture"]))
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.agentType, .workBuddy)
        manager.handleMessage(try message("Stop", fields: ["last_assistant_message": "intermediate reply"]))
        XCTAssertEqual(session.status, .completionUnconfirmed)
        XCTAssertEqual(session.agentResponse, "intermediate reply")
        manager.handleMessage(try message("SubagentStop", fields: ["agent_id": "child"]))
        manager.handleMessage(try message("SessionEnd", fields: ["reason": "other"]))
        XCTAssertEqual(session.status, .completionUnconfirmed)
        manager.handleMessage(try message("FinalStop", fields: ["final_stop_reason": "completed"]))
        XCTAssertEqual(session.status, .idle)
    }

    func testReceptionSwitchUsesIsolatedPreferences() throws {
        let key = "autoConfigure.workbuddy", defaults = AppPreferences.defaults
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let manager = SessionManager()
        defaults.set(false, forKey: key)
        manager.handleMessage(try message("SessionStart"))
        XCTAssertTrue(manager.sessions.isEmpty)
        defaults.set(true, forKey: key)
        manager.handleMessage(try message("SessionStart"))
        XCTAssertEqual(manager.sessions.count, 1)
    }
}
