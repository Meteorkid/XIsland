import XCTest
import DIShared
@testable import XIsland

@MainActor
final class NativeInteractionResolutionTests: XCTestCase {
    func testNativeRequestMetadataRoundTripsAndRemainsOptional() throws {
        var message = DIMessage(type: .interactionResolved, sessionId: "native")
        message.nativeRequestId = "request-1"
        message.nativeRequestKind = "permission"

        let decoded = try DIProtocol.decode(DIProtocol.encode(message))
        XCTAssertEqual(decoded.type, .interactionResolved)
        XCTAssertEqual(decoded.nativeRequestId, "request-1")
        XCTAssertEqual(decoded.nativeRequestKind, "permission")

        let legacy = try DIProtocol.decode(DIProtocol.encode(DIMessage(type: .question, sessionId: "legacy")))
        XCTAssertNil(legacy.nativeRequestId)
        XCTAssertNil(legacy.nativeRequestKind)
    }

    func testOldNativeIDCannotCancelReplacementPermissionOrQuestion() throws {
        for kind in ["permission", "question"] {
            let manager = SessionManager()
            let cancellations = NativeInteractionRecorder()
            addRequest(manager, kind: kind, sessionID: "replace", nativeID: "old", cancellations: cancellations)
            addRequest(manager, kind: kind, sessionID: "replace", nativeID: "new", cancellations: cancellations)
            let session = try XCTUnwrap(manager.sessions.first)
            let focus = manager.focusedInteraction

            manager.handleMessage(resolution(sessionID: "replace", nativeID: "old", kind: kind))

            XCTAssertEqual(cancellations.values, ["old"])
            XCTAssertEqual(session.pendingPermission?.nativeRequestId ?? session.pendingQuestion?.nativeRequestId, "new")
            XCTAssertEqual(manager.focusedInteraction, focus)
            XCTAssertTrue(manager.hasInteraction)
        }
    }

    func testParallelToolActivityPreservesNativePermissionAndQuestion() throws {
        for kind in ["permission", "question"] {
            let manager = SessionManager()
            let cancellations = NativeInteractionRecorder()
            var earlierTool = DIMessage(type: .toolStart, sessionId: "parallel")
            earlierTool.agentType = AgentType.openCode.rawValue
            earlierTool.tool = "Read"
            earlierTool.toolCallId = "before-request"
            manager.handleMessage(earlierTool)
            addRequest(manager, kind: kind, sessionID: "parallel", nativeID: "pending", cancellations: cancellations)
            let session = try XCTUnwrap(manager.sessions.first)
            let pendingID = session.pendingPermission?.id ?? session.pendingQuestion?.id
            let focus = manager.focusedInteraction
            let expectedStatus: SessionStatus = kind == "permission" ? .waitingPermission : .waitingAnswer

            var laterTool = DIMessage(type: .toolStart, sessionId: session.id)
            laterTool.agentType = AgentType.openCode.rawValue
            laterTool.tool = "Bash"
            laterTool.toolCallId = "during-request"
            earlierTool.type = .toolComplete
            earlierTool.toolResult = "Read completed"
            var failedTool = laterTool
            failedTool.type = .toolComplete
            failedTool.observedState = "error"
            failedTool.toolResult = "Unrelated command failed"

            for activity in [laterTool, earlierTool, failedTool] {
                manager.handleMessage(activity)
                XCTAssertEqual(session.pendingPermission?.id ?? session.pendingQuestion?.id, pendingID)
                XCTAssertEqual(session.status, expectedStatus)
                XCTAssertEqual(manager.focusedInteraction, focus)
                XCTAssertTrue(cancellations.values.isEmpty)
            }
            XCTAssertEqual(session.events.map(\.isComplete), [true, true])
            XCTAssertEqual(session.events.last?.result, "Unrelated command failed")
            XCTAssertNil(session.currentTool)

            manager.handleMessage(resolution(sessionID: session.id, nativeID: "pending", kind: kind))
            XCTAssertFalse(session.hasPendingInteraction)
            XCTAssertEqual(cancellations.values, ["pending"])
            XCTAssertEqual(session.status, .active)
        }
    }

