import XCTest
import DIShared
@testable import XIsland

@MainActor
final class SessionManagerToolMatchTests: XCTestCase {
    func testToolCompleteWithEmptyToolDoesNotCompletePendingEvent() throws {
        let sm = SessionManager()
        var start = DIMessage(type: .sessionStart, sessionId: "s1")
        start.agentType = "claude_code"
        sm.handleMessage(start)

        var toolStart = DIMessage(type: .toolStart, sessionId: "s1")
        toolStart.agentType = "claude_code"
        toolStart.tool = "bash"
        sm.handleMessage(toolStart)

        var complete = DIMessage(type: .toolComplete, sessionId: "s1")
        complete.agentType = "claude_code"
        complete.tool = ""
        sm.handleMessage(complete)

        let session = try XCTUnwrap(sm.sessions.first)
        let event = try XCTUnwrap(session.events.first { $0.tool == "bash" })
        XCTAssertFalse(event.isComplete)
    }

    func testToolCompleteWithNilToolDoesNotCompletePendingEvent() throws {
        let sm = SessionManager()
        var start = DIMessage(type: .sessionStart, sessionId: "s2")
        start.agentType = "claude_code"
        sm.handleMessage(start)

        var toolStart = DIMessage(type: .toolStart, sessionId: "s2")
        toolStart.agentType = "claude_code"
        toolStart.tool = "bash"
        sm.handleMessage(toolStart)

        var complete = DIMessage(type: .toolComplete, sessionId: "s2")
        complete.agentType = "claude_code"
        complete.tool = nil
        sm.handleMessage(complete)

        let session = try XCTUnwrap(sm.sessions.first)
        let event = try XCTUnwrap(session.events.first { $0.tool == "bash" })
        XCTAssertFalse(event.isComplete)
    }
}
