import XCTest
@testable import DIBridge

final class CodyUnsupportedProtocolTests: XCTestCase {
    func testLegacyTemplateCannotCreateUnverifiedCodyEvents() {
        for event in ["session_start", "SessionStart", "PreToolUse", "PermissionRequest", "Stop", "session_end"] {
            XCTAssertThrowsError(try DIBridge.makeMessage(agentType: "cody", hookType: event,
                sessionId: "guessed", stdinData: ["session_id": "unverified", "cwd": "/tmp/project"]))
        }
    }
}
