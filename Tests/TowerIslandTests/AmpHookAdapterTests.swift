import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

final class AmpHookAdapterTests: XCTestCase {
    func testToolResultPreservesIdentityAndDoesNotBecomeApproval() throws {
        let message = try DIBridge.makeMessage(agentType: "amp", hookType: "toolcomplete", sessionId: "fallback",
            stdinData: ["session_id": "thread", "native_event": "tool.result", "hook_event_name": "PostToolUse",
                        "tool_use_id": "call-1", "tool_name": "AskUserQuestion", "tool_input": ["question": "Continue?"],
                        "tool_response": ["value": "fixture"], "native_status": "error"])
        XCTAssertEqual(message.sessionId, "amp-thread")
        XCTAssertEqual(message.toolCallId, "call-1")
        XCTAssertEqual(message.type, .toolComplete)
        XCTAssertEqual(message.observedState, "error")
        XCTAssertNil(message.questionText)
        XCTAssertTrue(message.toolResult?.contains("fixture") == true)
    }

    func testCancellationEndsTurnWithoutSyntheticAssistantReplyOrSessionEnd() throws {
        let message = try AmpHookAdapter.normalize(hookType: "notification", stdinData: [
            "session_id": "thread", "native_event": "agent.end", "hook_event_name": "Stop",
            "native_status": "cancelled", "messages": [["role": "assistant", "content": "unverified schema"]],
        ])
        XCTAssertEqual(message.type, .statusUpdate)
        XCTAssertEqual(message.observedState, "idle")
        XCTAssertEqual(message.statusIsAssistantReply, false)
        XCTAssertNil(message.status)
    }

    func testMismatchedEventsMissingIdentityAndToolCallAreRejected() {
        let invalidPayloads: [[String: Any]] = [
            ["session_id": "", "native_event": "session.start", "hook_event_name": "SessionStart"],
            ["session_id": "thread", "native_event": "tool.call", "hook_event_name": "PermissionRequest"],
            ["session_id": "thread", "native_event": "agent.end", "hook_event_name": "SessionEnd"],
        ]
        for data in invalidPayloads {
            XCTAssertThrowsError(try AmpHookAdapter.normalize(hookType: "notification", stdinData: data))
        }
    }
}

@MainActor
final class NativeToolCorrelationTests: XCTestCase {
    func testParallelSameNameToolsCompleteByNativeID() {
        let manager = SessionManager()
        manager.handleMessage(message(.toolStart, id: "first"))
        manager.handleMessage(message(.toolStart, id: "second"))
        var complete = message(.toolComplete, id: "first")
        complete.toolResult = "first result"
        manager.handleMessage(complete)
        let session = manager.sessions.first
        XCTAssertEqual(session?.events.first?.result, "first result")
        XCTAssertEqual(session?.events.first?.isComplete, true)
        XCTAssertEqual(session?.events.last?.isComplete, false)
        XCTAssertEqual(session?.currentTool, "Bash")
        complete = message(.toolComplete, id: "second")
        complete.toolResult = "second result"
        manager.handleMessage(complete)
        XCTAssertEqual(session?.events.last?.result, "second result")
        XCTAssertNil(session?.currentTool)
    }

    func testResultWithoutStartIsVisibleAndRepeatedIDDoesNotDuplicate() {
        let manager = SessionManager()
        var result = message(.toolComplete, id: "result-only")
        result.toolResult = "done"
        manager.handleMessage(result)
        manager.handleMessage(result)
        manager.handleMessage(message(.toolStart, id: "result-only"))
        XCTAssertEqual(manager.sessions.first?.events.count, 1)
        XCTAssertEqual(manager.sessions.first?.events.first?.isComplete, true)
        XCTAssertEqual(manager.sessions.first?.events.first?.result, "done")
    }

    func testUnknownNativeIDDoesNotCompleteAnotherPendingTool() {
        let manager = SessionManager()
        manager.handleMessage(message(.toolStart, id: "pending"))
        manager.handleMessage(message(.toolComplete, id: "another-call"))
        XCTAssertEqual(manager.sessions.first?.events.count, 2)
        XCTAssertEqual(manager.sessions.first?.events.first?.isComplete, false)
        XCTAssertEqual(manager.sessions.first?.currentTool, "Bash")
    }

    private func message(_ type: DIMessageType, id: String) -> DIMessage {
        var message = DIMessage(type: type, sessionId: "native-tool-correlation")
        message.agentType = "amp"
        message.tool = "Bash"
        message.toolCallId = id
        return message
    }
}
