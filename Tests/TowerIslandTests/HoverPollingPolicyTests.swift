import Foundation
import XCTest
@testable import XIsland

final class HoverPollingPolicyTests: XCTestCase {
    private let frame = CGRect(x: 100, y: 100, width: 220, height: 40)

    func testHiddenOccludedApplicationAndIslandSwitchEachPauseSampling() {
        XCTAssertTrue(HoverPollingPolicy.canSample(windowVisible: true, windowOccluded: false,
            applicationHidden: false, hiddenByIslandSwitch: false))
        XCTAssertFalse(HoverPollingPolicy.canSample(windowVisible: false, windowOccluded: false,
            applicationHidden: false, hiddenByIslandSwitch: false))
        XCTAssertFalse(HoverPollingPolicy.canSample(windowVisible: true, windowOccluded: true,
            applicationHidden: false, hiddenByIslandSwitch: false))
        XCTAssertFalse(HoverPollingPolicy.canSample(windowVisible: true, windowOccluded: false,
            applicationHidden: true, hiddenByIslandSwitch: false))
        XCTAssertFalse(HoverPollingPolicy.canSample(windowVisible: true, windowOccluded: false,
            applicationHidden: false, hiddenByIslandSwitch: true))
    }

    func testHiddenWindowNeverSchedulesPointerSampling() {
        for allowsMotion in [false, true] {
            XCTAssertEqual(HoverPollingPolicy.cadence(
                isVisible: false, isDragging: false,
                pointerLocation: CGPoint(x: 210, y: 120), hoverFrame: frame,
                allowsContinuousMotion: allowsMotion
            ), .paused)
        }
    }

    func testFarAwayPointerUsesFiveSamplesPerSecond() {
        XCTAssertEqual(cadence(at: CGPoint(x: 600, y: 600)), .idle)
        XCTAssertEqual(HoverPollingPolicy.Cadence.idle.interval, 0.2)
    }

    func testNearbyPointerKeepsSmoothFeedbackIncludingOutsideWindow() {
        XCTAssertEqual(cadence(at: CGPoint(x: 210, y: 120)), .responsive)
        XCTAssertEqual(cadence(at: CGPoint(x: 210, y: 50)), .responsive)
        XCTAssertEqual(HoverPollingPolicy.Cadence.responsive.interval, 1.0 / 60.0)
    }

    func testReducedMotionAndDraggingAvoidHighFrequencySampling() {
        XCTAssertEqual(cadence(at: CGPoint(x: 210, y: 120), allowsMotion: false), .reducedMotion)
        XCTAssertEqual(HoverPollingPolicy.Cadence.reducedMotion.interval, 0.2)
        XCTAssertEqual(HoverPollingPolicy.cadence(
            isVisible: true, isDragging: true,
            pointerLocation: CGPoint(x: 210, y: 120), hoverFrame: frame,
            allowsContinuousMotion: true
        ), .idle)
    }

    func testStationaryPointerReturnsToIdleEvenWhenInsidePill() {
        XCTAssertEqual(HoverPollingPolicy.cadence(
            isVisible: true, isDragging: false,
            pointerLocation: CGPoint(x: 210, y: 120), hoverFrame: frame,
            allowsContinuousMotion: true, recentPointerMovement: false
        ), .idle)
    }

    func testVirtualTenSecondCallbackCountsForEveryCadence() {
        for (cadence, expected) in [
            (HoverPollingPolicy.Cadence.paused, 0), (.idle, 50),
            (.responsive, 600), (.reducedMotion, 50)
        ] {
            let clock = PollingClock()
            let controller = HoverPollingController(schedule: clock.schedule)
            var callbacks = 0
            controller.update(cadence: cadence) { callbacks += 1 }
            clock.advance(by: 10)
            XCTAssertEqual(callbacks, expected, "cadence=\(cadence)")
            controller.stop()
        }
    }

