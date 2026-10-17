import Foundation
import XCTest
@testable import XIsland

@MainActor
final class IntegrationSetupRecoveryTests: XCTestCase {
    func testSuccessfulPreparationCanRecoverAfterClientRemovesConfiguration() async throws {
        let fixture = Fixture()
        fixture.configurationSucceeds = true
        let defaults = try makeDefaults()
        let manager = IntegrationSetupManager(defaults: defaults, environment: fixture.environment)
        await manager.refresh(prepareAutomatically: true)
        XCTAssertTrue(fixture.configured)
        XCTAssertEqual(fixture.configurationCalls, 1)

        fixture.configured = false
        await manager.refresh(prepareAutomatically: true)

        XCTAssertTrue(fixture.configured)
        XCTAssertEqual(fixture.configurationCalls, 2)
        XCTAssertEqual(manager.rows.first { $0.agent == .claudeCode }?.phase, .waitingForActivity)
    }

    func testReadOnlyConfirmedRecoveryClearsFailedAttemptAcrossRestart() async throws {
        let fixture = Fixture()
        let defaults = try makeDefaults()
        let manager = IntegrationSetupManager(defaults: defaults, environment: fixture.environment)
        await manager.refresh(prepareAutomatically: true)
        XCTAssertEqual(fixture.configurationCalls, 1)
        XCTAssertFalse(fixture.configured)

        fixture.configured = true
        await manager.refresh()
        XCTAssertEqual(fixture.configurationCalls, 1, "只读确认恢复不应写入客户端")
        fixture.configured = false
        fixture.configurationSucceeds = true
        let restarted = IntegrationSetupManager(defaults: defaults, environment: fixture.environment)
        await restarted.refresh(prepareAutomatically: true)

        XCTAssertTrue(fixture.configured)
        XCTAssertEqual(fixture.configurationCalls, 2)
    }

    func testUnchangedFailedAttemptRemainsSuppressedAcrossRestart() async throws {
        let fixture = Fixture()
        let defaults = try makeDefaults()
        let manager = IntegrationSetupManager(defaults: defaults, environment: fixture.environment)
        await manager.refresh(prepareAutomatically: true)
        await manager.refresh()
        let restarted = IntegrationSetupManager(defaults: defaults, environment: fixture.environment)
        await restarted.refresh(prepareAutomatically: true)

        XCTAssertEqual(fixture.configurationCalls, 1)
        XCTAssertFalse(fixture.configured)
    }

    func testCodexActivityDuringProbeConnectsOnlyAfterGrantForSameDefinition() async throws {
        let fixture = ProbeFixture()
        let started = expectation(description: "probe started")
        fixture.onStart = { started.fulfill() }
        let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)
        let refresh = Task { await manager.refresh() }
        defer { fixture.finish(.unavailable) }
        await fulfillment(of: [started], timeout: 2)
        let received = Date()
        manager.recordActivity(from: .codex, at: received)
        XCTAssertNotEqual(manager.rows.first { $0.agent == .codex }?.phase, .connected)

        fixture.finish(.granted)
        await refresh.value

