import AppKit
import XCTest
@testable import XIsland

final class SwipeGestureRecognizerTests: XCTestCase {
    func testMomentumScrollDoesNotTriggerSwitch() {
        let recognizer = SwipeGestureRecognizer()
        XCTAssertEqual(scroll(recognizer, x: 90, phase: [], momentum: .changed), .inProgress)
        XCTAssertEqual(scroll(recognizer, x: 90, phase: .began), .progress(90))
        XCTAssertEqual(scroll(recognizer, x: 90, phase: [], momentum: .began), .cancelled)
        XCTAssertEqual(scroll(recognizer, phase: .ended), .inProgress)
    }

    func testSuppressionPreventsTargetFromConsumingSameGesture() {
        let recognizer = SwipeGestureRecognizer()
        recognizer.suppress(for: 1, now: date(0))
        XCTAssertEqual(scroll(recognizer, x: 90, phase: .began, time: 0.1), .inProgress)
        XCTAssertEqual(scroll(recognizer, x: 90, time: 1.1), .inProgress)
        XCTAssertEqual(scroll(recognizer, x: 90, phase: .began, time: 1.2), .progress(90))
        XCTAssertEqual(scroll(recognizer, phase: .ended, time: 1.3), .triggered(.right))
    }

    func testNewGestureDoesNotReusePreviousPartialDistance() {
        let recognizer = SwipeGestureRecognizer()
        XCTAssertEqual(scroll(recognizer, x: 25, phase: .began), .progress(25))
        XCTAssertEqual(scroll(recognizer, x: 20, phase: .began, time: 1), .progress(20))
        XCTAssertEqual(scroll(recognizer, phase: .ended, time: 1.1), .cancelled)
    }

    func testCrossingThresholdOnlyCommitsOnRelease() {
        let recognizer = SwipeGestureRecognizer()
        XCTAssertEqual(scroll(recognizer, x: 90, phase: .began), .progress(90))
        XCTAssertEqual(scroll(recognizer, x: 10), .progress(100))
        XCTAssertTrue(recognizer.isActive)
        XCTAssertEqual(scroll(recognizer, phase: .ended), .triggered(.right))
        XCTAssertFalse(recognizer.isActive)
        XCTAssertFalse(recognizer.consumesHorizontalScroll)
    }

    func testNegativeScrollCommitsLeft() {
        let recognizer = SwipeGestureRecognizer()
        XCTAssertEqual(scroll(recognizer, x: -90, phase: .began), .progress(-90))
        XCTAssertEqual(scroll(recognizer, phase: .ended), .triggered(.left))
        XCTAssertEqual(SwipeDirection.left.sign, -1)
        XCTAssertEqual(SwipeDirection.right.sign, 1)
        XCTAssertEqual(SwipeDirection(rawValue: "left"), .left)
    }

    func testReleaseBelowThresholdCancelsPreview() {
        let recognizer = SwipeGestureRecognizer()
        XCTAssertEqual(scroll(recognizer, x: 10, phase: .began), .progress(10))
        XCTAssertEqual(scroll(recognizer, phase: .ended), .cancelled)
        XCTAssertFalse(recognizer.isActive)
    }

    func testCancelledGestureNeverCommitsEvenAboveThreshold() {
        let recognizer = SwipeGestureRecognizer()
        _ = scroll(recognizer, x: 90, phase: .began)
        XCTAssertEqual(scroll(recognizer, phase: .cancelled), .cancelled)
        XCTAssertEqual(scroll(recognizer, phase: .ended), .inProgress)
    }

    func testReversingBeforeReleaseCancelsPreview() {
        let recognizer = SwipeGestureRecognizer()
        _ = scroll(recognizer, x: 90, phase: .began)
        XCTAssertEqual(scroll(recognizer, x: -85), .progress(5))
        XCTAssertEqual(scroll(recognizer, phase: .ended), .cancelled)
    }

    func testReversalCanCommitOppositeDirection() {
        let recognizer = SwipeGestureRecognizer()
        _ = scroll(recognizer, x: 90, phase: .began)
        XCTAssertEqual(scroll(recognizer, x: -180), .progress(-90))
        XCTAssertEqual(scroll(recognizer, phase: .ended), .triggered(.left))
    }

    func testVerticalGestureCannotBecomeHorizontalHalfwayThrough() {
        let recognizer = SwipeGestureRecognizer()
        XCTAssertEqual(scroll(recognizer, y: 10, phase: .began), .inProgress)
        XCTAssertTrue(recognizer.isActive)
        XCTAssertFalse(recognizer.consumesHorizontalScroll)
        XCTAssertEqual(scroll(recognizer, x: 100), .inProgress)
        XCTAssertFalse(recognizer.consumesHorizontalScroll)
        XCTAssertEqual(scroll(recognizer, phase: .ended), .inProgress)
    }