    func testClearingLegacyRequestKeepsNativeRequestWaitingAndFocused() throws {
        for kind in ["permission", "question"] {
            let manager = SessionManager()
            let cancellations = NativeInteractionRecorder()
            addRequest(manager, kind: kind, sessionID: "mixed", nativeID: "native", cancellations: cancellations)
            let session = try XCTUnwrap(manager.sessions.first)
            if kind == "permission" {
                let legacy = request(kind: "question", sessionID: session.id, nativeID: nil)
                manager.handleQuestionRequest(legacy, respond: { _ in XCTFail("Tool activity must not answer a question") },
                                              cancel: { cancellations.record("legacy") })
                manager.focusInteraction(session: session, kind: .question)
            } else {
                let legacy = request(kind: "permission", sessionID: session.id, nativeID: nil)
                manager.handlePermissionRequest(legacy, cancel: { cancellations.record("legacy") },
                                                respond: { _ in XCTFail("Tool activity must not decide permission") })
                manager.focusInteraction(session: session, kind: .permission)
            }
            var tool = DIMessage(type: .toolComplete, sessionId: session.id)
            tool.tool = "Read"
            tool.observedState = "error"

            manager.handleMessage(tool)

            XCTAssertEqual(session.pendingPermission?.nativeRequestId ?? session.pendingQuestion?.nativeRequestId, "native")
            XCTAssertEqual(session.status, kind == "permission" ? .waitingPermission : .waitingAnswer)
            XCTAssertEqual(manager.focusedInteraction?.kind, kind == "permission" ? .permission : .question)
            XCTAssertEqual(cancellations.values, ["legacy"])
            if kind == "permission" { XCTAssertNil(session.pendingQuestion) }
            else { XCTAssertNil(session.pendingPermission) }
        }
    }

    func testToolActivityRestoresNativeWaitingStateAfterAnEarlierError() throws {
        for kind in ["permission", "question"] {
            let manager = SessionManager()
            let cancellations = NativeInteractionRecorder()
            addRequest(manager, kind: kind, sessionID: "earlier-error", nativeID: "pending", cancellations: cancellations)
            let session = try XCTUnwrap(manager.sessions.first)
            session.status = .error
            var tool = DIMessage(type: .toolComplete, sessionId: session.id)
            tool.tool = "Read"
            tool.observedState = "error"

            manager.handleMessage(tool)

            XCTAssertEqual(session.status, kind == "permission" ? .waitingPermission : .waitingAnswer)
            XCTAssertTrue(session.hasPendingInteraction)
            XCTAssertTrue(cancellations.values.isEmpty)
        }
    }

    func testPermissionResolutionOnlyCancelsMatchingKindInMatchingSession() throws {
        let manager = SessionManager()
        let cancellations = NativeInteractionRecorder()
        addRequest(manager, kind: "permission", sessionID: "first", nativeID: "shared", cancellations: cancellations)
        addRequest(manager, kind: "question", sessionID: "first", nativeID: "shared", cancellations: cancellations)
        addRequest(manager, kind: "permission", sessionID: "second", nativeID: "shared", cancellations: cancellations)
        let first = try XCTUnwrap(manager.sessions.first(where: { $0.id == "first" }))
        let second = try XCTUnwrap(manager.sessions.first(where: { $0.id == "second" }))
        first.pendingPlanReview = PendingPlanReview(requestingAgent: .openCode, markdown: "Keep plan", respond: { _, _ in
            XCTFail("Resolution must not answer a plan review")
        })
        let questionID = first.pendingQuestion?.id
        let planID = first.pendingPlanReview?.id

        manager.handleMessage(resolution(sessionID: "first", nativeID: "shared", kind: "permission"))

        XCTAssertNil(first.pendingPermission)
        XCTAssertEqual(first.pendingQuestion?.id, questionID)
        XCTAssertEqual(first.pendingPlanReview?.id, planID)
        XCTAssertEqual(first.status, .waitingAnswer)
        XCTAssertEqual(second.pendingPermission?.nativeRequestId, "shared")
        XCTAssertEqual(cancellations.values, ["shared"])
        XCTAssertTrue(manager.hasInteraction)
        XCTAssertEqual(manager.focusedInteraction?.sessionID, "second")
        XCTAssertEqual(manager.focusedInteraction?.kind, .permission)
    }

