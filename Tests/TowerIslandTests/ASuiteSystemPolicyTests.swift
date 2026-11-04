import XCTest
@testable import XIsland

/// A5/A7/A2 与系统资源门控。
@MainActor
final class ASuiteSystemPolicyTests: XCTestCase {
    private let now = ASuiteFixtures.base

    // MARK: A5 会话生命周期

    func testAutoHideThresholdAndProtectedStates() {
        let old = now.addingTimeInterval(-31 * 60)
        XCTAssertTrue(SessionLifecyclePolicy.shouldAutoHide(
            status: "idle", hasPendingInteraction: false, lastActivityAt: old, now: now))
        XCTAssertFalse(SessionLifecyclePolicy.shouldAutoHide(
            status: "idle", hasPendingInteraction: true, lastActivityAt: old, now: now))
        XCTAssertFalse(SessionLifecyclePolicy.shouldAutoHide(
            status: "error", hasPendingInteraction: false, lastActivityAt: old, now: now))
        XCTAssertFalse(SessionLifecyclePolicy.shouldAutoHide(
            status: "idle", hasPendingInteraction: false, lastActivityAt: now, now: now))
    }

    func testAutoHideNeverTouchesUnreviewedCompletion() {
        let old = now.addingTimeInterval(-31 * 60)
        XCTAssertFalse(SessionLifecyclePolicy.shouldAutoHide(
            status: "completed", hasPendingInteraction: false, needsReview: true,
            lastActivityAt: old, now: now))
        XCTAssertTrue(SessionLifecyclePolicy.shouldAutoHide(
            status: "completed", hasPendingInteraction: false, needsReview: false,
            lastActivityAt: old, now: now))
    }

    func testWaitingStatusWithoutInteractionIsNotSuperseded() {
        // 观察型来源可能只有等待态、没有可回传的交互请求；这类会话被取代后会彻底消失。
        let waiting = ASuiteFixtures.summary(id: "a", status: "waitingPermission",
                                             last: now.addingTimeInterval(-60))
        let newer = ASuiteFixtures.summary(id: "b", last: now)
        XCTAssertTrue(SessionLifecyclePolicy.supersededSessionIDs([waiting, newer]).isEmpty)
    }

    func testSupersessionKeepsNewestAndIsStable() {
        let older = ASuiteFixtures.summary(id: "a", last: now.addingTimeInterval(-60))
        let newer = ASuiteFixtures.summary(id: "b", last: now)
        XCTAssertEqual(SessionLifecyclePolicy.supersededSessionIDs([older, newer]), ["a"])
        XCTAssertEqual(SessionLifecyclePolicy.supersededSessionIDs([newer, older]), ["a"])
    }

    func testPendingInteractionAndEmptyDirectoryNeverSuperseded() {
        let pending = ASuiteFixtures.summary(id: "a", interactionId: "r1",
                                             interactionKind: "permission",
                                             last: now.addingTimeInterval(-60))
        let newer = ASuiteFixtures.summary(id: "b", last: now)
        XCTAssertTrue(SessionLifecyclePolicy.supersededSessionIDs([pending, newer]).isEmpty)
        let noDirectory = ASuiteFixtures.summary(id: "c", cwd: "", last: now)
        XCTAssertTrue(SessionLifecyclePolicy.supersededSessionIDs([noDirectory, newer]).isEmpty)
    }

    func testReapRequiresDeadProcessAndGrace() {
        let old = now.addingTimeInterval(-120)
        XCTAssertFalse(SessionLifecyclePolicy.shouldReap(
            status: "waitingPermission", isProcessAlive: true, lastActivityAt: old, now: now))
        XCTAssertTrue(SessionLifecyclePolicy.shouldReap(
            status: "waitingPermission", isProcessAlive: false, lastActivityAt: old, now: now))
        XCTAssertFalse(SessionLifecyclePolicy.shouldReap(
            status: "completed", isProcessAlive: false, lastActivityAt: old, now: now))
    }

    func testIdentityAssociationPrefersExactIDAndRefusesAmbiguity() {
        let candidate = ASuiteFixtures.summary(id: "s1")
        XCTAssertEqual(SessionLifecyclePolicy.associate(
            identity: SessionIdentity(nativeTaskID: "s1", workingDirectory: "/tmp/proj"),
            candidates: [candidate]), "s1")
        XCTAssertNil(SessionLifecyclePolicy.associate(
            identity: SessionIdentity(nativeTaskID: "other", workingDirectory: ""),
            candidates: [candidate]))
        // 同目录有两条候选时拒绝猜测。
        let second = ASuiteFixtures.summary(id: "s2")
        XCTAssertNil(SessionLifecyclePolicy.associate(
            identity: SessionIdentity(nativeTaskID: nil, workingDirectory: "/tmp/proj"),
            candidates: [candidate, second]))
        XCTAssertEqual(SessionLifecyclePolicy.associate(
            identity: SessionIdentity(nativeTaskID: nil, workingDirectory: "/tmp/proj"),
            candidates: [candidate]), "s1")
    }

    // MARK: A7 防休眠

    func testKeepAwakeModes() {
        XCTAssertFalse(KeepAwakePolicy.shouldHold(
            mode: .off, hasWorkingSession: true, batteryPercent: 100,
            isCharging: true, lastWorkEndedAt: nil, now: now))
        XCTAssertTrue(KeepAwakePolicy.shouldHold(
            mode: .always, hasWorkingSession: false, batteryPercent: 100,
            isCharging: false, lastWorkEndedAt: nil, now: now))
        XCTAssertTrue(KeepAwakePolicy.shouldHold(
            mode: .auto, hasWorkingSession: true, batteryPercent: nil,
            isCharging: false, lastWorkEndedAt: nil, now: now))
        XCTAssertFalse(KeepAwakePolicy.shouldHold(
            mode: .auto, hasWorkingSession: false, batteryPercent: nil,
            isCharging: false, lastWorkEndedAt: nil, now: now))
    }

    func testKeepAwakeGraceAndLowBattery() {
        XCTAssertTrue(KeepAwakePolicy.shouldHold(
            mode: .auto, hasWorkingSession: false, batteryPercent: nil,
            isCharging: false, lastWorkEndedAt: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(KeepAwakePolicy.shouldHold(
            mode: .auto, hasWorkingSession: false, batteryPercent: nil,
            isCharging: false, lastWorkEndedAt: now.addingTimeInterval(-200), now: now))
        XCTAssertFalse(KeepAwakePolicy.shouldHold(
            mode: .always, hasWorkingSession: true, batteryPercent: 20,
            isCharging: false, lastWorkEndedAt: nil, now: now))
        XCTAssertTrue(KeepAwakePolicy.shouldHold(
            mode: .always, hasWorkingSession: true, batteryPercent: 20,
            isCharging: true, lastWorkEndedAt: nil, now: now))
    }

    // MARK: 系统资源门控

    func testSystemAPIsAreGatedInTestIsolation() {
        XCTAssertFalse(SystemNotificationCenter.isAvailable)
        XCTAssertFalse(SessionKeepAwakeController.isAvailable)
        XCTAssertFalse(PushNotifier.isAvailable)
    }
}
