import XCTest
@testable import XIsland

@MainActor
final class NotchContentViewTests: XCTestCase {
    func testInitialAutoExpandedStatePrefersWaitingPermissionSession() {
        let manager = SessionManager()

        let selected = AgentSession(id: "selected-active", agentType: .claudeCode, workingDirectory: "/tmp/selected")
        selected.status = .active

        let waiting = AgentSession(id: "waiting-permission", agentType: .codex, workingDirectory: "/tmp/waiting")
        waiting.status = .waitingPermission
        waiting.pendingPermission = PendingPermission(
            requestingAgent: .codex,
            tool: "Bash",
            description: "Run command",
            diff: nil,
            filePath: nil,
            respond: { _ in }
        )

        manager.sessions = [selected, waiting]
        manager.selectedSessionId = selected.id

        XCTAssertEqual(
            NotchContentView.initialAutoExpandedState(for: manager),
            .permission(waiting.id)
        )
    }

    func testInitialAutoExpandedStateReturnsPlanReviewWhenPlanReviewIsPrioritizedInteraction() {
        let manager = SessionManager()

        let waiting = AgentSession(id: "waiting-plan", agentType: .codex, workingDirectory: "/tmp/waiting")
        waiting.status = .waitingPlanReview
        waiting.pendingPlanReview = PendingPlanReview(
            requestingAgent: .codex,
            markdown: "## Plan",
            respond: { _, _ in }
        )

        manager.sessions = [waiting]
        manager.selectedSessionId = waiting.id

        XCTAssertEqual(
            NotchContentView.initialAutoExpandedState(for: manager),
            .planReview(waiting.id)
        )
    }

    func testInitialAutoExpandedStateReturnsNilWithoutWaitingInteraction() {
        let manager = SessionManager()

        let session = AgentSession(id: "active", agentType: .claudeCode, workingDirectory: "/tmp/active")
        session.status = .active

        manager.sessions = [session]
        manager.selectedSessionId = session.id

        XCTAssertNil(NotchContentView.initialAutoExpandedState(for: manager))
    }

    func testInitialIslandStateDefaultsToCollapsedWithoutWaitingInteraction() {
        let manager = SessionManager()

        let session = AgentSession(id: "active", agentType: .claudeCode, workingDirectory: "/tmp/active")
        session.status = .active

        manager.sessions = [session]
        manager.selectedSessionId = session.id

        XCTAssertEqual(NotchContentView.initialIslandState(for: manager), .collapsed)
    }

    func testDiagnosticsIslandStateDefaultsToCollapsedForVisibleNonInteractiveSessions() {
        let manager = SessionManager()

        let session = AgentSession(id: "active", agentType: .claudeCode, workingDirectory: "/tmp/active")
        session.status = .active

        manager.sessions = [session]
        manager.selectedSessionId = session.id

        XCTAssertEqual(
            NotchContentView.diagnosticsIslandState(for: manager, currentState: .collapsed),
            .collapsed
        )
    }

    func testDiagnosticsIslandStatePreservesExpandedViewForVisibleNonInteractiveSessions() {
        let manager = SessionManager()

        let session = AgentSession(id: "active", agentType: .claudeCode, workingDirectory: "/tmp/active")
        session.status = .active

        manager.sessions = [session]
        manager.selectedSessionId = session.id

        XCTAssertEqual(
            NotchContentView.diagnosticsIslandState(for: manager, currentState: .expanded),
            .expanded
        )
    }

    func testDiagnosticsIslandStatePrefersWaitingInteractionOverExpandedView() {
        let manager = SessionManager()

        let selected = AgentSession(id: "selected-active", agentType: .claudeCode, workingDirectory: "/tmp/selected")
        selected.status = .active

        let waiting = AgentSession(id: "waiting-question", agentType: .codex, workingDirectory: "/tmp/waiting")
        waiting.status = .waitingAnswer
        waiting.pendingQuestion = PendingQuestion(
            requestingAgent: .codex,
            text: "Continue?",
            options: ["yes", "no"],
            respond: { _ in },
            cancel: nil
        )

        manager.sessions = [selected, waiting]
        manager.selectedSessionId = selected.id

        XCTAssertEqual(
            NotchContentView.diagnosticsIslandState(for: manager, currentState: .expanded),
            .question(waiting.id)
        )
    }

