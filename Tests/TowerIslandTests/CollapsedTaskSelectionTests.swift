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
