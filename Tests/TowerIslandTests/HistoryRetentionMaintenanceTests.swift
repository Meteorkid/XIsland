import XCTest
import SwiftData
@testable import XIsland

@MainActor
final class HistoryRetentionMaintenanceTests: XCTestCase {
    private func makeManager() throws -> SessionPersistenceManager {
        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self,
                             StoredKimiCodeApprovalOrphan.self])
        let manager = SessionPersistenceManager()
        manager.modelContainer = try ModelContainer(for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return manager
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "dev.xisland.tests.retention.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func save(_ id: String, daysAgo: Int, in manager: SessionPersistenceManager) {
        let end = Date(timeIntervalSinceNow: -Double(daysAgo) * 86400)
        let session = AgentSession(id: id, agentType: .codex, startTime: end.addingTimeInterval(-60))
        session.status = .completed
        session.completedAt = end
        XCTAssertTrue(manager.save(session: session), manager.lastSaveError ?? "")
    }

    func testStartImmediatelyAppliesDefaultThirtyDayRetention() throws {
        let manager = try makeManager()
        let maintenance = HistoryRetentionMaintenance(manager: manager, defaults: try makeDefaults())
        defer { maintenance.stop() }
        save("expired", daysAgo: 90, in: manager)
        save("recent", daysAgo: 10, in: manager)

        maintenance.start()

        XCTAssertTrue(maintenance.isRunning)
        XCTAssertEqual(manager.totalCount(), 1)
        XCTAssertNil(try manager.sessionState(sessionId: "expired"))
        XCTAssertNotNil(try manager.sessionState(sessionId: "recent"))
    }

    func testRunReadsChangedRetentionPreference() throws {
        let manager = try makeManager()
        let defaults = try makeDefaults()
        defaults.set(30, forKey: "historyRetentionDays")
        let maintenance = HistoryRetentionMaintenance(manager: manager, defaults: defaults)
        save("twenty-days", daysAgo: 20, in: manager)

        maintenance.run()
        XCTAssertEqual(manager.totalCount(), 1)
        defaults.set(7, forKey: "historyRetentionDays")
        maintenance.run()

        XCTAssertEqual(manager.totalCount(), 0)
        XCTAssertFalse(maintenance.isRunning, "手动执行不应额外启动定时器")
    }

    func testNeverAndInvalidPreferencesNeverAutomaticallyClearHistory() throws {
        let manager = try makeManager()
        let defaults = try makeDefaults()
        let maintenance = HistoryRetentionMaintenance(manager: manager, defaults: defaults)
        save("expired", daysAgo: 90, in: manager)
        let revision = manager.revision
        let values: [Any] = [Int.max, 0, -1, "0", "7", 0.5, 7.5, true, false, NSNumber(value: UInt64.max)]

        for value in values {
            defaults.set(value, forKey: "historyRetentionDays")
            maintenance.run()
            XCTAssertEqual(manager.totalCount(), 1, "非法值或 Never 不应删除历史：\(value)")
            XCTAssertEqual(manager.revision, revision)
            XCTAssertNil(manager.lastSaveError)
        }
    }

    func testRepeatedStartDoesNotRunAgainAndStopCancelsAllScheduling() async throws {
        let manager = try makeManager()
        let defaults = try makeDefaults()
        defaults.set(Int.max, forKey: "historyRetentionDays")
        let maintenance = HistoryRetentionMaintenance(manager: manager, defaults: defaults, interval: 0.02)
        defer { maintenance.stop() }
        save("expired", daysAgo: 90, in: manager)
        maintenance.start()

        defaults.set(1, forKey: "historyRetentionDays")
        maintenance.start()
        XCTAssertEqual(manager.totalCount(), 1, "重复 start 应直接返回，不能再次立即清理")
        maintenance.stop()
        XCTAssertFalse(maintenance.isRunning)
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(manager.totalCount(), 1, "stop 后不应有遗留计时器继续清理")
    }

    func testTimerReadsCurrentPreferenceOnNextTick() async throws {
        let manager = try makeManager()
        let defaults = try makeDefaults()
        defaults.set(Int.max, forKey: "historyRetentionDays")
        let maintenance = HistoryRetentionMaintenance(manager: manager, defaults: defaults, interval: 0.02)
        defer { maintenance.stop() }
        save("expired", daysAgo: 90, in: manager)
        maintenance.start()
        XCTAssertEqual(manager.totalCount(), 1)
        defaults.set(1, forKey: "historyRetentionDays")

        for _ in 0..<100 {
            if manager.totalCount() == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(manager.totalCount(), 0, "下一次定时清理应采用更新后的保留期")
        XCTAssertTrue(maintenance.isRunning)
    }

    func testDeinitReleasesMaintenanceAndStopsTimer() async throws {
        let manager = try makeManager()
        let defaults = try makeDefaults()
        defaults.set(Int.max, forKey: "historyRetentionDays")
        save("expired", daysAgo: 90, in: manager)
        var maintenance: HistoryRetentionMaintenance? = HistoryRetentionMaintenance(
            manager: manager, defaults: defaults, interval: 0.02)
        weak var released = maintenance
        maintenance?.start()

        maintenance = nil
        defaults.set(1, forKey: "historyRetentionDays")
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertNil(released, "计时器不能强持有维护对象")
        XCTAssertEqual(manager.totalCount(), 1)
    }
}
