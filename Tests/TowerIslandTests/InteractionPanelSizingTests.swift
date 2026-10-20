import XCTest
@testable import XIsland

final class InteractionPanelSizingTests: XCTestCase {
    private let interactionStates: [IslandState] = [
        .permission("permission"), .question("question"), .planReview("plan")
    ]

    func testSingleInteractionHasRoomForItsActions() {
        for state in interactionStates {
            XCTAssertEqual(height(state, count: 1), 384, "\(state)")
        }
    }

    func testInteractionMinimumAlsoAppliesWhileSessionCountChanges() {
        for state in interactionStates {
            for count in [0, 1, 2, 3] {
                XCTAssertEqual(height(state, count: count), 384, "\(state), count=\(count)")
            }
            XCTAssertEqual(height(state, count: 4), 414)
            XCTAssertEqual(height(state, count: 20), 484)
        }
    }

    func testInteractionMinimumRespectsSmallerContentHeightLimit() {
        for state in interactionStates {
            for limit: CGFloat in [0, 160, 319, 320] {
                XCTAssertEqual(height(state, count: 1, limit: limit), limit + 64)
            }
            XCTAssertEqual(height(state, count: 1, limit: 700), 384)
        }
    }

    func testOrdinarySessionListRemainsCompact() {
        XCTAssertEqual(height(.expanded, count: 0), 94)
        XCTAssertEqual(height(.expanded, count: 1), 174)
        XCTAssertEqual(height(.expanded, count: 3), 334)
        XCTAssertEqual(height(.expanded, count: 20), 484)
    }

    func testWindowTargetMatchesRenderedPanelHeight() {
        for state in [.expanded] + interactionStates {
            for count in [0, 1, 4, 20] {
                for limit: CGFloat in [160, 320, 420, 700] {
                    let target = IslandSizeCalculator.targetSize(
                        for: state, visibleSessionCount: count,
                        panelWidth: 380, panelMaxHeight: limit
                    )
                    XCTAssertEqual(target.width, 380)
                    XCTAssertEqual(target.height, height(state, count: count, limit: limit))
                }
            }
        }
    }

    func testExpandedShapeCacheMatchesRenderedList() {
        for count in [0, 1, 4, 20] {
            XCTAssertEqual(
                IslandSizeCalculator.expandedPanelShapeHeight(visibleSessionCount: count, panelMaxHeight: 420),
                height(.expanded, count: count)
            )
        }
    }

    func testWindowTargetIncludesActivityLogForEveryExpandedState() {
        for state in [.expanded] + interactionStates {
            for count in [1, 20] {
                let target = IslandSizeCalculator.targetSize(
                    for: state, visibleSessionCount: count,
                    panelWidth: 380, panelMaxHeight: 420, activityLogExpanded: true
                )
                let renderedHeight = IslandSizeCalculator.expandedHeight(
                    for: state, visibleSessionCount: count,
                    panelMaxHeight: 420, activityLogExpanded: true
                )
                XCTAssertEqual(target.height, renderedHeight)
                XCTAssertEqual(renderedHeight, height(state, count: count) + 140)
            }
        }
    }

    func testCollapsedStateHasNoExpandedHeight() {
        XCTAssertEqual(height(.collapsed, count: 1), 0)
        XCTAssertEqual(IslandSizeCalculator.expandedHeight(
            for: .collapsed, visibleSessionCount: 1, panelMaxHeight: 420, activityLogExpanded: true
        ), 0)
    }

    private func height(_ state: IslandState, count: Int, limit: CGFloat = 420) -> CGFloat {
        IslandSizeCalculator.expandedHeight(
            for: state, visibleSessionCount: count,
            panelMaxHeight: limit, activityLogExpanded: false
        )
    }
}
