import XCTest
import DIShared
@testable import XIsland

@MainActor
final class NativeSubagentTests: XCTestCase {
    func testParallelSubagentsWithSamePromptCanFinishOutOfOrder() {
        let manager = SessionManager()
        let parent = AgentSession(id: "parent", agentType: .copilotCli)
        manager.sessions = [parent]
        manager.handleMessage(message(.subagentStart, id: "first"))
        manager.handleMessage(message(.subagentStart, id: "second"))

        XCTAssertEqual(parent.events.map(\.toolCallId), ["first", "second"])
        XCTAssertEqual(parent.events.map(\.input), ["Same task", "Same task"])
        manager.handleMessage(message(.subagentEnd, id: "first"))

        XCTAssertEqual(parent.subagentIds, ["second"])
        XCTAssertEqual(parent.events.map(\.isComplete), [true, false])
        XCTAssertEqual(parent.events.first?.result, "Completed")
        XCTAssertNil(parent.events.last?.result)

        manager.handleMessage(message(.subagentEnd, id: "second"))
        XCTAssertTrue(parent.subagentIds.isEmpty)
        XCTAssertEqual(parent.events.map(\.isComplete), [true, true])
    }

    func testNativeStartAndEndAreIdempotentIncludingLateStartReplay() {
        let manager = SessionManager()
        let parent = AgentSession(id: "parent", agentType: .copilotCli)
        manager.sessions = [parent]
        let start = message(.subagentStart, id: "repeated")
        manager.handleMessage(start)
        let eventID = parent.events.first?.id
        manager.handleMessage(start)

        XCTAssertEqual(parent.events.count, 1)
        XCTAssertEqual(parent.events.first?.id, eventID)
        XCTAssertEqual(parent.subagentIds, ["repeated"])

        var end = message(.subagentEnd, id: "repeated")
        end.tokensIn = 3
        end.tokensOut = 7
        manager.handleMessage(end)
        let finishedActivity = parent.lastActivityTime
        manager.handleMessage(end)
        manager.handleMessage(start)

        XCTAssertEqual(parent.events.count, 1)
        XCTAssertEqual(parent.events.first?.id, eventID)
        XCTAssertTrue(parent.events.first?.isComplete == true)
        XCTAssertTrue(parent.subagentIds.isEmpty)
        XCTAssertEqual(parent.tokenUsage.inputTokens, 3)
        XCTAssertEqual(parent.tokenUsage.outputTokens, 7)
        XCTAssertEqual(parent.lastActivityTime, finishedActivity)
    }

    func testUnknownNativeEndDoesNotCompleteAnotherSubagentOrConsumeTokens() {
        let manager = SessionManager()
        let parent = AgentSession(id: "parent", agentType: .copilotCli)
        manager.sessions = [parent]
        manager.handleMessage(message(.subagentStart, id: "running"))
        let activity = parent.lastActivityTime
        var unknown = message(.subagentEnd, id: "unknown")
        unknown.tokensIn = 20
        manager.handleMessage(unknown)

        XCTAssertEqual(parent.subagentIds, ["running"])
        XCTAssertEqual(parent.events.count, 1)
        XCTAssertFalse(parent.events[0].isComplete)
        XCTAssertNil(parent.events[0].result)
        XCTAssertEqual(parent.tokenUsage.inputTokens, 0)
        XCTAssertEqual(parent.lastActivityTime, activity)
    }

    func testNativeSubagentIDsAreScopedToTheirExplicitParent() {
        let manager = SessionManager()
        let first = AgentSession(id: "parent", agentType: .copilotCli)
        let second = AgentSession(id: "other-parent", agentType: .copilotCli)
        manager.sessions = [first, second]
        manager.handleMessage(message(.subagentStart, id: "shared"))
        manager.handleMessage(message(.subagentStart, id: "shared", parentID: second.id))

        manager.handleMessage(message(.subagentEnd, id: "shared", parentID: second.id))

        XCTAssertEqual(first.subagentIds, ["shared"])
        XCTAssertFalse(first.events[0].isComplete)
        XCTAssertTrue(second.subagentIds.isEmpty)
        XCTAssertTrue(second.events[0].isComplete)
    }

    func testNativeEndDoesNotMatchOrdinaryToolWithTheSameID() {
        let manager = SessionManager()
        let parent = AgentSession(id: "parent", agentType: .copilotCli)
        parent.events = [ToolEvent(tool: "Read", toolCallId: "shared")]
        manager.sessions = [parent]
        manager.handleMessage(message(.subagentEnd, id: "shared"))
        XCTAssertFalse(parent.events[0].isComplete)

        manager.handleMessage(message(.subagentStart, id: "shared"))
        manager.handleMessage(message(.subagentEnd, id: "shared"))

        XCTAssertEqual(parent.events.map(\.tool), ["Read", "Subagent"])
        XCTAssertEqual(parent.events.map(\.isComplete), [false, true])
    }

    func testLegacySubagentEventsKeepLastUnfinishedFallback() {
        let manager = SessionManager()
        let parent = AgentSession(id: "parent", agentType: .copilotCli)
        manager.sessions = [parent]
        manager.handleMessage(message(.subagentStart, id: nil))
        manager.handleMessage(message(.subagentStart, id: nil))
        let generatedIDs = parent.subagentIds

        XCTAssertEqual(generatedIDs.count, 2)
        XCTAssertEqual(Set(generatedIDs).count, 2)
        XCTAssertTrue(parent.events.allSatisfy { $0.toolCallId == nil })
        manager.handleMessage(message(.subagentEnd, id: nil))
        XCTAssertEqual(parent.events.map(\.isComplete), [false, true])
        XCTAssertEqual(parent.subagentIds, generatedIDs)
        manager.handleMessage(message(.subagentEnd, id: nil))
        XCTAssertEqual(parent.events.map(\.isComplete), [true, true])
    }

    private func message(_ type: DIMessageType, id: String?, parentID: String = "parent") -> DIMessage {
        var message = DIMessage(type: type, sessionId: "native-child-session")
        message.agentType = AgentType.copilotCli.rawValue
        message.parentSessionId = parentID
        message.subagentId = id
        message.prompt = "Same task"
        return message
    }
}
