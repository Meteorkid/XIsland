import XCTest
import DIShared
@testable import XIsland

@MainActor
final class SessionManagerStatusTests: XCTestCase {
    func testCodexStatusUpdateDoesNotCompleteSessionWithoutSessionEnd() {
        let manager = SessionManager()

        var start = DIMessage(type: .sessionStart, sessionId: "codex-session")
        start.agentType = AgentType.codex.rawValue
        start.prompt = "Fix the bug"
        manager.handleMessage(start)

        guard let session = manager.sessions.first(where: { $0.id == "codex-session" }) else {
            XCTFail("Expected session to be created")
            return
        }

        var doneLikeStatus = DIMessage(type: .statusUpdate, sessionId: "codex-session")
        doneLikeStatus.agentType = AgentType.codex.rawValue
        doneLikeStatus.status = "Done"
        manager.handleMessage(doneLikeStatus)

        XCTAssertEqual(session.status, .active)
        XCTAssertTrue(manager.activeSessions.contains(where: { $0.id == session.id }))

        var followupThinking = DIMessage(type: .progress, sessionId: "codex-session")
        followupThinking.agentType = AgentType.codex.rawValue
        followupThinking.status = "Thinking about additional improvements"
        manager.handleMessage(followupThinking)

        XCTAssertEqual(session.status, .active)
        XCTAssertEqual(session.statusText, "Thinking about additional improvements")
    }

    func testToolStartClearsPendingPermissionInteraction() {
        let manager = SessionManager()

        var start = DIMessage(type: .sessionStart, sessionId: "claude-perm")
        start.agentType = AgentType.claudeCode.rawValue
        manager.handleMessage(start)

        var permission = DIMessage(type: .permissionRequest, sessionId: "claude-perm")
        permission.agentType = AgentType.claudeCode.rawValue
        permission.tool = "Bash"
        permission.permDescription = "Run shell command"
        manager.handlePermissionRequest(permission, respond: { _ in })

        guard let session = manager.sessions.first(where: { $0.id == "claude-perm" }) else {
            XCTFail("Expected session to be created")
            return
        }
        XCTAssertEqual(session.status, .waitingPermission)
        XCTAssertNotNil(session.pendingPermission)

        var toolStart = DIMessage(type: .toolStart, sessionId: "claude-perm")
        toolStart.agentType = AgentType.claudeCode.rawValue
        toolStart.tool = "Bash"
        manager.handleMessage(toolStart)

        XCTAssertEqual(session.status, .active)
        XCTAssertNil(session.pendingPermission)
        XCTAssertEqual(session.currentTool, "Bash")
    }

    func testToolStartClearsPendingQuestionInteraction() {
        let manager = SessionManager()

        var start = DIMessage(type: .sessionStart, sessionId: "claude-question")
        start.agentType = AgentType.claudeCode.rawValue
        manager.handleMessage(start)

        var question = DIMessage(type: .question, sessionId: "claude-question")
        question.agentType = AgentType.claudeCode.rawValue
        question.questionText = "Continue?"
        question.options = ["yes", "no"]
        manager.handleQuestionRequest(question, respond: { _ in })

        guard let session = manager.sessions.first(where: { $0.id == "claude-question" }) else {
            XCTFail("Expected session to be created")
            return
        }
        XCTAssertEqual(session.status, .waitingAnswer)
        XCTAssertNotNil(session.pendingQuestion)

        var toolStart = DIMessage(type: .toolStart, sessionId: "claude-question")
        toolStart.agentType = AgentType.claudeCode.rawValue
        toolStart.tool = "Read"
        manager.handleMessage(toolStart)

        XCTAssertEqual(session.status, .active)
        XCTAssertNil(session.pendingQuestion)
        XCTAssertEqual(session.currentTool, "Read")
    }

    func testIgnoresMirroredClaudeSessionForCursorConversation() {
        let manager = SessionManager()

        var cursorStart = DIMessage(type: .sessionStart, sessionId: "cursor-shared-conversation")
        cursorStart.agentType = AgentType.cursor.rawValue
        cursorStart.prompt = "hello"
        manager.handleMessage(cursorStart)

        var mirroredClaudeStart = DIMessage(type: .sessionStart, sessionId: "claude_code-shared-conversation")
        mirroredClaudeStart.agentType = AgentType.claudeCode.rawValue
        manager.handleMessage(mirroredClaudeStart)

        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.sessions.first?.agentType, .cursor)