    func testQuestionResolutionPreservesPermissionAndHistory() throws {
        let manager = SessionManager()
        let cancellations = NativeInteractionRecorder()
        addRequest(manager, kind: "permission", sessionID: "history", nativeID: "shared", cancellations: cancellations)
        addRequest(manager, kind: "question", sessionID: "history", nativeID: "shared", cancellations: cancellations)
        let session = try XCTUnwrap(manager.sessions.first)
        let permissionID = session.pendingPermission?.id
        session.chatHistory = [ChatMessage(timestamp: Date(), role: .assistant, content: "Existing reply")]
        session.events = [ToolEvent(tool: "Read", input: "existing.txt")]
        session.currentTool = "Read"
        session.statusText = "Existing status"
        manager.focusInteraction(session: session, kind: .question)
        let chatID = session.chatHistory.first?.id
        let eventID = session.events.first?.id
        var resolved = resolution(sessionID: "history", nativeID: "shared", kind: "question")
        resolved.status = "This must not become a chat reply"
        resolved.tool = "This must not become a tool event"

        manager.handleMessage(resolved)

        XCTAssertNil(session.pendingQuestion)
        XCTAssertEqual(session.pendingPermission?.id, permissionID)
        XCTAssertEqual(session.status, .waitingPermission)
        XCTAssertEqual(cancellations.values, ["shared"])
        XCTAssertEqual(session.chatHistory.map(\.id), [chatID].compactMap { $0 })
        XCTAssertEqual(session.events.map(\.id), [eventID].compactMap { $0 })
        XCTAssertEqual(session.statusText, "Existing status")
        XCTAssertEqual(session.currentTool, "Read")
        XCTAssertEqual(manager.focusedInteraction?.kind, .permission)
    }

    func testResolvingUnfocusedQuestionPreservesExistingPermissionFocus() throws {
        let manager = SessionManager()
        let cancellations = NativeInteractionRecorder()
        addRequest(manager, kind: "permission", sessionID: "focus", nativeID: "permission", cancellations: cancellations)
        addRequest(manager, kind: "question", sessionID: "focus", nativeID: "question", cancellations: cancellations)
        let session = try XCTUnwrap(manager.sessions.first)
        let focus = manager.focusedInteraction
        let islandState = manager.currentIslandState

        manager.handleMessage(resolution(sessionID: session.id, nativeID: "question", kind: "question"))

        XCTAssertEqual(manager.focusedInteraction, focus)
        XCTAssertEqual(manager.currentIslandState, islandState)
        XCTAssertEqual(cancellations.values, ["question"])
        XCTAssertNotNil(session.pendingPermission)
    }

    func testLastResolutionRestoresActiveStateAndClearsInteractionFocus() throws {
        let manager = SessionManager()
        let cancellations = NativeInteractionRecorder()
        addRequest(manager, kind: "question", sessionID: "last", nativeID: "request", cancellations: cancellations)
        let session = try XCTUnwrap(manager.sessions.first)

        manager.handleMessage(resolution(sessionID: "last", nativeID: "request", kind: "question"))
        manager.handleMessage(resolution(sessionID: "last", nativeID: "request", kind: "question"))

        XCTAssertEqual(cancellations.values, ["request"])
        XCTAssertFalse(manager.hasInteraction)
        XCTAssertNil(manager.focusedInteraction)
        XCTAssertEqual(session.status, .active)
        XCTAssertEqual(manager.selectedSessionId, session.id)
        XCTAssertEqual(manager.currentIslandState, .collapsed)
        XCTAssertEqual(manager.diagnosticsIslandState, "collapsed")
    }

    func testUnknownSessionKindAndEmptyIDsCannotCancelPendingRequest() throws {
        let manager = SessionManager()
        let cancellations = NativeInteractionRecorder()
        addRequest(manager, kind: "permission", sessionID: "opencode-shared", nativeID: "request", cancellations: cancellations)
        let session = try XCTUnwrap(manager.sessions.first)
        let pendingID = session.pendingPermission?.id

        manager.handleMessage(resolution(sessionID: "claude_code-shared", nativeID: "request", kind: "permission"))
        manager.handleMessage(resolution(sessionID: session.id, nativeID: "request", kind: "question"))
        manager.handleMessage(resolution(sessionID: session.id, nativeID: "request", kind: "unknown"))
        manager.handleMessage(resolution(sessionID: session.id, nativeID: "request", kind: nil))
        manager.handleMessage(resolution(sessionID: session.id, nativeID: nil, kind: "permission"))
        manager.handleMessage(resolution(sessionID: session.id, nativeID: "", kind: "permission"))
        manager.handleMessage(resolution(sessionID: session.id, nativeID: " \n", kind: "permission"))

        XCTAssertEqual(manager.sessions.map(\.id), [session.id])
        XCTAssertEqual(session.pendingPermission?.id, pendingID)
        XCTAssertTrue(cancellations.values.isEmpty)
    }

    func testTwoIdenticalQuestionsWithDifferentNativeIDsRequireTwoAnswers() throws {
        let manager = SessionManager()
        let answers = NativeInteractionRecorder()
        var question = request(kind: "question", sessionID: "repeat", nativeID: "first")
        manager.handleQuestionRequest(question, respond: { answers.record($0) })
        let session = try XCTUnwrap(manager.sessions.first)
        manager.answerQuestion(session: session, answer: "Continue")
        XCTAssertEqual(answers.values, ["Continue"])

        question.nativeRequestId = "second"
        manager.handleQuestionRequest(question, respond: { answers.record($0) })

        XCTAssertEqual(answers.values, ["Continue"])
        XCTAssertEqual(session.pendingQuestion?.nativeRequestId, "second")
        XCTAssertEqual(session.status, .waitingAnswer)
        manager.answerQuestion(session: session, answer: "Stop")
        XCTAssertEqual(answers.values, ["Continue", "Stop"])
    }

