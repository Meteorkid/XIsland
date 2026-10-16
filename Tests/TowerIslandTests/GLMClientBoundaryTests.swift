import XCTest
@testable import DIBridge

final class GLMClientBoundaryTests: XCTestCase {
    func testUnverifiedStandaloneClientCannotFabricateEvents() {
        for event in ["session_start", "SessionStart", "PermissionRequest", "tool_start", "Stop", "session_end"] {
            XCTAssertThrowsError(try DIBridge.makeMessage(agentType: "glm", hookType: event,
                sessionId: "cwd-hash", stdinData: ["session_id": "unverified", "cwd": "/tmp/project"]))
        }
    }

    func testModelNameDoesNotReplaceVerifiedClientIdentity() throws {
        let message = try DIBridge.makeMessage(agentType: "claude_code", hookType: "SessionStart",
            sessionId: "native-session", stdinData: ["hook_event_name": "SessionStart", "session_id": "native-session",
                "cwd": "/tmp/project", "model": "glm-fixture"])
        XCTAssertEqual(message.type, .sessionStart)
        XCTAssertEqual(message.model, "glm-fixture")
        XCTAssertEqual(message.sessionId, "native-session")
    }
}