    func testTransitionTimingKeepsExistingAnimationDelaysWhenAnimationsEnabled() {
        XCTAssertEqual(
            NotchContentView.transitionTiming(disableAnimations: false),
            .init(expandStartDelay: 0.05, contentRevealDelay: 0.12, collapseCompletionDelay: 0.45)
        )
    }

    func testTransitionTimingRemovesDelaysWhenAnimationsDisabled() {
        XCTAssertEqual(
            NotchContentView.transitionTiming(disableAnimations: true),
            .init(expandStartDelay: 0, contentRevealDelay: 0, collapseCompletionDelay: 0)
        )
    }

    func testTransitionTimingUsesLowerDelaysForLowAnimationIntensity() {
        XCTAssertEqual(
            NotchContentView.transitionTiming(disableAnimations: false, intensity: .low),
            .init(expandStartDelay: 0.02, contentRevealDelay: 0.08, collapseCompletionDelay: 0.28)
        )
    }

    func testTransitionTimingUsesHigherDelaysForHighAnimationIntensity() {
        XCTAssertEqual(
            NotchContentView.transitionTiming(disableAnimations: false, intensity: .high),
            .init(expandStartDelay: 0.07, contentRevealDelay: 0.16, collapseCompletionDelay: 0.55)
        )
    }

    func testResolvedAnimationIntensityFallsBackToMedium() {
        XCTAssertEqual(
            NotchContentView.resolvedAnimationIntensity(rawValue: "unknown", reduceMotion: false),
            .medium
        )
    }

    func testResolvedAnimationIntensityUsesLowWhenReduceMotionEnabled() {
        XCTAssertEqual(
            NotchContentView.resolvedAnimationIntensity(rawValue: IslandAnimationIntensity.high.rawValue, reduceMotion: true),
            .low
        )
    }

    func testResolvedJellyIntensityFallsBackToMedium() {
        XCTAssertEqual(
            NotchContentView.resolvedJellyIntensity(rawValue: "unknown"),
            .medium
        )
    }

    func testHoverJellyScaleMatchesIntensityProfile() {
        XCTAssertEqual(
            NotchContentView.hoverJellyScale(for: IslandJellyIntensity.low),
            .init(xPop: 0.97, xSettle: 0.99, yPop: 1.10, ySettle: 1.03)
        )
        XCTAssertEqual(
            NotchContentView.hoverJellyScale(for: IslandJellyIntensity.medium),
            .init(xPop: 0.94, xSettle: 0.98, yPop: 1.25, ySettle: 1.08)
        )
        XCTAssertEqual(
            NotchContentView.hoverJellyScale(for: IslandJellyIntensity.high),
            .init(xPop: 0.90, xSettle: 0.96, yPop: 1.40, ySettle: 1.12)
        )
    }

    func testShouldTriggerHoverJellyRequiresUpwardEntryIntoCollapsedPill() {
        XCTAssertTrue(
            NotchContentView.shouldTriggerHoverJelly(
                isPointerInside: true,
                isExpanded: false,
                collapseAnimating: false,
                previousMouseY: 120,
                currentMouseY: 160
            )
        )

        XCTAssertFalse(
            NotchContentView.shouldTriggerHoverJelly(
                isPointerInside: true,
                isExpanded: true,
                collapseAnimating: false,
                previousMouseY: 120,
                currentMouseY: 160
            )
        )

        XCTAssertFalse(
            NotchContentView.shouldTriggerHoverJelly(
                isPointerInside: true,
                isExpanded: false,
                collapseAnimating: false,
                previousMouseY: 160,
                currentMouseY: 120
            )
        )
    }

    func testMagneticOffsetClampsTowardMouseWithinRange() {
        let offset = NotchContentView.magneticOffset(
            mouseLocation: CGPoint(x: 248, y: 110),
            windowFrame: CGRect(x: 100, y: 100, width: 220, height: 40),
            collapsedShapeHeight: 32,
            isExpanded: false,
            collapseAnimating: false
        )

        XCTAssertGreaterThan(offset.width, 0)
        XCTAssertLessThanOrEqual(offset.width, 8)
        XCTAssertEqual(offset.height, 0)
    }

