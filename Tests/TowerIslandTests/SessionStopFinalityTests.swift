import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

@MainActor
final class SessionStopFinalityTests: XCTestCase {
    private func event(_ name: String, fields: [String: Any] = [:]) throws -> DIMessage {
        var payload: [String: Any] = ["hook_event_name": name, "session_id": "pending", "cwd": "/tmp/project"]
        payload.merge(fields) { _, new in new }
        return try DIBridge.makeMessage(agentType: "codex", hookType: name,
                                       sessionId: "codex-pending", stdinData: payload)
    }

    func testStopLeavesRunningCountsWithoutDeclaringCompletionOrTimingOutAsSuccess() throws {
        let manager = SessionManager()
        manager.handleMessage(try event("SessionStart"))
        let session = try XCTUnwrap(manager.sessions.first)
        session.currentTool = "Bash"
        session.events = [ToolEvent(tool: "Bash", toolCallId: "old-call")]
        manager.handleMessage(try event("Stop", fields: ["last_assistant_message": "Review ready"]))

        XCTAssertEqual(session.status, .completionUnconfirmed)
        XCTAssertEqual(session.agentResponse, "Review ready")
        XCTAssertEqual(session.lastActivity, L10n.completionUnconfirmed)
        XCTAssertNil(session.currentTool)
        XCTAssertTrue(manager.trulyActiveSessions.isEmpty)
        XCTAssertFalse(manager.hasInteraction)
        let project = try XCTUnwrap(AgentFlowAggregator.group(sessions: manager.sessions).first)
        XCTAssertEqual(project.activeCount, 0)
        XCTAssertEqual(project.completedCount, 0)
        XCTAssertEqual(project.blockedCount, 0)
        XCTAssertEqual(project.unconfirmedCount, 1)

        session.lastActivityTime = Date().addingTimeInterval(-600)
        manager.cleanupStaleSessions()
        XCTAssertEqual(session.status, .completionUnconfirmed)
        XCTAssertNil(session.completedAt)
    }

    func testFreshToolOrPromptRestoresRunningAndLateStopCannotReopenClosedSession() throws {
        let manager = SessionManager()
        manager.handleMessage(try event("SessionStart"))
        let session = try XCTUnwrap(manager.sessions.first)
        let stop = try event("Stop", fields: ["last_assistant_message": "Preview"])
        manager.handleMessage(stop)
        manager.handleMessage(try event("PreToolUse", fields: ["tool_name": "Read", "tool_use_id": "fresh", "tool_input": [:]]))
        XCTAssertEqual(session.status, .active)
        manager.handleMessage(stop)
        manager.handleMessage(try event("UserPromptSubmit", fields: ["prompt": "Continue review"]))
        XCTAssertEqual(session.status, .active)
        manager.handleMessage(try event("SessionEnd"))
        let ended = try XCTUnwrap(session.completedAt)
        manager.handleMessage(stop)
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(session.completedAt, ended)
    }

    func testMainStopDoesNotHideAChildThatStillReportsRunning() throws {
        let manager = SessionManager()
        manager.handleMessage(try event("SessionStart"))
        manager.handleMessage(try event("SubagentStart", fields: ["agent_id": "background", "agent_type": "reviewer"]))
        manager.handleMessage(try event("Stop"))
        XCTAssertEqual(manager.trulyActiveSessions.count, 1)
        let running = try XCTUnwrap(AgentFlowAggregator.group(sessions: manager.sessions).first)
        XCTAssertEqual(running.activeCount, 1)
        XCTAssertEqual(running.unconfirmedCount, 0)
        manager.handleMessage(try event("SubagentStop", fields: ["agent_id": "background", "agent_type": "reviewer"]))
        XCTAssertTrue(manager.trulyActiveSessions.isEmpty)
        let pending = try XCTUnwrap(AgentFlowAggregator.group(sessions: manager.sessions).first)
        XCTAssertEqual(pending.activeCount, 0)
        XCTAssertEqual(pending.unconfirmedCount, 1)
        XCTAssertEqual(pending.completedCount, 0)
    }

    func testStopPreservesPendingPermissionAndKnownError() throws {
        let manager = SessionManager()
        manager.handleMessage(try event("SessionStart"))
        let session = try XCTUnwrap(manager.sessions.first)
        var permission = DIMessage(type: .permissionRequest, sessionId: session.id)
        permission.agentType = "codex"
        permission.tool = "Bash"
        permission.permDescription = "Review command"
        var answered = false
        manager.handlePermissionRequest(permission) { _ in answered = true }
        let waitingText = session.statusText
        manager.handleMessage(try event("Stop", fields: ["last_assistant_message": "Still waiting"]))
        XCTAssertEqual(session.status, .waitingPermission)
        XCTAssertNotNil(session.pendingPermission)
        XCTAssertFalse(answered)
        XCTAssertEqual(session.statusText, waitingText)

        let errorManager = SessionManager()
        errorManager.handleMessage(try event("SessionStart"))
        let failed = try XCTUnwrap(errorManager.sessions.first)
        failed.status = .error
        failed.statusText = "Original failure details"
        errorManager.handleMessage(try event("Stop"))
        XCTAssertEqual(failed.status, .error)
        XCTAssertEqual(failed.statusText, "Original failure details")
    }