        XCTAssertEqual(manager.rows.first { $0.agent == .codex }?.phase, .connected)
        XCTAssertEqual(manager.rows.first { $0.agent == .codex }?.lastSeen, received)
        XCTAssertEqual(fixture.scanCalls, 2, "授权结果落地前只读复核当前配置")
    }

    func testCodexActivityDuringRejectedOrUnavailableProbeIsDiscarded() async throws {
        for result in [CodexHookTrustSnapshot.State.required, .unavailable] {
            let fixture = ProbeFixture()
            let started = expectation(description: "probe started")
            fixture.onStart = { started.fulfill() }
            let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)
            let refresh = Task { await manager.refresh() }
            defer { fixture.finish(.unavailable) }
            await fulfillment(of: [started], timeout: 2)
            manager.recordActivity(from: .codex)
            fixture.finish(result)
            await refresh.value
            XCTAssertNotEqual(manager.rows.first { $0.agent == .codex }?.phase, .connected)
            XCTAssertNil(manager.rows.first { $0.agent == .codex }?.lastSeen)

            fixture.suspends = false
            await manager.refresh()
            XCTAssertEqual(manager.rows.first { $0.agent == .codex }?.phase, .waitingForActivity,
                           "之后授权不能复用先前失败检查期间的活动")
        }
    }

    func testCodexActivityDuringProbeIsDiscardedIfConfigurationOrEnablementChanges() async throws {
        for change in ["definition", "removed", "disabled", "disabled-then-enabled"] {
            let fixture = ProbeFixture()
            let started = expectation(description: "probe started")
            fixture.onStart = { started.fulfill() }
            let manager = IntegrationSetupManager(defaults: try makeDefaults(), environment: fixture.environment)
            let refresh = Task { await manager.refresh() }
            defer { fixture.finish(.unavailable) }
            await fulfillment(of: [started], timeout: 2)
            manager.recordActivity(from: .codex)
            switch change {
            case "definition": fixture.fingerprint = "changed-definition"
            case "removed": fixture.configured = false
            case "disabled-then-enabled":
                fixture.enabled = false
                await manager.refresh()
                fixture.enabled = true
                fixture.suspends = false
            default: fixture.enabled = false
            }
            fixture.finish(.granted)
            await refresh.value
            XCTAssertNotEqual(manager.rows.first { $0.agent == .codex }?.phase, .connected, change)
            XCTAssertNil(manager.rows.first { $0.agent == .codex }?.lastSeen, change)

            fixture.suspends = false
            fixture.configured = true
            fixture.enabled = true
            await manager.refresh()
            XCTAssertEqual(manager.rows.first { $0.agent == .codex }?.phase, .waitingForActivity, change)
        }
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "xisland-recovery-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor
    private final class Fixture {
        var configured = false
        var configurationSucceeds = false
        var configurationCalls = 0

        var environment: IntegrationSetupManager.Environment {
            .init(scan: { [self] in
                [IntegrationSetupDiscoveryEntry(agent: .claudeCode, installed: true, configured: configured,
                    fingerprint: configured ? "definition-configured" : "definition-missing",
                    appURL: nil, codexBinary: nil, detail: nil, canAutoConfigure: true)]
            }, isEnabled: { _ in true }, configure: { [self] _ in
                configurationCalls += 1
                configured = configurationSucceeds
            }, prepareTools: {}, inspectCodex: { _ in
                CodexHookTrustSnapshot(state: .unavailable, fingerprint: nil,
                    configuredCount: 0, trustedCount: 0, reason: nil)
            })
        }
    }

    @MainActor
    private final class ProbeFixture {
        var fingerprint = "codex-definition"
        var configured = true
        var enabled = true
        var suspends = true
        var scanCalls = 0
        var onStart: (() -> Void)?
        private var continuation: CheckedContinuation<CodexHookTrustSnapshot, Never>?

        var environment: IntegrationSetupManager.Environment {
            .init(scan: { [self] in
                scanCalls += 1
                return [IntegrationSetupDiscoveryEntry(agent: .codex, installed: true, configured: configured,
                    fingerprint: fingerprint, appURL: nil, codexBinary: URL(fileURLWithPath: "/fixture/codex"),
                    detail: nil, canAutoConfigure: true)]
            }, isEnabled: { [self] _ in enabled }, configure: { _ in XCTFail("本测试不得配置客户端") },
            prepareTools: { XCTFail("本测试不得同步工具") }, inspectCodex: { [self] _ in
                guard suspends else { return snapshot(.granted) }
                return await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    onStart?()
                }
            })
        }

        func finish(_ state: CodexHookTrustSnapshot.State) {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: snapshot(state))
        }

        private func snapshot(_ state: CodexHookTrustSnapshot.State) -> CodexHookTrustSnapshot {
            .init(state: state, fingerprint: state == .unavailable ? nil : "codex-current-hash",
                  configuredCount: 12, trustedCount: state == .granted ? 12 : 0, reason: nil)
        }
    }
}