    func testMagneticOffsetIsZeroWhenExpandedOrFarAway() {
        XCTAssertEqual(
            NotchContentView.magneticOffset(
                mouseLocation: CGPoint(x: 600, y: 600),
                windowFrame: CGRect(x: 100, y: 100, width: 220, height: 40),
                collapsedShapeHeight: 32,
                isExpanded: false,
                collapseAnimating: false
            ),
            .zero
        )

        XCTAssertEqual(
            NotchContentView.magneticOffset(
                mouseLocation: CGPoint(x: 248, y: 110),
                windowFrame: CGRect(x: 100, y: 100, width: 220, height: 40),
                collapsedShapeHeight: 32,
                isExpanded: true,
                collapseAnimating: false
            ),
            .zero
        )
    }

    func testCollapsedTickerTextFallsBackToNoActivityWithoutSession() {
        XCTAssertEqual(
            NotchContentView.collapsedTickerText(for: nil, mode: .activity),
            L10n.noActivity
        )
    }

    func testCollapsedTickerTextPrefersCurrentTool() {
        let session = AgentSession(id: "tool-session", agentType: .codex, workingDirectory: "/tmp/tool")
        session.currentTool = "Bash"

        XCTAssertEqual(
            NotchContentView.collapsedTickerText(for: session, mode: .activity),
            "Codex · \(L10n.toolRunning("Bash"))"
        )
    }

    func testCollapsedTickerTextUsesCompletedEventSummary() {
        let session = AgentSession(id: "event-session", agentType: .claudeCode, workingDirectory: "/tmp/event")
        session.events = [
            ToolEvent(tool: "bash", result: "Applied patch", isComplete: true)
        ]

        XCTAssertEqual(
            NotchContentView.collapsedTickerText(for: session, mode: .activity),
            "Claude · Bash: Applied patch"
        )
    }

    func testCollapsedTickerTextUsesWorkspaceNameInProjectMode() {
        let session = AgentSession(
            id: "project-session",
            agentType: .codex,
            workingDirectory: "/tmp/xisland"
        )
        session.prompt = "This title should not win"

        XCTAssertEqual(
            NotchContentView.collapsedTickerText(for: session, mode: .project),
            "Codex · xisland"
        )
    }

    func testCollapsedTickerTextAlternatesInAutomaticMode() {
        let session = AgentSession(
            id: "auto-session",
            agentType: .claudeCode,
            workingDirectory: "/tmp/xisland"
        )
        session.currentTool = "Edit"

        XCTAssertEqual(
            NotchContentView.collapsedTickerText(
                for: session,
                mode: .automatic,
                now: Date(timeIntervalSince1970: 0)
            ),
            "Claude · \(L10n.toolRunning("Edit"))"
        )

        XCTAssertEqual(
            NotchContentView.collapsedTickerText(
                for: session,
                mode: .automatic,
                now: Date(timeIntervalSince1970: CollapsedTickerContentMode.rotationInterval)
            ),
            "Claude · xisland"
        )
    }

    // MARK: - Agent Flow Entry (专用状态 → 总览入口)

    /// 专用状态下存在阻塞时应显示入口——这是核心交互缺口修复的入口判定。
    func testShouldShowAgentFlowEntryInInteractionStatesWhenBlocked() {
        XCTAssertTrue(NotchContentView.shouldShowAgentFlowEntry(state: .permission("s1"), hasAnyBlocker: true))
        XCTAssertTrue(NotchContentView.shouldShowAgentFlowEntry(state: .question("s1"), hasAnyBlocker: true))
        XCTAssertTrue(NotchContentView.shouldShowAgentFlowEntry(state: .planReview("s1"), hasAnyBlocker: true))
    }

    /// `.expanded` 已直接渲染完整 Agent Flow，不需要入口；`.collapsed` 不展示工具栏入口。
    func testShouldShowAgentFlowEntryHiddenInExpandedAndCollapsed() {
        XCTAssertFalse(NotchContentView.shouldShowAgentFlowEntry(state: .expanded, hasAnyBlocker: true))
        XCTAssertFalse(NotchContentView.shouldShowAgentFlowEntry(state: .collapsed, hasAnyBlocker: true))
    }

    /// 无阻塞时不显示入口——避免工具栏噪音。
    func testShouldShowAgentFlowEntryHiddenWithoutBlocker() {
        XCTAssertFalse(NotchContentView.shouldShowAgentFlowEntry(state: .permission("s1"), hasAnyBlocker: false))
        XCTAssertFalse(NotchContentView.shouldShowAgentFlowEntry(state: .question("s1"), hasAnyBlocker: false))
        XCTAssertFalse(NotchContentView.shouldShowAgentFlowEntry(state: .planReview("s1"), hasAnyBlocker: false))
    }
}
