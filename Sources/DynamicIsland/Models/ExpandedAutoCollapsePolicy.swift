import Foundation

/// 展开态自动折叠策略。
///
/// 决定指针离开灵动岛后，处于展开态的面板是否应当自动收拢。折叠成立需同时满足：
/// - `hoverExitDelay` 为正值（设为 0 即禁用「指针离开后折叠」这条路径）；
/// - 指针已离开面板，且面板当前处于 `.expanded`；
/// - 本次展开由悬停触发，或面板已无可视会话；
/// - 距展开时刻已经超过 `hoverExitDelay` 秒。
enum ExpandedAutoCollapsePolicy {
    static func shouldCollapseOnMouseExit(
        isPointerInside: Bool,
        state: IslandState,
        expandedByHover: Bool,
        visibleSessionCount: Int,
        hoverExitDelay: TimeInterval,
        elapsedSinceExpand: TimeInterval
    ) -> Bool {
        let collapseEnabled = hoverExitDelay > 0
        let pointerHasLeftExpandedPanel = !isPointerInside && state == .expanded
        let panelMayAutoCollapse = expandedByHover || visibleSessionCount == 0
        let gracePeriodElapsed = elapsedSinceExpand > hoverExitDelay

        return collapseEnabled
            && pointerHasLeftExpandedPanel
            && panelMayAutoCollapse
            && gracePeriodElapsed
    }
}