    func testHorizontalAxisKeepsProgressThroughVerticalNoise() {
        let recognizer = SwipeGestureRecognizer()
        _ = scroll(recognizer, x: 10, phase: .began)
        XCTAssertEqual(scroll(recognizer, y: 40), .progress(10))
        XCTAssertEqual(scroll(recognizer, x: 80), .progress(90))
        XCTAssertEqual(scroll(recognizer, phase: .ended), .triggered(.right))
    }

    func testSmallMovementsAccumulateBeforeAxisLocks() {
        let recognizer = SwipeGestureRecognizer()
        XCTAssertEqual(scroll(recognizer, x: 2, phase: .began), .inProgress)
        XCTAssertEqual(scroll(recognizer, x: 2), .inProgress)
        XCTAssertEqual(scroll(recognizer, x: 2), .progress(6))
    }

    func testPendingHorizontalIntentPreventsPrematureScrollExpand() {
        let recognizer = SwipeGestureRecognizer()
        XCTAssertEqual(scroll(recognizer, x: 5, y: 3, phase: .began), .inProgress)
        XCTAssertTrue(recognizer.consumesHorizontalScroll)
        recognizer.reset()
        XCTAssertFalse(recognizer.consumesHorizontalScroll)
        XCTAssertEqual(scroll(recognizer, y: 5, phase: .began), .inProgress)
        XCTAssertFalse(recognizer.consumesHorizontalScroll)
    }

    func testLongGestureAndRepeatedEndOnlyCommitOnce() {
        let recognizer = SwipeGestureRecognizer()
        _ = scroll(recognizer, x: 90, phase: .began)
        XCTAssertEqual(scroll(recognizer, x: 90, time: 10), .progress(180))
        XCTAssertEqual(scroll(recognizer, phase: .ended, time: 10.1), .triggered(.right))
        XCTAssertEqual(scroll(recognizer, phase: .ended, time: 10.2), .inProgress)
        XCTAssertEqual(scroll(recognizer, x: 90, time: 20), .inProgress)
        XCTAssertEqual(scroll(recognizer, phase: .ended, time: 20.1), .inProgress)
        XCTAssertEqual(scroll(recognizer, x: 90, phase: .began, time: 21), .progress(90))
        XCTAssertEqual(scroll(recognizer, phase: .ended, time: 21.1), .triggered(.right))
    }

    func testGestureStartedDuringCooldownCannotResumeAfterCooldown() {
        let recognizer = SwipeGestureRecognizer()
        _ = scroll(recognizer, x: 90, phase: .began)
        XCTAssertEqual(scroll(recognizer, phase: .ended, time: 0.1), .triggered(.right))
        XCTAssertEqual(scroll(recognizer, x: 90, phase: .began, time: 0.2), .inProgress)
        XCTAssertEqual(scroll(recognizer, x: 90, time: 0.7), .inProgress)
        XCTAssertEqual(scroll(recognizer, phase: .ended, time: 0.8), .inProgress)
    }

    func testTargetHandoffSuppressesTailUntilNextBegan() {
        let recognizer = SwipeGestureRecognizer()
        _ = scroll(recognizer, x: 90, phase: .began)
        recognizer.suppressUntilNextGesture()
        XCTAssertFalse(recognizer.isActive)
        XCTAssertEqual(scroll(recognizer, x: 90, time: 5), .inProgress)
        XCTAssertEqual(scroll(recognizer, phase: .ended, time: 5.1), .inProgress)
        XCTAssertEqual(scroll(recognizer, x: 90, phase: .began, time: 5.2), .progress(90))
        XCTAssertEqual(scroll(recognizer, phase: .ended, time: 5.3), .triggered(.right))
    }

    func testPhaseLessPreciseWheelCannotStartOrCommitGesture() {
        let recognizer = SwipeGestureRecognizer()
        XCTAssertEqual(scroll(recognizer, x: 90, phase: []), .inProgress)
        XCTAssertEqual(scroll(recognizer, phase: .ended), .inProgress)
        _ = scroll(recognizer, x: 10, phase: .began)
        XCTAssertEqual(scroll(recognizer, x: 90, phase: []), .cancelled)
        XCTAssertEqual(scroll(recognizer, phase: .ended), .inProgress)
    }

    func testImpreciseWheelCannotStartGesture() {
        let recognizer = SwipeGestureRecognizer()
        XCTAssertEqual(scroll(recognizer, x: 90, phase: .began, isPrecise: false), .inProgress)
        XCTAssertEqual(scroll(recognizer, phase: .ended), .inProgress)
    }

