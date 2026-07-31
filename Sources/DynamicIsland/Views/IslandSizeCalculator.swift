import SwiftUI

/// 统一灵动岛高度/宽度计算，消除 NotchContentView 中的重复逻辑。
enum IslandSizeCalculator {
    static let expandedPanelHeaderHeight: CGFloat = 48
    static let expandedPanelBottomInset: CGFloat = 16
    static let defaultCollapsedShapeHeight: CGFloat = 32
    static let collapsedPillWidthNotched: CGFloat = 276
    /// 收起状态默认宽度（未被刘海遮挡时）
    static let defaultCollapsedPillWidth: CGFloat = 180

    /// 读取用户设置的收起高度；未设置（0）时返回默认值
    static var collapsedShapeHeight: CGFloat {
        let saved = UserDefaults.standard.double(forKey: "islandHeight")
        return saved > 0 ? CGFloat(saved) : defaultCollapsedShapeHeight
    }

    /// 读取用户设置的收起宽度；未设置（0）时返回默认值
    static var collapsedPillWidth: CGFloat {
        let saved = UserDefaults.standard.double(forKey: "islandWidth")
        return saved > 0 ? CGFloat(saved) : defaultCollapsedPillWidth
    }

    // MARK: - Collapsed

    static func pillWidth(
        islandObscuredByNotch: Bool,
        visibleSessionCount: Int
    ) -> CGFloat {
        // 始终使用用户设置的宽度（参考 xnook），未设置时回落到默认值
        return collapsedPillWidth
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
