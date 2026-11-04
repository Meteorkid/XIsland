import XCTest
@testable import XIsland

/// 展开决策：锁定 6 个入口的优先级与守卫，防止后续改动让某个触发源把另一个挤掉。
@MainActor
final class IslandExpansionRouterTests: XCTestCase {

    // MARK: 全局阻塞

    func testNoTriggerInterruptsRunningExpansion() {
        var context = IslandExpansionContext()
        context.expandPending = true
        context.interactionTarget = .permission("s1")
        for trigger in IslandExpandTrigger.allCases {
            XCTAssertEqual(IslandExpansionRouter.decide(trigger, context), .ignore,
                           "展开动画进行中不应被 \(trigger.rawValue) 打断")
        }
    }

    func testAppSwitchDefersOnlyAutoInteraction() {
        var context = IslandExpansionContext()
        context.isSwitchingApps = true
        context.interactionTarget = .question("s1")
        XCTAssertEqual(IslandExpansionRouter.decide(.autoInteraction, context), .deferUntilHandoff)

        for trigger in [IslandExpandTrigger.click, .hover, .notification, .scroll] {
            XCTAssertEqual(IslandExpansionRouter.decide(trigger, context), .ignore)
        }
    }

    // MARK: 用户显式点击

    func testClickExpandsEvenWithNothingToShow() {
        // 空列表、终端聚焦、已展开都不能拦住用户的显式点击。
        var context = IslandExpansionContext()
        context.hasVisibleSessions = false
        context.smartSuppressionActive = true
        context.isExpanded = true
        XCTAssertEqual(IslandExpansionRouter.decide(.click, context), .expand(.expanded))
    }

    // MARK: 待处理交互

    func testAutoInteractionNeedsTarget() {
        var context = IslandExpansionContext()
        context.hasVisibleSessions = true
        XCTAssertEqual(IslandExpansionRouter.decide(.autoInteraction, context), .ignore)
    }

    func testAutoInteractionSwitchesPanelWhenAlreadyExpanded() {
        var context = IslandExpansionContext()
        context.isExpanded = true
        context.interactionTarget = .planReview("s2")
        XCTAssertEqual(IslandExpansionRouter.decide(.autoInteraction, context), .expand(.planReview("s2")))
    }

    func testAutoInteractionExpandsOverviewFirstWhenCollapsed() {
        var context = IslandExpansionContext()
        context.isExpanded = false
        context.interactionTarget = .question("s3")
        XCTAssertEqual(IslandExpansionRouter.decide(.autoInteraction, context), .expand(.expanded))
    }

    // MARK: 提醒

    func testNotificationPrefersPendingPanelOverOverview() {
        var context = IslandExpansionContext()
        context.hasVisibleSessions = true
        context.hasPendingInteraction = true
        context.interactionTarget = .permission("s4")
        XCTAssertEqual(IslandExpansionRouter.decide(.notification, context), .expand(.permission("s4")))
    }

    func testNotificationFallsBackToOverview() {
        var context = IslandExpansionContext()
        context.hasVisibleSessions = true
        XCTAssertEqual(IslandExpansionRouter.decide(.notification, context), .expand(.expanded))
    }

    func testNotificationIgnoredWithoutVisibleSessions() {
        XCTAssertEqual(IslandExpansionRouter.decide(.notification, IslandExpansionContext()), .ignore)
    }

    // MARK: 悬停

    func testHoverRespectsToggleAndSmartSuppression() {
        var context = IslandExpansionContext()
        context.hasVisibleSessions = true

        XCTAssertEqual(IslandExpansionRouter.decide(.hover, context), .expand(.expanded))

        context.hoverToExpandEnabled = false
        XCTAssertEqual(IslandExpansionRouter.decide(.hover, context), .ignore)

        context.hoverToExpandEnabled = true
        context.smartSuppressionActive = true
        XCTAssertEqual(IslandExpansionRouter.decide(.hover, context), .ignore)
    }

    func testHoverDoesNotOverrideExpandedPanel() {
        // 已展开时悬停必须无效，否则会把 permission 面板切回总览。
        var context = IslandExpansionContext()
        context.hasVisibleSessions = true
        context.isExpanded = true
        XCTAssertEqual(IslandExpansionRouter.decide(.hover, context), .ignore)
    }

    // MARK: 滚轮

    func testScrollRespectsCooldownAndState() {
        var context = IslandExpansionContext()
        context.secondsSinceLastScrollExpand = 0.1
        XCTAssertEqual(IslandExpansionRouter.decide(.scroll, context), .ignore)

        context.secondsSinceLastScrollExpand = 1.0
        XCTAssertEqual(IslandExpansionRouter.decide(.scroll, context), .expand(.expanded))

        context.isExpanded = true
        XCTAssertEqual(IslandExpansionRouter.decide(.scroll, context), .ignore)

        context.isExpanded = false
        context.collapseAnimating = true
        XCTAssertEqual(IslandExpansionRouter.decide(.scroll, context), .ignore)
    }

    // MARK: 竞争

    func testPendingPanelBeatsHoverWhileCollapsed() {
        // 两个触发源同时到达时，待处理必须赢——否则审批会被悬停的总览盖住。
        var context = IslandExpansionContext()
        context.hasVisibleSessions = true
        context.hasPendingInteraction = true
        context.interactionTarget = .permission("s5")

        XCTAssertEqual(IslandExpansionRouter.decide(.autoInteraction, context), .expand(.expanded))
        XCTAssertEqual(IslandExpansionRouter.decide(.notification, context), .expand(.permission("s5")))
        XCTAssertEqual(IslandExpansionRouter.decide(.hover, context), .expand(.expanded))
        XCTAssertEqual(IslandExpansionRouter.decide(.click, context), .expand(.expanded))
    }
}
