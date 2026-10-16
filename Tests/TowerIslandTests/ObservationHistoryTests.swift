import XCTest
@testable import XIsland

@MainActor
final class ObservationHistoryTests: XCTestCase {
    private func session(_ id: String, start: TimeInterval = 0, end: TimeInterval = 60,
                         tokens: Int = 100, cost: Double = 1) -> AgentSession {
        let session = AgentSession(id: id, agentType: .rooCode, startTime: Date(timeIntervalSince1970: start))
        session.sourceNamespace = String(repeating: "a", count: 24)
        session.sourceInstanceId = UUID().uuidString.lowercased()
        session.nativeTaskId = "native-task"
        session.observationEndedAt = Date(timeIntervalSince1970: end)
        session.status = .observationUnavailable
        session.tokenUsage.inputTokens = tokens
        session.tokenUsage.estimatedCostUSD = cost
        return session
    }

    func testDiskRoundTripPreservesObservationIdentityAndFrozenDurationWithoutCompletingTask() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xi-observation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.store")
        let observed = session("observation")
        try autoreleasepool {
            let manager = SessionPersistenceManager()
            XCTAssertTrue(manager.setupContainer(storeURL: url), manager.lastSaveError ?? "")
            XCTAssertTrue(manager.save(session: observed))
            observed.tokenUsage.inputTokens = 150
            XCTAssertTrue(manager.save(session: observed))
            XCTAssertEqual(manager.totalCount(), 1)
        }
        try autoreleasepool {
            let manager = SessionPersistenceManager()
            XCTAssertTrue(manager.setupContainer(storeURL: url), manager.lastSaveError ?? "")
            let stored = try XCTUnwrap(manager.fetchHistory().first)
            XCTAssertEqual(stored.sourceNamespace, observed.sourceNamespace)
            XCTAssertEqual(stored.sourceInstanceId, observed.sourceInstanceId)
            XCTAssertEqual(stored.nativeTaskId, observed.nativeTaskId)
            XCTAssertEqual(stored.observationEndedAt, observed.observationEndedAt)
            XCTAssertEqual(stored.status, .observationUnavailable)
            XCTAssertEqual(stored.duration, 60)
            XCTAssertNil(stored.completedAt)
            XCTAssertEqual(stored.inputTokens, 150)
            manager.cleanup(olderThanDays: 30)
            XCTAssertEqual(manager.totalCount(), 0, "中断记录也按观察结束日期清理")
        }
    }

    func testSharedNativeTaskUsesMaximumCumulativeUsageAndUnionOfObservationIntervals() throws {
        let records = [session("a", tokens: 100, cost: 1),
                       session("b", start: 30, end: 90, tokens: 150, cost: 1.5),
                       session("reload", start: 120, end: 150, tokens: 170, cost: 1.7)]
        let summary = HistoryUsageSummary.aggregate(records.map { StoredSession(from: $0) })
        let group = try XCTUnwrap(summary.first)
        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(group.totalTokens, 170)
        XCTAssertEqual(group.costUSD, 1.7)
        XCTAssertEqual(group.duration, 120)
        XCTAssertEqual(group.startTime, Date(timeIntervalSince1970: 0))
    }

    func testInterruptedHistoryIsSortedAndPaginatedByObservationEndWithoutFakeCompletion() throws {
        let manager = SessionPersistenceManager()
        XCTAssertTrue(manager.setupContainer(isStoredInMemoryOnly: true))
        let old = AgentSession(id: "old", agentType: .claudeCode, startTime: Date(timeIntervalSince1970: 0))
        old.status = .completed; old.completedAt = Date(timeIntervalSince1970: 5)
        for record in [old, session("first"), session("second", start: 80, end: 100)] {
            XCTAssertTrue(manager.save(session: record))
        }
        XCTAssertEqual(manager.fetchHistory(limit: 1).first?.sessionId, "second")
        XCTAssertEqual(manager.fetchHistory(limit: 1, offset: 1).first?.sessionId, "first")
        XCTAssertEqual(manager.fetchHistory(limit: 1, offset: 2).first?.sessionId, "old")
        XCTAssertNil(manager.fetchHistory().first?.completedAt)
    }

    func testObservationExportKeepsSourceAndDoesNotLabelInterruptionAsCompletion() throws {
        let observed = session("export")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: ExportView.exportJSON(session: observed)) as? [String: Any])
        XCTAssertEqual(json["nativeTaskId"] as? String, observed.nativeTaskId)
        XCTAssertEqual(json["sourceInstanceId"] as? String, observed.sourceInstanceId)
        XCTAssertNil(json["completedAt"])
        XCTAssertNotNil(json["observationEndedAt"])
        let markdown = try XCTUnwrap(String(data: ExportView.exportMarkdown(session: observed), encoding: .utf8))
        XCTAssertTrue(markdown.contains("Observation interrupted:"))
        XCTAssertFalse(markdown.contains(" | Completed:"))
    }

    func testResumedObservationCannotEraseEarlierStartOrCumulativeUsage() throws {
        let manager = SessionPersistenceManager()
        XCTAssertTrue(manager.setupContainer(isStoredInMemoryOnly: true))
        let original = session("same", tokens: 200, cost: 2)
        XCTAssertTrue(manager.save(session: original))
        let resumed = session("same", start: 90, end: 120, tokens: 0, cost: 0)
        resumed.sourceInstanceId = original.sourceInstanceId
        XCTAssertEqual(manager.observationStartTime(sessionId: "same", namespace: original.sourceNamespace!,
            instance: original.sourceInstanceId!), original.startTime)
        XCTAssertTrue(manager.save(session: resumed))
        let stored = try XCTUnwrap(manager.fetchHistory().first)
        XCTAssertEqual(stored.startTime, original.startTime)
        XCTAssertEqual(stored.inputTokens, 200)
        XCTAssertEqual(stored.estimatedCostUSD, 2)
        XCTAssertEqual(stored.observationEndedAt, resumed.observationEndedAt)
        XCTAssertEqual(stored.duration, 120)
    }

    func testDifferentAgentsProfilesTasksAndLegacyRecordsRemainIndependent() {
        let original = session("original")
        let profile = session("profile"); profile.sourceNamespace = String(repeating: "b", count: 24)
        let task = session("task"); task.nativeTaskId = "another"
        let agent = session("agent"); agent.agentType = .pearai
        let legacy = AgentSession(id: "legacy", agentType: .rooCode)
        legacy.tokenUsage.totalTokens = 50
        let records = [original, profile, task, agent, legacy].map { StoredSession(from: $0) }
        XCTAssertEqual(HistoryUsageSummary.aggregate(records).count, 5)
        XCTAssertEqual(HistoryUsageSummary.aggregate(records).reduce(0) { $0 + $1.totalTokens }, 450)
    }

    func testOpaqueNativeTaskIdentityUsesOriginalUTF8Bytes() {
        let first = session("composed"), second = session("decomposed")
        first.nativeTaskId = "é"
        second.nativeTaskId = "e\u{301}"
        XCTAssertEqual(first.nativeTaskId, second.nativeTaskId, "Swift字符串比较会进行规范等价比较")
        XCTAssertEqual(HistoryUsageSummary.aggregate([StoredSession(from: first), StoredSession(from: second)]).count, 2)
    }

    func testInterruptedObservationIsNeitherRunningBlockedNorCompletedInProjectCounts() throws {
        let observed = session("unknown")
        observed.workingDirectory = "/tmp/project"
        let projects = AgentFlowAggregator.group(sessions: [observed])
        let project = try XCTUnwrap(projects.first)
        XCTAssertEqual(project.activeCount, 0)
        XCTAssertEqual(project.completedCount, 0)
        XCTAssertEqual(project.blockedCount, 0)
        XCTAssertEqual(project.unavailableCount, 1)
        XCTAssertEqual(observed.lastActivity, L10n.observationInterrupted)
    }
}
