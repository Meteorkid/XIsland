import XCTest
@testable import XIsland

final class IslandSwipeOwnershipGateTests: XCTestCase {
    func testBeganAlwaysProbesEvenWithinSamplingInterval() {
        var gate = IslandSwipeOwnershipGate()
        var probes = 0
        let probe = { probes += 1; return true }
        XCTAssertTrue(gate.canHandleEvent(isNewGesture: true, isGestureActive: false, now: 0, probe: probe))
        XCTAssertTrue(gate.canHandleEvent(isNewGesture: true, isGestureActive: true, now: 0.01, probe: probe))
        XCTAssertEqual(probes, 2)
    }

    func testChangedEventsReuseOwnershipWithoutProbing() {
        var gate = IslandSwipeOwnershipGate()
        var probes = 0
        let probe = { probes += 1; return true }
        XCTAssertTrue(gate.canHandleEvent(isNewGesture: true, isGestureActive: false, now: 0, probe: probe))
        for index in 1...240 {
            XCTAssertTrue(gate.canHandleEvent(isNewGesture: false, isGestureActive: true,
                                              now: Double(index) / 120, probe: probe))
        }
        XCTAssertEqual(probes, 1, "持续 changed 不能重复枚举窗口")
    }

    func testPreviewChecksAtMostOnceEveryTenthOfASecond() {
        var gate = IslandSwipeOwnershipGate()
        var probes = 0
        let probe = { probes += 1; return true }
        _ = gate.canHandleEvent(isNewGesture: true, isGestureActive: false, now: 0, probe: probe)
        for time in [0.016, 0.032, 0.048, 0.064, 0.080, 0.096] {
            XCTAssertTrue(gate.canContinuePreview(now: time, probe: probe))
        }
        XCTAssertEqual(probes, 1)
        XCTAssertTrue(gate.canContinuePreview(now: 0.1, probe: probe))
        XCTAssertEqual(probes, 2)
        for time in [0.112, 0.128, 0.144, 0.160, 0.176, 0.192] {
            XCTAssertTrue(gate.canContinuePreview(now: time, probe: probe))
        }
        XCTAssertEqual(probes, 2)
        XCTAssertTrue(gate.canContinuePreview(now: 0.201, probe: probe))
        XCTAssertEqual(probes, 3)
    }

    func testLostOwnershipStopsPreviewAtNextScheduledCheck() {
        var gate = IslandSwipeOwnershipGate()
        var probes = 0
        var isOwner = true
        let probe = { probes += 1; return isOwner }
        _ = gate.canHandleEvent(isNewGesture: true, isGestureActive: false, now: 0, probe: probe)
        isOwner = false
        XCTAssertTrue(gate.canContinuePreview(now: 0.099, probe: probe))
        XCTAssertFalse(gate.canContinuePreview(now: 0.1, probe: probe))
        XCTAssertFalse(gate.canHandleEvent(isNewGesture: false, isGestureActive: true, now: 0.11, probe: probe))
        XCTAssertEqual(probes, 2)
        isOwner = true
        XCTAssertTrue(gate.canHandleEvent(isNewGesture: true, isGestureActive: false, now: 0.12, probe: probe))
        XCTAssertEqual(probes, 3)
    }

    func testResetDiscardsOwnershipUntilNextBegan() {
        var gate = IslandSwipeOwnershipGate()
        var probes = 0
        let probe = { probes += 1; return true }
        _ = gate.canHandleEvent(isNewGesture: true, isGestureActive: false, now: 0, probe: probe)
        gate.reset()
        XCTAssertFalse(gate.canHandleEvent(isNewGesture: false, isGestureActive: true, now: 0.01, probe: probe))
        XCTAssertFalse(gate.canContinuePreview(now: 1, probe: probe))
        XCTAssertEqual(probes, 1)
        XCTAssertTrue(gate.canHandleEvent(isNewGesture: true, isGestureActive: false, now: 1.01, probe: probe))
        XCTAssertEqual(probes, 2)
    }

    func testInactiveSequenceDiscardsCachedOwnership() {
        var gate = IslandSwipeOwnershipGate()
        var probes = 0
        let probe = { probes += 1; return true }
        _ = gate.canHandleEvent(isNewGesture: true, isGestureActive: false, now: 0, probe: probe)
        XCTAssertFalse(gate.canHandleEvent(isNewGesture: false, isGestureActive: false, now: 0.01, probe: probe))
        XCTAssertFalse(gate.canHandleEvent(isNewGesture: false, isGestureActive: true, now: 0.02, probe: probe))
        XCTAssertEqual(probes, 1)
    }

    func testRejectedBeganDoesNotRetryOnEveryChangedEvent() {
        var gate = IslandSwipeOwnershipGate()
        var probes = 0
        let probe = { probes += 1; return false }
        XCTAssertFalse(gate.canHandleEvent(isNewGesture: true, isGestureActive: false, now: 0, probe: probe))
        for index in 1...120 {
            XCTAssertFalse(gate.canHandleEvent(isNewGesture: false, isGestureActive: true,
                                               now: Double(index) / 120, probe: probe))
        }
        XCTAssertEqual(probes, 1)
    }

    func testInvalidOrReversedClockDiscardsOwnership() {
        for time in [Double.nan, .infinity, -1] {
            var gate = IslandSwipeOwnershipGate()
            var probes = 0
            let probe = { probes += 1; return true }
            _ = gate.canHandleEvent(isNewGesture: true, isGestureActive: false, now: 0, probe: probe)
            XCTAssertFalse(gate.canContinuePreview(now: time, probe: probe))
            XCTAssertFalse(gate.canHandleEvent(isNewGesture: false, isGestureActive: true, now: 1, probe: probe))
            XCTAssertEqual(probes, 1)
        }
    }
}
