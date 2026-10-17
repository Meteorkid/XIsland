import DIShared
import XCTest
@testable import XIsland

@MainActor
final class IntegrationActivityTests: XCTestCase {
    private func message(_ type: DIMessageType = .sessionStart, agent: AgentType = .codex,
                         id: String = "codex-integration") -> DIMessage {
        var message = DIMessage(type: type, sessionId: id)
        message.agentType = agent.rawValue
        return message
    }

    private func kimi(_ event: String, type: DIMessageType = .statusUpdate) -> DIMessage {
        var value = message(type, agent: .kimi, id: "kimi_code-integration")
        value.nativeEvent = "kimi_code." + event
        value.statusIsAssistantReply = false
        return value
    }

    private func permission(_ event: String, request: String = "approval") -> DIMessage {
        var value = kimi(event)
        value.nativeRequestId = request
        value.nativeAgentId = "main"
        value.nativeTurnId = "turn-1"
        value.toolCallId = "tool-1"
        return value
    }

    func testFirstAcceptedPermissionRequestConfirmsIntegrationAfterPendingIsVisible() {
        let manager = SessionManager()
        let previousBypass = manager.bypassMode
        manager.bypassMode = false
        defer { manager.bypassMode = previousBypass }
        var sources: [AgentType] = []
        manager.onIntegrationActivity = { [unowned manager] source in
            XCTAssertNotNil(manager.sessions.first?.pendingPermission)
            XCTAssertEqual(manager.sessions.first?.status, .waitingPermission)
            sources.append(source)
        }
        var request = message(.permissionRequest)
        request.tool = "Read"
        request.nativeRequestId = "permission-first"
        manager.handlePermissionRequest(request, delivery: { _ in true }, respond: { _ in
            XCTFail("An accepted request must still wait for the user")
        })
        XCTAssertEqual(sources, [.codex])
    }

    func testFirstAcceptedQuestionConfirmsIntegrationAfterPendingIsVisible() {
        let manager = SessionManager()
        let previousBypass = manager.bypassMode
        manager.bypassMode = false
        defer { manager.bypassMode = previousBypass }
        var sources: [AgentType] = []
        manager.onIntegrationActivity = { [unowned manager] source in
            XCTAssertNotNil(manager.sessions.first?.pendingQuestion)
            XCTAssertEqual(manager.sessions.first?.status, .waitingAnswer)
            sources.append(source)
        }
        var question = message(.question)
        question.questionText = "Choose the next action"
        question.options = ["Continue", "Stop"]
        question.nativeRequestId = "question-first"
        manager.handleQuestionRequest(question, delivery: { _ in true }, respond: { _ in
            XCTFail("An accepted question must still wait for the user")
        })
        XCTAssertEqual(sources, [.codex])
    }

    func testFirstAcceptedPlanConfirmsIntegrationAfterPendingIsVisible() {
        let manager = SessionManager()
        let previousBypass = manager.bypassMode
        manager.bypassMode = false
        defer { manager.bypassMode = previousBypass }
        var sources: [AgentType] = []
        manager.onIntegrationActivity = { [unowned manager] source in
            XCTAssertNotNil(manager.sessions.first?.pendingPlanReview)
            XCTAssertEqual(manager.sessions.first?.status, .waitingPlanReview)
            sources.append(source)
        }
        var plan = message(.planReview)
        plan.planMarkdown = "# Plan\nRead the existing configuration."
        manager.handlePlanReview(plan, delivery: { _ in true }, respond: { _, _ in
            XCTFail("An accepted plan must still wait for the user")
        })
        XCTAssertEqual(sources, [.codex])
    }

