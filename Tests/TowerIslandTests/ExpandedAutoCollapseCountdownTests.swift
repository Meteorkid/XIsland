import XCTest
@testable import XIsland

final class ExpandedAutoCollapseCountdownTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testStationaryPointerInsideNeverStartsCountdown() {
        var countdown = ExpandedAutoCollapseCountdown()
        for elapsed in [0.0, 3, 10, 600] {
            XCTAssertFalse(countdown.update(isPointerInside: true, delay: 0.5,
                                             now: start.addingTimeInterval(elapsed)))
            XCTAssertNil(countdown.pointerExitedAt)
        }
    }

    func testLongHoverStillRequiresFullDelayAfterExit() {
        var countdown = ExpandedAutoCollapseCountdown()
        XCTAssertFalse(countdown.update(isPointerInside: true, delay: 0.5, now: start))
        let exit = start.addingTimeInterval(600)
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: 0.5, now: exit))
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: 0.5, now: exit.addingTimeInterval(0.49)))
        XCTAssertTrue(countdown.update(isPointerInside: false, delay: 0.5, now: exit.addingTimeInterval(0.5)))
    }

    func testCollapsesWhenConfiguredDelayHasFullyElapsed() {
        var countdown = ExpandedAutoCollapseCountdown()
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: 0.5, now: start))
        XCTAssertTrue(countdown.update(isPointerInside: false, delay: 0.5, now: start.addingTimeInterval(0.5)))
    }

    func testReentryCancelsCountdownAndNextExitStartsFullDelay() {
        var countdown = ExpandedAutoCollapseCountdown()
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: 3, now: start))
        XCTAssertFalse(countdown.update(isPointerInside: true, delay: 3, now: start.addingTimeInterval(2)))
        XCTAssertNil(countdown.pointerExitedAt)
        XCTAssertFalse(countdown.update(isPointerInside: true, delay: 3, now: start.addingTimeInterval(5)))

        let nextExit = start.addingTimeInterval(6)
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: 3, now: nextExit))
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: 3, now: nextExit.addingTimeInterval(2.9)))
        XCTAssertTrue(countdown.update(isPointerInside: false, delay: 3, now: nextExit.addingTimeInterval(3)))
    }

    func testReentryWinsEvenWhenOldDeadlineHasPassed() {
        var countdown = ExpandedAutoCollapseCountdown()
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: 0.5, now: start))
        XCTAssertFalse(countdown.update(isPointerInside: true, delay: 0.5, now: start.addingTimeInterval(1)))
        XCTAssertNil(countdown.pointerExitedAt)
    }

    func testPermissionProtectionCancelsAndReleaseRestartsCountdown() {
        var countdown = ExpandedAutoCollapseCountdown()
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: 3, now: start))
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: nil, now: start.addingTimeInterval(2)))
        XCTAssertNil(countdown.pointerExitedAt)
        let release = start.addingTimeInterval(10)
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: 3, now: release))
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: 3, now: release.addingTimeInterval(2.9)))
        XCTAssertTrue(countdown.update(isPointerInside: false, delay: 3, now: release.addingTimeInterval(3)))
    }

    func testChangedDelayStartsNewFullCountdown() {
        var countdown = ExpandedAutoCollapseCountdown()
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: 10, now: start))
        let change = start.addingTimeInterval(9)
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: 3, now: change))
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: 3, now: change.addingTimeInterval(2.9)))
        XCTAssertTrue(countdown.update(isPointerInside: false, delay: 3, now: change.addingTimeInterval(3)))
    }

    func testHiddenCollapsedOrReopenedPanelCannotReusePreviousCountdown() {
        var countdown = ExpandedAutoCollapseCountdown()
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: 3, now: start))
        countdown.reset()
        XCTAssertNil(countdown.pointerExitedAt)
        let reopen = start.addingTimeInterval(10)
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: 3, now: reopen))
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: 3, now: reopen.addingTimeInterval(2.9)))
        XCTAssertTrue(countdown.update(isPointerInside: false, delay: 3, now: reopen.addingTimeInterval(3)))
    }

    func testDisabledOrInvalidDelayCancelsPendingCountdown() {
        for disabledDelay: TimeInterval? in [nil, 0, -1, .nan, .infinity] {
            var countdown = ExpandedAutoCollapseCountdown()
            XCTAssertFalse(countdown.update(isPointerInside: false, delay: 3, now: start))
            XCTAssertFalse(countdown.update(isPointerInside: false, delay: disabledDelay,
                                             now: start.addingTimeInterval(10)))
            XCTAssertNil(countdown.pointerExitedAt)
        }
    }
}
