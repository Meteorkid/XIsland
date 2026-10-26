import Foundation

/// 切换事务之外的展示代数：视图未挂载时保留准备请求，旧动画不能接管新显示。
struct IslandHandoffState {
    private(set) var generation: UInt64 = 0
    private(set) var pendingPreparation: UInt64?
    private(set) var pendingPresentation: UInt64?
    private(set) var isPresentingInbound = false
    private(set) var isHoverSuppressed = false
    private(set) var isFadingOut = false

    mutating func beginInbound() -> UInt64 {
        generation &+= 1
        pendingPreparation = generation
        pendingPresentation = nil
        isPresentingInbound = false
        isHoverSuppressed = true
        isFadingOut = false
        return generation
    }

    mutating func consumePreparation(_ generation: UInt64) -> Bool {
        guard pendingPreparation == generation, self.generation == generation else { return false }
        pendingPreparation = nil
        pendingPresentation = generation
        return true
    }

    mutating func beginPresentation(_ generation: UInt64) -> Bool {
        guard self.generation == generation, pendingPresentation == generation else { return false }
        pendingPresentation = nil
        isPresentingInbound = true
        return true
    }

    mutating func finishPresentation(_ generation: UInt64) -> Bool {
        guard self.generation == generation, isPresentingInbound else { return false }
        isPresentingInbound = false
        return true
    }

    mutating func cancelPresentation() {
        generation &+= 1
        pendingPreparation = nil
        pendingPresentation = nil
        isPresentingInbound = false
        isFadingOut = false
    }

    mutating func beginFadeOut() -> UInt64? {
        guard !isFadingOut else { return nil }
        generation &+= 1
        pendingPreparation = nil
        pendingPresentation = nil
        isPresentingInbound = false
        isFadingOut = true
        return generation
    }

    mutating func finishFadeOut(_ generation: UInt64) -> Bool {
        guard self.generation == generation, isFadingOut else { return false }
        isFadingOut = false
        return true
    }

    /// 必须传真实几何检测结果，不能用收起动画期间人为置 false 的交互状态。
    mutating func observePointer(isInside: Bool) -> Bool {
        // 准备完成前仍可能使用旧屏幕的 frame，不能据此认定指针已经离开。
        guard pendingPreparation == nil else { return isHoverSuppressed }
        if !isInside { isHoverSuppressed = false }
        return isHoverSuppressed
    }

    func shouldRestoreContent(
        preparedGeneration: UInt64?, isWindowVisible: Bool,
        didPresentWindow: Bool, hiddenByIslandSwitch: Bool
    ) -> Bool {
        guard let preparedGeneration else { return false }
        return (didPresentWindow || isWindowVisible) && preparedGeneration != generation
            && pendingPreparation == nil && pendingPresentation == nil
            && !isPresentingInbound && !hiddenByIslandSwitch && !isFadingOut
    }

    static func inboundContentDuration(reduceMotion: Bool) -> TimeInterval { reduceMotion ? 0 : 0.15 }
    static func outboundDuration(reduceMotion: Bool) -> TimeInterval { reduceMotion ? 0 : 0.12 }
}