    func testNoninteractiveWaitingAndEndedObservationsKeepTheirStateAndExplanation() throws {
        for status in [SessionStatus.waitingPermission, .waitingAnswer, .waitingPlanReview, .observationUnavailable, .completed] {
            let manager = SessionManager()
            manager.handleMessage(try event("SessionStart"))
            let session = try XCTUnwrap(manager.sessions.first)
            session.status = status
            session.statusText = "Original observation"
            XCTAssertFalse(session.hasPendingInteraction)
            for reply in ["", "Late reply preview"] {
                manager.handleMessage(try event("Stop", fields: ["last_assistant_message": reply]))
                XCTAssertEqual(session.status, status)
                XCTAssertEqual(session.statusText, "Original observation")
            }
        }
    }

    func testUnconfirmedStatusSurvivesHistorySaveAndReopen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-turn-finality-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent("history.store")
        try autoreleasepool {
            let persistence = SessionPersistenceManager()
            XCTAssertTrue(persistence.setupContainer(storeURL: store))
            let manager = SessionManager()
            manager.persistenceManager = persistence
            manager.handleMessage(try event("SessionStart"))
            manager.handleMessage(try event("Stop", fields: ["last_assistant_message": "Reply preview"]))
            XCTAssertEqual(persistence.fetchHistory().count, 1)
        }
        try autoreleasepool {
            let persistence = SessionPersistenceManager()
            XCTAssertTrue(persistence.setupContainer(storeURL: store))
            let saved = try XCTUnwrap(persistence.fetchHistory().first)
            XCTAssertEqual(saved.status, .completionUnconfirmed)
            XCTAssertNil(saved.completedAt)
            XCTAssertEqual(saved.chatMessages.last?.content, "Reply preview")
        }
    }

    func testUndocumentedGeminiAndTabnineIdleNoticesDoNotCreateFinalState() throws {
        for agent in ["gemini_cli", "tabnine"] {
            let message = try DIBridge.makeMessage(agentType: agent, hookType: "Notification", sessionId: "\(agent)-runtime",
                stdinData: ["session_id": "runtime", "hook_event_name": "Notification", "notification_type": "idle_prompt", "message": "unknown type"])
            XCTAssertNil(message.observedState)
            XCTAssertEqual(message.statusIsAssistantReply, false)
        }
    }

    func testKnownFinalCompletionUpdatesThePersistedPendingCheckpoint() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-final-idle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(storeURL: folder.appendingPathComponent("history.store")))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        func workbuddy(_ name: String, fields: [String: Any]) throws -> DIMessage {
            var payload: [String: Any] = ["session_id": "history", "hook_event_name": name, "cwd": "/tmp/project"]
            payload.merge(fields) { _, new in new }
            return try WorkBuddyHookAdapter.normalize(hookType: name, stdinData: payload)
        }
        manager.handleMessage(try workbuddy("UserPromptSubmit", fields: ["prompt": "Review"]))
        manager.handleMessage(try workbuddy("Stop", fields: ["last_assistant_message": "Reply preview"]))
        XCTAssertEqual(persistence.fetchHistory().first?.status, .completionUnconfirmed)
        manager.handleMessage(try workbuddy("FinalStop", fields: ["final_stop_reason": "completed"]))
        XCTAssertEqual(manager.sessions.first?.status, .completed)
        XCTAssertEqual(persistence.fetchHistory().first?.status, .completed)
        XCTAssertNotNil(persistence.fetchHistory().first?.completedAt)
        XCTAssertEqual(persistence.fetchHistory().first?.completionNeedsReview, true)
    }

    func testUncorrelatedChildNoticesDoNotReplaceImportantParentExplanations() throws {
        let common: [String: Any] = ["session_id": "notice", "hook_event_name": "SubagentStop", "cwd": "/tmp/project"]
        let notices = [
            try CodeBuddyHookAdapter.normalize(hookType: "SubagentStop", sessionId: "code_buddy-notice", stdinData: common),
            try KimiHookAdapter.normalize(hookType: "SubagentStop", stdinData: common.merging([
                "agent_name": "reviewer", "response": "Child result",
            ]) { _, new in new }),
            try WorkBuddyHookAdapter.normalize(hookType: "SubagentStop", stdinData: common.merging([
                "agent_id": "child", "agent_type": "reviewer",
            ]) { _, new in new }),
        ]
        for notice in notices {
            let manager = SessionManager()
            let session = AgentSession(id: notice.sessionId, agentType: try XCTUnwrap(AgentType(rawValue: notice.agentType ?? "")))
            manager.sessions = [session]
            for state in [SessionStatus.waitingPermission, .error, .observationUnavailable, .completed] {
                session.status = state
                session.statusText = "Original explanation"
                manager.handleMessage(notice)
                XCTAssertEqual(session.status, state)
                XCTAssertEqual(session.statusText, "Original explanation")
            }
            session.status = .active
            manager.handleMessage(notice)
            XCTAssertEqual(session.statusText, try XCTUnwrap(notice.status))
        }
    }
}