    func testBypassedInteractionsDoNotConfirmIntegration() {
        let manager = SessionManager()
        let previousBypass = manager.bypassMode
        manager.bypassMode = true
        defer { manager.bypassMode = previousBypass }
        var sources: [AgentType] = []
        manager.onIntegrationActivity = { sources.append($0) }
        var request = message(.permissionRequest)
        request.tool = "Read"
        manager.handlePermissionRequest(request, respond: { _ in })
        var question = message(.question)
        question.questionText = "Continue?"
        question.options = ["Yes", "No"]
        manager.handleQuestionRequest(question, respond: { _ in })
        var plan = message(.planReview)
        plan.planMarkdown = "# Plan"
        manager.handlePlanReview(plan, respond: { _, _ in })
        XCTAssertTrue(sources.isEmpty)
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    func testReplayedAndObservationOnlyInteractionsDoNotConfirmIntegration() {
        let manager = SessionManager()
        let previousBypass = manager.bypassMode
        manager.bypassMode = false
        defer { manager.bypassMode = previousBypass }
        var sources: [AgentType] = []
        manager.onIntegrationActivity = { sources.append($0) }
        for replay in [true, false] {
            var request = message(.permissionRequest)
            request.tool = "Read"
            request.questionText = "Continue?"
            request.options = ["Yes"]
            request.planMarkdown = "# Plan"
            request.nativeMessageReplay = replay
            if !replay { request.sourceNamespace = "observation-only" }
            manager.handlePermissionRequest(request, respond: { _ in XCTFail("Rejected permission was answered") })
            request.type = .question
            manager.handleQuestionRequest(request, respond: { _ in XCTFail("Rejected question was answered") })
            request.type = .planReview
            manager.handlePlanReview(request, respond: { _, _ in XCTFail("Rejected plan was answered") })
        }
        XCTAssertTrue(sources.isEmpty)
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    func testEmptyInteractionPlaceholdersDoNotConfirmIntegration() {
        let manager = SessionManager()
        let previousBypass = manager.bypassMode
        manager.bypassMode = false
        defer { manager.bypassMode = previousBypass }
        var sources: [AgentType] = []
        manager.onIntegrationActivity = { sources.append($0) }
        manager.handlePermissionRequest(message(.permissionRequest), respond: { _ in })
        var question = message(.question)
        question.questionText = "Question"
        manager.handleQuestionRequest(question, respond: { _ in })
        var plan = message(.planReview)
        plan.planMarkdown = " \n "
        manager.handlePlanReview(plan, respond: { _, _ in })
        XCTAssertTrue(sources.isEmpty)
    }

    func testAcceptedActivityReportsTheActualSourceAndDuplicatePromptDoesNotReportAgain() {
        let manager = SessionManager()
        var sources: [AgentType] = []
        manager.onIntegrationActivity = { sources.append($0) }
        var start = message()
        start.nativeMessageId = "prompt-1"
        start.prompt = "Read a file"
        manager.handleMessage(start)
        manager.handleMessage(start)
        var tool = message(.toolStart)
        tool.tool = "Read"
        tool.toolCallId = "read-1"
        manager.handleMessage(tool)
        manager.handleMessage(tool)
        XCTAssertEqual(sources, [.codex, .codex])
        XCTAssertEqual(manager.sessions.first?.events.count, 1)
    }

    func testUnknownSourceAndUnhandledMessageTypesNeverUseClaudeFallbackForConnection() {
        let manager = SessionManager()
        var sources: [AgentType] = []
        manager.onIntegrationActivity = { sources.append($0) }
        for source in [nil, "unknown-agent"] as [String?] {
            var value = DIMessage(type: .sessionStart, sessionId: "unknown-\(source ?? "nil")")
            value.agentType = source
            manager.handleMessage(value)
        }
        for type in [DIMessageType.permissionResponse, .questionResponse, .planResponse] {
            manager.handleMessage(message(type))
        }
        manager.handleMessage(message(.statusUpdate))
        XCTAssertTrue(sources.isEmpty)
    }

    func testReplayMessagesCannotConfirmAnIntegration() {
        for type in [DIMessageType.sessionStart, .sessionEnd, .toolStart, .toolComplete,
                     .statusUpdate, .contextCompact, .recap] {
            let manager = SessionManager()
            manager.handleMessage(message())
            var sources: [AgentType] = []
            manager.onIntegrationActivity = { sources.append($0) }
            var replay = message(type)
            replay.nativeMessageReplay = true
            replay.prompt = "Old prompt"
            replay.status = "Old reply"
            replay.observedState = "active"
            replay.recapText = "Old recap"
            replay.tool = "Read"
            manager.handleMessage(replay)
            XCTAssertTrue(sources.isEmpty, type.rawValue)
        }
    }

    func testRejectedOldCodexTurnsCannotConfirmAnIntegration() {
        let manager = SessionManager()
        var start = message()
        start.nativeEvent = "UserPromptSubmit"
        start.nativeTurnId = "old"
        manager.handleMessage(start)
        start.nativeTurnId = "current"
        manager.handleMessage(start)
        var sources: [AgentType] = []
        manager.onIntegrationActivity = { sources.append($0) }
        start.nativeTurnId = "old"
        manager.handleMessage(start)
        var stale = message(.statusUpdate)
        stale.nativeEvent = "PostCompact"
        stale.nativeTurnId = "old"
        stale.observedState = "active"
        manager.handleMessage(stale)
        var oldTool = message(.toolComplete)
        oldTool.nativeEvent = "PostToolUse"
        oldTool.nativeTurnId = "old"
        oldTool.tool = "Read"
        manager.handleMessage(oldTool)
        XCTAssertTrue(sources.isEmpty)
    }

    func testClosedAndArchivedLateResultsCannotConfirmAnIntegration() throws {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        manager.handleMessage(message())
        var end = message(.sessionEnd)
        end.observedState = "completed"
        manager.handleMessage(end)
        let session = try XCTUnwrap(manager.sessions.first)
        var sources: [AgentType] = []
        manager.onIntegrationActivity = { sources.append($0) }
        var late = message(.toolComplete)
        late.tool = "Read"
        manager.handleMessage(late)
        var status = message(.statusUpdate)
        status.status = "Late reply"
        status.statusIsAssistantReply = true
        manager.handleMessage(status)
        manager.handleMessage(end)
        manager.dismissSession(session)
        manager.handleMessage(late)
        manager.handleMessage(status)
        XCTAssertTrue(sources.isEmpty)
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    func testIgnoredClaudeMirrorDoesNotConfirmEitherSource() {
        let manager = SessionManager()
        manager.handleMessage(message(agent: .cursor, id: "cursor-shared"))
        var sources: [AgentType] = []
        manager.onIntegrationActivity = { sources.append($0) }
        manager.handleMessage(message(agent: .claudeCode, id: "claude_code-shared"))
        manager.handleMessage(message(.sessionEnd, agent: .claudeCode, id: "claude_code-shared"))
        XCTAssertTrue(sources.isEmpty)
        var accepted = message(.statusUpdate, agent: .claudeCode, id: "claude_code-shared")
        accepted.status = "Working"
        manager.handleMessage(accepted)
        XCTAssertEqual(sources, [.cursor])
    }

    func testFixtureLoadingDoesNotConfirmAnIntegration() throws {
        let manager = SessionManager()
        var sources: [AgentType] = []
        manager.onIntegrationActivity = { sources.append($0) }
        _ = try AppTestFixtureLoader.load(named: "session-list", into: manager, updateManager: UpdateManager())
        XCTAssertFalse(manager.sessions.isEmpty)
        XCTAssertTrue(sources.isEmpty)
    }

    func testKimiAcceptedApprovalReportsOnceButReplayConflictAndClosedRequestsDoNot() throws {
        let manager = SessionManager()
        var sources: [AgentType] = []
        manager.onIntegrationActivity = { sources.append($0) }
        let request = permission("PermissionRequest")
        manager.handleMessage(request)
        manager.handleMessage(request)
        var conflict = request
        conflict.nativeTurnId = "conflicting-turn"
        manager.handleMessage(conflict)
        var replay = permission("PermissionResult")
        replay.nativeMessageReplay = true
        manager.handleMessage(replay)
        XCTAssertEqual(sources, [.kimi])
        manager.handleMessage(permission("PermissionResult"))
        XCTAssertEqual(sources, [.kimi, .kimi])
        let session = try XCTUnwrap(manager.sessions.first)
        session.status = .completed
        sources.removeAll()
        manager.handleMessage(permission("PermissionRequest", request: "late"))
        manager.handleMessage(permission("PermissionResult", request: "late"))
        XCTAssertTrue(sources.isEmpty)
    }

    func testKimiBackgroundTaskReportsAcceptedFactButNotReplayOrLateResult() throws {
        let manager = SessionManager()
        var sources: [AgentType] = []
        manager.onIntegrationActivity = { sources.append($0) }
        var start = kimi("TaskStarted")
        start.nativeBackgroundTask = DINativeBackgroundTask(id: "background", kind: "agent", status: "running")
        manager.handleMessage(start)
        manager.handleMessage(start)
        XCTAssertEqual(sources, [.kimi])
        var replay = kimi("Notification")
        replay.nativeBackgroundTask = DINativeBackgroundTask(id: "background", status: "completed", result: "Old result")
        replay.nativeMessageReplay = true
        manager.handleMessage(replay)
        XCTAssertEqual(sources, [.kimi])
        let session = try XCTUnwrap(manager.sessions.first)
        session.status = .completed
        var late = kimi("Notification")
        late.nativeBackgroundTask = DINativeBackgroundTask(id: "background", status: "failed", result: "Late result")
        manager.handleMessage(late)
        XCTAssertEqual(sources, [.kimi])
    }

    func testKimiHeartbeatAndOrphanResultsDoNotConfirmAnIntegration() {
        let manager = SessionManager()
        var sources: [AgentType] = []
        manager.onIntegrationActivity = { sources.append($0) }
        manager.handleMessage(kimi("SessionHeartbeat"))
        manager.handleMessage(permission("PermissionResult"))
        manager.handleMessage(permission("PermissionRequest"))
        var invalid = kimi("PermissionRequest")
        invalid.nativeRequestId = "invalid-without-correlation"
        manager.handleMessage(invalid)
        XCTAssertTrue(sources.isEmpty)
    }

    func testObservationHeartbeatAndRejectedSequenceDoNotConfirmAnIntegration() throws {
        let manager = SessionManager()
        var sources: [AgentType] = []
        manager.onIntegrationActivity = { sources.append($0) }
        var observed = message(.observationHeartbeat, agent: .rooCode, id: "")
        observed.sourceNamespace = String(repeating: "a", count: 24)
        observed.sourceInstanceId = "00000000-0000-4000-8000-000000000001"
        observed.observationSequence = 1
        let source = try XCTUnwrap(ObservationSource(message: observed))
        observed.sessionId = source.id
        manager.handleMessage(observed)
        XCTAssertTrue(sources.isEmpty)
        observed.type = .sessionStart
        observed.nativeTaskId = "task"
        observed.sessionId = source.sessionID(task: "task")
        observed.observationSequence = 2
        manager.handleMessage(observed)
        XCTAssertEqual(sources, [.rooCode])
        manager.handleMessage(observed)
        observed.observationSequence = 1
        manager.handleMessage(observed)
        XCTAssertEqual(sources, [.rooCode])
    }
}
