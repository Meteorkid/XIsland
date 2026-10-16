import XCTest
import DIShared
@testable import XIsland
@testable import DIBridge

@MainActor
final class CustomQuestionAnswerTests: XCTestCase {
    func testStaleInputCannotStealFocusFromCurrentRequest() throws {
        let manager = SessionManager()
        var firstMessage = try question(custom: true)
        firstMessage.sessionId = "first"
        manager.handleQuestionRequest(firstMessage, respond: { _ in })
        let first = manager.sessions[0]
        var secondMessage = try question(custom: true)
        secondMessage.sessionId = "second"
        manager.handleQuestionRequest(secondMessage, respond: { _ in })
        let second = try XCTUnwrap(manager.sessions.first(where: { $0.id == "second" }))
        let oldID = try XCTUnwrap(second.pendingQuestion?.id)
        manager.handleQuestionRequest(secondMessage, respond: { _ in })
        manager.focusInteraction(session: first, kind: .question)
        manager.focusInteraction(session: second, kind: .question, requestID: oldID)
        XCTAssertEqual(manager.focusedInteraction?.sessionID, first.id)
        let currentID = try XCTUnwrap(second.pendingQuestion?.id)
        manager.focusInteraction(session: second, kind: .question, requestID: currentID)
        XCTAssertEqual(manager.focusedInteraction?.requestID, currentID)
    }

    func testDraftsAndSubmissionAreScopedToCurrentRequest() throws {
        let manager = SessionManager()
        manager.handleQuestionRequest(try question(custom: true), respond: { _ in XCTFail("Superseded request") })
        let session = manager.sessions[0]
        let first = try XCTUnwrap(session.pendingQuestion)
        first.state.draftAnswer = "old draft"
        var replacement = try question(custom: true)
        replacement.nativeRequestId = "question-2"
        manager.handleQuestionRequest(replacement, respond: { _ in XCTFail("Stale submission") })
        let second = try XCTUnwrap(session.pendingQuestion)
        XCTAssertEqual(second.state.draftAnswer, "")
        XCTAssertEqual(first.state.draftAnswer, "old draft")
        manager.answerQuestion(session: session, answer: "old draft", requestID: first.id)
        XCTAssertEqual(session.pendingQuestion?.id, second.id)
    }

    private func question(custom: Bool) throws -> DIMessage {
        try OpenCodeHookAdapter.normalize(hookType: "question.asked", stdinData: [
            "native_event": "question.asked", "session_id": "custom-fixture", "native_request_id": "question-1",
            "native_request_kind": "question", "question": "Which path?", "options": ["A"], "allow_custom_answer": custom
        ])
    }

    func testCustomAnswerRequiresExplicitCapability() throws {
        let manager = SessionManager()
        manager.handleQuestionRequest(try question(custom: false), respond: { _ in XCTFail("Unexpected response") })
        let session = manager.sessions[0]
        manager.answerQuestion(session: session, answer: "custom path")
        XCTAssertNotNil(session.pendingQuestion)
        manager.handleQuestionRequest(try question(custom: true), respond: { answer in XCTAssertEqual(answer, "custom path") })
        manager.answerQuestion(session: session, answer: "custom path")
        XCTAssertNil(session.pendingQuestion)
    }

    func testEmptyOversizedAndNullAnswersAreRejected() throws {
        let manager = SessionManager()
        manager.handleQuestionRequest(try question(custom: true), respond: { _ in XCTFail("Invalid response") })
        for answer in ["  \n", String(repeating: "x", count: 8193), "a\0b"] {
            manager.answerQuestion(session: manager.sessions[0], answer: answer)
            XCTAssertNotNil(manager.sessions[0].pendingQuestion)
        }
    }

    func testPureFreeTextQuestionNeedsCapability() throws {
        var payload: [String: Any] = ["native_event": "question.asked", "session_id": "fixture", "native_request_id": "1",
            "native_request_kind": "question", "question": "Path?", "options": [] as [String]]
        XCTAssertThrowsError(try OpenCodeHookAdapter.normalize(hookType: "question.asked", stdinData: payload))
        payload["allow_custom_answer"] = true
        let message = try OpenCodeHookAdapter.normalize(hookType: "question.asked", stdinData: payload)
        XCTAssertEqual(message.allowsCustomAnswer, true)
        XCTAssertEqual(message.options, [])
        payload["allow_custom_answer"] = 1
        XCTAssertThrowsError(try OpenCodeHookAdapter.normalize(hookType: "question.asked", stdinData: payload))
    }

    func testNativeFreeTextNamedQuestionIsNotMistakenForLegacyPlaceholder() {
        let manager = SessionManager()
        var message = DIMessage(type: .question, sessionId: "native-fixture")
        message.agentType = "opencode"
        message.nativeRequestId = "request"
        message.questionText = "Question"
        message.options = []
        message.allowsCustomAnswer = true
        manager.handleQuestionRequest(message, respond: { _ in })
        XCTAssertEqual(manager.sessions.first?.pendingQuestion?.text, "Question")
    }
}
