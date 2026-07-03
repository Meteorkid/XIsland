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
    private let threshold: CGFloat = 45
    /// 手势冷却时间（秒），防止连续触发
    private let cooldown: TimeInterval = 0.5
    /// 横向与纵向位移的最小比例（横向必须明显大于纵向）
    private let axisRatio: CGFloat = 1.5

    // MARK: - 状态

    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var gestureStartTime: Date?
    private var hasTriggered = false
    private var lastTriggerTime: Date = .distantPast

    /// 处理滚动事件，返回识别结果
    func handleScroll(event: NSEvent) -> SwipeResult {
        // 冷却期内忽略
        guard Date().timeIntervalSince(lastTriggerTime) > cooldown else {
            return .inProgress
        }

        // 仅处理触控板精确滚动
        guard event.hasPreciseScrollingDeltas else {
            reset()
            return .inProgress
        }

        // 忽略惯性滚动（phase 为 .ended 或 .mayBegin 表示惯性阶段）
        let phase = event.phase
        if phase == .ended || phase == .mayBegin {
            reset()
            return .inProgress
        }

        // 新手势开始时重置
        if gestureStartTime == nil {
            gestureStartTime = Date()
        }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        // 方向判断：横向必须明显大于纵向
        guard abs(dx) > abs(dy) * axisRatio else {
            // 纵向为主，重置横向累计
            accumulatedX = 0
            return .inProgress
        }

        accumulatedX += dx
        accumulatedY += dy

        // 累计阈值检查
        guard abs(accumulatedX) >= threshold else {
            return .inProgress
        }

        // 触发切换
        hasTriggered = true
        let direction: SwipeDirection = accumulatedX > 0 ? .right : .left
        lastTriggerTime = Date()

        // 延迟重置，允许手势完成后清理
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.reset()
        }

        return .triggered(direction)
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
