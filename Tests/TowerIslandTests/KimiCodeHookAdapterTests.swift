import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

final class KimiCodeHookAdapterTests: XCTestCase {
    func testBackgroundTaskFactsUseTheirOwnProtocolField() throws {
        let started = try normalize("TaskStarted")
        XCTAssertEqual(started.nativeBackgroundTask?.id, "task-1")
        XCTAssertEqual(started.nativeBackgroundTask?.kind, "process")
        XCTAssertEqual(started.nativeBackgroundTask?.status, "running")
        XCTAssertNil(started.toolCallId)
        XCTAssertNil(started.subagentId)
        XCTAssertFalse(started.hasObservationMetadata)
        XCTAssertEqual(try DIProtocol.decode(DIProtocol.encode(started)).nativeBackgroundTask, started.nativeBackgroundTask)
        for state in ["completed", "failed", "timed_out", "killed", "lost"] {
            var data = try payload("Notification")
            data["notification_type"] = "task." + state
            data["source_kind"] = "background_task"
            data["source_id"] = "task-1"
            let message = try normalize("Notification", data)
            XCTAssertEqual(message.nativeBackgroundTask?.status, state)
            XCTAssertNil(message.nativeBackgroundTask?.kind)
            XCTAssertEqual(message.nativeBackgroundTask?.result, message.status)
        }
        var ordinary = try payload("Notification")
        ordinary["source_kind"] = "other"
        XCTAssertNil(try normalize("Notification", ordinary).nativeBackgroundTask)
    }

    @MainActor
    func testPublishedNodeProcessNameKeepsObservedSessionAlive() throws {
        let manager = SessionManager()
        manager.handleMessage(try normalize("SessionStart"))
        manager.handleMessage(try normalize("TurnStarted"))
        manager.checkProcessesAlive(processStatus: { names in names.contains("kimi-code") })
        XCTAssertEqual(manager.sessions.first?.status, .active)
        XCTAssertNil(manager.sessions.first?.observationEndedAt)
    }

