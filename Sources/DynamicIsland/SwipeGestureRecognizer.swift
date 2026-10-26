import AppKit

/// 横滑切换方向沿用 AppKit 已应用自然滚动设置后的横向增量。
enum SwipeDirection: String, Equatable, Sendable {
    case left
    case right

    var sign: CGFloat { self == .left ? -1 : 1 }
}

/// 只有手指结束滚动后才提交；进度为有符号的累计位移（pt）。
enum SwipeResult: Equatable {
    case inProgress
    case progress(CGFloat)
    case cancelled
    case triggered(SwipeDirection)
}

final class SwipeGestureRecognizer {
    private enum Axis {
        case undecided
        case horizontal
        case vertical
    }

    private let axisLockDistance: CGFloat = 6
    private let cooldown: TimeInterval = 0.5
    private var axis: Axis?
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var threshold: CGFloat = 0
    private var axisRatio: CGFloat = 0
    private var lastTriggerTime: Date = .distantPast
    private var suppressedUntil: Date = .distantPast

    func handleScroll(event: NSEvent) -> SwipeResult {
        handleScroll(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            isPrecise: event.hasPreciseScrollingDeltas,
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            now: Date()
        )
    }

    func handleScroll(
        deltaX: CGFloat,
        deltaY: CGFloat,
        isPrecise: Bool,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        now: Date
    ) -> SwipeResult {
        guard deltaX.isFinite, deltaY.isFinite, now.timeIntervalSinceReferenceDate.isFinite,
              isPrecise, momentumPhase.isEmpty,
              now >= suppressedUntil else {
            return cancelActiveGesture()
        }

        if phase.contains(.cancelled) || phase.contains(.mayBegin) {
            return cancelActiveGesture()
        }

        // 没有 phase 的精确滚轮没有可靠的松手边界，不参与切换。
        guard !phase.isEmpty else { return cancelActiveGesture() }

        let replacesPreview = phase.contains(.began) && axis == .horizontal
        if phase.contains(.began) {
            reset()
            guard now.timeIntervalSince(lastTriggerTime) > cooldown else { return .inProgress }
            let sensitivity = IslandIntegrationSettings.swipeSensitivity
            threshold = sensitivity.threshold
            axisRatio = sensitivity.axisRatio
            axis = .undecided
        }

        // 不接管半途进入命中区域的 changed，也不消费已结束手势的尾部。
        guard axis != nil else { return .inProgress }
        let nextX = accumulatedX + deltaX
        let nextY = accumulatedY + deltaY
        guard nextX.isFinite, nextY.isFinite else { return cancelActiveGesture() }
        accumulatedX = nextX
        accumulatedY = nextY

        if axis == .undecided,
           max(abs(accumulatedX), abs(accumulatedY)) >= axisLockDistance {
            axis = abs(accumulatedX) > abs(accumulatedY) * axisRatio ? .horizontal : .vertical
        }

        if phase.contains(.ended) {
            let shouldCommit = axis == .horizontal && abs(accumulatedX) >= threshold
            let direction: SwipeDirection = accumulatedX > 0 ? .right : .left
            let result: SwipeResult = shouldCommit ? .triggered(direction)
                : (axis == .horizontal ? .cancelled : .inProgress)
            reset()
            if shouldCommit { lastTriggerTime = now }
            return result
        }

        if axis == .horizontal { return .progress(accumulatedX) }
        return replacesPreview ? .progress(0) : .inProgress
    }

    /// 目标接管后丢弃来源手势的尾部；只有新的 began 可以重新开始。
    func suppressUntilNextGesture() {
        reset()
    }

    /// 保留时间抑制接口；抑制到期也必须等到新的 began。
    func suppress(for duration: TimeInterval, now: Date = Date()) {
        reset()
        guard duration.isFinite, now.timeIntervalSinceReferenceDate.isFinite else { return }
        let deadline = now.addingTimeInterval(max(0, duration))
        guard deadline.timeIntervalSinceReferenceDate.isFinite else { return }
        suppressedUntil = max(suppressedUntil, deadline)
    }

    func reset() {
        axis = nil
        accumulatedX = 0
        accumulatedY = 0
    }

    /// 包括尚未锁轴的开始阶段，供事件入口保留本次手势的所有权。
    var isActive: Bool { axis != nil }
    var hasLockedVerticalAxis: Bool { axis == .vertical }

    /// 判轴前先保留横向意图，避免轻微纵向分量提前展开面板。
    var consumesHorizontalScroll: Bool {
        axis == .horizontal || (axis == .undecided && abs(accumulatedX) > abs(accumulatedY))
    }

    private func cancelActiveGesture() -> SwipeResult {
        let result: SwipeResult = axis == .horizontal ? .cancelled : .inProgress
        reset()
        return result
    }
}
