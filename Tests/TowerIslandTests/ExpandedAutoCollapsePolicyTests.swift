import XCTest
@testable import XIsland

final class ExpandedAutoCollapsePolicyTests: XCTestCase {
    func testHoverExpandedPanelCollapsesAfterPointerLeaves() {
        XCTAssertTrue(
            ExpandedAutoCollapsePolicy.shouldCollapseOnMouseExit(
                isPointerInside: false,
                state: .expanded,
                expandedByHover: true,
                visibleSessionCount: 2,
                elapsedSinceExpand: 0.6
            )
        )
    }

    func testManuallyExpandedEmptyPanelCollapsesAfterPointerLeaves() {
        XCTAssertTrue(
            ExpandedAutoCollapsePolicy.shouldCollapseOnMouseExit(
                isPointerInside: false,
                state: .expanded,
                expandedByHover: false,
                visibleSessionCount: 0,
                elapsedSinceExpand: 0.6
            )
        )
    }
}
