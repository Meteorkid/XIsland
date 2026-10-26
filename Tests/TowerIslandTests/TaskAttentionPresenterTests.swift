import DIShared
import XCTest
@testable import XIsland

@MainActor
final class TaskAttentionPresenterTests: XCTestCase {
    @MainActor private final class Harness {
        var enabled = true
        var valid: Set<UUID> = []
        var scheduled: [@MainActor () -> Void] = []
        var presented: [TaskAttentionEvent] = []
        lazy var presenter = TaskAttentionPresenter(environment: .init(
            isEnabled: { self.enabled }, isCurrent: { self.valid.contains($0.id) },
            schedule: { _, action in self.scheduled.append(action); return {} },
            present: { self.presented.append($0) }
        ))

        func enqueue(_ kind: TaskAttentionEvent.Kind, session: String = UUID().uuidString) -> TaskAttentionEvent {
            let event = TaskAttentionEvent(sessionID: session, kind: kind)
            valid.insert(event.id)
            presenter.enqueue(event)
            return event
        }
    }

    func testBatchCoalescesAndInteractionTakesPriorityOverCompletions() {
        let h = Harness()
        _ = h.enqueue(.completion)
        let question = h.enqueue(.question)
        _ = h.enqueue(.completion)
        XCTAssertEqual(h.scheduled.count, 1)
        h.scheduled[0]()
        XCTAssertEqual(h.presented, [question])
    }

    func testNewestCompletionSelectedWithoutAcknowledgingOthers() {
        let h = Harness()
        let first = h.enqueue(.completion)
        let last = h.enqueue(.completion)
        h.scheduled[0]()
        XCTAssertEqual(h.presented, [last])
        XCTAssertEqual(h.valid, [first.id, last.id])
    }

    func testResolvedRequestAndResumedTaskAreDroppedAtDelivery() {
        let h = Harness()
        let resolved = h.enqueue(.permission)
        let resumed = h.enqueue(.completion)
        let current = h.enqueue(.planReview)
        h.valid.subtract([resolved.id, resumed.id])
        h.scheduled[0]()
        XCTAssertEqual(h.presented, [current])
    }

    func testOptOutBeforeAndAfterSchedulingPreventsPresentation() {
        let h = Harness()
        h.enabled = false
        _ = h.enqueue(.completion)
        XCTAssertTrue(h.scheduled.isEmpty)
        h.enabled = true
        _ = h.enqueue(.permission)
        h.enabled = false
        h.scheduled[0]()
        XCTAssertTrue(h.presented.isEmpty)
        h.enabled = true
        let next = h.enqueue(.question)
        h.scheduled[1]()
        XCTAssertEqual(h.presented, [next])
    }

    func testCancellationInvalidatesEvenAlreadyEnqueuedCallback() {
        let h = Harness()
        _ = h.enqueue(.completion)
        h.presenter.cancel()
        let next = h.enqueue(.question)
        h.scheduled[0]()
        XCTAssertTrue(h.presented.isEmpty)
        h.scheduled[1]()
        XCTAssertEqual(h.presented, [next])
        h.presenter.cancel()
    }

    func testRealManagerReviewBeforeDeliveryDoesNotShowOrChangeOtherTask() throws {
        let original = AppPreferences.defaults.object(forKey: TaskAttentionSettings.enabledKey)
        AppPreferences.defaults.set(true, forKey: TaskAttentionSettings.enabledKey)
        defer {
            if let original { AppPreferences.defaults.set(original, forKey: TaskAttentionSettings.enabledKey) }
            else { AppPreferences.defaults.removeObject(forKey: TaskAttentionSettings.enabledKey) }
        }
        let manager = SessionManager()
        var delivery: (@MainActor () -> Void)?
        var presented: [TaskAttentionEvent] = []
        let presenter = TaskAttentionPresenter(environment: .init(
            isEnabled: { true }, isCurrent: { manager.isCurrentTaskAttention($0) },
            schedule: { _, action in delivery = action; return {} },
            present: { presented.append($0) }
        ))
        manager.onTaskAttention = { presenter.enqueue($0) }
        var start = DIMessage(type: .sessionStart, sessionId: "completed")
        start.agentType = AgentType.codex.rawValue
        var end = DIMessage(type: .sessionEnd, sessionId: "completed")
        end.agentType = AgentType.codex.rawValue
        end.observedState = "completed"
        manager.handleMessage(start)
        manager.handleMessage(end)
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertTrue(session.completionNeedsReview)
        manager.markCompletionReviewed(sessionID: session.id)
        delivery?()
        XCTAssertTrue(presented.isEmpty)
        XCTAssertFalse(session.completionNeedsReview)
    }
}