    private func fixtures() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/companion/kimi-code-hooks.json")
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(document["cases"] as? [[String: Any]])
    }

    private func payload(_ event: String) throws -> [String: Any] {
        try XCTUnwrap(fixtures().first { $0["event"] as? String == event }?["input"] as? [String: Any])
    }

    private func normalize(_ event: String, _ data: [String: Any]? = nil) throws -> DIMessage {
        try DIBridge.makeMessage(agentType: "kimi", hookType: event, sessionId: "ignored-environment-identity",
            stdinData: data ?? payload(event), adapter: "kimi_code")
    }

    func testAllTwentyPublishedEventsUseDedicatedNonInteractivePipeline() throws {
        let cases = try fixtures()
        XCTAssertEqual(cases.count, 20)
        for fixture in cases {
            let event = try XCTUnwrap(fixture["event"] as? String)
            let message = try normalize(event)
            XCTAssertEqual(message.type.rawValue, fixture["expectedType"] as? String, event)
            XCTAssertEqual(message.observedState, fixture["expectedState"] as? String, event)
            XCTAssertEqual(message.sessionId, "kimi_code-node-fixture")
            XCTAssertEqual(message.agentType, "kimi")
            XCTAssertEqual(message.nativeEvent, "kimi_code." + event)
            XCTAssertEqual(message.statusIsAssistantReply, false)
            XCTAssertFalse([DIMessageType.permissionRequest, .question, .planReview].contains(message.type))
            XCTAssertFalse(message.hasObservationMetadata)
            XCTAssertNil(message.approved)
            XCTAssertNil(message.subagentId)
            XCTAssertNil(message.tokensIn)
            XCTAssertNil(message.tokensOut)
            XCTAssertNil(message.totalTokens)
            XCTAssertFalse(DIBridge.needsJsonOutput(event, agentType: "kimi", adapter: "kimi_code"))
            XCTAssertTrue(DIBridge.needsJsonOutput(event, agentType: "kimi"))
        }
    }

    func testRuntimeNamespacesCannotCollideAndLegacySchemaStaysSeparate() throws {
        var old: [String: Any] = ["session_id": "node-fixture", "hook_event_name": "Stop"]
        let legacy = try DIBridge.makeMessage(agentType: "kimi", hookType: "Stop", sessionId: "ignored", stdinData: old)
        XCTAssertEqual(legacy.sessionId, "kimi-node-fixture")
        XCTAssertNotEqual(try normalize("Stop").sessionId, legacy.sessionId)
        old["session_id"] = "code-node-fixture"
        XCTAssertNotEqual(try normalize("Stop").sessionId,
            try DIBridge.makeMessage(agentType: "kimi", hookType: "Stop", sessionId: "ignored", stdinData: old).sessionId)
        XCTAssertThrowsError(try normalize("Stop", old))
        XCTAssertThrowsError(try DIBridge.makeMessage(agentType: "codex", hookType: "Stop", sessionId: "ignored",
            stdinData: payload("Stop"), adapter: "kimi_code"))
    }

    func testPromptPartsOnlyCreateUserTextAndQueuedOrSystemTurnsDoNotDuplicateIt() throws {
        let submitted = try normalize("UserPromptSubmit")
        XCTAssertEqual(submitted.prompt, "Inspect fixture")
        XCTAssertFalse(submitted.prompt?.contains("image") == true)
        XCTAssertNil(try normalize("UserPromptQueued").prompt)
        for origin in ["user", "task", "system_trigger"] {
            var turn = try payload("TurnStarted")
            turn["origin_kind"] = origin
            turn["origin_name"] = "fixture"
            let message = try normalize("TurnStarted", turn)
            XCTAssertNil(message.prompt)
            XCTAssertEqual(message.nativeTurnId, "0")
            XCTAssertNil(message.nativeMessageId)
            XCTAssertEqual(message.observedState, "active")
        }
        var legacyPrompt = try payload("UserPromptSubmit")
        legacyPrompt["prompt"] = "Legacy Python prompt"
        XCTAssertThrowsError(try normalize("UserPromptSubmit", legacyPrompt))
    }

    func testApprovalIdentityAndDecisionAreObservationsNotApprovalResponses() throws {
        let request = try normalize("PermissionRequest")
        XCTAssertEqual(request.nativeRequestId, "approval_fixture")
        XCTAssertEqual(request.nativeAgentId, "agent-main")
        XCTAssertEqual(request.nativeTurnId, "0")
        XCTAssertEqual(request.toolCallId, "call-1")
        for decision in ["approved", "rejected", "cancelled", "error"] {
            var data = try payload("PermissionResult")
            data["decision"] = decision
            let result = try normalize("PermissionResult", data)
            XCTAssertEqual(result.nativeRequestId, request.nativeRequestId)
            XCTAssertTrue(result.status?.contains(decision) == true)
            XCTAssertNil(result.observedState)
            XCTAssertNil(result.approved)
            XCTAssertEqual(result.type, .statusUpdate)
        }
        var data = try payload("PermissionRequest")
        data.removeValue(forKey: "id")
        XCTAssertNil(try normalize("PermissionRequest", data).nativeRequestId)
        let decoded = try DIProtocol.decode(DIProtocol.encode(request))
        XCTAssertEqual(decoded.nativeAgentId, request.nativeAgentId)
        XCTAssertEqual(decoded.nativeTurnId, request.nativeTurnId)
        XCTAssertFalse(decoded.hasObservationMetadata)
    }

    func testTaskAndNotificationIdentitiesDoNotPretendToBeSubagentsOrLeaseTasks() throws {
        for kind in ["agent", "process", "question"] {
            var data = try payload("TaskStarted")
            data["kind"] = kind
            let message = try normalize("TaskStarted", data)
            XCTAssertTrue(message.status?.contains("task-1") == true)
            XCTAssertNil(message.subagentId)
            XCTAssertNil(message.nativeTaskId)
            XCTAssertNil(message.observedState)
        }
        let notification = try normalize("Notification")
        XCTAssertEqual(notification.nativeAgentId, "receiving-agent")
        XCTAssertNil(notification.subagentId)
        XCTAssertNil(notification.observedState)
        XCTAssertEqual(notification.status, "Fixture task\nObserved result")
        XCTAssertNil(try normalize("SessionHeartbeat").observedState)
    }

    func testMalformedNumericIdentityAndWrongPayloadTypesAreRejected() throws {
        for value in [true, -1, 1.5, "0", 9_007_199_254_740_992] as [Any] {
            var data = try payload("TurnStarted")
            data["turn_id"] = value
            XCTAssertThrowsError(try normalize("TurnStarted", data))
        }
        for (event, field, value) in [
            ("Stop", "session_id", "" as Any),
            ("Stop", "hook_event_name", "SessionEnd"),
            ("PreToolUse", "tool_input", "not an object"),
            ("PostToolUseFailure", "error", "not an error object"),
            ("PermissionResult", "decision", "allow"),
            ("UserPromptSubmit", "is_steer", 1),
            ("TaskStarted", "detached", 0),
        ] {
            var data = try payload(event)
            data[field] = value
            XCTAssertThrowsError(try normalize(event, data), event + "/" + field)
        }
    }
}
