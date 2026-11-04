import XCTest
@testable import XIsland

/// 收起态稳定性：失败优先级、集合不变时锁定顺序、最短驻留。
@MainActor
final class CollapsedTaskStabilityTests: XCTestCase {

    // MARK: 失败优先级

    func testRecentErrorOutranksRunningTask() {
        // 时间必须相对基准时刻构造：rank 以"现在"判断失败是否新鲜，
        // 用 1970 年的时间戳会被判成早已过期。
        let base = Date(timeIntervalSince1970: 1_000_000)
        let failed = failed("failed", activity: base.timeIntervalSince1970 - 100,
                            completed: base.timeIntervalSince1970 - 5)
        let running = task("running", activity: base.timeIntervalSince1970 - 1)
        let ordered = CollapsedTaskSelection.ordered(
            from: [running, failed], remindersEnabled: true, now: base
        )
        XCTAssertEqual(ordered.map(\.id), ["failed", "running"])
    }

    func testErrorOlderThanErrorMomentDropsBelowRunningTask() {
        // 60 秒窗外的失败不再抢占，避免历史失败长期占位。
        let base = Date(timeIntervalSince1970: 1_000_000)
        let stale = failed("stale", activity: base.timeIntervalSince1970 - 500,
                           completed: base.timeIntervalSince1970 - 120)
        let running = task("running", activity: base.timeIntervalSince1970 - 1)
        let ordered = CollapsedTaskSelection.ordered(
            from: [stale, running], remindersEnabled: true, now: base
        )
        XCTAssertEqual(ordered.map(\.id), ["running", "stale"])
    }

    func testPendingOutranksRecentError() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let failed = failed("failed", activity: base.timeIntervalSince1970 - 100,
                            completed: base.timeIntervalSince1970 - 5)
        let waiting = task("waiting", activity: base.timeIntervalSince1970 - 100)
        waiting.pendingPermission = PendingPermission(
            requestingAgent: .codex, tool: "Shell",
            description: "Review command", diff: nil, filePath: nil, respond: { _ in }
        )
        let ordered = CollapsedTaskSelection.ordered(
            from: [failed, waiting], remindersEnabled: true, now: base
        )
        XCTAssertEqual(ordered.map(\.id), ["waiting", "failed"])
    }

    // MARK: 顺序锁定

    func testOrderIsHeldWhenCandidateSetIsUnchanged() {
        // 两个同档任务活动时间交替，集合不变时顺序不应跟随 lastActivity 抖动。
        let a = task("a", activity: 10)
        let b = task("b", activity: 20)
        let first = CollapsedTaskSelection.stableSelection(from: [a, b], limit: 2)
        XCTAssertEqual(first.sessions.map(\.id), ["b", "a"])

        a.lastActivityTime = Date(timeIntervalSince1970: 30)
        let second = CollapsedTaskSelection.stableSelection(
            from: [a, b], limit: 2, previousOrder: first.sessions.map(\.id)
        )
        XCTAssertEqual(second.sessions.map(\.id), ["b", "a"],
                       "集合未变时必须沿用上次顺序，否则图标会左右平移")
    }

    func testOrderChangesWhenCandidateSetChanges() {
        let a = task("a", activity: 10)
        let b = task("b", activity: 20)
        let first = CollapsedTaskSelection.stableSelection(from: [a, b], limit: 2)
        let c = task("c", activity: 30)
        let second = CollapsedTaskSelection.stableSelection(
            from: [a, b, c], limit: 2, previousOrder: first.sessions.map(\.id)
        )
        XCTAssertEqual(second.sessions.map(\.id), ["c", "b"])
    }

    // MARK: 最短驻留

    func testHoldsCurrentWithinMinHoldWhenRankIsEqual() {
        let a = task("a", activity: 20)
        let b = task("b", activity: 10)
        let since = Date(timeIntervalSince1970: 100)
        let result = CollapsedTaskSelection.stableSelection(
            from: [a, b], limit: 2,
            current: "b", since: since,
            now: since.addingTimeInterval(CollapsedTaskSelection.minHold - 0.1)
        )
        XCTAssertEqual(result.shownId, "b")
        XCTAssertEqual(result.shownSince, since)
    }

    func testYieldsAfterMinHoldWhenRankIsEqual() {
        let a = task("a", activity: 20)
        let b = task("b", activity: 10)
        let since = Date(timeIntervalSince1970: 100)
        let result = CollapsedTaskSelection.stableSelection(
            from: [a, b], limit: 2,
            current: "b", since: since,
            now: since.addingTimeInterval(CollapsedTaskSelection.minHold + 0.1)
        )
        XCTAssertEqual(result.shownId, "a")
    }

    func testYieldsImmediatelyToStrictlyMoreUrgentCandidate() {
        // 新出现的待处理请求即使尚在驻留期内也必须立刻让位。
        let running = task("running", activity: 10)
        let since = Date(timeIntervalSince1970: 100)
        let waiting = task("waiting", activity: 5)
        waiting.pendingPermission = PendingPermission(
            requestingAgent: .codex, tool: "Shell",
            description: "Review command", diff: nil, filePath: nil, respond: { _ in }
        )
        let result = CollapsedTaskSelection.stableSelection(
            from: [running, waiting], limit: 2,
            current: "running", since: since,
            now: since.addingTimeInterval(0.1)
        )
        XCTAssertEqual(result.shownId, "waiting")
    }

    func testEmptyInputProducesNoShowcase() {
        let result = CollapsedTaskSelection.stableSelection(from: [], limit: 3)
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertNil(result.shownId)
    }

    // MARK: Helpers

    private func ids(_ sessions: [AgentSession], limit: Int) -> [String] {
        CollapsedTaskSelection.select(from: sessions, limit: limit).map(\.id)
    }

    private func task(_ id: String, activity: TimeInterval, start: TimeInterval = 0) -> AgentSession {
        let session = AgentSession(id: id, agentType: .codex,
                                   startTime: Date(timeIntervalSince1970: start))
        session.lastActivityTime = Date(timeIntervalSince1970: activity)
        return session
    }

    private func failed(_ id: String, activity: TimeInterval, completed: TimeInterval) -> AgentSession {
        let session = task(id, activity: activity)
        session.status = .error
        session.completedAt = Date(timeIntervalSince1970: completed)
        return session
    }
}
