import SwiftUI

/// 管理灵动岛的 hover 轮询、自动收起、展开交互标记。
/// 从 NotchContentView 中提取，降低 God View 复杂度。
@MainActor
final class IslandHoverManager {
    // MARK: - State
    var isHovering = false
    var expandedByHover = false
    var expandedAt: Date = .distantPast
    var showContent = false
    var jumpMouseLocation: CGPoint?
    var lastCollapseAt: Date = .distantPast
    var expandPending = false
    var collapseAnimating = false
    var collapseGeneration = 0
    var expandedAutoHideWorkItem: DispatchWorkItem?
    var lastExpandedInteractionAt: Date = .distantPast
    var lastExpandedInteractionMarkAt: Date = .distantPast

    private var hoverTimer: Timer?

    // MARK: - Constants

    static let expandSpring = Animation.spring(response: 0.4, dampingFraction: 0.82)
    static let collapseSpring = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let contentFade = Animation.easeInOut(duration: 0.2)
    static let expandedInactivityAutoHideDelay: TimeInterval = 10

    struct TransitionTiming: Equatable {
        let expandStartDelay: TimeInterval
        let contentRevealDelay: TimeInterval
        let collapseCompletionDelay: TimeInterval
    }

    static func transitionTiming(disableAnimations: Bool) -> TransitionTiming {
        disableAnimations
            ? TransitionTiming(expandStartDelay: 0, contentRevealDelay: 0, collapseCompletionDelay: 0)
            : TransitionTiming(expandStartDelay: 0.05, contentRevealDelay: 0.12, collapseCompletionDelay: 0.45)
    }

    var transitionTiming: TransitionTiming {
        Self.transitionTiming(disableAnimations: disableAnimations)
    }

    // MARK: - External dependencies (set by NotchContentView)
    var disableAnimations = false
    var smartSuppression = false
    var autoCollapseDelay: TimeInterval = 3.0

    // MARK: - Hover polling

    func startHoverPolling(
        onMouseInside: @escaping () -> Void,
        onMouseOutsideHovering: @escaping () -> Void,
        onShouldCollapse: @escaping () -> Void,
        getIsExpanded: @escaping () -> Bool,
        getIsDragging: @escaping () -> Bool,
        getIsWindowVisible: @escaping () -> Bool,
        getMouseInFrame: @escaping () -> Bool,
        getObscuredByNotch: @escaping () -> Bool,
        onObscuredChanged: @escaping (Bool) -> Void
    ) {
        stopHoverPolling()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // This method is intentionally empty — the actual polling logic
                // remains in NotchContentView.pollMousePosition() because it depends
                // on too many view-level references. We keep the timer management here.
            }
        }
    }

    func stopHoverPolling() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    // MARK: - Auto-hide scheduling

    func cancelExpandedAutoHide() {
        expandedAutoHideWorkItem?.cancel()
        expandedAutoHideWorkItem = nil
    }

    func markExpandedInteraction(throttled: Bool = false, isExpanded: Bool) {
        guard isExpanded else { return }
        let now = Date()
        if throttled, now.timeIntervalSince(lastExpandedInteractionMarkAt) < 0.4 {
            return
        }
        lastExpandedInteractionMarkAt = now
        lastExpandedInteractionAt = now
        scheduleExpandedAutoHide(isExpanded: isExpanded, collapse: {})
    }

    func scheduleExpandedAutoHide(isExpanded: Bool, collapse: @escaping () -> Void) {
        cancelExpandedAutoHide()
        guard isExpanded else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.showContent else { return }
            let elapsed = Date().timeIntervalSince(self.lastExpandedInteractionAt)
            guard elapsed >= Self.expandedInactivityAutoHideDelay else {
                self.scheduleExpandedAutoHide(isExpanded: true, collapse: collapse)
                return
            }
            self.expandedByHover = false
            collapse()
        }
        expandedAutoHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.expandedInactivityAutoHideDelay, execute: workItem)
    }

    // MARK: - Collapse after delay (for interaction dismiss)

    func collapseAfterDelay(
        autoCollapseDelay: TimeInterval,
        hasInteraction: Bool,
        collapse: @escaping () -> Void
    ) {
        guard autoCollapseDelay > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + autoCollapseDelay) { [weak self] in
            if !hasInteraction {
                self?.expandedByHover = false
                collapse()
            }
        }
    }

    deinit {
        hoverTimer?.invalidate()
    }
}
