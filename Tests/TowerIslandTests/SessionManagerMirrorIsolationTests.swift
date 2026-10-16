import XCTest
import DIShared
@testable import XIsland

@MainActor
final class SessionManagerMirrorIsolationTests: XCTestCase {
    private func message(_ type: DIMessageType, agent: AgentType, suffix: String = "shared") -> DIMessage {
        var message = DIMessage(type: type, sessionId: "\(agent.rawValue)-\(suffix)")
        message.agentType = agent.rawValue
        return message
    }

    func testRooAndPearSocketTasksRetainSixteenIndependentPrompts() {
        let manager = SessionManager()
        for agent in [AgentType.rooCode, .pearai] {
            for index in 0..<8 {
                var start = message(.sessionStart, agent: agent, suffix: "socket-\(index)")
                start.prompt = "\(agent.rawValue) prompt \(index)"
                manager.handleMessage(start)
            }
        }
        XCTAssertEqual(manager.sessions.count, 16)
        for session in manager.sessions {
            XCTAssertEqual(session.prompt, "\(session.agentType.rawValue) prompt \(session.id.last!)")
        }
    }

    func testEveryIndependentSourceKeepsItsSessionWithSharedSuffix() {
        let manager = SessionManager()
        let agents = AgentType.allCases.filter { $0 != .claudeCode && $0 != .hermes }
        for agent in agents {
            var start = message(.sessionStart, agent: agent)
            start.prompt = agent.rawValue
            manager.handleMessage(start)
        }
        XCTAssertEqual(Set(manager.sessions.map(\.agentType)), Set(agents))
        XCTAssertEqual(manager.sessions.count, agents.count)
        for session in manager.sessions { XCTAssertEqual(session.prompt, session.agentType.rawValue) }
    }

    func testIndependentColdStatusToolAndContextEventsCannotModifyCursor() throws {
        for type in [DIMessageType.statusUpdate, .progress, .toolStart, .toolComplete, .contextCompact, .recap] {
            let manager = SessionManager()
            manager.handleMessage(message(.sessionStart, agent: .cursor))
            let cursor = try XCTUnwrap(manager.sessions.first)
            var incoming = message(type, agent: .rooCode)
            incoming.status = "Roo activity"
            incoming.tool = "Read"
            incoming.toolCallId = "tool-1"
            manager.handleMessage(incoming)
            XCTAssertEqual(manager.sessions.count, 2, "\(type)")
            XCTAssertEqual(cursor.statusText, "", "\(type)")
            XCTAssertTrue(cursor.events.isEmpty, "\(type)")
            XCTAssertEqual(cursor.status, .active, "\(type)")
        }
    }

    func testUnknownIndependentEndCannotFinishMatchingSuffix() throws {
        for agent in [AgentType.rooCode, .pearai, .workBuddy, .codex, .trae, .windsurf] {
            let manager = SessionManager()
            manager.handleMessage(message(.sessionStart, agent: .cursor))
            let cursor = try XCTUnwrap(manager.sessions.first)
            var end = message(.sessionEnd, agent: agent)
            end.status = "other response"
            end.observedState = "completed"
            manager.handleMessage(end)
            XCTAssertEqual(manager.sessions.count, 1)
            XCTAssertEqual(cursor.status, .active, "\(agent)")
            XCTAssertEqual(cursor.agentResponse, "", "\(agent)")
        }
    }

    func testIndependentRequestsNeverReplaceCursorInteractions() throws {
        for kind in [DIMessageType.permissionRequest, .question, .planReview] {
            let manager = SessionManager()
            var cursorRequest = message(kind, agent: .cursor)
            cursorRequest.questionText = "Continue?"
            cursorRequest.options = ["Yes", "No"]
            addRequest(cursorRequest, manager: manager)
            let cursor = try XCTUnwrap(manager.sessions.first)
            let focus = manager.focusedInteraction
            var independent = cursorRequest
            independent.sessionId = "pearai-shared"
            independent.agentType = "pearai"
            addRequest(independent, manager: manager)
            XCTAssertEqual(manager.sessions.count, 2, "\(kind)")
            XCTAssertEqual(manager.focusedInteraction, focus, "\(kind)")
            XCTAssertTrue(cursor.hasPendingInteraction)
        }
    }

