import XCTest
import DIShared
@testable import XIsland

@MainActor
final class MultipleQuestionAnswerTests: XCTestCase {
    func testUTF8BudgetCountsCombinedLabelsAndCustomText() {
        let request = PendingQuestion(requestingAgent: .openCode, text: "Pick", options: ["选"], respond: { _ in }, cancel: nil,
            allowsCustomAnswer: true, allowsMultipleAnswers: true)
        let exact = String(repeating: "中", count: 2729) + "ab"
        XCTAssertEqual("选".utf8.count + exact.utf8.count, 8192)
        XCTAssertTrue(request.acceptsAnswers(["选", exact]))
        XCTAssertFalse(request.acceptsAnswers(["选", exact + "c"]))
    }

    func testBypassDoesNotAnswerMultipleQuestionAndShortcutsOnlyToggle() throws {
        let manager = SessionManager()
        let previous = AppPreferences.defaults.object(forKey: "bypassMode")
        defer {
            if let previous { AppPreferences.defaults.set(previous, forKey: "bypassMode") }
            else { AppPreferences.defaults.removeObject(forKey: "bypassMode") }
        }
        manager.bypassMode = true
        var message = DIMessage(type: .question, sessionId: "multiple-shortcuts")
        message.agentType = "opencode"
        message.questionText = "Pick several"
        message.options = ["A", "B"]
        message.allowsMultipleAnswers = true
        manager.handleQuestionRequest(message, respond: { _ in XCTFail("Must not auto-answer multiple question") })
        let question = try XCTUnwrap(manager.sessions.first?.pendingQuestion)
        XCTAssertTrue(manager.handleInteractionShortcut("2"))
        XCTAssertTrue(manager.handleInteractionShortcut("1"))
        XCTAssertEqual(question.selectedAnswerValues, ["A", "B"])
        XCTAssertTrue(manager.handleInteractionShortcut("2"))
        XCTAssertEqual(question.selectedAnswerValues, ["A"])
        XCTAssertFalse(manager.handleInteractionShortcut("3"))
        XCTAssertEqual(manager.sessions.first?.pendingQuestion?.id, question.id)
        question.state.phase = .sending
        XCTAssertFalse(manager.handleInteractionShortcut("1"))
        XCTAssertEqual(question.selectedAnswerValues, ["A"])
    }

    func testSelectionOrderIsStableAndDraftDoesNotLeakAcrossRequests() {
        let request = PendingQuestion(requestingAgent: .openCode, text: "Pick", options: ["A", "B"], respond: { _ in }, cancel: nil,
            allowsCustomAnswer: true, allowsMultipleAnswers: true)
        request.state.selectedAnswers = ["B", "A"]
        request.state.draftAnswer = "custom"
        XCTAssertEqual(request.selectedAnswerValues, ["A", "B", "custom"])
        let next = PendingQuestion(requestingAgent: .openCode, text: "Next", options: ["A"], respond: { _ in }, cancel: nil,
            allowsMultipleAnswers: true)
        XCTAssertTrue(next.selectedAnswerValues.isEmpty)
    }

    func testMultipleValidationAndExactArrayDelivery() throws {
        let manager = SessionManager()
        var message = DIMessage(type: .question, sessionId: "multiple-fixture")
        message.agentType = "opencode"; message.questionText = "Choose"
        message.options = ["A,comma", "B\nnewline"]
        message.allowsMultipleAnswers = true
        manager.handleQuestionRequest(message, respond: { _ in XCTFail("Single-answer callback") })
        let session = manager.sessions[0]
        let request = try XCTUnwrap(session.pendingQuestion)
        session.pendingQuestion?.respondMultiple = { values in XCTAssertEqual(values, ["A,comma", "B\nnewline"]) }
        for values in [[], ["unknown"], ["A,comma", "A,comma"]] {
            manager.answerQuestion(session: session, answers: values, requestID: request.id)
            XCTAssertNotNil(session.pendingQuestion)
        }
        manager.answerQuestion(session: session, answer: "A,comma", requestID: request.id)
        XCTAssertNotNil(session.pendingQuestion)
        manager.answerQuestion(session: session, answers: ["A,comma"], requestID: UUID())
        XCTAssertNotNil(session.pendingQuestion)
        manager.answerQuestion(session: session, answers: ["A,comma", "B\nnewline"], requestID: request.id)
        XCTAssertNil(session.pendingQuestion)
    }

    func testMultipleCustomInputIsExplicitAndBounded() {
        var request = PendingQuestion(requestingAgent: .openCode, text: "Pick", options: ["A"], respond: { _ in }, cancel: nil,
            allowsMultipleAnswers: true)
        XCTAssertFalse(request.acceptsAnswers(["A", "custom"]))
        request.allowsCustomAnswer = true
        XCTAssertTrue(request.acceptsAnswers(["A", "custom"]))
        XCTAssertFalse(request.acceptsAnswers(["one custom", "two custom"]))
        XCTAssertFalse(request.acceptsAnswers(["A", String(repeating: "x", count: 8192)]))
    }
}
