import AppKit
import XCTest
@testable import XIsland

final class SwipeGestureRecognizerTests: XCTestCase {
    func testMomentumScrollDoesNotTriggerSwitch() {
        let recognizer = SwipeGestureRecognizer()
        let now = Date()

        let result = recognizer.handleScroll(
            deltaX: 60,
            deltaY: 0,
            isPrecise: true,
            phase: [],
            momentumPhase: .changed,
            now: now
        )

        guard case .inProgress = result else {
            return XCTFail("惯性滚动不应触发切换")
        }
    }

    func testSuppressionPreventsTargetFromConsumingSameGesture() {
        let recognizer = SwipeGestureRecognizer()
        let now = Date()
        recognizer.suppress(for: 1, now: now)

        let result = recognizer.handleScroll(
            deltaX: 60,
            deltaY: 0,
            isPrecise: true,
            phase: .changed,
            momentumPhase: [],
            now: now.addingTimeInterval(0.1)
        )

        guard case .inProgress = result else {
            return XCTFail("目标岛显示后的抑制期内不应触发切换")
        }
    }

    func testNewGestureDoesNotReusePreviousPartialDistance() {
        let recognizer = SwipeGestureRecognizer()
        let now = Date()

        _ = recognizer.handleScroll(
            deltaX: 30,
            deltaY: 0,
            isPrecise: true,
            phase: .changed,
            momentumPhase: [],
            now: now
        )
        let result = recognizer.handleScroll(
            deltaX: 20,
            deltaY: 0,
            isPrecise: true,
            phase: .began,
            momentumPhase: [],
            now: now.addingTimeInterval(1)
        )

        guard case .inProgress = result else {
            return XCTFail("新手势不应继承上一次未完成的累计距离")
        }
    }
}