    func testRecentAnswerCannotAutomaticallyAnswerIndependentSource() throws {
        let manager = SessionManager()
        var question = message(.question, agent: .cursor)
        question.questionText = "Continue?"
        question.options = ["Yes", "No"]
        manager.handleQuestionRequest(question, respond: { XCTAssertEqual($0, "Yes") })
        manager.answerQuestion(session: try XCTUnwrap(manager.sessions.first), answer: "Yes")
        question.sessionId = "pearai-shared"
        question.agentType = "pearai"
        manager.handleQuestionRequest(question, respond: { _ in XCTFail("Cross-source cached answer") })
        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertNotNil(manager.sessions.first(where: { $0.id == question.sessionId })?.pendingQuestion)
    }

    func testFamilyClaudePairsKeepLifecycleToolsInteractionsAndRecentAnswers() throws {
        for family in [AgentType.cursor, .trae, .windsurf] {
            let manager = SessionManager()
            var start = message(.sessionStart, agent: family)
            start.prompt = "native prompt"
            manager.handleMessage(start)
            let session = try XCTUnwrap(manager.sessions.first)
            manager.handleMessage(message(.sessionStart, agent: .claudeCode))
            XCTAssertEqual(session.prompt, "native prompt")
            var status = message(.statusUpdate, agent: .claudeCode)
            status.status = "Working"
            manager.handleMessage(status)
            XCTAssertEqual(session.statusText, "Working")
            var tool = message(.toolStart, agent: .claudeCode)
            tool.tool = "Read"
            tool.toolCallId = "mirrored-tool"
            manager.handleMessage(tool)
            tool.type = .toolComplete
            manager.handleMessage(tool)
            XCTAssertEqual(session.events.count, 1)
            XCTAssertEqual(session.events.first?.isComplete, true)
            for kind in [DIMessageType.permissionRequest, .question, .planReview] {
                var request = message(kind, agent: .claudeCode)
                request.questionText = "Continue?"
                request.options = ["Yes", "No"]
                addRequest(request, manager: manager)
                XCTAssertEqual(manager.sessions.count, 1)
            }
            manager.answerQuestion(session: session, answer: "Yes")
            var duplicate = message(.question, agent: family)
            duplicate.questionText = "Continue?"
            duplicate.options = ["Yes", "No"]
            manager.handleQuestionRequest(duplicate, respond: { XCTAssertEqual($0, "Yes") })
            XCTAssertNil(session.pendingQuestion)
            manager.handleMessage(message(.sessionEnd, agent: .claudeCode))
            XCTAssertNotEqual(session.status, .completed)
            XCTAssertEqual(manager.sessions.count, 1)
        }
    }

    func testClaudeFirstBindsOnlyOneFamily() {
        for family in [AgentType.cursor, .trae, .windsurf] {
            let manager = SessionManager()
            manager.handleMessage(message(.sessionStart, agent: .claudeCode))
            var primary = message(.sessionStart, agent: family)
            primary.prompt = "primary"
            manager.handleMessage(primary)
            XCTAssertEqual(manager.sessions.count, 1)
            let other: AgentType = family == .cursor ? .windsurf : .cursor
            var secondary = message(.sessionStart, agent: other)
            secondary.prompt = "secondary"
            manager.handleMessage(secondary)
            XCTAssertEqual(manager.sessions.count, 2)
            XCTAssertEqual(manager.sessions.first?.prompt, "primary")
            var status = message(.statusUpdate, agent: family)
            status.status = "primary response"
            manager.handleMessage(status)
            XCTAssertEqual(manager.sessions.first?.statusText, "primary response")
            XCTAssertEqual(manager.sessions.last?.statusText, "")
        }
    }

    func testAmbiguousFamilySuffixDoesNotAbsorbClaude() {
        let manager = SessionManager()
        manager.handleMessage(message(.sessionStart, agent: .cursor))
        manager.handleMessage(message(.sessionStart, agent: .windsurf))
        var claude = message(.statusUpdate, agent: .claudeCode)
        claude.status = "standalone"
        manager.handleMessage(claude)
        XCTAssertEqual(manager.sessions.count, 3)
        XCTAssertEqual(manager.sessions.first(where: { $0.id == claude.sessionId })?.agentType, .claudeCode)
        XCTAssertEqual(manager.sessions.filter { $0.statusText.isEmpty }.count, 2)
    }

