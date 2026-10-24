import Foundation

/// 所有自动收起路径共用资格判断，并从本次指针离开后采用适用的最短正延时。
enum ExpandedAutoCollapsePolicy {
    static func delay(
        state: IslandState,
        protectsInteraction: Bool,
        expandedByHover: Bool,
        visibleSessionCount: Int,
        hoverExitDelay: TimeInterval,
        inactivityDelay: TimeInterval,
        interactionCompleted: Bool,
        interactionCompletionDelay: TimeInterval
    ) -> TimeInterval? {
        guard state != .collapsed, !protectsInteraction else { return nil }

        var delays = [inactivityDelay]
        if state == .expanded && (expandedByHover || visibleSessionCount == 0) {
            delays.append(hoverExitDelay)
        }
        if interactionCompleted {
            delays.append(interactionCompletionDelay)
        }
        return delays.filter { $0.isFinite && $0 > 0 }.min()
    }
}
