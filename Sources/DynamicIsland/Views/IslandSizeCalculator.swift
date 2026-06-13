import SwiftUI

/// 统一灵动岛高度/宽度计算，消除 NotchContentView 中的重复逻辑。
enum IslandSizeCalculator {
    static let expandedPanelHeaderHeight: CGFloat = 48
    static let expandedPanelBottomInset: CGFloat = 16
    static let collapsedShapeHeight: CGFloat = 32
    static let collapsedPillWidthNotched: CGFloat = 276

    // MARK: - Collapsed

    static func pillWidth(
        islandObscuredByNotch: Bool,
        visibleSessionCount: Int
    ) -> CGFloat {
        if islandObscuredByNotch { return collapsedPillWidthNotched }
        let n = visibleSessionCount
        if n == 0 { return 180 }
        let icon: CGFloat = 22
        let gap: CGFloat = 8
        let horizontalPadding: CGFloat = 40
        let w = horizontalPadding + CGFloat(n) * icon + CGFloat(max(0, n - 1)) * gap
        return min(max(w, 160), 420)
    }

    // MARK: - Expanded

    static func expandedWidth(for state: IslandState, panelWidth: CGFloat) -> CGFloat {
        switch state {
        case .collapsed: return 0
        case .expanded, .permission, .question, .planReview: return panelWidth
        }
    }

    static func expandedHeight(
        for state: IslandState,
        visibleSessionCount: Int,
        panelMaxHeight: CGFloat,
        activityLogExpanded: Bool
    ) -> CGFloat {
        switch state {
        case .collapsed: return 0
        case .expanded, .permission, .question, .planReview:
            let listH = min(CGFloat(visibleSessionCount) * 80 + 30, panelMaxHeight)
            let logH: CGFloat = activityLogExpanded ? 140 : 0
            return expandedPanelHeaderHeight + listH + logH + expandedPanelBottomInset
        }
    }

    // MARK: - Target size (for window resize before state updates)

    static func targetSize(
        for state: IslandState,
        visibleSessionCount: Int,
        panelWidth: CGFloat,
        panelMaxHeight: CGFloat
    ) -> (width: CGFloat, height: CGFloat) {
        switch state {
        case .collapsed:
            return (pillWidth(islandObscuredByNotch: false, visibleSessionCount: visibleSessionCount),
                    collapsedShapeHeight)
        case .expanded, .permission, .question, .planReview:
            let listH = min(CGFloat(visibleSessionCount) * 80 + 30, panelMaxHeight)
            return (panelWidth,
                    expandedPanelHeaderHeight + listH + expandedPanelBottomInset)
        }
    }

    /// Expanded panel shape height for `.expanded` state, used for caching before state change.
    static func expandedPanelShapeHeight(visibleSessionCount: Int, panelMaxHeight: CGFloat) -> CGFloat {
        let listH = min(CGFloat(visibleSessionCount) * 80 + 30, panelMaxHeight)
        return expandedPanelHeaderHeight + listH + expandedPanelBottomInset
    }
}
