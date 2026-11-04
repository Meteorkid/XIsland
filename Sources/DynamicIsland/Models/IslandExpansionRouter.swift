import Foundation

/// 收起态可以发起展开的入口。
///
/// 收敛前这些条件分散在 `NotchContentView` 的 6 处调用点上，各自正确但无法回答
/// "两个触发源同时到达时谁赢"。这里只回答**要不要展开、展开到哪个状态**；
/// 0.18s 二次确认、跨应用切换后的延迟等**时序细节仍留在视图层**。
enum IslandExpandTrigger: String, CaseIterable {
    /// 用户点击药丸本体
    case click
    /// 鼠标悬停
    case hover
    /// 任务提醒（完成、待处理）
    case notification
    /// 滚轮
    case scroll
    /// 出现待处理请求时的自动展开
    case autoInteraction
}

/// 决策所需的全部输入。全部是值类型，便于在测试里构造组合。
struct IslandExpansionContext {
    var isExpanded: Bool = false
    var expandPending: Bool = false
    var collapseAnimating: Bool = false
    var isSwitchingApps: Bool = false

    var hasVisibleSessions: Bool = false
    var hasPendingInteraction: Bool = false
    /// 待处理请求对应的目标状态（permission / question / planReview）。
    var interactionTarget: IslandState?

    var hoverToExpandEnabled: Bool = true
    /// 智能抑制：终端处于前台且开关打开，此时不应因悬停自动弹出。
    var smartSuppressionActive: Bool = false

    var secondsSinceLastScrollExpand: TimeInterval = .infinity
    var scrollCooldown: TimeInterval = 0.5
}

enum IslandExpansionDecision: Equatable {
    /// 展开到指定状态。
    case expand(IslandState)
    /// 当前正跨应用切换，等切换结束后再展开（仅自动展开使用）。
    case deferUntilHandoff
    /// 保持现状。
    case ignore
}

/// 展开决策的唯一入口。
///
/// 优先级：用户显式点击 > 待处理交互 > 提醒 > 悬停 > 滚轮。
/// 前两者是"用户必须看到"的内容，不受悬停开关与智能抑制影响；
/// 后两者是"顺手的便利"，允许被抑制。
enum IslandExpansionRouter {

    static func decide(_ trigger: IslandExpandTrigger,
                       _ context: IslandExpansionContext) -> IslandExpansionDecision {
        // 展开动画进行中：任何触发都不打断，避免两次展开互相覆盖。
        guard !context.expandPending else { return .ignore }

        // 跨应用切换期间窗口所有权在移交，此时展开会丢失目标窗口。
        if context.isSwitchingApps {
            return trigger == .autoInteraction ? .deferUntilHandoff : .ignore
        }

        switch trigger {
        case .click:
            // 显式点击永不被内容条件拦住：用户点了就该响应。
            return .expand(.expanded)

        case .autoInteraction:
            // 没有待处理请求就没有自动展开的理由。
            guard let target = context.interactionTarget else { return .ignore }
            // 已展开时直接切到专用面板；未展开先展开总览，由视图负责 0.18s 后二次校正。
            return .expand(context.isExpanded ? target : .expanded)

        case .notification:
            guard context.hasVisibleSessions else { return .ignore }
            // 有阻塞项时优先呈现交互面板，与自动展开保持一致，避免提醒把审批挤掉。
            if context.hasPendingInteraction, let target = context.interactionTarget {
                return .expand(target)
            }
            return .expand(.expanded)

        case .hover:
            guard context.hasVisibleSessions else { return .ignore }
            guard context.hoverToExpandEnabled else { return .ignore }
            guard !context.smartSuppressionActive else { return .ignore }
            // 已展开时不重复触发，否则会把专用面板切回总览。
            guard !context.isExpanded else { return .ignore }
            return .expand(.expanded)

        case .scroll:
            guard !context.isExpanded, !context.collapseAnimating else { return .ignore }
            guard context.secondsSinceLastScrollExpand > context.scrollCooldown else { return .ignore }
            return .expand(.expanded)
        }
    }
}
