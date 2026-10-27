import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

@MainActor
final class WorkBuddySessionTests: XCTestCase {
    private func manager(remindersEnabled: Bool = true) -> SessionManager {
        XCTAssertTrue(AppPreferences.isIsolated)
        let defaults = AppPreferences.defaults
        let settings: [(String, Bool)] = [(TaskAttentionSettings.enabledKey, remindersEnabled),
                                        ("autoConfigure.workbuddy", true)]
        let previous = settings.map { ($0.0, defaults.object(forKey: $0.0)) }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        addTeardownBlock {
            for (key, value) in previous {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        return SessionManager()
    }

    private func message(_ event: String, fields: [String: Any] = [:]) throws -> DIMessage {
        var input: [String: Any] = ["hook_event_name": event, "session_id": "parent", "cwd": "/tmp/project"]
        input.merge(fields) { _, value in value }
        return try WorkBuddyHookAdapter.normalize(hookType: event, stdinData: input)
    }

    func testSuccessfulFinalStopCreatesOneCurrentCompletionReminder() throws {
        let manager = manager()
        var reminders: [TaskAttentionEvent] = []
        manager.onTaskAttention = { reminders.append($0) }
        manager.handleMessage(try message("UserPromptSubmit", fields: ["prompt": "reminder fixture"]))
        manager.handleMessage(try message("Stop", fields: ["last_assistant_message": "验收完成"]))
        XCTAssertTrue(reminders.isEmpty)
        manager.handleMessage(try message("FinalStop", fields: ["final_stop_reason": "completed"]))

        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.status, .completed)
        XCTAssertTrue(session.completionNeedsReview)
        XCTAssertNotNil(session.completedAt)
        XCTAssertEqual(session.agentResponse, "验收完成")
        XCTAssertEqual(session.chatHistory.filter { $0.role == .assistant }.map(\.content), ["验收完成"])
        XCTAssertEqual(reminders.count, 1)
        let reminder = try XCTUnwrap(reminders.first)
        XCTAssertEqual(reminder.kind, .completion)
        XCTAssertEqual(reminder.sessionID, session.id)
        XCTAssertTrue(manager.isCurrentTaskAttention(reminder))

        manager.handleMessage(try message("FinalStop", fields: ["final_stop_reason": "completed"]))
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(session.completedAt, reminder.completedAt)
        manager.markCompletionReviewed(sessionID: session.id)
        XCTAssertFalse(manager.isCurrentTaskAttention(reminder))
        manager.handleMessage(try message("FinalStop", fields: ["final_stop_reason": "completed"]))
        XCTAssertFalse(session.completionNeedsReview)
        XCTAssertEqual(reminders.count, 1)
    }

    func testOnlyFinalStopChangesParentActivity() throws {
        let manager = manager()
        manager.handleMessage(try message("UserPromptSubmit", fields: ["prompt": "fixture"]))
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.agentType, .workBuddy)
        manager.handleMessage(try message("Stop", fields: ["last_assistant_message": "intermediate reply"]))
        XCTAssertEqual(session.status, .completionUnconfirmed)
        XCTAssertEqual(session.agentResponse, "intermediate reply")
        manager.handleMessage(try message("SubagentStop", fields: ["agent_id": "child"]))
        manager.handleMessage(try message("SessionEnd", fields: ["reason": "other"]))
        XCTAssertEqual(session.status, .completionUnconfirmed)
        manager.handleMessage(try message("FinalStop", fields: ["final_stop_reason": "completed"]))
        XCTAssertEqual(session.status, .completed)
    }

    func testNonSuccessStopsAndChildNotificationsDoNotCreateCompletion() throws {
        for reason in ["cancelled", "interrupted", "failed", "future-value"] {
            let manager = manager()
            var reminders: [TaskAttentionEvent] = []
            manager.onTaskAttention = { reminders.append($0) }
            manager.handleMessage(try message("UserPromptSubmit", fields: ["prompt": "fixture"]))
            manager.handleMessage(try message("Stop", fields: ["last_assistant_message": "partial reply"]))
            manager.handleMessage(try message("SubagentStart", fields: ["agent_id": "child"]))
            manager.handleMessage(try message("SubagentStop", fields: ["agent_id": "child"]))
            manager.handleMessage(try message("SessionEnd", fields: ["reason": "other"]))
            XCTAssertEqual(manager.sessions.first?.status, .completionUnconfirmed)
            manager.handleMessage(try message("FinalStop", fields: ["final_stop_reason": reason]))
            let session = try XCTUnwrap(manager.sessions.first)
            XCTAssertEqual(session.status, reason == "failed" ? .error
                : reason == "future-value" ? .completionUnconfirmed : .idle)
            XCTAssertNil(session.completedAt)
            XCTAssertFalse(session.completionNeedsReview)
            XCTAssertTrue(reminders.isEmpty, reason)
        }
    }

