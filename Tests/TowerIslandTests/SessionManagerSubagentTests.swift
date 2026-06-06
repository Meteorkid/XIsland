import XCTest
import DIShared
@testable import XIsland

@MainActor
final class SessionManagerSubagentTests: XCTestCase {
    func testSubagentStartWithUnknownParentDoesNotAttachToOtherSessions() {
        let sm = SessionManager()
        let parentA = AgentSession(id: "parent-a", agentType: .claudeCode)
        let parentB = AgentSession(id: "parent-b", agentType: .claudeCode)
        sm.sessions = [parentA, parentB]

        var msg = DIMessage(type: .subagentStart, sessionId: "child-session")
        msg.agentType = "claude_code"
        msg.parentSessionId = "nonexistent-parent"
        msg.subagentId = "sub-1"
        sm.handleMessage(msg)

        XCTAssertTrue(parentA.subagentIds.isEmpty)
        XCTAssertTrue(parentB.subagentIds.isEmpty)
        XCTAssertTrue(parentA.events.isEmpty)
        XCTAssertTrue(parentB.events.isEmpty)
    }

    func testSubagentStartAttachesWhenParentExists() {
        let sm = SessionManager()
        let parentA = AgentSession(id: "parent-a", agentType: .claudeCode)
        sm.sessions = [parentA]

        var msg = DIMessage(type: .subagentStart, sessionId: "child")
        msg.agentType = "claude_code"
        msg.parentSessionId = "parent-a"
        msg.subagentId = "sub-1"
        sm.handleMessage(msg)

        XCTAssertEqual(parentA.subagentIds, ["sub-1"])
        XCTAssertEqual(parentA.events.last?.tool, "Subagent")
    }
}