        var mirroredClaudeEnd = DIMessage(type: .sessionEnd, sessionId: "claude_code-shared-conversation")
        mirroredClaudeEnd.agentType = AgentType.claudeCode.rawValue
        manager.handleMessage(mirroredClaudeEnd)

        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.sessions.first?.status, .active)
    }

    func testInfersCursorFromSessionIdWhenAgentTypeMissing() {
        let manager = SessionManager()

        var start = DIMessage(type: .sessionStart, sessionId: "cursor-shared-conversation")
        start.agentType = nil
        manager.handleMessage(start)

        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.sessions.first?.agentType, .cursor)
    }

    func testMapsTraeAliasToTraeAgent() {
        let manager = SessionManager()

        var start = DIMessage(type: .sessionStart, sessionId: "trae-123")
        start.agentType = "trae"
        manager.handleMessage(start)

        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.sessions.first?.agentType, .trae)
    }

    func testInfersTraeFromTerminalWhenAgentTypeMissing() {
        let manager = SessionManager()

        var start = DIMessage(type: .sessionStart, sessionId: "session-123")
        start.agentType = nil
        start.terminal = "Trae CN"
        manager.handleMessage(start)

        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.sessions.first?.agentType, .trae)
    }

    func testOpenCodePlaceholderPermissionIsAutoApprovedAndNotShown() {
        let manager = SessionManager()

        var start = DIMessage(type: .sessionStart, sessionId: "opencode-s1")
        start.agentType = AgentType.openCode.rawValue
        manager.handleMessage(start)

        var permission = DIMessage(type: .permissionRequest, sessionId: "opencode-s1")
        permission.agentType = AgentType.openCode.rawValue
        permission.tool = "unknown"
        permission.permDescription = ""
        permission.filePath = ""

        var approved: Bool?
        manager.handlePermissionRequest(permission, respond: { value in
            approved = value
        })

        let session = manager.sessions.first(where: { $0.id == "opencode-s1" })
        XCTAssertEqual(approved, true)
        XCTAssertEqual(session?.status, .active)
        XCTAssertNil(session?.pendingPermission)
    }

    func testOpenCodeExternalDirectoryPermissionIsAutoApprovedAndNotShown() {
        let manager = SessionManager()

        var start = DIMessage(type: .sessionStart, sessionId: "opencode-s2")
        start.agentType = AgentType.openCode.rawValue
        manager.handleMessage(start)

        var permission = DIMessage(type: .permissionRequest, sessionId: "opencode-s2")
        permission.agentType = AgentType.openCode.rawValue
        permission.tool = "External_directory"
        permission.permDescription = "External_directory: /tmp/*"
        permission.filePath = "/tmp/*"

        var approved: Bool?
        manager.handlePermissionRequest(permission, respond: { value in
            approved = value
        })

        let session = manager.sessions.first(where: { $0.id == "opencode-s2" })
        XCTAssertEqual(approved, true)
        XCTAssertEqual(session?.status, .active)
        XCTAssertNil(session?.pendingPermission)
    }

    func testMirroredClaudeStatusUsesExistingCursorSession() {
        let manager = SessionManager()

        var cursorStart = DIMessage(type: .sessionStart, sessionId: "cursor-shared-conversation")
        cursorStart.agentType = AgentType.cursor.rawValue
        manager.handleMessage(cursorStart)

        var mirroredStatus = DIMessage(type: .statusUpdate, sessionId: "claude_code-shared-conversation")
        mirroredStatus.agentType = AgentType.claudeCode.rawValue
        mirroredStatus.status = "Working via subagent"
        manager.handleMessage(mirroredStatus)

        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.sessions.first?.agentType, .cursor)
        XCTAssertEqual(manager.sessions.first?.statusText, "Working via subagent")
    }

    func testDiagnosticsIslandStatePrefersWaitingInteractionOverSelectedActiveSession() {
        let manager = SessionManager()

        let selected = AgentSession(id: "selected-active", agentType: .claudeCode, workingDirectory: "/tmp/selected")
        selected.status = .active

        let waiting = AgentSession(id: "waiting-plan", agentType: .codex, workingDirectory: "/tmp/waiting")
        waiting.status = .waitingPlanReview
        waiting.pendingPlanReview = PendingPlanReview(
            requestingAgent: .codex,
            markdown: "## Plan",
            respond: { _, _ in }
        )

        manager.sessions = [selected, waiting]
        manager.selectedSessionId = selected.id

        XCTAssertEqual(manager.diagnosticsIslandState, "planReview")
    }

    func testDiagnosticsIslandStateReportsCollapsedForVisibleNonInteractiveSessionsUntilViewExpands() {
        let manager = SessionManager()

        let session = AgentSession(id: "active", agentType: .claudeCode, workingDirectory: "/tmp/selected")
        session.status = .active

        manager.sessions = [session]
        manager.selectedSessionId = session.id

        XCTAssertEqual(manager.diagnosticsIslandState, "collapsed")
    }
}
