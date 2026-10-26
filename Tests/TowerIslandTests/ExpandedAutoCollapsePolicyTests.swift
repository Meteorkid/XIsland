import XCTest
@testable import XIsland

final class ExpandedAutoCollapsePolicyTests: XCTestCase {
    private func delay(
        state: IslandState = .expanded,
        protectsInteraction: Bool = false,
        isEnabled: Bool = true,
        configuredDelay: TimeInterval = 3
    ) -> TimeInterval? {
        ExpandedAutoCollapsePolicy.delay(
            state: state,
            protectsInteraction: protectsInteraction,
            isEnabled: isEnabled,
            configuredDelay: configuredDelay
        )
    }

    func testEveryExpandedStateUsesTheSameConfiguredDelay() {
        let states: [IslandState] = [.expanded, .permission("s"), .question("s"), .planReview("s")]
        for state in states {
            XCTAssertEqual(delay(state: state, configuredDelay: 0.15), 0.15)
            XCTAssertEqual(delay(state: state, configuredDelay: 5), 5)
        }
    }

    func testZeroMeansImmediateInsteadOfDisabled() {
        let states: [IslandState] = [.expanded, .permission("s"), .question("s"), .planReview("s")]
        for state in states {
            XCTAssertEqual(delay(state: state, configuredDelay: 0), 0)
        }
        var countdown = ExpandedAutoCollapseCountdown()
        XCTAssertTrue(countdown.update(isPointerInside: false, delay: delay(configuredDelay: 0),
                                       now: Date(timeIntervalSince1970: 1_000)))
    }

    func testIndependentSwitchDisablesZeroAndPositiveDelays() {
        for configuredDelay in [0.0, 0.15, 5, 600] {
            XCTAssertNil(delay(isEnabled: false, configuredDelay: configuredDelay))
        }
    }

    func testIgnoresInvalidConfiguredDelays() {
        for invalidDelay: TimeInterval in [-1, .nan, .infinity, -.infinity] {
            XCTAssertNil(delay(configuredDelay: invalidDelay))
        }
    }

    func testCollapsedPanelCannotAutoCollapseAgain() {
        XCTAssertNil(delay(state: .collapsed, configuredDelay: 0))
        XCTAssertNil(delay(state: .collapsed, configuredDelay: 5))
    }

    func testWaitingInteractionProtectsEveryExpandedState() {
        let states: [IslandState] = [.expanded, .permission("s"), .question("s"), .planReview("s")]
        for state in states {
            XCTAssertNil(delay(state: state, protectsInteraction: true, configuredDelay: 0))
            XCTAssertNil(delay(state: state, protectsInteraction: true, configuredDelay: 5))
        }
    }

    func testReenablingStartsANewCountdownRatherThanReusingTimeWhileDisabled() {
        let start = Date(timeIntervalSince1970: 1_000)
        var countdown = ExpandedAutoCollapseCountdown()
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: delay(), now: start))
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: delay(isEnabled: false),
                                         now: start.addingTimeInterval(2)))
        XCTAssertNil(countdown.pointerExitedAt)
        let enabledAgain = start.addingTimeInterval(30)
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: delay(), now: enabledAgain))
        XCTAssertFalse(countdown.update(isPointerInside: false, delay: delay(),
                                         now: enabledAgain.addingTimeInterval(2.9)))
        XCTAssertTrue(countdown.update(isPointerInside: false, delay: delay(),
                                        now: enabledAgain.addingTimeInterval(3)))
    }
}
