import XCTest
@testable import XIsland

/// 事件推导：判重、消费后重建、压缩不误唤醒、新会话只报一次。
@MainActor
final class ASuiteEventDeriverTests: XCTestCase {
    private let now = ASuiteFixtures.base

    func testNewPermissionEmitsExactlyOnce() {
        let current = [ASuiteFixtures.summary(
            status: "waitingPermission",
            interactionId: "r1", interactionKind: "permission")]
        let events = IslandEventDeriver.derive(previous: [], current: current, now: now)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .permission)
        XCTAssertEqual(events.first?.requestId, "r1")
        XCTAssertTrue(events.first?.requiresUserDecision == true)

        let key = events[0].deduplicationKey
        XCTAssertTrue(IslandEventDeriver.derive(
            previous: current, current: current, now: now,
            emitted: [key]).isEmpty)
    }

    func testConsumedRequestFollowedByNewOneEmitsAgain() {
        let first = [ASuiteFixtures.summary(interactionId: "r1", interactionKind: "permission")]
        let emitted = Set(IslandEventDeriver.derive(
            previous: [], current: first, now: now).map(\.deduplicationKey))
        let second = [ASuiteFixtures.summary(interactionId: "r2", interactionKind: "permission")]
        let events = IslandEventDeriver.derive(previous: first, current: second,
                                               now: now, emitted: emitted)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.requestId, "r2")
    }

    func testCompactionNeverBecomesCompletionEvent() {
        let current = [ASuiteFixtures.summary(status: "compacting", needsReview: true)]
        XCTAssertTrue(IslandEventDeriver.derive(previous: [], current: current,
                                                now: now).isEmpty)
    }

    func testStartedOnlyFiresForNewSession() {
        let current = [ASuiteFixtures.summary()]
        XCTAssertEqual(IslandEventDeriver.derive(previous: [], current: current,
                                                 now: now).first?.kind, .started)
        XCTAssertTrue(IslandEventDeriver.derive(previous: current, current: current,
                                                now: now).isEmpty)
    }

    func testCompletionRequiresUnreviewedFlag() {
        let unreviewed = [ASuiteFixtures.summary(status: "completed", needsReview: true)]
        XCTAssertEqual(IslandEventDeriver.derive(previous: [], current: unreviewed,
                                                 now: now).first?.kind, .completed)
        let reviewed = [ASuiteFixtures.summary(status: "completed", needsReview: false)]
        XCTAssertTrue(IslandEventDeriver.derive(previous: [], current: reviewed,
                                                now: now).isEmpty)
    }

    func testErrorEmitsAgainAfterRecovery() {
        let erroring = [ASuiteFixtures.summary(status: "error", last: now)]
        XCTAssertEqual(IslandEventDeriver.derive(previous: [], current: erroring,
                                                 now: now).first?.kind, .error)
        // 同一错误状态持续期间不重复提醒。
        XCTAssertTrue(IslandEventDeriver.derive(previous: erroring, current: erroring,
                                                now: now).isEmpty)
        // 恢复后再次出错必须重新提醒：状态型事件不能被 emitted 永久阻断。
        let recovered = [ASuiteFixtures.summary(status: "active", last: now)]
        _ = IslandEventDeriver.derive(previous: erroring, current: recovered, now: now)
        XCTAssertEqual(IslandEventDeriver.derive(previous: recovered, current: erroring,
                                                 now: now).first?.kind, .error)
    }

    func testCompletionEmitsAgainAfterReviewReset() {
        let completed = [ASuiteFixtures.summary(status: "completed", needsReview: true,
                                                completedAt: now)]
        XCTAssertEqual(IslandEventDeriver.derive(previous: [], current: completed,
                                                 now: now).first?.kind, .completed)
        let reviewed = [ASuiteFixtures.summary(status: "completed", needsReview: false,
                                               completedAt: now)]
        XCTAssertTrue(IslandEventDeriver.derive(previous: completed, current: reviewed,
                                                now: now).isEmpty)
        XCTAssertEqual(IslandEventDeriver.derive(previous: reviewed, current: completed,
                                                 now: now).first?.kind, .completed)
    }

    func testSubagentFlagIsPreservedAndPruneDropsVanishedKeys() {
        let session = [ASuiteFixtures.summary(isSubagent: true)]
        let events = IslandEventDeriver.derive(previous: [], current: session, now: now)
        XCTAssertEqual(events.first?.isSubagent, true)

        let kept = "completed|s1|completed-1"
        let dropped = "error|s2|error-1"
        XCTAssertEqual(IslandEventDeriver.prune(emitted: [kept, dropped],
                                               liveSessionIDs: ["s1"]), [kept])
    }
}
