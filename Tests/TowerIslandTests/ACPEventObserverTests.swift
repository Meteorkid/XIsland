import XCTest
import DIShared
@testable import DIBridge

final class ACPEventObserverTests: XCTestCase {
    func testNoEventsBeforeNegotiationAndUnsupportedVersionsRemainUnobserved() throws {
        let observer = try ACPEventObserver(host: "zed", source: "fixture")
        XCTAssertTrue(try request(observer, "session/new", id: 1, params: ["cwd": "/tmp/project"]).isEmpty)
        _ = try request(observer, "initialize", id: 0)
        _ = try response(observer, id: 0, result: ["protocolVersion": 99])
        XCTAssertTrue(try request(observer, "session/new", id: 1).isEmpty)
        XCTAssertTrue(try response(observer, id: 1, result: ["sessionId": "fake"]).isEmpty)
        XCTAssertThrowsError(try ACPEventObserver(host: "other", source: "fixture"))
    }

    func testNativeSessionIDsAreStableAcrossObserversAndSeparatedByHostAndRegistration() throws {
        let a = try setup(1), b = try setup(1), c = try setup(1, host: "jetbrains_ai"), d = try setup(1, source: "another")
        let snapshots = try [a, b, c, d].map { try create($0, session: "native-session") }
        XCTAssertEqual(snapshots[0].sessionId, snapshots[1].sessionId)
        XCTAssertNotEqual(snapshots[0].sessionId, snapshots[2].sessionId)
        XCTAssertNotEqual(snapshots[0].sessionId, snapshots[3].sessionId)
        XCTAssertEqual(snapshots[0].observedState, "idle")
        XCTAssertEqual(snapshots[0].workingDir, "/tmp/project")
    }

    func testV1PromptResponseEndsOnlyTheTurn() throws {
        let o = try setup(1); _ = try create(o)
        let start = try request(o, "session/prompt", id: 2, params: ["sessionId": "s", "prompt": [["type": "text", "text": "Work"]]])
        XCTAssertEqual(start.first?.prompt, "Work")
        XCTAssertEqual(start.first?.type, .sessionStart)
        let end = try response(o, id: 2, result: ["stopReason": "end_turn"])
        XCTAssertEqual(end.last?.type, .statusUpdate)
        XCTAssertEqual(end.last?.observedState, "idle")
        XCTAssertFalse(end.contains { $0.type == .sessionEnd })
    }

    func testV2PromptAcknowledgmentDoesNotFinishForegroundWork() throws {
        let o = try setup(2); _ = try create(o)
        _ = try update(o, ["sessionUpdate": "state_update", "state": "running"])
        XCTAssertTrue(try request(o, "session/prompt", id: 2, params: ["sessionId": "s", "prompt": [["type": "text", "text": "Queued prompt"]]]).isEmpty)
        let ack = try response(o, id: 2, result: ["messageId": "user-msg"])
        XCTAssertEqual(ack.first?.prompt, "Queued prompt")
        XCTAssertEqual(ack.first?.nativeMessageId, "user-msg")
        XCTAssertFalse(ack.contains { $0.observedState == "idle" })
        let end = try update(o, ["sessionUpdate": "state_update", "state": "idle", "stopReason": "end_turn"])
        XCTAssertEqual(end.last?.observedState, "idle")
    }

    func testV2RejectedQueuedPromptDoesNotOverwriteForegroundState() throws {
        let o = try setup(2); _ = try create(o)
        _ = try update(o, ["sessionUpdate": "state_update", "state": "running"])
        _ = try request(o, "session/prompt", id: 2, params: ["sessionId": "s", "prompt": []])
        let rejected = o.consume(try json(["jsonrpc": "2.0", "id": 2, "error": ["code": -32602, "message": "invalid prompt"]]), direction: .agentToClient)
        XCTAssertNil(rejected.last?.observedState)
        let permission = try request(o, "session/request_permission", id: 3, params: ["sessionId": "s", "title": "Permission", "options": []], direction: .agentToClient)
        XCTAssertEqual(permission.last?.observedState, "waitingPermission")
        XCTAssertEqual(try response(o, id: 3, result: ["outcome": ["outcome": "cancelled"]], direction: .clientToAgent).last?.observedState, "active")
    }

