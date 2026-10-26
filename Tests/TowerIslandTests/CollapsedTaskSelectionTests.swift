import XCTest
@testable import XIsland

@MainActor
final class CollapsedTaskSelectionTests: XCTestCase {
    func testSelectsMostRecentlyActiveTasksInsteadOfInsertionOrder() {
        let sessions = [task("old", activity: 10), task("newest", activity: 40),
                        task("middle", activity: 20), task("recent", activity: 30)]
        XCTAssertEqual(selectedIDs(sessions, limit: 2), ["newest", "recent"])
        XCTAssertEqual(sessions.map(\.id), ["old", "newest", "middle", "recent"])
    }

    func testOlderTaskWithNewActivityReturnsToTheVisibleSet() {
        let old = task("old", activity: 1, start: 1)
        let newer = task("newer", activity: 10, start: 10)
        XCTAssertEqual(selectedIDs([old, newer], limit: 1), ["newer"])
        old.lastActivityTime = Date(timeIntervalSince1970: 20)
        XCTAssertEqual(selectedIDs([old, newer], limit: 1), ["old"])
    }

    func testEqualActivityTimesHaveStableCreationAndIDTieBreakers() {
        let sessions = [task("b", activity: 10, start: 5), task("older", activity: 10, start: 1),
                        task("a", activity: 10, start: 5)]
        XCTAssertEqual(selectedIDs(sessions, limit: 5), ["a", "b", "older"])
        XCTAssertEqual(selectedIDs(Array(sessions.reversed()), limit: 5), ["a", "b", "older"])
    }

    func testAllPendingInteractionTypesTakePriorityWithoutExceedingLimit() {
        for kind in 0..<3 {
            let waiting = task("waiting", activity: 1)
            addInteraction(kind, to: waiting)
            let sessions = [task("recent", activity: 100), waiting]
            XCTAssertEqual(selectedIDs(sessions, limit: 1), ["waiting"])
        }
    }

    func testStaleWaitingStatusAloneDoesNotPinOldTask() {
        let stale = task("stale", activity: 1)
        stale.status = .waitingPermission
        XCTAssertEqual(selectedIDs([stale, task("recent", activity: 100)], limit: 1), ["recent"])
    }

    func testSeveralPendingTasksStillRespectLimitAndRecency() {
        let waiting = (1...4).map { task("pending-\($0)", activity: Double($0)) }
        for session in waiting { addInteraction(0, to: session) }
        XCTAssertEqual(selectedIDs(waiting + [task("new", activity: 100)], limit: 2), ["pending-4", "pending-3"])
    }

    func testUnreviewedCompletionsTakePriorityAndUseCompletionRecency() {
        let older = completed("older-result", activity: 50, completed: 100)
        let newest = completed("newest-result", activity: 1, completed: 200)
        let active = task("active", activity: 500)
        XCTAssertEqual(CollapsedTaskSelection.select(from: [active, older, newest], limit: 2,
                                                     remindersEnabled: true).map(\.id),
                       ["newest-result", "older-result"])
        newest.completionNeedsReview = false
        XCTAssertEqual(CollapsedTaskSelection.select(from: [active, older, newest], limit: 2,
                                                     remindersEnabled: true).map(\.id),
                       ["older-result", "active"])
    }

    func testPendingRequestOutranksCompletionAndDisabledRemindersKeepRecency() {
        let pending = task("pending", activity: 1)
        addInteraction(1, to: pending)
        let completed = completed("result", activity: 2, completed: 500)
        let active = task("active", activity: 300)
        let sessions = [completed, active, pending]
        XCTAssertEqual(CollapsedTaskSelection.select(from: sessions, limit: 3,
                                                     remindersEnabled: true).map(\.id),
                       ["pending", "result", "active"])
        XCTAssertEqual(CollapsedTaskSelection.select(from: sessions, limit: 3,
                                                     remindersEnabled: false).map(\.id),
                       ["pending", "active", "result"])
    }

