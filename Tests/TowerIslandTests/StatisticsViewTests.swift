import XCTest
import SwiftData
@testable import XIsland

/// 直接执行统计面板使用的生产聚合器，确保 XCTest 能发现这些用例。
@MainActor
final class StatisticsViewTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 12))!
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: now)!
    }

    private func makeSession(
        id: String = UUID().uuidString,
        agentType: AgentType = .claudeCode,
        startTime: Date? = nil,
        completedAt: Date? = nil,
        totalTokens: Int = 0,
        cost: Double = 0,
        toolEvents: [StoredToolEvent] = []
    ) -> StoredSession {
        let start = startTime ?? now
        let session = StoredSession(sessionId: id, agentTypeRaw: agentType.rawValue,
            startTime: start, completedAt: completedAt ?? start.addingTimeInterval(60),
            prompt: "test", workingDirectory: "/test", terminal: "terminal",
            statusRaw: SessionStatus.completed.rawValue, totalTokens: totalTokens,
            estimatedCostUSD: cost)
        session.toolEvents = toolEvents
        return session
    }

    private func mirror(_ id: String, start: Date, end: Date, tokens: Int = 100,
                        cost: Double = 1, task: String = "task") -> StoredSession {
        let session = makeSession(id: id, agentType: .rooCode, startTime: start,
                                  completedAt: end, totalTokens: tokens, cost: cost)
        session.sourceNamespace = "profile"
        session.sourceInstanceId = id
        session.nativeTaskId = task
        return session
    }

    private func aggregate(_ sessions: [StoredSession], range: HistoryStatistics.TimeRange = .all,
                           batchSize: Int = 2) -> HistoryStatistics {
        var accumulator = HistoryStatistics.Accumulator(timeRange: range, now: now, calendar: calendar)
        for start in stride(from: 0, to: sessions.count, by: batchSize) {
            accumulator.add(Array(sessions[start..<min(start + batchSize, sessions.count)]))
        }
        return accumulator.finish()
    }

    private func makeManager() throws -> SessionPersistenceManager {
        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self,
                             StoredKimiCodeApprovalOrphan.self])
        let manager = SessionPersistenceManager()
        manager.modelContainer = try ModelContainer(for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return manager
    }

    func testDailyUsageAggregation() {
        let statistics = aggregate([
            makeSession(startTime: now.addingTimeInterval(-3600)),
            makeSession(startTime: now.addingTimeInterval(-7200)),
            makeSession(startTime: day(-1)),
            makeSession(startTime: day(-2)),
            makeSession(startTime: day(-2)),
        ])
        XCTAssertEqual(statistics.dailyUsages.map(\.sessionCount), [2, 1, 2])
        XCTAssertEqual(statistics.dailyUsages.map(\.date), [-2, -1, 0].map { calendar.startOfDay(for: day($0)) })
    }

    func testAgentUsageDistribution() {
        let statistics = aggregate([.claudeCode, .claudeCode, .codex, .cursor, .cursor, .cursor]
            .map { makeSession(agentType: $0) })
        XCTAssertEqual(statistics.agentUsages.map(\.agentType), [.cursor, .claudeCode, .codex])
        XCTAssertEqual(statistics.agentUsages.map(\.sessionCount), [3, 2, 1])
    }

    func testToolFrequencyTop10IgnoresIncompleteCalls() {
        let tools = ["bash", "read", "write", "edit", "grep", "glob", "ls", "curl", "git", "find", "awk", "sed", "cat", "head", "tail"]
        var events: [StoredToolEvent] = []
        for (index, tool) in tools.enumerated() {
            for _ in 0..<(15 - index) { events.append(StoredToolEvent(tool: tool, isComplete: true)) }
        }
        events.append(contentsOf: (0..<100).map { _ in StoredToolEvent(tool: "unfinished") })
        let statistics = aggregate([makeSession(toolEvents: events)])
        XCTAssertEqual(statistics.toolFrequencies.count, 10)
        XCTAssertEqual(statistics.toolFrequencies.first?.toolName, "bash")
        XCTAssertEqual(statistics.toolFrequencies.first?.callCount, 15)
        XCTAssertEqual(statistics.toolFrequencies.last?.toolName, "find")
        XCTAssertEqual(statistics.toolFrequencies.last?.callCount, 6)
        XCTAssertFalse(statistics.toolFrequencies.contains { $0.toolName == "unfinished" })
    }

    func testTokenTrendAndSummaryValuesUseProductionAggregation() {
        let statistics = aggregate([
            makeSession(startTime: day(-2), completedAt: day(-2).addingTimeInterval(1800), totalTokens: 1000, cost: 0.05),
            makeSession(startTime: day(-1), completedAt: day(-1).addingTimeInterval(1800), totalTokens: 2000, cost: 0.10),
            makeSession(startTime: day(-1), completedAt: day(-1).addingTimeInterval(3600), totalTokens: 500, cost: 0.02),
        ])
        XCTAssertEqual(statistics.totalCount, 3)
        XCTAssertEqual(statistics.totalTokens, 3500)
        XCTAssertEqual(statistics.totalCost, 0.17, accuracy: 0.0001)
        XCTAssertEqual(statistics.totalDuration, 7200)
        XCTAssertEqual(statistics.dailyUsages.map(\.totalTokens), [1000, 2500])
        XCTAssertEqual(statistics.dailyUsages.last?.totalCost ?? 0, 0.12, accuracy: 0.0001)
    }

    func testEmptySessionsProducesEmptyCharts() {
        let statistics = aggregate([])
        XCTAssertEqual(statistics.totalCount, 0)
        XCTAssertEqual(statistics.totalDuration, 0)
        XCTAssertEqual(statistics.totalTokens, 0)
        XCTAssertEqual(statistics.totalCost, 0)
        XCTAssertTrue(statistics.dailyUsages.isEmpty)
        XCTAssertTrue(statistics.agentUsages.isEmpty)
        XCTAssertTrue(statistics.toolFrequencies.isEmpty)
    }

    func testRollingRangesIncludeExactStartBoundaryAndIgnoreCompletionDate() {
        let records = [
            makeSession(startTime: day(-7)),
            makeSession(startTime: day(-7).addingTimeInterval(-0.001), completedAt: now),
            makeSession(startTime: day(-30)),
            makeSession(startTime: day(-30).addingTimeInterval(-0.001), completedAt: now),
            makeSession(startTime: day(-365)),
        ]
        XCTAssertEqual(aggregate(records, range: .week).totalCount, 1)
        XCTAssertEqual(aggregate(records, range: .month).totalCount, 3)
        XCTAssertEqual(aggregate(records, range: .all).totalCount, 5)
    }

    func testMirrorsAcrossBatchesMatchHistorySummaryAndKeepEarliestDay() {
        let start = day(-2)
        let records = [
            mirror("first", start: start, end: start.addingTimeInterval(60)),
            mirror("later", start: start.addingTimeInterval(30), end: start.addingTimeInterval(90), tokens: 120, cost: 2),
            mirror("restart", start: start.addingTimeInterval(120), end: start.addingTimeInterval(150), tokens: 170, cost: 1.7),
        ]
        records[1].inputTokens = 200
        records[1].outputTokens = 50
        // 乱序与批次边界不能改变区间并集或累计快照取最大值的口径。
        let statistics = aggregate([records[2], records[0], records[1]], batchSize: 1)
        let summary = HistoryUsageSummary.aggregate(records, now: now)
        XCTAssertEqual(statistics.totalCount, summary.count)
        XCTAssertEqual(statistics.totalCount, 1)
        XCTAssertEqual(statistics.totalDuration, 120)
        XCTAssertEqual(statistics.totalDuration, summary.first?.duration)
        XCTAssertEqual(statistics.totalTokens, 250)
        XCTAssertEqual(statistics.totalTokens, summary.first?.totalTokens)
        XCTAssertEqual(statistics.totalCost, 2)
        XCTAssertEqual(statistics.totalCost, summary.first?.costUSD)
        XCTAssertEqual(statistics.dailyUsages.first?.date, calendar.startOfDay(for: start))
        XCTAssertEqual(statistics.dailyUsages.first?.totalTokens, 250)
    }

    func testRangeFiltersMirrorFragmentsBeforeCombiningUsage() {
        let before = mirror("before", start: day(-7).addingTimeInterval(-1), end: now, tokens: 900, cost: 9)
        let inside = mirror("inside", start: day(-7), end: now, tokens: 100, cost: 1)
        let statistics = aggregate([before, inside], range: .week, batchSize: 1)
        XCTAssertEqual(statistics.totalCount, 1)
        XCTAssertEqual(statistics.totalTokens, 100)
        XCTAssertEqual(statistics.totalCost, 1)
        XCTAssertEqual(statistics.totalDuration, now.timeIntervalSince(day(-7)))
    }

    func testInterruptedAndOpenMirrorIntervalsUseObservationEndAndCapturedNow() {
        let interrupted = mirror("interrupted", start: now.addingTimeInterval(-120), end: now)
        interrupted.completedAt = nil
        interrupted.observationEndedAt = now.addingTimeInterval(-60)
        let open = mirror("open", start: now.addingTimeInterval(-90), end: now)
        open.completedAt = nil
        let statistics = aggregate([open, interrupted], batchSize: 1)
        XCTAssertEqual(statistics.totalCount, 1)
        XCTAssertEqual(statistics.totalDuration, 120)
        XCTAssertEqual(statistics.totalDuration,
                       HistoryUsageSummary.aggregate([open, interrupted], now: now).first?.duration)
    }

    func testMirrorIdentityKeepsAgentsNamespacesAndOpaqueTaskBytesSeparate() {
        let original = mirror("original", start: now, end: now)
        let otherAgent = mirror("agent", start: now, end: now)
        otherAgent.agentTypeRaw = AgentType.pearai.rawValue
        let otherProfile = mirror("profile", start: now, end: now)
        otherProfile.sourceNamespace = "other-profile"
        let otherTask = mirror("task", start: now, end: now, task: "other-task")
        let composed = mirror("composed", start: now, end: now, task: "é")
        let decomposed = mirror("decomposed", start: now, end: now, task: "e\u{301}")
        let records = [original, otherAgent, otherProfile, otherTask, composed, decomposed]
        XCTAssertEqual(aggregate(records).totalCount, 6)
        XCTAssertEqual(aggregate(records).totalCount, HistoryUsageSummary.aggregate(records, now: now).count)
    }

    func testMirrorToolCallsDeduplicateWithinTaskAndRetainOtherTasksAndLegacyEvents() {
        let first = mirror("first", start: now, end: now)
        let second = mirror("second", start: now, end: now)
        let otherTask = mirror("other", start: now, end: now, task: "other-task")
        let eventId = UUID()
        for record in [first, second] {
            let event = StoredToolEvent(tool: "write", isComplete: true)
            event.eventId = eventId
            record.toolEvents = [
                StoredToolEvent(tool: "read", isComplete: true, toolCallId: "same-call"),
                event,
                StoredToolEvent(tool: "legacy", isComplete: true),
                StoredToolEvent(tool: "pending", toolCallId: "pending-call"),
            ]
        }
        otherTask.toolEvents = [StoredToolEvent(tool: "read", isComplete: true, toolCallId: "same-call")]
        let statistics = aggregate([first, otherTask, second], batchSize: 1)
        let counts = Dictionary(uniqueKeysWithValues: statistics.toolFrequencies.map { ($0.toolName, $0.callCount) })
        XCTAssertEqual(counts, ["read": 2, "write": 1, "legacy": 2])
    }

    func testFullHistoryLoadIncludes10001RecordsBeyondOldLimit() throws {
        let manager = try makeManager()
        let context = try XCTUnwrap(manager.modelContainer).mainContext
        context.autosaveEnabled = false
        for index in 0..<10_001 {
            let old = index == 10_000
            let session = makeSession(id: String(format: "record-%05d", index),
                agentType: old ? .codex : .claudeCode,
                startTime: old ? day(-90) : now,
                totalTokens: old ? 7 : 1, cost: old ? 0.5 : 0.01)
            if old { session.toolEvents = [StoredToolEvent(tool: "old-tool", isComplete: true)] }
            context.insert(session)
        }
        try context.save()

        let all = try HistoryStatistics.load(from: manager, timeRange: .all, now: now, calendar: calendar)
        XCTAssertEqual(all.totalCount, 10_001)
        XCTAssertEqual(all.totalTokens, 10_007)
        XCTAssertEqual(all.totalCost, 100.5, accuracy: 0.0001)
        XCTAssertEqual(all.totalDuration, 10_001 * 60)
        XCTAssertEqual(all.dailyUsages.map(\.sessionCount), [1, 10_000])
        XCTAssertEqual(all.agentUsages.last?.agentType, .codex)
        XCTAssertEqual(all.toolFrequencies.first?.toolName, "old-tool")
        XCTAssertEqual(all.toolFrequencies.first?.callCount, 1)
        let week = try HistoryStatistics.load(from: manager, timeRange: .week, now: now, calendar: calendar)
        XCTAssertEqual(week.totalCount, 10_000)
        XCTAssertEqual(week.totalTokens, 10_000)
        XCTAssertTrue(week.toolFrequencies.isEmpty)
    }

    func testRevisionRequestsReloadSavedAndDeletedHistory() throws {
        let manager = try makeManager()
        var state = HistoryStatistics.LoadState()
        let initial = HistoryStatistics.LoadRequest(timeRange: .all, revision: manager.revision)
        state.reload(from: manager, timeRange: .all, now: now, calendar: calendar)
        XCTAssertEqual(state.statistics?.totalCount, 0)

        let session = AgentSession(id: "fresh", agentType: .codex, startTime: now)
        session.completedAt = now.addingTimeInterval(60)
        session.status = .completed
        session.tokenUsage.totalTokens = 120
        XCTAssertTrue(manager.save(session: session))
        let saved = HistoryStatistics.LoadRequest(timeRange: .all, revision: manager.revision)
        XCTAssertNotEqual(saved, initial)
        state.reload(from: manager, timeRange: .all, now: now, calendar: calendar)
        XCTAssertEqual(state.statistics?.totalCount, 1)
        XCTAssertEqual(state.statistics?.totalTokens, 120)

        session.tokenUsage.totalTokens = 180
        XCTAssertTrue(manager.save(session: session))
        let updated = HistoryStatistics.LoadRequest(timeRange: .all, revision: manager.revision)
        XCTAssertNotEqual(updated, saved)
        state.reload(from: manager, timeRange: .all, now: now, calendar: calendar)
        XCTAssertEqual(state.statistics?.totalCount, 1)
        XCTAssertEqual(state.statistics?.totalTokens, 180)

        let stored = try XCTUnwrap(manager.fetchHistory().first)
        manager.deleteSession(stored)
        XCTAssertNotEqual(HistoryStatistics.LoadRequest(timeRange: .all, revision: manager.revision), updated)
        XCTAssertNotEqual(HistoryStatistics.LoadRequest(timeRange: .week, revision: saved.revision), saved)
        state.reload(from: manager, timeRange: .all, now: now, calendar: calendar)
        XCTAssertEqual(state.statistics?.totalCount, 0)
        XCTAssertNil(state.errorMessage)
    }

    func testStorageFailureIsDistinctFromEmptyAndRetryRecovers() throws {
        let manager = try makeManager()
        let container = try XCTUnwrap(manager.modelContainer)
        let context = container.mainContext
        context.insert(makeSession(totalTokens: 42))
        try context.save()
        var state = HistoryStatistics.LoadState()
        state.reload(from: manager, timeRange: .all, now: now, calendar: calendar)
        XCTAssertEqual(state.statistics?.totalCount, 1)
        XCTAssertNil(state.errorMessage)

        manager.modelContainer = nil
        XCTAssertThrowsError(try HistoryStatistics.load(from: manager, timeRange: .all, now: now, calendar: calendar))
        state.reload(from: manager, timeRange: .all, now: now, calendar: calendar)
        XCTAssertNil(state.statistics)
        XCTAssertNotNil(state.errorMessage)

        manager.modelContainer = container
        state.reload(from: manager, timeRange: .all, now: now, calendar: calendar)
        XCTAssertEqual(state.statistics?.totalTokens, 42)
        XCTAssertNil(state.errorMessage)
    }
}
