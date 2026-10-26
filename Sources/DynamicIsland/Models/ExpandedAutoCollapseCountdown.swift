import Foundation

/// 只累计本次连续离开区域的时间；无独立延迟回调，重入后旧倒计时不会再触发。
struct ExpandedAutoCollapseCountdown: Equatable {
    private(set) var pointerExitedAt: Date?
    private var activeDelay: TimeInterval?

    mutating func update(isPointerInside: Bool, delay: TimeInterval?, now: Date) -> Bool {
        guard !isPointerInside, let delay, delay.isFinite, delay >= 0 else {
            reset()
            return false
        }

        if pointerExitedAt == nil || activeDelay != delay {
            pointerExitedAt = now
            activeDelay = delay
        }
        guard let pointerExitedAt else { return false }
        return now.timeIntervalSince(pointerExitedAt) >= delay
    }

    mutating func reset() {
        pointerExitedAt = nil
        activeDelay = nil
    }
}
