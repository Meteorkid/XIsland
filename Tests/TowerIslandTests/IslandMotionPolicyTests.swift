import XCTest
@testable import XIsland

final class IslandMotionPolicyTests: XCTestCase {
    func testSystemAndApplicationPreferencesEachStopContinuousMotion() {
        for appReduceMotion in [false, true] {
            for systemReduceMotion in [false, true] {
                let policy = IslandMotionPolicy(
                    reduceMotion: appReduceMotion,
                    systemReduceMotion: systemReduceMotion,
                    disableAnimations: false
                )

                XCTAssertEqual(policy.allowsContinuousAnimation, !appReduceMotion && !systemReduceMotion)
            }
        }
    }

    func testDisabledAnimationsOverrideBothMotionPreferences() {
        for appReduceMotion in [false, true] {
            for systemReduceMotion in [false, true] {
                XCTAssertFalse(IslandMotionPolicy(
                    reduceMotion: appReduceMotion,
                    systemReduceMotion: systemReduceMotion,
                    disableAnimations: true
                ).allowsContinuousAnimation)
            }
        }
    }
}
