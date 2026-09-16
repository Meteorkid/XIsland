import XCTest
@testable import XIsland

final class MarqueeTextTests: XCTestCase {
    private let motion = IslandMotionPolicy(
        reduceMotion: false,
        systemReduceMotion: false,
        disableAnimations: false
    )

    func testTextThatFitsDoesNotScheduleContinuousUpdates() {
        for width: CGFloat in [0, 80, 100, 104] {
            XCTAssertFalse(MarqueeText.shouldAnimate(
                textWidth: width, availableWidth: 100, speed: 25,
                motionPolicy: motion, isVisible: true
            ))
        }
    }

    func testOverflowScrollsOnlyWhenVisibleAndSpeedIsPositive() {
        XCTAssertTrue(MarqueeText.shouldAnimate(
            textWidth: 200, availableWidth: 100, speed: 25,
            motionPolicy: motion, isVisible: true
        ))
        XCTAssertFalse(MarqueeText.shouldAnimate(
            textWidth: 200, availableWidth: 100, speed: 0,
            motionPolicy: motion, isVisible: true
        ))
        XCTAssertFalse(MarqueeText.shouldAnimate(
            textWidth: 200, availableWidth: 100, speed: 25,
            motionPolicy: motion, isVisible: false
        ))
    }

    func testMotionPreferencesStopLongTextWithoutChangingItsContent() {
        for policy in [
            IslandMotionPolicy(reduceMotion: true, systemReduceMotion: false, disableAnimations: false),
            IslandMotionPolicy(reduceMotion: false, systemReduceMotion: true, disableAnimations: false),
            IslandMotionPolicy(reduceMotion: false, systemReduceMotion: false, disableAnimations: true),
        ] {
            XCTAssertFalse(MarqueeText.shouldAnimate(
                textWidth: 200, availableWidth: 100, speed: 25,
                motionPolicy: policy, isVisible: true
            ))
        }
    }

    func testScrollingPreservesInitialReadingPauseAndTravelSpeed() {
        XCTAssertEqual(MarqueeText.scrollOffset(textWidth: 200, availableWidth: 100, speed: 25, elapsed: 1.4), 0)
        XCTAssertEqual(MarqueeText.scrollOffset(textWidth: 200, availableWidth: 100, speed: 25, elapsed: 2.5), -25, accuracy: 0.001)
        XCTAssertEqual(MarqueeText.scrollOffset(textWidth: 200, availableWidth: 100, speed: 25, elapsed: 6.2), 0, accuracy: 0.001)
    }

    func testStoppedOrUnmeasuredTextHasNoOffset() {
        XCTAssertEqual(MarqueeText.scrollOffset(textWidth: 80, availableWidth: 100, speed: 25, elapsed: 100), 0)
        XCTAssertEqual(MarqueeText.scrollOffset(textWidth: 200, availableWidth: 100, speed: 0, elapsed: 100), 0)
        XCTAssertEqual(MarqueeText.scrollOffset(textWidth: 200, availableWidth: 100, speed: 25, elapsed: -1), 0)
    }
}