    func testStaleReviewFlagDoesNotPromoteUnconfirmedOrRunningTasks() {
        for status in [SessionStatus.active, .idle, .observationUnavailable, .completionUnconfirmed] {
            let stale = completed("stale", activity: 1, completed: 500)
            stale.status = status
            XCTAssertEqual(CollapsedTaskSelection.select(from: [stale, task("recent", activity: 100)],
                                                         limit: 1, remindersEnabled: true).map(\.id), ["recent"])
        }
    }

    func testEmptyAndShortListsDoNotCreateExtraTasks() {
        XCTAssertTrue(CollapsedTaskSelection.select(from: [], limit: 3).isEmpty)
        XCTAssertEqual(selectedIDs([task("only", activity: 1)], limit: 5), ["only"])
    }

    func testInvalidStoredLimitsAreClampedAndDefaultIsThree() {
        XCTAssertEqual(CollapsedTaskSelection.defaultLimit, 3)
        XCTAssertEqual(CollapsedTaskSelection.normalizedLimit(Int.min), 1)
        XCTAssertEqual(CollapsedTaskSelection.normalizedLimit(0), 1)
        XCTAssertEqual(CollapsedTaskSelection.normalizedLimit(3), 3)
        XCTAssertEqual(CollapsedTaskSelection.normalizedLimit(Int.max), 5)
        let sessions = (1...8).map { task("task-\($0)", activity: Double($0)) }
        XCTAssertEqual(CollapsedTaskSelection.select(from: sessions, limit: 0).count, 1)
        XCTAssertEqual(CollapsedTaskSelection.select(from: sessions, limit: 99).count, 5)
    }

    func testDisplayLimitDoesNotTrimCountsExpandedListOrPendingRequests() {
        XCTAssertTrue(AppPreferences.isIsolated)
        let manager = SessionManager()
        manager.sessions = (1...8).map { task("task-\($0)", activity: Double($0)) }
        for kind in 0..<3 { addInteraction(kind, to: manager.sessions[kind]) }
        let allIDs = manager.sessions.map(\.id)
        let expandedIDs = manager.filteredSessions.map(\.id)
        let pendingIDs = manager.pendingInteractionSessions.map(\.id)
        let activeCount = manager.trulyActiveSessions.count
        for limit in CollapsedTaskSelection.limitRange {
            XCTAssertEqual(CollapsedTaskSelection.select(from: manager.visibleSessions, limit: limit).count, limit)
            XCTAssertEqual(manager.sessions.map(\.id), allIDs)
            XCTAssertEqual(manager.filteredSessions.map(\.id), expandedIDs)
            XCTAssertEqual(manager.pendingInteractionSessions.map(\.id), pendingIDs)
            XCTAssertEqual(manager.trulyActiveSessions.count, activeCount)
            XCTAssertTrue(manager.hasInteraction)
        }
    }

    private func task(_ id: String, activity: TimeInterval, start: TimeInterval = 0) -> AgentSession {
        let session = AgentSession(id: id, agentType: .codex, startTime: Date(timeIntervalSince1970: start))
        session.lastActivityTime = Date(timeIntervalSince1970: activity)
        return session
    }

    private func completed(_ id: String, activity: TimeInterval, completed: TimeInterval) -> AgentSession {
        let session = task(id, activity: activity)
        session.status = .completed
        session.completionNeedsReview = true
        session.completedAt = Date(timeIntervalSince1970: completed)
        return session
    }

    private func selectedIDs(_ sessions: [AgentSession], limit: Int) -> [String] {
        CollapsedTaskSelection.select(from: sessions, limit: limit).map(\.id)
    }

    private func addInteraction(_ kind: Int, to session: AgentSession) {
        switch kind {
        case 0:
            session.pendingPermission = PendingPermission(requestingAgent: .codex, tool: "Shell",
                description: "Review command", diff: nil, filePath: nil, respond: { _ in })
        case 1:
            session.pendingQuestion = PendingQuestion(requestingAgent: .codex, text: "Choose",
                options: ["A"], respond: { _ in }, cancel: nil)
        default:
            session.pendingPlanReview = PendingPlanReview(requestingAgent: .codex, markdown: "Plan", respond: { _, _ in })
        }
    }
}
