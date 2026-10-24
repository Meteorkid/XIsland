import XCTest
@testable import XIsland

final class ExpandedAutoCollapsePolicyTests: XCTestCase {
    private func delay(
        state: IslandState = .expanded,
        protectsInteraction: Bool = false,
        expandedByHover: Bool = false,
        visibleSessionCount: Int = 2,
        hoverExitDelay: TimeInterval = 0.5,
        inactivityDelay: TimeInterval = 10,
        interactionCompleted: Bool = false,
        interactionCompletionDelay: TimeInterval = 3
    ) -> TimeInterval? {
        ExpandedAutoCollapsePolicy.delay(
            state: state,
            protectsInteraction: protectsInteraction,
            expandedByHover: expandedByHover,
            visibleSessionCount: visibleSessionCount,
            hoverExitDelay: hoverExitDelay,
            inactivityDelay: inactivityDelay,
            interactionCompleted: interactionCompleted,
            interactionCompletionDelay: interactionCompletionDelay
        )
    }

    func testHoverExpandedPanelUsesHoverExitDelay() {
        XCTAssertEqual(delay(expandedByHover: true), 0.5)
    }

    func testManuallyExpandedEmptyPanelUsesHoverExitDelay() {
        XCTAssertEqual(delay(visibleSessionCount: 0), 0.5)
    }

    func testManuallyExpandedPanelWithSessionsUsesInactivityDelay() {
        XCTAssertEqual(delay(), 10)
    }

    func testCompletedInteractionUsesItsConfiguredDelay() {
        XCTAssertEqual(delay(state: .permission("session"), interactionCompleted: true), 3)
    }

    func testUsesShortestApplicablePositiveDelay() {
        XCTAssertEqual(delay(expandedByHover: true, inactivityDelay: 0.2, interactionCompleted: true), 0.2)
        XCTAssertEqual(delay(expandedByHover: true, hoverExitDelay: 0, interactionCompleted: true), 3)
        XCTAssertEqual(delay(inactivityDelay: 0, interactionCompleted: true, interactionCompletionDelay: 4), 4)
    }

    func testZeroDisablesEachPath() {
        XCTAssertNil(delay(expandedByHover: true, hoverExitDelay: 0, inactivityDelay: 0,
                           interactionCompleted: true, interactionCompletionDelay: 0))
        XCTAssertNil(delay(inactivityDelay: 0))
    }

    func testIgnoresInvalidConfiguredDelays() {
        XCTAssertNil(delay(expandedByHover: true, hoverExitDelay: .nan, inactivityDelay: -.infinity,
                           interactionCompleted: true, interactionCompletionDelay: -1))
    }

    func testCollapsedPanelCannotAutoCollapseAgain() {
        XCTAssertNil(delay(state: .collapsed, expandedByHover: true, interactionCompleted: true))
    }

    func testWaitingInteractionProtectsEveryExpandedState() {
        let states: [IslandState] = [.expanded, .permission("s"), .question("s"), .planReview("s")]
        for state in states {
            XCTAssertNil(delay(state: state, protectsInteraction: true,
                               expandedByHover: true, interactionCompleted: true))
        }
    }
}
