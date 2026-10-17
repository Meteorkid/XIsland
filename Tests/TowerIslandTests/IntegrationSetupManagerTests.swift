import Foundation
import XCTest
@testable import XIsland

@MainActor
final class IntegrationSetupManagerTests: XCTestCase {
    func testUnsupportedEditionRequiresSetupEvenWhenOldConfigurationExists() async throws {
        let fixture = Fixture(entries: [IntegrationSetupDiscoveryEntry(agent: .trae, installed: true,
            configured: true, fingerprint: "international", appURL: nil, codexBinary: nil,
            detail: nil, canAutoConfigure: false)])
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)
        await manager.refresh()
        XCTAssertEqual(phase(.trae, in: manager), .needsSetup)
        XCTAssertFalse(row(.trae, in: manager)?.canConfigure ?? true)
    }

    func testReadOnlyRefreshDoesNotPrepareOrConfigureClients() async throws {
        let fixture = Fixture(entries: [entry(.claudeCode, configured: false)])
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)

        await manager.refresh()

        XCTAssertEqual(phase(.claudeCode, in: manager), .needsConfiguration)
        XCTAssertTrue(fixture.configurationCalls.isEmpty)
        XCTAssertEqual(fixture.prepareCalls, 0)
        XCTAssertFalse(manager.isRefreshing)
    }

    func testAutomaticPreparationOnlyConfiguresDetectedEnabledSupportedRoutes() async throws {
        let fixture = Fixture(entries: [
            entry(.claudeCode, configured: false),
            entry(.codex, installed: false, configured: false),
            entry(.cursor, configured: false),
            entry(.workBuddy, configured: false),
            entry(.geminiCli),
        ])
        fixture.disabledAgents = [.cursor]
        fixture.successfulConfigurations = [.claudeCode]
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)

        await manager.refresh(prepareAutomatically: true)

        XCTAssertEqual(fixture.configurationCalls, [.claudeCode])
        XCTAssertEqual(fixture.prepareCalls, 1)
        XCTAssertEqual(fixture.scanCalls, 2, "配置完成后应重新扫描实际结果")
        XCTAssertEqual(phase(.claudeCode, in: manager), .waitingForActivity)
        XCTAssertEqual(phase(.codex, in: manager), .notInstalled)
        XCTAssertEqual(phase(.cursor, in: manager), .disabled)
        XCTAssertEqual(phase(.workBuddy, in: manager), .needsSetup)
        XCTAssertTrue(fixture.inspectedBinaries.isEmpty)
    }

    func testAutomaticPreparationWithNoEligibleClientsDoesNotWriteAnything() async throws {
        let fixture = Fixture(entries: [entry(.claudeCode, installed: false, configured: false),
                                        entry(.zed, configured: false), entry(.cursor, configured: false)])
        fixture.disabledAgents = [.cursor]
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)

        await manager.refresh(prepareAutomatically: true)

        XCTAssertTrue(fixture.configurationCalls.isEmpty)
        XCTAssertEqual(fixture.prepareCalls, 0)
    }

    func testFailedAutomaticConfigurationIsNotRepeatedForSameFingerprintAfterRestart() async throws {
        let defaults = try makeDefaults()
        let fixture = Fixture(entries: [entry(.claudeCode, configured: false)])
        let manager = IntegrationSetupManager(defaults: defaults, environment: fixture.environment)
        await manager.refresh(prepareAutomatically: true)
        await manager.refresh(prepareAutomatically: true)
        XCTAssertEqual(phase(.claudeCode, in: manager), .needsConfiguration)

        let restarted = IntegrationSetupManager(defaults: defaults, environment: fixture.environment)
        await restarted.refresh(prepareAutomatically: true)

        XCTAssertEqual(fixture.configurationCalls, [.claudeCode])
        XCTAssertEqual(phase(.claudeCode, in: restarted), .needsConfiguration)
    }

    func testExplicitConfigureCanRetryAFailedAutomaticAttempt() async throws {
        let fixture = Fixture(entries: [entry(.claudeCode, configured: false)])
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)
        await manager.refresh(prepareAutomatically: true)
        fixture.successfulConfigurations = [.claudeCode]

        await manager.configure(.claudeCode)

        XCTAssertEqual(fixture.configurationCalls, [.claudeCode, .claudeCode])
        XCTAssertEqual(phase(.claudeCode, in: manager), .waitingForActivity)
        XCTAssertNil(row(.claudeCode, in: manager)?.lastSeen)
    }

    func testExplicitConfigureDoesNotWriteForMissingManualOrUnknownClients() async throws {
        let fixture = Fixture(entries: [entry(.claudeCode, installed: false, configured: false),
                                        entry(.zed, configured: false)])
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)
        await manager.refresh()

        await manager.configure(.claudeCode)
        await manager.configure(.zed)
        await manager.configure(.cursor)

        XCTAssertTrue(fixture.configurationCalls.isEmpty)
        XCTAssertEqual(fixture.prepareCalls, 0)
    }

    func testRequiredCodexAuthorizationCannotConnectAndPresentedReminderSurvivesRestart() async throws {
        let defaults = try makeDefaults()
        let fixture = Fixture(entries: [entry(.codex)])
        fixture.codexSnapshot = trust(.required)
        let manager = IntegrationSetupManager(defaults: defaults, environment: fixture.environment)
        var reminders = 0
        manager.onNeedsAttention = { reminders += 1 }

        await manager.refresh()
        manager.recordActivity(from: .codex)

        XCTAssertEqual(phase(.codex, in: manager), .needsAuthorization)
        XCTAssertEqual(manager.attentionCount, 1)
        XCTAssertNil(row(.codex, in: manager)?.lastSeen)
        XCTAssertTrue(manager.hasUnpresentedReminder)
        XCTAssertEqual(reminders, 1)
        manager.markPresented()
        await manager.refresh()
        XCTAssertFalse(manager.hasUnpresentedReminder)
        XCTAssertEqual(reminders, 1)

        let restarted = IntegrationSetupManager(defaults: defaults, environment: fixture.environment)
        await restarted.refresh()
        XCTAssertEqual(phase(.codex, in: restarted), .needsAuthorization)
        XCTAssertFalse(restarted.hasUnpresentedReminder)
    }

    func testCodexGrantStillWaitsForActivityBeforeConnecting() async throws {
        let fixture = Fixture(entries: [entry(.codex)])
        fixture.codexSnapshot = trust(.required)
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)
        await manager.refresh()
        manager.markPresented()
        fixture.codexSnapshot = trust(.granted)

        await manager.refresh()

        XCTAssertEqual(phase(.codex, in: manager), .waitingForActivity)
        XCTAssertNil(row(.codex, in: manager)?.lastSeen)
        let receivedAt = Date(timeIntervalSince1970: 1_792_180_800)
        manager.recordActivity(from: .codex, at: receivedAt)
        XCTAssertEqual(phase(.codex, in: manager), .connected)
        XCTAssertEqual(row(.codex, in: manager)?.lastSeen, receivedAt)
        XCTAssertEqual(manager.attentionCount, 0)
        XCTAssertFalse(manager.hasUnpresentedReminder)
    }

    func testRevokedCodexAuthorizationClearsOldActivityAndRemindsAgain() async throws {
        let defaults = try makeDefaults()
        let fixture = Fixture(entries: [entry(.codex)])
        let manager = IntegrationSetupManager(defaults: defaults, environment: fixture.environment)
        await manager.refresh()
        manager.recordActivity(from: .codex)
        manager.markPresented()
        XCTAssertEqual(phase(.codex, in: manager), .connected)
        fixture.codexSnapshot = trust(.required)

        await manager.refresh()

        XCTAssertEqual(phase(.codex, in: manager), .needsAuthorization)
        XCTAssertTrue(manager.hasUnpresentedReminder)
        XCTAssertNil(row(.codex, in: manager)?.lastSeen)
        manager.markPresented()
        fixture.codexSnapshot = trust(.granted)
        let restarted = IntegrationSetupManager(defaults: defaults, environment: fixture.environment)
        await restarted.refresh()
        XCTAssertEqual(phase(.codex, in: restarted), .waitingForActivity,
                       "重新授权不能复用撤销前的活动，即使已重启")
        XCTAssertNil(row(.codex, in: restarted)?.lastSeen)
        restarted.recordActivity(from: .codex)
        XCTAssertEqual(phase(.codex, in: restarted), .connected)
    }

    func testConnectedConfigurationAndLastActivityAreRememberedAcrossRestart() async throws {
        for agent in [AgentType.claudeCode, .codex] {
            let defaults = try makeDefaults()
            let fixture = Fixture(entries: [entry(agent)])
            let manager = IntegrationSetupManager(defaults: defaults, environment: fixture.environment)
            await manager.refresh()
            let receivedAt = Date(timeIntervalSince1970: 1_792_180_800)
            manager.recordActivity(from: agent, at: receivedAt)

            let restarted = IntegrationSetupManager(defaults: defaults, environment: fixture.environment)
            await restarted.refresh(prepareAutomatically: true)

            XCTAssertEqual(phase(agent, in: restarted), .connected, agent.rawValue)
            XCTAssertEqual(row(agent, in: restarted)?.lastSeen, receivedAt, agent.rawValue)
            XCTAssertFalse(restarted.hasUnpresentedReminder, agent.rawValue)
            XCTAssertTrue(fixture.configurationCalls.isEmpty, agent.rawValue)
        }
    }

    func testChangedConfigurationNeedsNewActivityAndAnotherIntroduction() async throws {
        let fixture = Fixture(entries: [entry(.claudeCode)])
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)
        await manager.refresh()
        manager.recordActivity(from: .claudeCode)
        manager.markPresented()
        fixture.entries = [entry(.claudeCode, fingerprint: "configuration-v2")]

        await manager.refresh()

        XCTAssertEqual(phase(.claudeCode, in: manager), .waitingForActivity)
        XCTAssertNil(row(.claudeCode, in: manager)?.lastSeen)
        XCTAssertTrue(manager.hasUnpresentedReminder)
        manager.markPresented()
        await manager.refresh()
        XCTAssertFalse(manager.hasUnpresentedReminder)
        manager.recordActivity(from: .claudeCode)
        XCTAssertEqual(phase(.claudeCode, in: manager), .connected)
    }

    func testChangedFailedConfigurationFingerprintAllowsOneNewAutomaticAttempt() async throws {
        let fixture = Fixture(entries: [entry(.claudeCode, configured: false)])
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)
        await manager.refresh(prepareAutomatically: true)
        manager.markPresented()
        fixture.entries = [entry(.claudeCode, configured: false, fingerprint: "configuration-v2")]

        await manager.refresh(prepareAutomatically: true)
        await manager.refresh(prepareAutomatically: true)

        XCTAssertEqual(fixture.configurationCalls, [.claudeCode, .claudeCode])
        XCTAssertTrue(manager.hasUnpresentedReminder)
    }

    func testChangedCodexTrustDefinitionRequiresNewAuthorizationReminder() async throws {
        let fixture = Fixture(entries: [entry(.codex)])
        fixture.codexSnapshot = trust(.required)
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)
        await manager.refresh()
        manager.markPresented()
        fixture.codexSnapshot = trust(.required, fingerprint: "hooks-v2")

        await manager.refresh()

        XCTAssertEqual(phase(.codex, in: manager), .needsAuthorization)
        XCTAssertTrue(manager.hasUnpresentedReminder)
        XCTAssertNil(row(.codex, in: manager)?.lastSeen)
    }

    func testUnavailableCodexProbeDoesNotAcceptActivity() async throws {
        let fixture = Fixture(entries: [entry(.codex)])
        fixture.codexSnapshot = trust(.unavailable, fingerprint: nil)
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)
        await manager.refresh()
        manager.recordActivity(from: .codex)

        XCTAssertEqual(phase(.codex, in: manager), .checkFailed)
        XCTAssertNil(row(.codex, in: manager)?.lastSeen)
        fixture.codexSnapshot = trust(.granted)
        await manager.refresh()
        XCTAssertEqual(phase(.codex, in: manager), .waitingForActivity)
        XCTAssertNil(row(.codex, in: manager)?.lastSeen)
    }

    func testUnconfiguredCodexCannotAcceptActivityBeforeAuthorizationIsChecked() async throws {
        let fixture = Fixture(entries: [entry(.codex, configured: false)])
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)
        await manager.refresh()
        manager.recordActivity(from: .codex)

        XCTAssertEqual(phase(.codex, in: manager), .needsConfiguration)
        XCTAssertNil(row(.codex, in: manager)?.lastSeen)
        XCTAssertTrue(fixture.inspectedBinaries.isEmpty)
    }

    func testMissingCodexBinaryCannotBypassAuthorizationCheck() async throws {
        let fixture = Fixture(entries: [entry(.codex, hasCodexBinary: false)])
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)
        await manager.refresh()
        manager.recordActivity(from: .codex)

        XCTAssertEqual(phase(.codex, in: manager), .checkFailed)
        XCTAssertNil(row(.codex, in: manager)?.lastSeen)
        XCTAssertTrue(fixture.inspectedBinaries.isEmpty)
    }

    func testManualRouteCanConnectFromActivityWithoutAutomaticConfiguration() async throws {
        let fixture = Fixture(entries: [entry(.zed, configured: false), entry(.workBuddy, configured: false)])
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)
        await manager.refresh(prepareAutomatically: true)

        for agent in [AgentType.zed, .workBuddy] {
            XCTAssertEqual(phase(agent, in: manager), .needsSetup)
            manager.recordActivity(from: agent)
            XCTAssertEqual(phase(agent, in: manager), .connected)
            XCTAssertNotNil(row(agent, in: manager)?.lastSeen)
        }
        XCTAssertTrue(fixture.configurationCalls.isEmpty)
        XCTAssertEqual(fixture.prepareCalls, 1)
        XCTAssertEqual(fixture.artifactCalls, [.workBuddy])
    }

    func testDisabledUnknownAndGLMSourcesCannotRecordActivity() async throws {
        let fixture = Fixture(entries: [entry(.claudeCode), entry(.glm)])
        fixture.disabledAgents = [.claudeCode]
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)
        await manager.refresh()

        for agent in [AgentType.claudeCode, .cursor, .glm, .hermes] {
            manager.recordActivity(from: agent)
            XCTAssertNil(row(agent, in: manager)?.lastSeen, agent.rawValue)
        }
        XCTAssertEqual(phase(.claudeCode, in: manager), .disabled)
        XCTAssertEqual(phase(.cursor, in: manager), .notInstalled)
        XCTAssertEqual(phase(.glm, in: manager), .needsSetup)
        XCTAssertNil(row(.hermes, in: manager))
    }

    func testWaitingForFirstActivityIsIntroducedOnlyOnceAcrossRestart() async throws {
        let defaults = try makeDefaults()
        let fixture = Fixture(entries: [entry(.claudeCode)])
        let manager = IntegrationSetupManager(defaults: defaults, environment: fixture.environment)
        var reminders = 0
        manager.onNeedsAttention = { reminders += 1 }
        await manager.refresh()
        XCTAssertEqual(phase(.claudeCode, in: manager), .waitingForActivity)
        XCTAssertTrue(manager.hasUnpresentedReminder)
        XCTAssertEqual(reminders, 1)
        manager.markPresented()

        await manager.refresh()
        let restarted = IntegrationSetupManager(defaults: defaults, environment: fixture.environment)
        await restarted.refresh()

        XCTAssertEqual(reminders, 1)
        XCTAssertFalse(manager.hasUnpresentedReminder)
        XCTAssertFalse(restarted.hasUnpresentedReminder)
        XCTAssertEqual(phase(.claudeCode, in: restarted), .waitingForActivity)
    }

    func testDismissingDuringCodexProbeRemembersTheFinalStateWithoutPromptingAgain() async throws {
        let defaults = try makeDefaults()
        let fixture = Fixture(entries: [entry(.codex)])
        let required = trust(.required)
        fixture.codexSnapshot = required
        let manager = IntegrationSetupManager(defaults: defaults, environment: fixture.environment)
        await manager.refresh()
        manager.markPresented()
        var reminders = 0
        manager.onNeedsAttention = { reminders += 1 }
        let probeStarted = expectation(description: "Codex 授权检查已开始")
        var pendingProbe: CheckedContinuation<CodexHookTrustSnapshot, Never>?
        defer { pendingProbe?.resume(returning: required) }
        fixture.inspectCodex = { _ in
            await withCheckedContinuation { continuation in
                pendingProbe = continuation
                probeStarted.fulfill()
            }
        }

        let refresh = Task { await manager.refresh() }
        await fulfillment(of: [probeStarted], timeout: 2)
        XCTAssertTrue(manager.isRefreshing)
        manager.markPresented() // 用户在检查结束前关闭接入窗口。
        let continuation = try XCTUnwrap(pendingProbe)
        pendingProbe = nil
        continuation.resume(returning: required)
        await refresh.value

        XCTAssertFalse(manager.isRefreshing)
        XCTAssertEqual(phase(.codex, in: manager), .needsAuthorization)
        XCTAssertFalse(manager.hasUnpresentedReminder)
        XCTAssertEqual(reminders, 0)
        fixture.inspectCodex = nil
        let restarted = IntegrationSetupManager(defaults: defaults, environment: fixture.environment)
        await restarted.refresh()
        XCTAssertFalse(restarted.hasUnpresentedReminder)
    }

    func testRefreshRequestedDuringCodexProbeAppliesChangedEnablementAfterProbeFinishes() async throws {
        let fixture = Fixture(entries: [entry(.codex), entry(.claudeCode)])
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)
        await manager.refresh()
        let receivedAt = Date(timeIntervalSince1970: 1_792_180_800)
        manager.recordActivity(from: .claudeCode, at: receivedAt)
        manager.markPresented()
        let probeStarted = expectation(description: "并发刷新前 Codex 检查已开始")
        let granted = trust(.granted)
        var pendingProbe: CheckedContinuation<CodexHookTrustSnapshot, Never>?
        var shouldSuspend = true
        defer { pendingProbe?.resume(returning: granted) }
        fixture.inspectCodex = { _ in
            guard shouldSuspend else { return granted }
            shouldSuspend = false
            return await withCheckedContinuation { continuation in
                pendingProbe = continuation
                probeStarted.fulfill()
            }
        }

        let refresh = Task { await manager.refresh() }
        await fulfillment(of: [probeStarted], timeout: 2)
        fixture.disabledAgents.insert(.claudeCode)
        manager.recordActivity(from: .claudeCode, at: receivedAt.addingTimeInterval(60))
        XCTAssertEqual(row(.claudeCode, in: manager)?.lastSeen, receivedAt,
                       "开关关闭后不能再按刷新前的 enabled 状态接受活动")
        await manager.refresh() // 模拟设置开关写入后请求刷新。
        let continuation = try XCTUnwrap(pendingProbe)
        pendingProbe = nil
        continuation.resume(returning: granted)
        await refresh.value

        XCTAssertFalse(manager.isRefreshing)
        XCTAssertGreaterThanOrEqual(fixture.scanCalls, 3, "应在正在进行的检查结束后补做一次扫描")
        XCTAssertEqual(phase(.claudeCode, in: manager), .disabled)
        XCTAssertNil(row(.claudeCode, in: manager)?.lastSeen)
    }

    func testAutomaticManualArtifactsArePreparedWithoutConfiguringOrConnectingClients() async throws {
        let fixture = Fixture(entries: [entry(.workBuddy, configured: false), entry(.kiro, configured: false),
                                        entry(.zed, configured: false), entry(.claudeCode, installed: false)])
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)

        await manager.refresh(prepareAutomatically: true)
        await manager.refresh(prepareAutomatically: true)

        XCTAssertEqual(fixture.artifactCalls, [.workBuddy, .kiro], "同一运行内已准备的文件不应重复生成")
        XCTAssertEqual(fixture.prepareCalls, 1)
        XCTAssertTrue(fixture.configurationCalls.isEmpty)
        for agent in [AgentType.workBuddy, .kiro] {
            XCTAssertEqual(phase(agent, in: manager), .needsSetup)
            XCTAssertNil(row(agent, in: manager)?.lastSeen)
            let detail = try XCTUnwrap(row(agent, in: manager)?.detail)
            XCTAssertTrue(detail.contains("接入文件已准备") || detail.contains("Setup files are ready"))
        }
    }

    func testArtifactPreparationFailureIsVisibleAndCanBeRetriedExplicitly() async throws {
        let fixture = Fixture(entries: [entry(.workBuddy, configured: false)])
        fixture.failedArtifacts = [.workBuddy]
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)
        await manager.refresh()

        XCTAssertNil(manager.prepareFiles(for: .workBuddy))

        let failureDetail = try XCTUnwrap(row(.workBuddy, in: manager)?.detail)
        XCTAssertTrue(failureDetail.contains("接入文件未能准备") || failureDetail.contains("Setup files could not be prepared"))
        XCTAssertEqual(phase(.workBuddy, in: manager), .needsSetup)
        await manager.refresh(prepareAutomatically: true)
        XCTAssertEqual(fixture.artifactCalls, [.workBuddy], "失败后不能在自动刷新中不断重复写入")
        fixture.failedArtifacts.remove(.workBuddy)

        let prepared = manager.prepareFiles(for: .workBuddy)

        XCTAssertEqual(prepared, URL(fileURLWithPath: "/fixture/integrations/workbuddy"))
        XCTAssertEqual(fixture.artifactCalls, [.workBuddy, .workBuddy])
        XCTAssertTrue(fixture.configurationCalls.isEmpty)
        XCTAssertNotEqual(row(.workBuddy, in: manager)?.detail, failureDetail)
        XCTAssertEqual(phase(.workBuddy, in: manager), .needsSetup)
        XCTAssertNil(row(.workBuddy, in: manager)?.lastSeen)
    }

    func testMissingDisabledAndUnsupportedManualRoutesDoNotPrepareArtifacts() async throws {
        let fixture = Fixture(entries: [entry(.workBuddy, installed: false, configured: false),
                                        entry(.kiro, configured: false), entry(.zed, configured: false)])
        fixture.disabledAgents = [.kiro]
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)

        await manager.refresh(prepareAutomatically: true)
        for agent in [AgentType.workBuddy, .kiro, .zed] {
            XCTAssertNil(manager.prepareFiles(for: agent))
        }

        XCTAssertTrue(fixture.artifactCalls.isEmpty)
        XCTAssertTrue(fixture.configurationCalls.isEmpty)
        XCTAssertEqual(fixture.prepareCalls, 0)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "dev.xisland.tests.integration-manager.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func row(_ agent: AgentType, in manager: IntegrationSetupManager) -> IntegrationSetupRow? {
        manager.rows.first { $0.agent == agent }
    }

    private func phase(_ agent: AgentType, in manager: IntegrationSetupManager) -> IntegrationSetupPhase? {
        row(agent, in: manager)?.phase
    }

    private func entry(_ agent: AgentType, installed: Bool = true, configured: Bool = true,
                       fingerprint: String = "configuration-v1", hasCodexBinary: Bool = true) -> IntegrationSetupDiscoveryEntry {
        IntegrationSetupDiscoveryEntry(agent: agent, installed: installed, configured: configured,
            fingerprint: fingerprint, appURL: nil,
            codexBinary: agent == .codex && hasCodexBinary ? URL(fileURLWithPath: "/fixture/codex") : nil,
            detail: "Isolated integration fixture",
            canAutoConfigure: IntegrationSetupDescriptor.descriptor(for: agent, language: "en").canAutoConfigure)
    }

    private func trust(_ state: CodexHookTrustSnapshot.State, fingerprint: String? = "hooks-v1") -> CodexHookTrustSnapshot {
        CodexHookTrustSnapshot(state: state, fingerprint: fingerprint, configuredCount: 12,
                              trustedCount: state == .granted ? 12 : 0, reason: nil)
    }

    @MainActor
    private final class Fixture {
        var entries: [IntegrationSetupDiscoveryEntry]
        var disabledAgents: Set<AgentType> = []
        var successfulConfigurations: Set<AgentType> = []
        var codexSnapshot = CodexHookTrustSnapshot(state: .granted, fingerprint: "hooks-v1",
                                                  configuredCount: 12, trustedCount: 12, reason: nil)
        var configurationCalls: [AgentType] = []
        var prepareCalls = 0
        var scanCalls = 0
        var inspectedBinaries: [URL] = []
        var inspectCodex: ((URL) async -> CodexHookTrustSnapshot)?
        var artifactCalls: [AgentType] = []
        var failedArtifacts: Set<AgentType> = []

        private enum ArtifactError: Error { case preparationFailed }

        init(entries: [IntegrationSetupDiscoveryEntry]) { self.entries = entries }

        var environment: IntegrationSetupManager.Environment {
            .init(scan: {
                self.scanCalls += 1
                return self.entries
            }, isEnabled: { !self.disabledAgents.contains($0) }, configure: { agent in
                self.configurationCalls.append(agent)
                guard self.successfulConfigurations.contains(agent),
                      let index = self.entries.firstIndex(where: { $0.agent == agent }) else { return }
                let previous = self.entries[index]
                self.entries[index] = IntegrationSetupDiscoveryEntry(agent: previous.agent,
                    installed: previous.installed, configured: true, fingerprint: previous.fingerprint + ":ready",
                    appURL: previous.appURL, codexBinary: previous.codexBinary,
                    detail: previous.detail, canAutoConfigure: previous.canAutoConfigure)
            }, prepareTools: {
                self.prepareCalls += 1
            }, inspectCodex: {
                self.inspectedBinaries.append($0)
                if let inspectCodex = self.inspectCodex { return await inspectCodex($0) }
                return self.codexSnapshot
            }, prepareArtifact: { agent in
                self.artifactCalls.append(agent)
                if self.failedArtifacts.contains(agent) { throw ArtifactError.preparationFailed }
                return URL(fileURLWithPath: "/fixture/integrations/\(agent.rawValue)")
            })
        }
    }
}
