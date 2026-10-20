import DIShared
import XCTest
@testable import XIsland

@MainActor
final class StartupIsolationTests: XCTestCase {
    override func setUpWithError() throws {
        // 隔离检测失效时先终止用例，不能用真实钥匙串操作来证明测试失败。
        _ = try XCTUnwrap(AppPreferences.isIsolated ? true : nil, "必须先进入隔离测试模式")
    }

    func testXCTestDisablesQuotaPollingForDefaultAndProductionConfigurations() {
        let defaultDelegate = AppDelegate()
        let productionDelegate = AppDelegate(
            testConfiguration: AppTestConfiguration.make(arguments: [], environment: [:])
        )

        XCTAssertFalse(defaultDelegate.quotaTracker.isPolling)
        XCTAssertFalse(productionDelegate.quotaTracker.isPolling)
        XCTAssertTrue(defaultDelegate.quotaTracker.quotas.isEmpty)
        XCTAssertTrue(productionDelegate.quotaTracker.quotas.isEmpty)
    }

    func testIsolatedQuotaRefreshesDoNotLoadLocalOrRemoteUsage() async {
        let tracker = QuotaTracker(testConfiguration: isolatedConfiguration())

        tracker.fetchAll()
        tracker.fetchAnthropic()
        tracker.fetchOpenAI()
        tracker.fetchKimi()
        tracker.fetchDeepSeek()
        tracker.fetchGLM()
        await Task.yield()

        XCTAssertFalse(tracker.isPolling)
        XCTAssertTrue(tracker.quotas.isEmpty)
    }

    func testAppDelegateIntegrationRefreshUsesIsolatedEnvironmentDuringTests() async {
        for configuration in [isolatedConfiguration(), AppTestConfiguration.make(arguments: [], environment: [:])] {
            let delegate = AppDelegate(testConfiguration: configuration)
            let manager = delegate.integrationSetupManager

            await manager.refresh(prepareAutomatically: true)

            XCTAssertEqual(manager.rows.count, AgentType.allCases.filter(\.isSupported).count)
            XCTAssertTrue(manager.rows.allSatisfy { $0.phase == .notInstalled })
            XCTAssertFalse(manager.hasUnpresentedReminder)
            XCTAssertEqual(manager.attentionCount, 0)
            XCTAssertFalse(manager.isRefreshing)
            let workBuddyFiles = await manager.prepareFiles(for: .workBuddy)
            let kiroFiles = await manager.prepareFiles(for: .kiro)
            XCTAssertNil(workBuddyFiles)
            XCTAssertNil(kiroFiles)
        }
    }

    func testKeychainEntryPointsRejectAccessDuringXCTest() {
        let provider = "test-isolation-" + UUID().uuidString

        XCTAssertNil(QuotaTracker.loadAPIKey(for: provider))
        XCTAssertFalse(QuotaTracker.saveAPIKey("test-value", for: provider))
        XCTAssertFalse(QuotaTracker.deleteAPIKey(for: provider))
        QuotaTracker.migrateKeychainAccessibility()
    }

    func testIntegrationSettingsUseIsolatedPreferencesDuringXCTest() {
        XCTAssertTrue(AppPreferences.isIsolated)
        XCTAssertTrue(IslandIntegrationSettings.sharedDefaults === AppPreferences.defaults)
        let previous = IslandIntegrationSettings.lastShownIsland
        defer { IslandIntegrationSettings.lastShownIsland = previous }
        IslandIntegrationSettings.markVisible(.xisland)

        XCTAssertEqual(AppPreferences.defaults.string(forKey: IslandIntegrationSettings.Key.lastShownIsland), "xisland")
    }

    func testTestSessionsNeverInvokeExternalWindowCapture() {
        for configuration in [isolatedConfiguration(), AppTestConfiguration.make(arguments: [], environment: [:])] {
            var captures = 0
            let manager = SessionManager(testConfiguration: configuration, captureWindowNumber: { _, _ in
                captures += 1
                return 123
            })
            var message = DIMessage(type: .sessionStart, sessionId: UUID().uuidString)
            message.agentType = AgentType.cursor.rawValue
            message.terminal = "Cursor"

            manager.handleMessage(message)

            XCTAssertEqual(captures, 0)
            XCTAssertEqual(manager.sessions.count, 1)
            XCTAssertNil(manager.sessions.first?.windowNumber)
        }
    }

    private func isolatedConfiguration() -> AppTestConfiguration {
        AppTestConfiguration.make(arguments: ["--ui-test-mode"], environment: [:])
    }
}
