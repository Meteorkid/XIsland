import Foundation
import os
import XCTest
@testable import XIsland

@MainActor
final class IntegrationSetupConcurrencyTests: XCTestCase {
    func testLicenseReactivationDoesNotLoseRefreshBehindCancelledStartup() async throws {
        let started = expectation(description: "old startup scan suspended")
        var pendingScan: CheckedContinuation<[IntegrationSetupDiscoveryEntry], Never>?
        var scans = 0
        var environment = environment()
        let latest = entry(.cursor, configured: true)
        environment.scan = {
            scans += 1
            if scans == 1 { return await withCheckedContinuation { pendingScan = $0; started.fulfill() } }
            return [latest]
        }
        let manager = IntegrationSetupManager(defaults: try defaults(), environment: environment)
        let oldStartup = Task { await manager.refresh(prepareAutomatically: true) }
        await fulfillment(of: [started], timeout: 2)
        oldStartup.cancel()
        manager.shutdown()
        manager.resumeAfterLicenseActivation()
        await manager.refresh()
        pendingScan?.resume(returning: [entry(.claudeCode)])
        await oldStartup.value
        let deadline = ContinuousClock.now + .seconds(1)
        while (scans < 2 || manager.isRefreshing), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(scans, 2)
        XCTAssertEqual(manager.rows.first { $0.agent == .cursor }?.phase, .waitingForActivity)
        XCTAssertFalse(manager.isRefreshing)
    }

    func testClosingPanelDiscardsInFlightScanWithoutPreparingClients() async throws {
        let started = expectation(description: "scan suspended")
        var pendingScan: CheckedContinuation<[IntegrationSetupDiscoveryEntry], Never>?
        var writes = 0
        var environment = environment()
        environment.scan = { await withCheckedContinuation { pendingScan = $0; started.fulfill() } }
        environment.prepareTools = { writes += 1 }
        environment.configure = { _ in writes += 1 }
        let manager = IntegrationSetupManager(defaults: try defaults(), environment: environment)
        let pending = Task { await manager.prepareAll() }
        await fulfillment(of: [started], timeout: 2)

        manager.endMonitoring()
        pendingScan?.resume(returning: [entry(.claudeCode)])
        await pending.value

        XCTAssertEqual(writes, 0)
        XCTAssertTrue(manager.rows.isEmpty)
        XCTAssertFalse(manager.isRefreshing)
    }

    func testRepeatedRefreshDiscardsOlderScanAndKeepsLatestPreparationIntent() async throws {
        let started = expectation(description: "first scan suspended")
        var pendingScan: CheckedContinuation<[IntegrationSetupDiscoveryEntry], Never>?
        var scans = 0
        var configured: [AgentType] = []
        var environment = environment()
        let latest = entry(.cursor, configured: true)
        environment.scan = {
            scans += 1
            if scans == 1 { return await withCheckedContinuation { pendingScan = $0; started.fulfill() } }
            return [latest]
        }
        environment.configure = { configured.append($0) }
        let manager = IntegrationSetupManager(defaults: try defaults(), environment: environment)
        let first = Task { await manager.refresh() }
        await fulfillment(of: [started], timeout: 2)
        await manager.refresh()
        await manager.prepareAll()
        pendingScan?.resume(returning: [entry(.claudeCode)])
        await first.value

        XCTAssertEqual(scans, 2, "重复请求应合并为最新一轮")
        XCTAssertTrue(configured.isEmpty, "过期扫描不能触发旧客户端配置")
        XCTAssertEqual(manager.rows.first { $0.agent == .cursor }?.phase, .waitingForActivity)
        XCTAssertEqual(manager.rows.first { $0.agent == .claudeCode }?.phase, .notInstalled)
    }

    func testReadOnlyRefreshPreservesInFlightPrepareAllAndRetryIntent() async throws {
        let started = expectation(description: "prepare all scan suspended")
        var pendingScan: CheckedContinuation<[IntegrationSetupDiscoveryEntry], Never>?
        var suspendScan = false
        var configurations = 0
        var configured = false
        var environment = environment()
        let missing = entry(.claudeCode)
        let ready = entry(.claudeCode, configured: true)
        environment.scan = {
            if suspendScan {
                suspendScan = false
                return await withCheckedContinuation { pendingScan = $0; started.fulfill() }
            }
            return [configured ? ready : missing]
        }
        environment.configure = { _ in
            configurations += 1
            configured = configurations > 1
        }
        let manager = IntegrationSetupManager(defaults: try defaults(), environment: environment)
        // 先保留一次失败尝试，后续批量准备必须同时保留主动重试意图。
        await manager.refresh(prepareAutomatically: true)
        XCTAssertEqual(configurations, 1)

        suspendScan = true
        let pending = Task { await manager.prepareAll() }
        await fulfillment(of: [started], timeout: 2)
        await manager.refresh()
        pendingScan?.resume(returning: [entry(.claudeCode)])
        await pending.value

        XCTAssertEqual(configurations, 2)
        XCTAssertEqual(manager.rows.first { $0.agent == .claudeCode }?.phase, .waitingForActivity)
        XCTAssertFalse(manager.isRefreshing)
    }

