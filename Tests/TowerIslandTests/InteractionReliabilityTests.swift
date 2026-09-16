import XCTest
import DIShared
@testable import XIsland

@MainActor
final class InteractionReliabilityTests: XCTestCase {
    func testNewInteractionDoesNotReuseAnotherSessionOfSameAgent() {
        let manager = SessionManager()
        var start = DIMessage(type: .sessionStart, sessionId: "existing")
        start.agentType = AgentType.claudeCode.rawValue
        manager.handleMessage(start)
        var request = DIMessage(type: .permissionRequest, sessionId: "independent")
        request.agentType = AgentType.claudeCode.rawValue
        request.tool = "Bash"
        manager.handlePermissionRequest(request, respond: { _ in })

        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertNil(manager.sessions.first(where: { $0.id == "existing" })?.pendingPermission)
        XCTAssertNotNil(manager.sessions.first(where: { $0.id == "independent" })?.pendingPermission)
    }

    func testLateApprovalWithoutPendingRequestDoesNotReactivateSession() {
        let manager = SessionManager()
        let session = AgentSession(id: "finished", agentType: .claudeCode)
        session.status = .completed
        manager.sessions = [session]
        manager.approvePermission(session: session)
        XCTAssertEqual(session.status, .completed)
    }

    func testChangedQuestionOptionsDoNotReusePreviousAnswer() {
        let manager = SessionManager()
        var question = DIMessage(type: .question, sessionId: "question")
        question.agentType = AgentType.claudeCode.rawValue
        question.questionText = "Choose the next action"
        question.options = ["Continue", "Stop"]
        manager.handleQuestionRequest(question, respond: { _ in })
        let session = try! XCTUnwrap(manager.sessions.first)
        manager.answerQuestion(session: session, answer: "Continue")

        question.options = ["Retry", "Cancel"]
        manager.handleQuestionRequest(question, respond: { _ in
            XCTFail("A changed question must await a new user answer")
        })
        XCTAssertEqual(session.pendingQuestion?.options, ["Retry", "Cancel"])
    }

    func testOldRequestIDCannotApproveItsReplacement() {
        let manager = SessionManager()
        var message = DIMessage(type: .permissionRequest, sessionId: "replace")
        message.agentType = AgentType.claudeCode.rawValue
        message.tool = "Bash"
        manager.handlePermissionRequest(message, respond: { _ in })
        let session = manager.sessions[0]
        let oldID = session.pendingPermission!.id
        manager.handlePermissionRequest(message, respond: { _ in XCTFail("Stale click submitted replacement") })
        manager.approvePermission(session: session, requestID: oldID)
        XCTAssertNotEqual(session.pendingPermission?.id, oldID)
        XCTAssertTrue(session.pendingPermission!.state.canSubmit)
    }

    func testFocusedPlanShortcutKeepsDraftWhenAnotherRequestArrives() {
        let manager = SessionManager()
        var plan = DIMessage(type: .planReview, sessionId: "plan-draft")
        plan.agentType = AgentType.claudeCode.rawValue
        plan.planMarkdown = "# Plan"
        let result = DecisionRecorder()
        manager.handlePlanReview(plan, respond: { approved, feedback in result.record(approved, feedback) })
        let session = manager.sessions[0]
        session.pendingPlanReview!.state.draftFeedback = "先补测试\n保留原有接口"
        manager.focusInteraction(session: session, kind: .plan)

        var question = DIMessage(type: .question, sessionId: "another-request")
        question.agentType = AgentType.cursor.rawValue
        question.questionText = "Continue?"
        question.options = ["Yes", "No"]
        manager.handleQuestionRequest(question, respond: { _ in XCTFail("Wrong interaction") })
        XCTAssertTrue(manager.handleInteractionShortcut("n"))
        XCTAssertEqual(result.approved, false)
        XCTAssertEqual(result.feedback, "先补测试\n保留原有接口")
        XCTAssertTrue(manager.hasInteraction)
        XCTAssertEqual(manager.focusedInteraction?.sessionID, "another-request")
    }

    func testFailedDeliveryKeepsRequestAndDoesNotAllowResendingClosedChannel() async {
        let manager = SessionManager()
        var message = DIMessage(type: .permissionRequest, sessionId: "failure")
        message.agentType = AgentType.claudeCode.rawValue
        let result = DecisionRecorder()
        manager.handlePermissionRequest(message, delivery: { _ in result.record(true, nil); return false },
                                        respond: { _ in XCTFail("Socket delivery must bypass legacy callback") })
        let session = manager.sessions[0]
        let state = session.pendingPermission!.state
        manager.approvePermission(session: session)
        manager.approvePermission(session: session)
        for _ in 0..<1000 where state.phase == .sending { await Task.yield() }
        XCTAssertEqual(state.phase, .failed)
        XCTAssertNotNil(session.pendingPermission)
        XCTAssertEqual(session.status, .waitingPermission)
        XCTAssertEqual(result.count, 1)
        manager.approvePermission(session: session)
        XCTAssertEqual(result.count, 1)
    }