    func testClientAndAgentRequestIDSpacesDoNotCollideAndParallelPermissionsRemainPending() throws {
        let o = try setup(1); _ = try create(o)
        _ = try request(o, "session/prompt", id: 7, params: ["sessionId": "s", "prompt": []])
        for id in [7, 8] {
            let events = try request(o, "session/request_permission", id: id, params: ["sessionId": "s", "toolCall": ["toolCallId": "c"], "options": []], direction: .agentToClient)
            XCTAssertEqual(events.last?.observedState, "waitingPermission")
            XCTAssertFalse(events.contains { $0.type == .permissionRequest })
        }
        let first = try response(o, id: 7, result: ["outcome": ["outcome": "future-value"]], direction: .clientToAgent)
        XCTAssertEqual(first.last?.observedState, "waitingPermission")
        XCTAssertNil(first.last?.approved)
        let second = try response(o, id: 8, result: ["outcome": ["outcome": "cancelled"]], direction: .clientToAgent)
        XCTAssertEqual(second.last?.observedState, "active")
        XCTAssertEqual(try response(o, id: 7, result: ["stopReason": "end_turn"]).last?.observedState, "idle")
    }

    func testStringAndIntegerRequestIDsAreDistinctAndInt64IdentityIsPreserved() throws {
        let o = try setup(1)
        _ = try request(o, "session/new", id: 2, params: ["cwd": "/tmp/number"])
        _ = try request(o, "session/new", id: "2", params: ["cwd": "/tmp/string"])
        XCTAssertEqual(try response(o, id: "2", result: ["sessionId": "string"]).first?.workingDir, "/tmp/string")
        XCTAssertEqual(try response(o, id: 2, result: ["sessionId": "number"]).first?.workingDir, "/tmp/number")
        _ = try request(o, "session/new", id: Int64.max, params: ["cwd": "/tmp/large"])
        XCTAssertEqual(try response(o, id: Int64.max, result: ["sessionId": "large"]).first?.workingDir, "/tmp/large")
    }

    func testCancelWaitsForAgentCompletionAndStillAcceptsToolUpdates() throws {
        let o = try setup(1); _ = try create(o)
        _ = try request(o, "session/prompt", id: 2, params: ["sessionId": "s", "prompt": []])
        let cancelling = try request(o, "session/cancel", params: ["sessionId": "s"])
        XCTAssertNil(cancelling.last?.observedState)
        let tool = try update(o, ["sessionUpdate": "tool_call_update", "toolCallId": "call", "status": "completed", "title": "Tool"])
        XCTAssertTrue(tool.contains { $0.type == .toolComplete })
        XCTAssertEqual(try response(o, id: 2, result: ["stopReason": "cancelled"]).last?.observedState, "idle")
    }

    func testPendingToolIsNotExecutionAndNativeCallIDMatchesUpdates() throws {
        let o = try setup(1); _ = try create(o)
        XCTAssertTrue(try update(o, ["sessionUpdate": "tool_call", "toolCallId": "call", "title": "Shell", "status": "pending", "rawInput": ["command": "pwd"]]).isEmpty)
        let start = try update(o, ["sessionUpdate": "tool_call_update", "toolCallId": "call", "status": "in_progress"])
        XCTAssertEqual(start.first?.type, .toolStart)
        XCTAssertEqual(start.first?.tool, "Shell")
        XCTAssertTrue(start.first?.toolInput?.contains("pwd") == true)
        let failed = try update(o, ["sessionUpdate": "tool_call_update", "toolCallId": "call", "status": "failed"])
        XCTAssertEqual(failed.first?.toolCallId, start.first?.toolCallId)
        XCTAssertEqual(failed.first?.observedState, "error")
    }

    func testV2ToolNullPatchesClearCachedValuesAndBackgroundToolsDoNotChangeForegroundState() throws {
        let o = try setup(2); _ = try create(o)
        _ = try update(o, ["sessionUpdate": "state_update", "state": "idle"])
        let start = try update(o, ["sessionUpdate": "tool_call_update", "toolCallId": "call", "name": "Shell", "status": "in_progress", "rawInput": ["command": "pwd"]])
        XCTAssertEqual(start.first?.type, .toolStart)
        XCTAssertEqual(start.last?.observedState, "idle")
        let end = try update(o, ["sessionUpdate": "tool_call_update", "toolCallId": "call", "status": "cancelled", "rawInput": NSNull()])
        XCTAssertEqual(end.first?.toolInput, "")
        XCTAssertNil(end.first?.observedState)
        XCTAssertEqual(end.last?.observedState, "idle")
    }

