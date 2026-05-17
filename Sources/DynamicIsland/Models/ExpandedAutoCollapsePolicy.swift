import Foundation

enum ExpandedAutoCollapsePolicy {
    static func shouldCollapseOnMouseExit(
        isPointerInside: Bool,
        state: IslandState,
        expandedByHover: Bool,
        visibleSessionCount: Int,
        hoverExitDelay: TimeInterval,
        elapsedSinceExpand: TimeInterval
    ) -> Bool {
        guard hoverExitDelay > 0 else { return false }
        guard !isPointerInside, state == .expanded else { return false }
        guard expandedByHover || visibleSessionCount == 0 else { return false }
        return elapsedSinceExpand > hoverExitDelay
    }
}