    func testCancellationAfterReadOnlyRefreshDoesNotResumePrepareAll() async throws {
        let started = expectation(description: "prepare all scan suspended")
        var pendingScan: CheckedContinuation<[IntegrationSetupDiscoveryEntry], Never>?
        var scans = 0
        var writes = 0
        var environment = environment()
        let missing = entry(.claudeCode)
        environment.scan = {
            scans += 1
            if scans == 1 { return await withCheckedContinuation { pendingScan = $0; started.fulfill() } }
            return [missing]
        }
        environment.prepareTools = { writes += 1 }
        environment.configure = { _ in writes += 1 }
        let manager = IntegrationSetupManager(defaults: try defaults(), environment: environment)
        let pending = Task { await manager.prepareAll() }
        await fulfillment(of: [started], timeout: 2)
        await manager.refresh()
        pending.cancel()
        pendingScan?.resume(returning: [entry(.claudeCode)])
        await pending.value

        XCTAssertEqual(writes, 0)
        XCTAssertTrue(manager.rows.isEmpty)
        XCTAssertFalse(manager.isRefreshing)
    }

    func testClosingPanelClearsPreparationBeforeNextReadOnlyRefresh() async throws {
        let started = expectation(description: "prepare all scan suspended")
        var pendingScan: CheckedContinuation<[IntegrationSetupDiscoveryEntry], Never>?
        var scans = 0
        var writes = 0
        var environment = environment()
        let missing = entry(.claudeCode)
        environment.scan = {
            scans += 1
            if scans == 1 { return await withCheckedContinuation { pendingScan = $0; started.fulfill() } }
            return [missing]
        }
        environment.prepareTools = { writes += 1 }
        environment.configure = { _ in writes += 1 }
        let manager = IntegrationSetupManager(defaults: try defaults(), environment: environment)
        let pending = Task { await manager.prepareAll() }
        await fulfillment(of: [started], timeout: 2)
        await manager.refresh()
        manager.endMonitoring()
        await manager.refresh()
        pendingScan?.resume(returning: [entry(.claudeCode)])
        await pending.value

        XCTAssertEqual(writes, 0)
        XCTAssertEqual(manager.rows.first { $0.agent == .claudeCode }?.phase, .needsConfiguration)
        XCTAssertFalse(manager.isRefreshing)
    }

    func testCancellationDuringToolPreparationPreventsConfiguration() async throws {
        let started = expectation(description: "tools suspended")
        var tools: CheckedContinuation<Void, Never>?
        var configurations = 0
        var environment = environment(entries: [entry(.claudeCode)])
        environment.prepareTools = { await withCheckedContinuation { tools = $0; started.fulfill() } }
        environment.configure = { _ in configurations += 1 }
        let manager = IntegrationSetupManager(defaults: try defaults(), environment: environment)
        let pending = Task { await manager.prepareAll() }
        await fulfillment(of: [started], timeout: 2)
        pending.cancel()
        tools?.resume()
        await pending.value

        XCTAssertEqual(configurations, 0)
        XCTAssertTrue(manager.rows.isEmpty)
        XCTAssertFalse(manager.isRefreshing)
    }

    func testShutdownDuringConfigurationStopsRemainingClientsAndPublication() async throws {
        let started = expectation(description: "first configuration suspended")
        var configuration: CheckedContinuation<Void, Never>?
        var configured: [AgentType] = []
        var environment = environment(entries: [entry(.claudeCode), entry(.cursor)])
        environment.configure = { agent in
            configured.append(agent)
            await withCheckedContinuation { configuration = $0; started.fulfill() }
        }
        let manager = IntegrationSetupManager(defaults: try defaults(), environment: environment)
        let pending = Task { await manager.prepareAll() }
        await fulfillment(of: [started], timeout: 2)
        manager.shutdown()
        configuration?.resume()
        await pending.value

        XCTAssertEqual(configured, [.claudeCode])
        XCTAssertTrue(manager.rows.isEmpty)
        XCTAssertFalse(manager.isRefreshing)
    }

    func testCancelledConfigurationDoesNotSuppressNextAutomaticAttempt() async throws {
        let started = expectation(description: "configuration suspended")
        var configuration: CheckedContinuation<Void, Never>?
        var calls = 0
        var environment = environment(entries: [entry(.claudeCode)])
        environment.configure = { _ in
            calls += 1
            if calls == 1 { await withCheckedContinuation { configuration = $0; started.fulfill() } }
        }
        let manager = IntegrationSetupManager(defaults: try defaults(), environment: environment)
        let pending = Task { await manager.prepareAll() }
        await fulfillment(of: [started], timeout: 2)
        pending.cancel()
        configuration?.resume()
        await pending.value
        await manager.refresh(prepareAutomatically: true)

        XCTAssertEqual(calls, 2, "取消不是完成的失败尝试，下次自动修复仍应可执行")
    }

