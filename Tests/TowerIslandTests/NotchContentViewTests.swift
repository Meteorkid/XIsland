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
}
