import AppKit

/// 横滑切换手势方向
enum SwipeDirection {
    case left
    case right
}

/// 横滑切换手势识别结果
enum SwipeResult {
    case inProgress
    case triggered(SwipeDirection)
}

/// 触控板横滑切换手势识别器
/// 用于在 XNook 和 X Island 之间切换
final class SwipeGestureRecognizer {
    // MARK: - 配置

    /// 横向累计位移触发阈值（pt）
    private var threshold: CGFloat {
        IslandIntegrationSettings.swipeSensitivity.threshold
    }
    /// 手势冷却时间（秒），防止连续触发
    private let cooldown: TimeInterval = 0.5
    /// 横向与纵向位移的最小比例（横向必须明显大于纵向）
    private var axisRatio: CGFloat {
        IslandIntegrationSettings.swipeSensitivity.axisRatio
    }

    // MARK: - 状态

    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var gestureStartTime: Date?
    private var hasTriggered = false
    private var lastTriggerTime: Date = .distantPast
    private var suppressedUntil: Date = .distantPast

    /// 处理滚动事件，返回识别结果
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
        guard momentumPhase.isEmpty else {
            reset()
            return .inProgress
        }

        guard now >= suppressedUntil else {
            reset()
            return .inProgress
        }

        // 冷却期内忽略
        guard now.timeIntervalSince(lastTriggerTime) > cooldown else {
            return .inProgress
        }

        // 仅处理触控板精确滚动
        guard isPrecise else {
            reset()
            return .inProgress
        }

        // 手势结束或取消时清理累计状态
        if phase.contains(.ended) || phase.contains(.cancelled) || phase.contains(.mayBegin) {
            reset()
            return .inProgress
        }

        if phase.contains(.began) {
            reset()
        }

        // 新手势开始时重置
        if gestureStartTime == nil {
            gestureStartTime = now
        }

        // 方向判断：横向必须明显大于纵向
        guard abs(deltaX) > abs(deltaY) * axisRatio else {
            // 纵向为主，重置横向累计
            accumulatedX = 0
            return .inProgress
        }

        accumulatedX += deltaX
        accumulatedY += deltaY

        // 累计阈值检查
        guard abs(accumulatedX) >= threshold else {
            return .inProgress
        }

        // 触发切换
        hasTriggered = true
        let direction: SwipeDirection = accumulatedX > 0 ? .right : .left
        lastTriggerTime = now

        // 延迟重置，允许手势完成后清理
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.reset()
        }

        return .triggered(direction)
    }

    /// 目标岛刚显示时，暂时忽略来源手势的剩余事件。
    func suppress(for duration: TimeInterval, now: Date = Date()) {
        suppressedUntil = max(suppressedUntil, now.addingTimeInterval(duration))
        reset()
    }

    /// 重置手势状态
    func reset() {
        accumulatedX = 0
        accumulatedY = 0
        gestureStartTime = nil
        hasTriggered = false
    }

    /// 是否正在活跃手势中
    var isActive: Bool {
        gestureStartTime != nil && !hasTriggered
    }
}