    func testClosingPanelDiscardsInFlightTrustResult() async throws {
        let started = expectation(description: "trust suspended")
        var probe: CheckedContinuation<CodexHookTrustSnapshot, Never>?
        var environment = environment(entries: [entry(.codex, configured: true)])
        environment.inspectCodex = { _ in await withCheckedContinuation { probe = $0; started.fulfill() } }
        let manager = IntegrationSetupManager(defaults: try defaults(), environment: environment)
        let pending = Task { await manager.refresh() }
        await fulfillment(of: [started], timeout: 2)
        manager.endMonitoring()
        let before = manager.rows.first { $0.agent == .codex }?.phase
        probe?.resume(returning: .init(state: .granted, fingerprint: "trusted", configuredCount: 12, trustedCount: 12, reason: nil))
        await pending.value

        XCTAssertEqual(manager.rows.first { $0.agent == .codex }?.phase, before)
        XCTAssertNotEqual(manager.rows.first { $0.agent == .codex }?.phase, .waitingForActivity)
    }

    func testClosingPanelDiscardsPreparedArtifactURLAndStatus() async throws {
        let started = expectation(description: "artifact suspended")
        var artifact: CheckedContinuation<URL?, Error>?
        var environment = environment(entries: [entry(.workBuddy)])
        environment.prepareArtifact = { _ in try await withCheckedThrowingContinuation { artifact = $0; started.fulfill() } }
        let manager = IntegrationSetupManager(defaults: try defaults(), environment: environment)
        await manager.refresh()
        let before = manager.rows.first { $0.agent == .workBuddy }?.detail
        let pending = Task { await manager.prepareFiles(for: .workBuddy) }
        await fulfillment(of: [started], timeout: 2)
        manager.endMonitoring()
        artifact?.resume(returning: URL(fileURLWithPath: "/fixture/prepared"))
        let result = await pending.value

        XCTAssertNil(result)
        XCTAssertEqual(manager.rows.first { $0.agent == .workBuddy }?.detail, before)
    }

    func testMonitoringDoesNotRetainManagerDuringDelay() async throws {
        let waiting = expectation(description: "monitor waiting")
        var delay: CheckedContinuation<Void, Error>?
        var environment = environment()
        environment.waitForRecheck = { try await withCheckedThrowingContinuation { delay = $0; waiting.fulfill() } }
        var manager: IntegrationSetupManager? = IntegrationSetupManager(defaults: try defaults(), environment: environment)
        weak var reference = manager
        manager?.beginMonitoring()
        await fulfillment(of: [waiting], timeout: 2)
        manager = nil
        XCTAssertNil(reference)
        delay?.resume(throwing: CancellationError())
    }

    func testSlowFileScanRunsOffMainThreadAndCancellationStopsFurtherReads() async throws {
        let entered = expectation(description: "file worker running")
        let state = OSAllocatedUnfairLock(initialState: (reads: 0, mainThread: false))
        let environment = IntegrationSetupDiscovery.Environment(homeDirectory: URL(fileURLWithPath: "/fixture"),
            path: "/fixture/bin", applicationURL: { _ in nil }, isExecutable: { _ in
                let first = state.withLock { state in
                    state.reads += 1
                    state.mainThread = state.mainThread || Thread.isMainThread
                    return state.reads == 1
                }
                if first { entered.fulfill(); Thread.sleep(forTimeInterval: 0.15) }
                return false
            }, extensionIDs: [], hasConfiguration: { _ in false })
        let pending = Task { await IntegrationSetupDiscovery.scanInBackground(environment: environment) }
        await fulfillment(of: [entered], timeout: 2)
        let heartbeat = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(5))
        XCTAssertLessThan(heartbeat.duration(to: .now), .milliseconds(100))
        pending.cancel()
        let result = await pending.value

        XCTAssertTrue(result.isEmpty)
        XCTAssertFalse(state.withLock { $0.mainThread })
        XCTAssertEqual(state.withLock { $0.reads }, 1)
    }

    func testCancelledArtifactWorkerDoesNotCreateDestination() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("integration-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let pending = Task {
            try await IntegrationSetupIO.run {
                try IntegrationSetupArtifacts.prepare(for: .workBuddy, directory: home,
                    bridgeURL: home.appendingPathComponent("bridge"))
            }
        }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("取消应抛出 CancellationError") }
        catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }

    private func defaults() throws -> UserDefaults {
        let name = "xisland-concurrency-\(UUID().uuidString)"
        let value = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { value.removePersistentDomain(forName: name) }
        return value
    }

    private func entry(_ agent: AgentType, configured: Bool = false) -> IntegrationSetupDiscoveryEntry {
        .init(agent: agent, installed: true, configured: configured, fingerprint: "v1", appURL: nil,
            codexBinary: agent == .codex ? URL(fileURLWithPath: "/fixture/codex") : nil, detail: nil,
            canAutoConfigure: agent != .workBuddy)
    }

    private func environment(entries: [IntegrationSetupDiscoveryEntry] = []) -> IntegrationSetupManager.Environment {
        .init(scan: { entries }, isEnabled: { _ in true }, configure: { _ in }, prepareTools: {},
            inspectCodex: { _ in .init(state: .unavailable, fingerprint: nil, configuredCount: 0, trustedCount: 0, reason: nil) })
    }
}