    func testHideStopsExistingTimerAndShowResumesWithOneTimer() {
        let clock = PollingClock()
        let controller = HoverPollingController(schedule: clock.schedule)
        var callbacks = 0
        controller.update(cadence: .responsive) { callbacks += 1 }
        clock.advance(by: 1)
        XCTAssertEqual(callbacks, 60)

        controller.update(cadence: .paused) { XCTFail("Hidden pointer callback") }
        clock.advance(by: 5)
        XCTAssertEqual(callbacks, 60)
        XCTAssertEqual(clock.activeTimers, 0)

        controller.update(cadence: .idle) { callbacks += 1 }
        controller.update(cadence: .idle) { callbacks += 1 }
        XCTAssertEqual(clock.activeTimers, 1)
        clock.advance(by: 1)
        XCTAssertEqual(callbacks, 65)
    }

    func testDisappearAndDeinitCancelCallbacks() {
        let clock = PollingClock()
        var controller: HoverPollingController? = HoverPollingController(schedule: clock.schedule)
        controller?.update(cadence: .idle) { XCTFail("Stopped pointer callback") }
        controller?.stop()
        clock.advance(by: 1)
        XCTAssertEqual(clock.activeTimers, 0)
        controller?.update(cadence: .responsive) { XCTFail("Released pointer callback") }
        weak var weakController = controller
        controller = nil
        XCTAssertNil(weakController)
        clock.advance(by: 1)
        XCTAssertEqual(clock.activeTimers, 0)
    }

    private func cadence(at point: CGPoint, allowsMotion: Bool = true) -> HoverPollingPolicy.Cadence {
        HoverPollingPolicy.cadence(isVisible: true, isDragging: false,
            pointerLocation: point, hoverFrame: frame, allowsContinuousMotion: allowsMotion)
    }

    @MainActor
    func testMeasureActualTimerCallbacksWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["X_ISLAND_MEASURE_HOVER_CALLBACKS"] == "1" else {
            throw XCTSkip("显式启用真实 Timer 回调计数；不是 CPU 或 FPS 测量")
        }
        var baselineCount = 0
        let baseline = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in baselineCount += 1 }
        RunLoop.main.add(baseline, forMode: .common)
        let baselineStart = Date()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        baseline.invalidate()
        print("HOVER_CALLBACK_MEASUREMENT baseline60Hz count=\(baselineCount) elapsed=\(Date().timeIntervalSince(baselineStart))")
        for cadence in [HoverPollingPolicy.Cadence.idle, .paused, .responsive, .reducedMotion] {
            let controller = HoverPollingController()
            var callbacks = 0
            controller.update(cadence: cadence) { callbacks += 1 }
            let start = Date()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            controller.stop()
            let elapsed = Date().timeIntervalSince(start)
            print("HOVER_CALLBACK_MEASUREMENT \(cadence) count=\(callbacks) elapsed=\(elapsed)")
            if let interval = cadence.interval {
                XCTAssertLessThanOrEqual(callbacks, Int(ceil(elapsed / interval)) + 1)
            } else {
                XCTAssertEqual(callbacks, 0)
            }
        }
    }
}

private final class PollingClock {
    private struct Scheduled {
        let timer: Timer
        var nextFire: TimeInterval
    }
    private var scheduled: [Scheduled] = []
    private var now: TimeInterval = 0

    var activeTimers: Int { scheduled.filter { $0.timer.isValid }.count }

    func schedule(interval: TimeInterval, action: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
        scheduled.append(Scheduled(timer: timer, nextFire: now + interval))
        return timer
    }

    func advance(by duration: TimeInterval) {
        let end = now + duration
        while let index = scheduled.indices.filter({ scheduled[$0].timer.isValid && scheduled[$0].nextFire <= end + 0.000_001 })
            .min(by: { scheduled[$0].nextFire < scheduled[$1].nextFire }) {
            now = scheduled[index].nextFire
            scheduled[index].nextFire += scheduled[index].timer.timeInterval
            scheduled[index].timer.fire()
        }
        now = end
    }
}
