import XCTest
@testable import XIsland

final class CollapsedPillViewTests: XCTestCase {
    func testCollapsedCountsAlternateInFiveSecondSlots() {
        for elapsed in [0.0, 1.0, 4.999, 10.0, 14.999] {
            XCTAssertEqual(CollapsedPillView.countKind(isExpanded: false, at: Date(timeIntervalSince1970: elapsed)), .active)
        }
        for elapsed in [5.0, 6.0, 9.999, 15.0] {
            XCTAssertEqual(CollapsedPillView.countKind(isExpanded: false, at: Date(timeIntervalSince1970: elapsed)), .total)
        }
    }

    func testExpandedCountsAlwaysShowTotal() {
        for elapsed in [0.0, 4.999, 5.0, 10.0] {
            XCTAssertEqual(CollapsedPillView.countKind(isExpanded: true, at: Date(timeIntervalSince1970: elapsed)), .total)
        }
    }

    func testCountRotationContinuesWithAllMotionDisabled() {
        let policy = IslandMotionPolicy(reduceMotion: true, systemReduceMotion: true, disableAnimations: true)
        XCTAssertFalse(policy.allowsContinuousAnimation)
        // 计数是状态刷新，周期不受动画策略影响。
        XCTAssertEqual(CollapsedPillView.countKind(isExpanded: false, at: Date(timeIntervalSince1970: 0)), .active)
        XCTAssertEqual(CollapsedPillView.countKind(isExpanded: false, at: Date(timeIntervalSince1970: 5)), .total)
    }
}