    func testNativeQuestionDoesNotReuseLegacyAnswerCache() throws {
        let manager = SessionManager()
        let answers = NativeInteractionRecorder()
        var question = request(kind: "question", sessionID: "legacy-cache", nativeID: nil)
        manager.handleQuestionRequest(question, respond: { answers.record($0) })
        let session = try XCTUnwrap(manager.sessions.first)
        manager.answerQuestion(session: session, answer: "Continue")

        question.nativeRequestId = "native-request"
        manager.handleQuestionRequest(question, respond: { answers.record($0) })

        XCTAssertEqual(answers.values, ["Continue"])
        XCTAssertEqual(session.pendingQuestion?.nativeRequestId, "native-request")
    }

    func testNativeAnswerDoesNotPopulateLegacyQuestionCache() throws {
        let manager = SessionManager()
        let answers = NativeInteractionRecorder()
        var question = request(kind: "question", sessionID: "native-cache", nativeID: "native-request")
        manager.handleQuestionRequest(question, respond: { answers.record($0) })
        let session = try XCTUnwrap(manager.sessions.first)
        manager.answerQuestion(session: session, answer: "Continue")

        question.nativeRequestId = nil
        manager.handleQuestionRequest(question, respond: { answers.record($0) })

        XCTAssertEqual(answers.values, ["Continue"])
        XCTAssertNotNil(session.pendingQuestion)
        XCTAssertEqual(session.status, .waitingAnswer)
    }

    func testExternalDirectoryAliasesWaitForApprovalUnlessBypassExplicitlyEnabled() throws {
        let manager = SessionManager()
        let original = AppPreferences.defaults.object(forKey: "bypassMode")
        AppPreferences.defaults.set(false, forKey: "bypassMode")
        defer { AppPreferences.defaults.set(original, forKey: "bypassMode") }
        for tool in ["external_directory", "ExternalDirectory", "unknown"] {
            var permission = request(kind: "permission", sessionID: tool, nativeID: tool)
            permission.tool = tool
            manager.handlePermissionRequest(permission, respond: { _ in
                XCTFail("Permission must await an explicit decision")
            })
            let session = try XCTUnwrap(manager.sessions.first(where: { $0.id == tool }))
            XCTAssertEqual(session.status, .waitingPermission)
            XCTAssertEqual(session.pendingPermission?.nativeRequestId, tool)
        }

        manager.bypassMode = true
        let decisions = NativeInteractionRecorder()
        manager.handlePermissionRequest(request(kind: "permission", sessionID: "bypass", nativeID: "bypass"), respond: {
            decisions.record(String($0))
        })
        XCTAssertEqual(decisions.values, ["true"])
        XCTAssertFalse(manager.sessions.contains(where: { $0.id == "bypass" }))
    }

    private func request(kind: String, sessionID: String, nativeID: String?) -> DIMessage {
        var message = DIMessage(type: kind == "permission" ? .permissionRequest : .question, sessionId: sessionID)
        message.agentType = AgentType.openCode.rawValue
        message.nativeRequestId = nativeID
        message.nativeRequestKind = kind
        message.tool = "Bash"
        message.questionText = "Choose the next action"
        message.options = ["Continue", "Stop"]
        return message
    }

    private func addRequest(_ manager: SessionManager, kind: String, sessionID: String, nativeID: String,
                            cancellations: NativeInteractionRecorder) {
        let message = request(kind: kind, sessionID: sessionID, nativeID: nativeID)
        if kind == "permission" {
            manager.handlePermissionRequest(message, cancel: { cancellations.record(nativeID) }, respond: { _ in
                XCTFail("Resolution must not decide permission")
            })
        } else {
            manager.handleQuestionRequest(message, respond: { _ in
                XCTFail("Resolution must not answer a question")
            }, cancel: { cancellations.record(nativeID) })
        }
    }

    private func resolution(sessionID: String, nativeID: String?, kind: String?) -> DIMessage {
        var message = DIMessage(type: .interactionResolved, sessionId: sessionID)
        message.nativeRequestId = nativeID
        message.nativeRequestKind = kind
        return message
    }
}

private final class NativeInteractionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(value)
    }
}