    func testNonFiniteInputCancelsWithoutPoisoningNextGesture() {
        for invalid in [CGFloat.nan, .infinity, -.infinity] {
            let recognizer = SwipeGestureRecognizer()
            _ = scroll(recognizer, x: 90, phase: .began)
            XCTAssertEqual(scroll(recognizer, x: invalid), .cancelled)
            XCTAssertEqual(scroll(recognizer, phase: .ended), .inProgress)
            XCTAssertEqual(scroll(recognizer, x: 90, phase: .began, time: 1), .progress(90))
            XCTAssertEqual(scroll(recognizer, phase: .ended, time: 1.1), .triggered(.right))
        }
    }

    func testAccumulatedOverflowCancelsPreview() {
        let recognizer = SwipeGestureRecognizer()
        _ = scroll(recognizer, x: .greatestFiniteMagnitude, phase: .began)
        XCTAssertEqual(scroll(recognizer, x: .greatestFiniteMagnitude), .cancelled)
        XCTAssertEqual(scroll(recognizer, phase: .ended), .inProgress)
    }

    func testNewBeganClearsOldPreviewBeforeAxisLock() {
        let recognizer = SwipeGestureRecognizer()
        _ = scroll(recognizer, x: 90, phase: .began)
        XCTAssertEqual(scroll(recognizer, x: 1, phase: .began), .progress(0))
        XCTAssertEqual(scroll(recognizer, x: 9), .progress(10))
        XCTAssertEqual(scroll(recognizer, phase: .ended), .cancelled)
    }

    func testMayBeginClearsUnfinishedPreviewWithoutCommitting() {
        let recognizer = SwipeGestureRecognizer()
        _ = scroll(recognizer, x: 90, phase: .began)
        XCTAssertEqual(scroll(recognizer, phase: .mayBegin), .cancelled)
        XCTAssertEqual(scroll(recognizer, x: 90), .inProgress)
    }

    func testZeroBeganRemainsUndecidedUntilHorizontalMovementArrives() {
        let recognizer = SwipeGestureRecognizer()
        XCTAssertEqual(scroll(recognizer, phase: .began), .inProgress)
        XCTAssertTrue(recognizer.isActive)
        XCTAssertFalse(recognizer.hasLockedVerticalAxis)
        XCTAssertFalse(recognizer.consumesHorizontalScroll)
        XCTAssertEqual(scroll(recognizer), .inProgress)
        XCTAssertFalse(recognizer.hasLockedVerticalAxis)
        XCTAssertEqual(scroll(recognizer, x: 2), .inProgress)
        XCTAssertTrue(recognizer.consumesHorizontalScroll)
        XCTAssertFalse(recognizer.hasLockedVerticalAxis)
        XCTAssertEqual(scroll(recognizer, x: 8), .progress(10))
        XCTAssertFalse(recognizer.hasLockedVerticalAxis)
        XCTAssertEqual(scroll(recognizer, phase: .ended), .cancelled)
        XCTAssertFalse(recognizer.isActive)
    }

    func testZeroBeganDoesNotReportVerticalLockUntilVerticalAxisIsDecided() {
        let recognizer = SwipeGestureRecognizer()
        XCTAssertEqual(scroll(recognizer, phase: .began), .inProgress)
        XCTAssertFalse(recognizer.hasLockedVerticalAxis)
        XCTAssertEqual(scroll(recognizer, y: 2), .inProgress)
        XCTAssertTrue(recognizer.isActive)
        XCTAssertFalse(recognizer.hasLockedVerticalAxis, "尚未判轴不能当成纵向拒绝")
        XCTAssertFalse(recognizer.consumesHorizontalScroll)
        XCTAssertEqual(scroll(recognizer, y: 8), .inProgress)
        XCTAssertTrue(recognizer.hasLockedVerticalAxis)
        XCTAssertFalse(recognizer.consumesHorizontalScroll)
        XCTAssertEqual(scroll(recognizer, x: 100), .inProgress)
        XCTAssertTrue(recognizer.hasLockedVerticalAxis)
        XCTAssertEqual(scroll(recognizer, phase: .ended), .inProgress)
        XCTAssertFalse(recognizer.hasLockedVerticalAxis)
        XCTAssertFalse(recognizer.isActive)
    }

    private func scroll(
        _ recognizer: SwipeGestureRecognizer,
        x: CGFloat = 0,
        y: CGFloat = 0,
        phase: NSEvent.Phase = .changed,
        momentum: NSEvent.Phase = [],
        isPrecise: Bool = true,
        time: TimeInterval = 0
    ) -> SwipeResult {
        recognizer.handleScroll(deltaX: x, deltaY: y, isPrecise: isPrecise,
            phase: phase, momentumPhase: momentum, now: date(time))
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: 1_000 + offset)
    }
}