    func testMessageChunksAndReplacementPatchesHaveDifferentSemantics() throws {
        let o = try setup(2); _ = try create(o)
        _ = try update(o, ["sessionUpdate": "agent_message_chunk", "messageId": "m", "content": ["type": "text", "text": "A"]])
        let second = try update(o, ["sessionUpdate": "agent_message_chunk", "messageId": "m", "content": ["type": "text", "text": "B"]])
        XCTAssertEqual(second.first?.status, "AB")
        XCTAssertEqual(second.first?.nativeMessageId, "m")
        let replacement = try update(o, ["sessionUpdate": "agent_message", "messageId": "m", "content": [["type": "text", "text": "C"]]])
        XCTAssertEqual(replacement.first?.status, "C")
        XCTAssertTrue(try update(o, ["sessionUpdate": "agent_message", "messageId": "m"]).isEmpty)
        XCTAssertEqual(try update(o, ["sessionUpdate": "agent_message", "messageId": "m", "content": NSNull()]).first?.status, "")
    }

    func testLoadReplaysOnlyAfterSuccessfulAcknowledgmentAndMissingMessageIDsAreNotInvented() throws {
        let o = try setup(1)
        _ = try request(o, "session/load", id: 2, params: ["sessionId": "s", "cwd": "/tmp/recovered"])
        XCTAssertTrue(try update(o, ["sessionUpdate": "agent_message_chunk", "messageId": "m", "content": ["type": "text", "text": "History"]]).isEmpty)
        XCTAssertTrue(try update(o, ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "No ID"]]).isEmpty)
        let replay = try response(o, id: 2, result: [:])
        XCTAssertTrue(replay.contains { $0.status == "History" && $0.nativeMessageId == "m" })
        XCTAssertFalse(replay.contains { $0.prompt == "No ID" })
        XCTAssertEqual(replay.last?.observedState, "idle")
    }

    func testFailedLoadDoesNotPublishPartialHistory() throws {
        let o = try setup(1)
        _ = try request(o, "session/load", id: 2, params: ["sessionId": "s", "cwd": "/tmp"])
        _ = try update(o, ["sessionUpdate": "agent_message_chunk", "messageId": "m", "content": ["type": "text", "text": "History"]])
        XCTAssertTrue(o.consume(try json(["jsonrpc": "2.0", "id": 2, "error": ["code": -1, "message": "failed"]]), direction: .agentToClient).isEmpty)
    }

    func testContextOccupancyIsNotTotalUsageAndOnlyUSDCostIsReported() throws {
        let o = try setup(2); _ = try create(o)
        let data = try update(o, ["sessionUpdate": "usage_update", "used": 100, "size": 200, "cost": ["amount": 0.4, "currency": "USD"]])
        XCTAssertNil(data.first?.totalTokens)
        XCTAssertEqual(data.first?.costUSD, 0.4)
        XCTAssertEqual(data.first?.usageIsCumulative, true)
        XCTAssertTrue(try update(o, ["sessionUpdate": "usage_update", "used": 100, "size": 200, "cost": ["amount": 0.4, "currency": "EUR"]]).isEmpty)
    }

    func testAuthConfigurationReasoningAndFormAnswersAreNotObserved() throws {
        let o = try setup(2)
        XCTAssertTrue(try request(o, "authenticate", id: 9, params: ["secret": "PRIVATE"]).isEmpty)
        _ = try create(o)
        XCTAssertTrue(try update(o, ["sessionUpdate": "agent_thought_chunk", "messageId": "m", "content": ["type": "text", "text": "PRIVATE"]]).isEmpty)
        let events = try request(o, "elicitation/create", id: 9, params: ["sessionId": "s", "mode": "form", "message": "Fill form", "requestedSchema": [:]], direction: .agentToClient)
        XCTAssertEqual(events.last?.observedState, "waitingAnswer")
        let answered = try response(o, id: 9, result: ["action": "accept", "content": ["password": "PRIVATE"]], direction: .clientToAgent)
        XCTAssertFalse(String(decoding: try DIProtocol.encode(answered[0]), as: UTF8.self).contains("PRIVATE"))
    }

    func testSuccessfulCloseRejectsLateSessionUpdatesAndDuplicateIDsSuspendObservation() throws {
        let o = try setup(1); _ = try create(o)
        _ = try request(o, "session/close", id: 2, params: ["sessionId": "s"])
        XCTAssertEqual(try response(o, id: 2, result: [:]).first?.observedState, "completed")
        XCTAssertTrue(try update(o, ["sessionUpdate": "agent_message_chunk", "messageId": "m", "content": ["type": "text", "text": "Late"]]).isEmpty)
        _ = try request(o, "session/new", id: 3)
        _ = try request(o, "session/new", id: 3)
        XCTAssertFalse(o.isObserving)
    }

    func testOversizedObservationsPauseWithoutGeneratingProtocolDecisions() throws {
        let o = try setup(1); _ = try create(o)
        let messages = o.consume(Data(repeating: 32, count: 1_048_577), direction: .agentToClient)
        XCTAssertFalse(o.isObserving)
        XCTAssertTrue(messages.allSatisfy { $0.type == .statusUpdate && $0.observedState == nil && $0.approved == nil })
    }

    func testToolContentChunksAppendButSnapshotsReplaceAndPlansAreNotApprovalRequests() throws {
        let o = try setup(2); _ = try create(o)
        _ = try update(o, ["sessionUpdate": "tool_call_update", "toolCallId": "call", "title": "Tool", "status": "completed"])
        for text in ["A", "B"] {
            let value = try update(o, ["sessionUpdate": "tool_call_content_chunk", "toolCallId": "call", "content": ["type": "content", "content": ["type": "text", "text": text]]])
            XCTAssertEqual(value.first?.toolResult, text == "A" ? "A" : "AB")
        }
        let replaced = try update(o, ["sessionUpdate": "tool_call_update", "toolCallId": "call", "content": [["type": "content", "content": ["type": "text", "text": "C"]]]])
        XCTAssertEqual(replaced.first?.toolResult, "C")
        let plan = try update(o, ["sessionUpdate": "plan_update", "plan": ["type": "items", "planId": "plan-1", "entries": [["content": "Inspect", "status": "pending", "priority": "high"]]]])
        XCTAssertEqual(plan.first?.type, .statusUpdate)
        XCTAssertNil(plan.first?.planMarkdown)
    }

    private func setup(_ version: Int, host: String = "zed", source: String = "fixture") throws -> ACPEventObserver {
        let observer = try ACPEventObserver(host: host, source: source)
        _ = try request(observer, "initialize", id: 0)
        _ = try response(observer, id: 0, result: ["protocolVersion": version])
        return observer
    }
    private func create(_ observer: ACPEventObserver, session: String = "s") throws -> DIMessage {
        _ = try request(observer, "session/new", id: 1, params: ["cwd": "/tmp/project", "mcpServers": [["env": [["name": "TOKEN", "value": "PRIVATE"]]]]])
        return try XCTUnwrap(response(observer, id: 1, result: ["sessionId": session]).first)
    }
    private func request(_ observer: ACPEventObserver, _ method: String, id: Any? = nil, params: [String: Any] = [:], direction: ACPEventObserver.Direction = .clientToAgent) throws -> [DIMessage] {
        var packet: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        packet["id"] = id
        return observer.consume(try json(packet), direction: direction)
    }
    private func response(_ observer: ACPEventObserver, id: Any, result: [String: Any], direction: ACPEventObserver.Direction = .agentToClient) throws -> [DIMessage] {
        observer.consume(try json(["jsonrpc": "2.0", "id": id, "result": result]), direction: direction)
    }
    private func update(_ observer: ACPEventObserver, _ update: [String: Any]) throws -> [DIMessage] {
        try request(observer, "session/update", params: ["sessionId": "s", "update": update], direction: .agentToClient)
    }
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
}