    func testStreamingAssistantUpdatePreservesMessageIdentity() {
        let manager = SessionManager()
        var message = DIMessage(type: .statusUpdate, sessionId: "stream")
        message.agentType = AgentType.claudeCode.rawValue
        message.status = "First response"
        manager.handleMessage(message)
        let session = manager.sessions[0]
        let firstID = session.chatHistory.last?.id
        XCTAssertNotNil(firstID)
        message.status = "Longer updated response"
        manager.handleMessage(message)
        XCTAssertEqual(session.chatHistory.last?.id, firstID)
        XCTAssertEqual(session.chatHistory.count, 1)
    }

    func testDismissKeepsSessionWhenItsHistoryCannotBeSaved() {
        let manager = SessionManager()
        manager.persistenceManager = SessionPersistenceManager()
        let session = AgentSession(id: "unsaved", agentType: .claudeCode, prompt: "Keep this work")
        manager.sessions = [session]
        manager.dismissSession(session)
        XCTAssertEqual(manager.sessions.map(\.id), ["unsaved"])
        XCTAssertNotNil(manager.persistenceManager?.lastSaveError)
        XCTAssertEqual(manager.unsavedSessionIDs, ["unsaved"])
        XCTAssertTrue(manager.persistenceManager!.setupContainer(isStoredInMemoryOnly: true))
        manager.retryPendingHistorySaves()
        XCTAssertTrue(manager.unsavedSessionIDs.isEmpty)
        XCTAssertEqual(manager.persistenceManager?.fetchHistory().first?.sessionId, "unsaved")
    }

    func testLingerCleanupRetainsCompletedSessionsThatFailedToSave() {
        let manager = SessionManager()
        manager.persistenceManager = SessionPersistenceManager()
        let key = "completedLingerDuration"
        let original = AppPreferences.defaults.object(forKey: key)
        AppPreferences.defaults.set(0.01, forKey: key)
        defer { AppPreferences.defaults.set(original, forKey: key) }
        var start = DIMessage(type: .sessionStart, sessionId: "unsaved-completed")
        start.agentType = AgentType.droid.rawValue
        manager.handleMessage(start)
        var end = DIMessage(type: .sessionEnd, sessionId: "unsaved-completed")
        end.agentType = AgentType.droid.rawValue
        manager.handleMessage(end)
        guard let session = manager.sessions.first else { XCTFail("Expected retained session"); return }
        session.completedAt = Date().addingTimeInterval(-3600)
        manager.cleanupLingeredSessions()
        XCTAssertEqual(manager.sessions.map(\.id), ["unsaved-completed"])
        XCTAssertEqual(manager.unsavedSessionIDs, ["unsaved-completed"])
    }

    func testCompletedAgentCancelsItsPendingRequestWithoutApprovingIt() {
        let manager = SessionManager()
        let cancellation = DecisionRecorder()
        var permission = DIMessage(type: .permissionRequest, sessionId: "ended-request")
        permission.agentType = AgentType.droid.rawValue
        manager.handlePermissionRequest(permission, cancel: { cancellation.record(true, nil) },
                                        respond: { _ in XCTFail("Completion must not decide a pending request") })
        var end = DIMessage(type: .sessionEnd, sessionId: "ended-request")
        end.agentType = AgentType.droid.rawValue
        manager.handleMessage(end)
        XCTAssertFalse(manager.hasInteraction)
        XCTAssertNil(manager.sessions.first?.pendingPermission)
        XCTAssertEqual(cancellation.count, 1)
    }

    func testNewPromptKeepsThePreviousAssistantReply() {
        let manager = SessionManager()
        var start = DIMessage(type: .sessionStart, sessionId: "two-turns")
        start.agentType = AgentType.claudeCode.rawValue
        start.prompt = "First question"
        manager.handleMessage(start)
        var reply = DIMessage(type: .statusUpdate, sessionId: start.sessionId)
        reply.agentType = start.agentType
        reply.status = "First answer"
        manager.handleMessage(reply)
        start.prompt = "Second question"
        manager.handleMessage(start)
        reply.status = "Second answer"
        manager.handleMessage(reply)
        XCTAssertEqual(manager.sessions.first?.chatHistory.map(\.content),
                       ["First question", "First answer", "Second question", "Second answer"])
    }

    func testNewTurnInvalidatesOldPendingRequest() {
        let manager = SessionManager()
        var permission = DIMessage(type: .permissionRequest, sessionId: "new-turn")
        permission.agentType = AgentType.claudeCode.rawValue
        manager.handlePermissionRequest(permission, respond: { _ in XCTFail("Obsolete request was submitted") })
        var start = DIMessage(type: .sessionStart, sessionId: permission.sessionId)
        start.agentType = permission.agentType
        start.prompt = "Start another task"
        manager.handleMessage(start)
        XCTAssertFalse(manager.hasInteraction)
        XCTAssertNil(manager.sessions.first?.pendingPermission)
    }
}

private final class DecisionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Bool, String?)] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var approved: Bool? { lock.lock(); defer { lock.unlock() }; return values.last?.0 }
    var feedback: String? { lock.lock(); defer { lock.unlock() }; return values.last?.1 }
    func record(_ approved: Bool, _ feedback: String?) {
        lock.lock(); defer { lock.unlock() }
        values.append((approved, feedback))
    }
}
