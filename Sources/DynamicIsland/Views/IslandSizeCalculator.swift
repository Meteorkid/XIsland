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
        case .expanded: return panelWidth
        case .permission, .question: return panelWidth + 20
        case .planReview: return panelWidth + 80
        }
    }

    static func expandedHeight(
        for state: IslandState,
        visibleSessionCount: Int,
        panelMaxHeight: CGFloat,
        activityLogExpanded: Bool,
        pendingPermission: PendingPermission?,
        pendingQuestion: PendingQuestion?
    ) -> CGFloat {
        switch state {
        case .collapsed: return 0
        case .expanded:
            let listH = min(CGFloat(visibleSessionCount) * 80 + 30, panelMaxHeight)
            let logH: CGFloat = activityLogExpanded ? 140 : 0
            return expandedPanelHeaderHeight + listH + logH + expandedPanelBottomInset
        case .permission(let id):
            return permissionExpandedTotalHeight(pendingPermission: pendingPermission, sessionId: id)
        case .question(let id):
            return questionExpandedTotalHeight(pendingQuestion: pendingQuestion)
        case .planReview: return 480
        }
    }

    // MARK: - Permission

    static func permissionCardInnerHeight(pendingPermission: PendingPermission?) -> CGFloat {
        var h: CGFloat = 42 + 1 + 30
        let hasDesc = pendingPermission != nil && !pendingPermission!.description.isEmpty
        let hasPath = pendingPermission?.filePath.map { !$0.isEmpty } ?? false
        let hasDiff = pendingPermission?.diff.map { !$0.isEmpty } ?? false
        h += hasDesc ? 52 : (hasPath ? 52 : 0)
        if hasDesc && hasPath { h += 22 }
        if hasDiff { h += 130 }
        h += 52
        return min(h, 480)
    }

    static func permissionExpandedTotalHeight(pendingPermission: PendingPermission?, sessionId: String) -> CGFloat {
        let inner = permissionCardInnerHeight(pendingPermission: pendingPermission)
        return inner + expandedPanelHeaderHeight + expandedPanelBottomInset
    }

    // MARK: - Question

    static func questionExpandedTotalHeight(pendingQuestion: PendingQuestion?) -> CGFloat {
        let optionCount = pendingQuestion?.options.count ?? 0
        let questionInnerHeight: CGFloat = min(120 + CGFloat(max(optionCount, 2)) * 42, 480)
        let total = questionInnerHeight + expandedPanelHeaderHeight + expandedPanelBottomInset
        return min(total, 480)
    }

    // MARK: - Target size (for window resize before state updates)

    static func targetSize(
        for state: IslandState,
        visibleSessionCount: Int,
        panelWidth: CGFloat,
        panelMaxHeight: CGFloat,
        pendingPermission: PendingPermission?,
        pendingQuestion: PendingQuestion?
    ) -> (width: CGFloat, height: CGFloat) {
        switch state {
        case .collapsed:
            return (pillWidth(islandObscuredByNotch: false, visibleSessionCount: visibleSessionCount),
                    collapsedShapeHeight)
        case .expanded:
            let listH = min(CGFloat(visibleSessionCount) * 80 + 30, panelMaxHeight)
            return (panelWidth,
                    expandedPanelHeaderHeight + listH + expandedPanelBottomInset)
        case .permission(let id):
            return (panelWidth + 20,
                    permissionExpandedTotalHeight(pendingPermission: pendingPermission, sessionId: id) + 8)
        case .question:
            return (panelWidth + 20,
                    questionExpandedTotalHeight(pendingQuestion: pendingQuestion) + 8)
        case .planReview:
            return (panelWidth + 80, panelMaxHeight)
        }
    }

    /// Expanded panel shape height for `.expanded` state, used for caching before state change.
    static func expandedPanelShapeHeight(visibleSessionCount: Int, panelMaxHeight: CGFloat) -> CGFloat {
        let listH = min(CGFloat(visibleSessionCount) * 80 + 30, panelMaxHeight)
        return expandedPanelHeaderHeight + listH + expandedPanelBottomInset
    }
}
