import CoreGraphics

/// 刘海（灵动岛）外形几何计算。
///
/// 把「折叠条 → 展开卡片」的过渡抽象成一段 0...1 的展开进度，再用它插值底部圆角，
/// 使圆角跟随弹簧动画中的实际高度平滑变化，而不是在高度阈值处突变。
enum NotchShapeGeometry {
    /// 折叠条高度。
    static let collapsedShapeHeight: CGFloat = 32
    /// 展开态卡片底部圆角。
    static let expandedCornerRadius: CGFloat = 22
    /// 折叠态卡片底部圆角。
    static let collapsedBottomCornerRadius: CGFloat = 17

    /// 将当前高度映射为 0...1 的展开进度（0 = 折叠条，1 = 完整展开卡片）。
    static func openProgress(shapeHeight: CGFloat, cachedExpandedShapeHeight: CGFloat) -> CGFloat {
        let lowerBound = collapsedShapeHeight
        // 分母至少取 1，避免缓存的展开高度尚未就绪时出现除零或负区间。
        let upperBound = max(cachedExpandedShapeHeight, lowerBound + 1)
        let rawProgress = (shapeHeight - lowerBound) / (upperBound - lowerBound)
        return min(1, max(0, rawProgress))
    }

    /// 顶边圆角。灵动岛顶部始终贴合系统刘海边缘，所有状态均为平直（0）。
    static func topCornerRadius(state: IslandState) -> CGFloat {
        switch state {
        case .collapsed, .expanded, .permission, .question, .planReview:
            return 0
        }
    }

    /// 底部圆角随展开进度在「折叠 → 展开」之间线性插值。
    static func bottomCornerRadius(openProgress: CGFloat) -> CGFloat {
        let radiusSpan = expandedCornerRadius - collapsedBottomCornerRadius
        return collapsedBottomCornerRadius + radiusSpan * openProgress
    }
}
