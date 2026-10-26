import Foundation

/// 手势开始时确认所有权；跟手事件复用结果，悬停轮询限频复核失权。
struct IslandSwipeOwnershipGate {
    private let recheckInterval: TimeInterval = 0.1
    private var lastCheckedAt: TimeInterval?
    private var ownsGesture = false

    mutating func canHandleEvent(
        isNewGesture: Bool,
        isGestureActive: Bool,
        now: TimeInterval,
        probe: () -> Bool
    ) -> Bool {
        if isNewGesture {
            reset()
            return sample(now: now, probe: probe)
        }
        guard isGestureActive else {
            reset()
            return false
        }
        return ownsGesture
    }

    mutating func canContinuePreview(now: TimeInterval, probe: () -> Bool) -> Bool {
        guard ownsGesture, let lastCheckedAt else { return false }
        guard now.isFinite, now >= lastCheckedAt else {
            reset()
            return false
        }
        guard now - lastCheckedAt >= recheckInterval else { return true }
        return sample(now: now, probe: probe)
    }

    mutating func reset() {
        lastCheckedAt = nil
        ownsGesture = false
    }

    private mutating func sample(now: TimeInterval, probe: () -> Bool) -> Bool {
        guard now.isFinite else { return false }
        lastCheckedAt = now
        ownsGesture = probe()
        return ownsGesture
    }
}