    func testNewPromptResumesSameConversationAndProducesNewCompletion() throws {
        let manager = manager()
        var reminders: [TaskAttentionEvent] = []
        manager.onTaskAttention = { reminders.append($0) }
        manager.handleMessage(try message("UserPromptSubmit", fields: ["prompt": "first turn"]))
        let completed = try message("FinalStop", fields: ["final_stop_reason": "completed"])
        manager.handleMessage(completed)
        let session = try XCTUnwrap(manager.sessions.first)
        let first = try XCTUnwrap(reminders.first)
        manager.handleMessage(try message("UserPromptSubmit", fields: ["prompt": "second turn"]))
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertTrue(manager.sessions.first === session)
        XCTAssertEqual(session.status, .active)
        XCTAssertNil(session.completedAt)
        XCTAssertFalse(session.completionNeedsReview)
        XCTAssertFalse(manager.isCurrentTaskAttention(first))
        var replay = completed
        replay.nativeMessageReplay = true
        manager.handleMessage(replay)
        XCTAssertEqual(session.status, .active)
        XCTAssertEqual(reminders.count, 1)
        manager.handleMessage(completed)
        XCTAssertEqual(reminders.count, 2)
        XCTAssertTrue(manager.isCurrentTaskAttention(try XCTUnwrap(reminders.last)))
        XCTAssertEqual(session.chatHistory.filter { $0.role == .user }.map(\.content), ["first turn", "second turn"])
    }

    func testDisabledRemindersKeepCompletionAvailableForReview() throws {
        let manager = manager(remindersEnabled: false)
        manager.onTaskAttention = { _ in XCTFail("关闭提醒时不能请求切回") }
        manager.handleMessage(try message("UserPromptSubmit", fields: ["prompt": "fixture"]))
        manager.handleMessage(try message("FinalStop", fields: ["final_stop_reason": "completed"]))
        XCTAssertEqual(manager.sessions.first?.status, .completed)
        XCTAssertEqual(manager.sessions.first?.completionNeedsReview, true)
    }

    func testCompletionSurvivesReopenAndArchivedDuplicateDoesNotRemind() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xi-workbuddy-completion-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent("history.store")
        let persistence = SessionPersistenceManager(usesBackgroundWrites: true)
        XCTAssertTrue(persistence.setupContainer(storeURL: store))
        let manager = manager()
        manager.persistenceManager = persistence
        var reminders: [TaskAttentionEvent] = []
        manager.onTaskAttention = { reminders.append($0) }
        manager.handleMessage(try message("UserPromptSubmit", fields: ["prompt": "fixture"]))
        manager.handleMessage(try message("Stop", fields: ["last_assistant_message": "saved reply"]))
        let completed = try message("FinalStop", fields: ["final_stop_reason": "completed"])
        manager.handleMessage(completed)
        let saved = await manager.drainPersistenceOperations()
        XCTAssertTrue(saved)
        let session = try XCTUnwrap(manager.sessions.first)
        let reopened = SessionPersistenceManager()
        XCTAssertTrue(reopened.setupContainer(storeURL: store))
        let restored = try XCTUnwrap(reopened.restoreSession(sessionId: session.id))
        XCTAssertEqual(restored.status, .completed)
        XCTAssertEqual(restored.completedAt, session.completedAt)
        XCTAssertTrue(restored.completionNeedsReview)
        XCTAssertEqual(restored.agentResponse, "saved reply")
        manager.markCompletionReviewed(sessionID: session.id)
        let reviewed = await manager.drainPersistenceOperations()
        XCTAssertTrue(reviewed)
        manager.dismissSession(session)
        let dismissed = await manager.drainPersistenceOperations()
        XCTAssertTrue(dismissed)
        manager.handleMessage(completed)
        let duplicateSaved = await manager.drainPersistenceOperations()
        XCTAssertTrue(duplicateSaved)
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertEqual(reminders.count, 1)
        let reviewedStore = SessionPersistenceManager()
        XCTAssertTrue(reviewedStore.setupContainer(storeURL: store))
        XCTAssertFalse(try XCTUnwrap(reviewedStore.restoreSession(sessionId: session.id)).completionNeedsReview)
    }

    func testOrphanFinalStopDoesNotInventAnEmptySession() throws {
        let manager = manager()
        manager.onTaskAttention = { _ in XCTFail("没有已知会话时不能制造完成提醒") }
        manager.handleMessage(try message("FinalStop", fields: ["final_stop_reason": "completed"]))
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    func testReceptionSwitchUsesIsolatedPreferences() throws {
        let key = "autoConfigure.workbuddy", defaults = AppPreferences.defaults
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let manager = SessionManager()
        defaults.set(false, forKey: key)
        manager.handleMessage(try message("SessionStart"))
        XCTAssertTrue(manager.sessions.isEmpty)
        defaults.set(true, forKey: key)
        manager.handleMessage(try message("SessionStart"))
        XCTAssertEqual(manager.sessions.count, 1)
    }
}
