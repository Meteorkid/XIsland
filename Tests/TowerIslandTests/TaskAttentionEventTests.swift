import DIShared
import XCTest
@testable import XIsland

@MainActor
final class TaskAttentionEventTests: XCTestCase {
    private func manager(enabled: Bool = true) -> SessionManager {
        let oldSetting = AppPreferences.defaults.object(forKey: TaskAttentionSettings.enabledKey)
        let oldBypass = AppPreferences.defaults.object(forKey: "bypassMode")
        AppPreferences.defaults.set(enabled, forKey: TaskAttentionSettings.enabledKey)
        AppPreferences.defaults.set(false, forKey: "bypassMode")
        addTeardownBlock {
            for (key, old) in [(TaskAttentionSettings.enabledKey, oldSetting), ("bypassMode", oldBypass)] {
                if let old { AppPreferences.defaults.set(old, forKey: key) }
                else { AppPreferences.defaults.removeObject(forKey: key) }
            }
        }
        return SessionManager()
    }

    private func message(_ type: DIMessageType, id: String = "attention-session") -> DIMessage {
        var message = DIMessage(type: type, sessionId: id)
        message.agentType = AgentType.codex.rawValue
        message.statusIsAssistantReply = false
        if type == .sessionEnd { message.observedState = "completed" }
        return message
    }

    private func request(_ kind: TaskAttentionEvent.Kind, nativeID: String? = "native-one") -> DIMessage {
        let type: DIMessageType = kind == .permission ? .permissionRequest : kind == .question ? .question : .planReview
        var result = message(type)
        result.nativeRequestId = nativeID
        result.tool = "Read"
        result.permDescription = "Inspect a file"
        result.questionText = "Choose an option"
        result.options = ["Continue", "Stop"]
        result.planMarkdown = "Proposed plan"
        return result
    }

    private func send(_ value: DIMessage, kind: TaskAttentionEvent.Kind, manager: SessionManager) {
        switch kind {
        case .permission: manager.handlePermissionRequest(value, respond: { _ in })
        case .question: manager.handleQuestionRequest(value, respond: { _ in })
        case .planReview: manager.handlePlanReview(value, respond: { _, _ in })
        case .completion: manager.handleMessage(value)
        }
    }

    func testDefaultEnabledAndPersistedOptOut() throws {
        let suite = "dev.xisland.tests.attention-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(TaskAttentionSettings.isEnabled(defaults: defaults))
        defaults.set(false, forKey: TaskAttentionSettings.enabledKey)
        XCTAssertFalse(TaskAttentionSettings.isEnabled(defaults: defaults))
        defaults.set(true, forKey: TaskAttentionSettings.enabledKey)
        XCTAssertTrue(TaskAttentionSettings.isEnabled(defaults: defaults))
    }

