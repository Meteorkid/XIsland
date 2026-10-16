import XCTest
import DIShared
@testable import DIBridge

final class ContinueStateObserverTests: XCTestCase {
    private func snapshot(id: String = "native", processing: Any = false, permission: Any = NSNull(), history: [[String: Any]] = [], usage: [String: Any]? = nil) throws -> Data {
        var session: [String: Any] = ["sessionId": id, "workspaceDirectory": "/tmp/project", "history": history]
        session["usage"] = usage
        return try JSONSerialization.data(withJSONObject: ["session": session, "isProcessing": processing, "messageQueueLength": 0, "pendingPermission": permission])
    }

    func testStateDeduplicationAndDisconnectDoesNotEndNativeSession() throws {
        let observer = ContinueStateObserver()
        XCTAssertNil(observer.disconnected())
        let data = try snapshot()
        let first = try observer.consume(data)
        XCTAssertEqual(first.last?.observedState, "idle")
        XCTAssertEqual(first.last?.agentType, "continue")
        XCTAssertTrue(try observer.consume(data).isEmpty)
        XCTAssertEqual(try observer.consume(snapshot(processing: true)).last?.observedState, "active")
        XCTAssertEqual(observer.disconnected()?.type, .statusUpdate)
        XCTAssertNil(observer.disconnected()?.observedState)
    }

    func testPermissionIsObservationWithoutActionableRequest() throws {
        let output = try ContinueStateObserver().consume(snapshot(processing: true, permission: ["requestId": "tool-request-1", "toolName": "run_terminal_command"]))
        XCTAssertEqual(output.last?.observedState, "waitingPermission")
        XCTAssertNil(output.last?.nativeRequestId)
        XCTAssertTrue(output.allSatisfy { $0.type == .statusUpdate })
    }

    func testRejectsChangedSessionAndInvalidTypes() throws {
        let observer = ContinueStateObserver(expectedSessionID: "native")
        XCTAssertThrowsError(try observer.consume(snapshot(id: "replacement")))
        XCTAssertNil(observer.disconnected())
        XCTAssertThrowsError(try observer.consume(snapshot(processing: 1)))
        XCTAssertThrowsError(try observer.consume(snapshot(permission: [:])))
        _ = try observer.consume(snapshot())
        XCTAssertThrowsError(try observer.consume(snapshot(id: "replacement")))
    }

    func testHistoricalToolsDeduplicateAndHidePrivateOutput() throws {
        let tool: [String: Any] = ["toolCallId": "call-1", "toolCall": ["id": "call-1", "function": ["name": "read_file"]], "status": "done", "parsedArgs": ["path": "README.md"], "output": [["content": "visible"], ["content": "secret", "hidden": true]]]
        let data = try snapshot(history: [["toolCallStates": [tool, tool]]])
        let observer = ContinueStateObserver()
        let tools = try observer.consume(data).filter { $0.type == .toolComplete }
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.toolCallId, "call-1")
        XCTAssertEqual(tools.first?.toolResult, "visible")
        XCTAssertEqual(tools.first?.nativeMessageReplay, true)
        XCTAssertTrue(try observer.consume(data).isEmpty)
    }

    func testReplyIsOnlyPreviewAndUsageIsCumulative() throws {
        let data = try snapshot(history: [["message": ["role": "assistant", "content": "answer"], "reasoning": "private"]], usage: ["promptTokens": 12, "completionTokens": 3, "totalCost": 0.01])
        let output = try ContinueStateObserver().consume(data)
        XCTAssertEqual(output.first?.totalTokens, 15)
        XCTAssertEqual(output.first?.usageIsCumulative, true)
        XCTAssertTrue(output.last?.status?.contains("answer") == true)
        XCTAssertFalse(output.last?.status?.contains("private") == true)
        XCTAssertTrue(output.allSatisfy { $0.nativeMessageId == nil && $0.statusIsAssistantReply == false })
    }

    func testEndpointAndOptionsRejectAmbiguousOrRemoteTargets() throws {
        XCTAssertEqual(try ContinueStateWatcher.endpoint("http://127.0.0.1:3000").path, "/state")
        for url in ["http://localhost:3000", "https://127.0.0.1:3000", "http://127.0.0.1", "http://127.0.0.1:3000/permission", "http://user@127.0.0.1:3000", "http://127.0.0.1:3000?x=1", "http://example.com:3000"] {
            XCTAssertThrowsError(try ContinueStateWatcher.endpoint(url), url)
        }
        let args = ["--url", "http://127.0.0.1:3000"]
        XCTAssertEqual(try ContinueStateWatcher.options(args).duration, 300)
        XCTAssertThrowsError(try ContinueStateWatcher.options(args + ["--duration", "nan"]))
        XCTAssertThrowsError(try ContinueStateWatcher.options(args + ["--interval", "0"]))
        XCTAssertThrowsError(try ContinueStateWatcher.options(args + args))
    }
}
