import Foundation

struct IslandMotionPolicy {
    let reduceMotion: Bool
    let systemReduceMotion: Bool
    let disableAnimations: Bool

    var allowsContinuousAnimation: Bool {
        !disableAnimations && !reduceMotion && !systemReduceMotion
    }
}