    func testClaudeFirstKeepsBoundFamilyForSubsequentClaudeEvents() throws {
        for family in [AgentType.cursor, .trae, .windsurf] {
            let manager = SessionManager()
            manager.handleMessage(message(.sessionStart, agent: .claudeCode))
            var native = message(.sessionStart, agent: family)
            native.prompt = "native prompt"
            manager.handleMessage(native)
            let session = try XCTUnwrap(manager.sessions.first)
            XCTAssertEqual(session.agentType, family)
            var claudeStart = message(.sessionStart, agent: .claudeCode)
            claudeStart.prompt = "duplicate prompt"
            manager.handleMessage(claudeStart)
            XCTAssertEqual(session.prompt, "native prompt")
            var status = message(.statusUpdate, agent: .claudeCode)
            status.status = "Working"
            manager.handleMessage(status)
            XCTAssertEqual(session.statusText, "Working")
            manager.handlePermissionRequest(message(.permissionRequest, agent: .claudeCode), respond: { _ in })
            let request = try XCTUnwrap(session.pendingPermission)
            XCTAssertEqual(request.requestingAgent, family)
            var end = message(.sessionEnd, agent: .claudeCode)
            end.observedState = "completed"
            manager.handleMessage(end)
            XCTAssertEqual(session.pendingPermission?.id, request.id)
            XCTAssertEqual(session.status, .waitingPermission)
            XCTAssertEqual(manager.sessions.count, 1)
        }
    }

    func testUnknownPrefixAndConflictingAgentCannotBecomeCursorMirror() {
        for (id, agent) in [("unknown-shared", nil), ("roo_code-shared", nil),
                            ("roo_code-shared", "claude_code"), ("claude_code-shared", "pearai"),
                            ("claude_code-shared", "unknown-agent")] as [(String, String?)] {
            let manager = SessionManager()
            manager.handleMessage(message(.sessionStart, agent: .cursor))
            var status = DIMessage(type: .statusUpdate, sessionId: id)
            status.agentType = agent
            status.status = "separate"
            manager.handleMessage(status)
            XCTAssertEqual(manager.sessions.count, 2, "\(id), \(agent ?? "nil")")
            XCTAssertEqual(manager.sessions.first?.statusText, "")
            XCTAssertNotEqual(manager.sessions.last?.agentType, .cursor)
        }
    }

    func testCanonicalClaudePrefixWithoutAgentStillMirrorsSingleFamily() {
        let manager = SessionManager()
        manager.handleMessage(message(.sessionStart, agent: .trae))
        var status = message(.statusUpdate, agent: .claudeCode)
        status.agentType = nil
        status.status = "Working"
        manager.handleMessage(status)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.sessions.first?.statusText, "Working")
    }

    func testExactCompletedSessionWinsOverOtherSourcesSharedSuffix() throws {
        let manager = SessionManager()
        let completed = AgentSession(id: "pearai-shared", agentType: .pearai)
        completed.status = .completed
        let cursor = AgentSession(id: "cursor-shared", agentType: .cursor)
        manager.sessions = [completed, cursor]
        var status = message(.statusUpdate, agent: .pearai)
        status.status = "late response"
        manager.handleMessage(status)
        XCTAssertEqual(completed.statusText, "late response")
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(cursor.statusText, "")
        var question = message(.question, agent: .pearai)
        question.questionText = "Continue?"
        question.options = ["Yes"]
        addRequest(question, manager: manager)
        XCTAssertNotNil(completed.pendingQuestion)
        XCTAssertNil(cursor.pendingQuestion)
        XCTAssertEqual(manager.sessions.count, 2)
    }

    private func addRequest(_ request: DIMessage, manager: SessionManager) {
        switch request.type {
        case .permissionRequest: manager.handlePermissionRequest(request, respond: { _ in })
        case .question: manager.handleQuestionRequest(request, respond: { _ in })
        case .planReview: manager.handlePlanReview(request, respond: { _, _ in })
        default: XCTFail("Unexpected request type")
        }
    }
}