    func testCompletionOnlyOnceAndReviewInvalidatesQueuedReminder() throws {
        let manager = manager()
        var events: [TaskAttentionEvent] = []
        manager.onTaskAttention = { events.append($0) }
        manager.handleMessage(message(.sessionStart))
        manager.handleMessage(message(.sessionEnd))
        manager.handleMessage(message(.sessionEnd))
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.kind, .completion)
        XCTAssertTrue(manager.isCurrentTaskAttention(event))
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(event.completedAt, session.completedAt)
        XCTAssertTrue(session.completionNeedsReview)
        manager.markCompletionReviewed(sessionID: session.id)
        XCTAssertFalse(manager.isCurrentTaskAttention(event))
        manager.handleMessage(message(.sessionEnd))
        XCTAssertEqual(events.count, 1)
    }

    func testNewRunProducesNewCompletionAndInvalidatesOldGeneration() throws {
        let manager = manager()
        var events: [TaskAttentionEvent] = []
        manager.onTaskAttention = { events.append($0) }
        for _ in 0..<2 {
            manager.handleMessage(message(.sessionStart))
            manager.handleMessage(message(.sessionEnd))
        }
        XCTAssertEqual(events.count, 2)
        let old = try XCTUnwrap(events.first), latest = try XCTUnwrap(events.last)
        XCTAssertNotEqual(old.id, latest.id)
        XCTAssertFalse(manager.isCurrentTaskAttention(old))
        XCTAssertTrue(manager.isCurrentTaskAttention(latest))
    }

    func testDisabledRemindersDoNotAcknowledgeOrAnswerRequests() throws {
        let manager = manager(enabled: false)
        var events: [TaskAttentionEvent] = []
        manager.onTaskAttention = { events.append($0) }
        manager.handleMessage(message(.sessionStart))
        manager.handleMessage(message(.sessionEnd))
        XCTAssertTrue(try XCTUnwrap(manager.sessions.first).completionNeedsReview)
        for kind in [TaskAttentionEvent.Kind.permission, .question, .planReview] {
            send(request(kind), kind: kind, manager: manager)
        }
        XCTAssertTrue(manager.hasInteraction)
        XCTAssertTrue(events.isEmpty)
        AppPreferences.defaults.set(true, forKey: TaskAttentionSettings.enabledKey)
        XCTAssertTrue(events.isEmpty)
    }

    func testReplayAndUnconfirmedStatesDoNotCreateCompletionReminder() {
        let manager = manager()
        var events: [TaskAttentionEvent] = []
        manager.onTaskAttention = { events.append($0) }
        manager.handleMessage(message(.sessionStart))
        for state in ["idle", "completionUnconfirmed", "observationUnavailable"] {
            var status = message(.statusUpdate)
            status.observedState = state
            manager.handleMessage(status)
        }
        var replay = message(.sessionEnd)
        replay.nativeMessageReplay = true
        manager.handleMessage(replay)
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(manager.sessions.first?.completionNeedsReview ?? true)
    }

    func testRestoredCompletedSessionAndDuplicateEndDoNotNotify() {
        let manager = manager()
        let restored = AgentSession(id: "attention-session", agentType: .codex)
        restored.status = .completed
        restored.completedAt = Date(timeIntervalSince1970: 123)
        restored.completionNeedsReview = true
        manager.sessions = [restored]
        var events: [TaskAttentionEvent] = []
        manager.onTaskAttention = { events.append($0) }
        manager.handleMessage(message(.sessionEnd))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(restored.completionNeedsReview)
    }

    func testNativeDuplicatesKeepQueuedReminderValidButRevisedRequestNotifies() throws {
        for kind in [TaskAttentionEvent.Kind.permission, .question, .planReview] {
            let manager = manager()
            var events: [TaskAttentionEvent] = []
            manager.onTaskAttention = { events.append($0) }
            var value = request(kind)
            send(value, kind: kind, manager: manager)
            let first = try XCTUnwrap(events.first)
            send(value, kind: kind, manager: manager)
            XCTAssertEqual(events.count, 1, "\(kind)")
            XCTAssertTrue(manager.isCurrentTaskAttention(first), "\(kind)")
            value.permDescription = "Changed operation"
            value.questionText = "Changed question"
            value.planMarkdown = "Changed plan"
            send(value, kind: kind, manager: manager)
            XCTAssertEqual(events.count, 2, "\(kind)")
            XCTAssertFalse(manager.isCurrentTaskAttention(first), "\(kind)")
            XCTAssertTrue(manager.isCurrentTaskAttention(try XCTUnwrap(events.last)))
        }
    }

    func testRequestsWithoutNativeIdentityNeverDeduplicateByContent() {
        for kind in [TaskAttentionEvent.Kind.permission, .question, .planReview] {
            let manager = manager()
            var events: [TaskAttentionEvent] = []
            manager.onTaskAttention = { events.append($0) }
            send(request(kind, nativeID: nil), kind: kind, manager: manager)
            send(request(kind, nativeID: nil), kind: kind, manager: manager)
            XCTAssertEqual(events.count, 2, "\(kind)")
        }
    }

    func testResolvedOrSupersededRequestsCannotShowAndSameIDLaterCanNotifyAgain() throws {
        let manager = manager()
        var events: [TaskAttentionEvent] = []
        manager.onTaskAttention = { events.append($0) }
        send(request(.permission), kind: .permission, manager: manager)
        let old = try XCTUnwrap(events.first)
        var resolved = message(.interactionResolved)
        resolved.nativeRequestKind = "permission"
        resolved.nativeRequestId = "native-one"
        manager.handleMessage(resolved)
        XCTAssertFalse(manager.isCurrentTaskAttention(old))
        send(request(.permission), kind: .permission, manager: manager)
        XCTAssertEqual(events.count, 2)
        XCTAssertFalse(manager.isCurrentTaskAttention(old))
        XCTAssertTrue(manager.isCurrentTaskAttention(try XCTUnwrap(events.last)))
    }

    func testReplayedAndPlaceholderInteractionsDoNotNotify() {
        let manager = manager()
        var events: [TaskAttentionEvent] = []
        manager.onTaskAttention = { events.append($0) }
        for kind in [TaskAttentionEvent.Kind.permission, .question, .planReview] {
            var replay = request(kind)
            replay.nativeMessageReplay = true
            send(replay, kind: kind, manager: manager)
        }
        var placeholder = request(.question, nativeID: nil)
        placeholder.questionText = "Question"
        placeholder.options = []
        send(placeholder, kind: .question, manager: manager)
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(manager.hasInteraction)
    }

    func testObservedWaitingTransitionsNotifyWithoutInventingLocalApproval() throws {
        let manager = manager()
        var events: [TaskAttentionEvent] = []
        manager.onTaskAttention = { events.append($0) }
        for state in [SessionStatus.waitingPermission, .waitingAnswer, .waitingPlanReview] {
            var value = message(.statusUpdate)
            value.observedState = state.rawValue
            manager.handleMessage(value)
            let event = try XCTUnwrap(events.last)
            XCTAssertNil(event.requestID)
            XCTAssertFalse(manager.hasInteraction)
            XCTAssertTrue(manager.isCurrentTaskAttention(event))
            let count = events.count
            manager.handleMessage(value)
            XCTAssertEqual(events.count, count)
            value.observedState = "active"
            manager.handleMessage(value)
            XCTAssertFalse(manager.isCurrentTaskAttention(event))
        }
        XCTAssertEqual(events.map(\.kind), [.permission, .question, .planReview])
    }

    func testObservedWaitingReplayAndRestoredStateDoNotNotify() {
        let manager = manager()
        var events: [TaskAttentionEvent] = []
        manager.onTaskAttention = { events.append($0) }
        var waiting = message(.statusUpdate)
        waiting.observedState = "waitingPermission"
        waiting.nativeMessageReplay = true
        manager.handleMessage(waiting)
        XCTAssertTrue(events.isEmpty)
        let restored = AgentSession(id: "attention-session", agentType: .codex)
        restored.status = .waitingPermission
        manager.sessions = [restored]
        waiting.nativeMessageReplay = nil
        manager.handleMessage(waiting)
        XCTAssertTrue(events.isEmpty)
    }

    func testKimiObservedApprovalDeduplicatesAndResolutionInvalidates() throws {
        let manager = manager()
        var events: [TaskAttentionEvent] = []
        manager.onTaskAttention = { events.append($0) }
        var value = message(.statusUpdate, id: "kimi_code-attention")
        value.agentType = "kimi"
        value.nativeEvent = "kimi_code.PermissionRequest"
        value.nativeRequestId = "request-one"
        value.nativeAgentId = "main"
        value.nativeTurnId = "turn-one"
        value.toolCallId = "tool-one"
        manager.handleMessage(value)
        let first = try XCTUnwrap(events.first)
        XCTAssertNil(first.requestID)
        XCTAssertFalse(manager.hasInteraction)
        XCTAssertTrue(manager.isCurrentTaskAttention(first))
        manager.handleMessage(value)
        XCTAssertEqual(events.count, 1)
        value.nativeEvent = "kimi_code.PermissionResult"
        manager.handleMessage(value)
        XCTAssertFalse(manager.isCurrentTaskAttention(first))
    }

    func testDisabledNewGenerationCannotReviveAnOlderQueuedReminder() throws {
        let manager = manager()
        var events: [TaskAttentionEvent] = []
        manager.onTaskAttention = { events.append($0) }
        var value = message(.statusUpdate)
        value.observedState = "waitingPermission"
        manager.handleMessage(value)
        let old = try XCTUnwrap(events.first)
        AppPreferences.defaults.set(false, forKey: TaskAttentionSettings.enabledKey)
        value.observedState = "active"
        manager.handleMessage(value)
        value.observedState = "waitingPermission"
        manager.handleMessage(value)
        AppPreferences.defaults.set(true, forKey: TaskAttentionSettings.enabledKey)
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(manager.isCurrentTaskAttention(old))
    }
}
