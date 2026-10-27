import AppKit
import Foundation
import Observation

/// 配置存在、客户端授权和实际收到活动是三份不同的证据。
@MainActor
@Observable
final class IntegrationSetupManager {
    @MainActor
    struct Environment {
        var scan: () async -> [IntegrationSetupDiscoveryEntry]
        var isEnabled: (AgentType) -> Bool
        var configure: (AgentType) async -> Void
        var prepareTools: () async -> Void
        var inspectCodex: (URL) async -> CodexHookTrustSnapshot
        var prepareArtifact: (AgentType) async throws -> URL? = { _ in nil }
        var waitForRecheck: () async throws -> Void = { try await Task.sleep(for: .seconds(8)) }

        static var live: Self {
            Self(scan: { await IntegrationSetupDiscovery.scan() },
                 isEnabled: { ZeroConfigManager.isAutoConfigEnabled(for: $0) },
                 configure: { agent in
                    _ = try? await IntegrationSetupIO.run { ZeroConfigManager.configure(agent) }
                 },
                 prepareTools: {
                    _ = try? await IntegrationSetupIO.run { ZeroConfigManager.syncCommandLineTools() }
                 },
                 inspectCodex: { binary in
                    await CodexHookTrustProbe.inspect(binary: binary,
                        cwd: FileManager.default.homeDirectoryForCurrentUser,
                        expectedCommands: IntegrationSetupDiscovery.codexExpectedCommands())
                 }, prepareArtifact: { agent in
                    let home = FileManager.default.homeDirectoryForCurrentUser
                    return try await IntegrationSetupIO.run {
                        try IntegrationSetupArtifacts.prepare(for: agent,
                            directory: home.appendingPathComponent(".xisland/integrations"),
                            bridgeURL: home.appendingPathComponent(".xisland/bin/di-bridge"))
                    }
                 })
        }

        static var isolated: Self {
            Self(scan: { [] }, isEnabled: { _ in false }, configure: { _ in },
                 prepareTools: {}, inspectCodex: { _ in
                    CodexHookTrustSnapshot(state: .unavailable, fingerprint: nil,
                        configuredCount: 0, trustedCount: 0, reason: nil)
                 })
        }
    }

    private struct ObservationRecord: Codable {
        let fingerprint: String
        let lastSeen: Date
    }

    private enum Key {
        static let attempts = "integrationSetup.v1.configurationAttempts"
        static let reminders = "integrationSetup.v1.reminders"
        static let introductions = "integrationSetup.v1.introductions"
        static let observations = "integrationSetup.v1.observations"
    }

    private(set) var rows: [IntegrationSetupRow] = []
    private(set) var isRefreshing = false
    var onNeedsAttention: (() -> Void)?
    private let environment: Environment
    private let defaults: UserDefaults
    private var entries: [AgentType: IntegrationSetupDiscoveryEntry] = [:]
    private var evidence: [AgentType: IntegrationSetupEvidence] = [:]
    private var observations: [String: ObservationRecord]
    private var attempts: [String: String]
    private var reminders: [String: String]
    private var introductions: [String: String]
    private var receivedThisRun: Set<AgentType> = []
    private var preparedTools = false
    private var refreshPending = false
    private var preparationPending = false
    private var retryPreparationPending = false
    private var presentationPending = false
    private var preparedArtifacts: [AgentType: URL] = [:]
    private var artifactFailures: Set<AgentType> = []
    private var artifactFingerprints: [AgentType: String] = [:]
    private var codexProbeFingerprint: String?
    private var pendingCodexActivity: (fingerprint: String, date: Date)?
    private var checkingCodexRow: IntegrationSetupRow?
    private(set) var isPresented = false
    private var isShuttingDown = false
    private var resumesCancelledLicenseScan = false
    @ObservationIgnored private var monitoringTask: Task<Void, Never>?
    @ObservationIgnored private var monitoringGeneration = 0
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var operationGeneration: Int?
    @ObservationIgnored private var cancelOperation: (@Sendable () -> Void)?

    init(defaults: UserDefaults = AppPreferences.defaults, environment: Environment? = nil) {
        self.defaults = defaults
        self.environment = environment ?? (AppPreferences.isIsolated ? .isolated : .live)
        self.attempts = defaults.dictionary(forKey: Key.attempts) as? [String: String] ?? [:]
        self.reminders = defaults.dictionary(forKey: Key.reminders) as? [String: String] ?? [:]
        self.introductions = defaults.dictionary(forKey: Key.introductions) as? [String: String] ?? [:]
        self.observations = defaults.data(forKey: Key.observations)
            .flatMap { try? JSONDecoder().decode([String: ObservationRecord].self, from: $0) } ?? [:]
    }

    deinit {
        monitoringTask?.cancel()
        cancelOperation?()
    }

    var attentionCount: Int {
        rows.filter { [.needsConfiguration, .needsAuthorization, .needsSetup, .checkFailed].contains($0.phase) }.count
    }

    var hasUnpresentedReminder: Bool {
        rows.contains { row in
            let fingerprint = evidence[row.agent]?.configurationFingerprint
            if IntegrationSetupReminderPolicy.shouldPrompt(agent: row.agent, phase: row.phase,
                    fingerprint: fingerprint, lastPrompted: reminders) { return true }
            // 自动配置成功也只展示一次下一步，不能让用户误以为已经接通。
            return row.phase == .waitingForActivity && fingerprint != nil
                && introductions[row.id] != fingerprint
        }
    }

    func refresh(prepareAutomatically: Bool = false) async {
        await refresh(prepareAutomatically: prepareAutomatically, retryFailed: false)
    }

    /// 用户主动批量准备时允许重试失败项，仍不启用已关闭来源或重写完整配置。
    func prepareAll() async {
        await refresh(prepareAutomatically: true, retryFailed: true)
    }

    private func refresh(prepareAutomatically: Bool, retryFailed: Bool) async {
        guard !Task.isCancelled, !isShuttingDown else { return }
        refreshGeneration += 1
        if isRefreshing {
            cancelOperation?()
            refreshPending = true
            preparationPending = preparationPending || prepareAutomatically
            retryPreparationPending = retryPreparationPending || retryFailed
            if !environment.isEnabled(.codex) {
                codexProbeFingerprint = nil
                pendingCodexActivity = nil
            }
            return
        }
        isRefreshing = true
        defer {
            // 授权恢复可能排在已取消的启动扫描后；用新任务承接，不能继承旧任务的取消状态。
            let resumePending = refreshPending && !isShuttingDown && resumesCancelledLicenseScan
            let resumePreparation = preparationPending
            let resumeRetry = retryPreparationPending
            isRefreshing = false
            preparationPending = false
            retryPreparationPending = false
            resumesCancelledLicenseScan = false
            if resumePending {
                refreshPending = false
                Task { [weak self] in
                    await self?.refresh(prepareAutomatically: resumePreparation, retryFailed: resumeRetry)
                }
            }
        }
        var prepare = prepareAutomatically
        var retry = retryFailed
        var completedGeneration = refreshGeneration
        repeat {
            refreshPending = false
            // 普通回查继承未完成的准备意图；显式取消仍由 cancelPendingWork 清空。
            preparationPending = prepare
            retryPreparationPending = retry
            completedGeneration = refreshGeneration
            await runOperation { [self] in
                await performRefresh(prepareAutomatically: prepare, retryFailed: retry, generation: completedGeneration)
            }
            prepare = preparationPending
            retry = retryPreparationPending
        } while refreshPending && !Task.isCancelled && !isShuttingDown
        isRefreshing = false
        guard isCurrent(completedGeneration) else { return }
        if presentationPending {
            presentationPending = false
            markPresented()
        }
        if hasUnpresentedReminder { onNeedsAttention?() }
    }

    private func performRefresh(prepareAutomatically: Bool, retryFailed: Bool, generation: Int) async {
        guard isCurrent(generation) else { return }
        defer { checkingCodexRow = nil }
        var discovered = await environment.scan()
        guard isCurrent(generation) else { return }
        for entry in discovered where [.workBuddy, .kiro].contains(entry.agent) {
            if artifactFingerprints[entry.agent] != entry.fingerprint {
                preparedArtifacts.removeValue(forKey: entry.agent)
                artifactFailures.remove(entry.agent)
            }
            artifactFingerprints[entry.agent] = entry.fingerprint
        }
        if prepareAutomatically {
            let eligible = discovered.filter { $0.installed && $0.canAutoConfigure && environment.isEnabled($0.agent) }
            if !eligible.isEmpty && !preparedTools {
                await environment.prepareTools()
                guard isCurrent(generation) else { return }
                preparedTools = true
            }
            var changed = false
            for entry in eligible where !entry.configured && (retryFailed || attempts[entry.agent.rawValue] != entry.fingerprint) {
                guard isCurrent(generation), environment.isEnabled(entry.agent) else { return }
                await environment.configure(entry.agent)
                guard isCurrent(generation) else { return }
                // 只记录完成的尝试；取消不能留下一个阻止下次恢复的失败标记。
                attempts[entry.agent.rawValue] = entry.fingerprint
                defaults.set(attempts, forKey: Key.attempts)
                changed = true
            }
            if changed { discovered = await environment.scan() }
            guard isCurrent(generation) else { return }
            for entry in discovered where entry.installed && environment.isEnabled(entry.agent)
                && [.workBuddy, .kiro].contains(entry.agent)
                && preparedArtifacts[entry.agent] == nil && (retryFailed || !artifactFailures.contains(entry.agent)) {
                guard isCurrent(generation) else { return }
                _ = await prepareArtifact(for: entry.agent, generation: generation)
            }
        }
        guard isCurrent(generation) else { return }

        // 只保留失败尝试；成功后客户端若重写配置，仍应允许自动补回。
        let recovered = discovered.filter { $0.configured && attempts[$0.agent.rawValue] != nil }
        if !recovered.isEmpty {
            for entry in recovered { attempts.removeValue(forKey: entry.agent.rawValue) }
            defaults.set(attempts, forKey: Key.attempts)
        }
        if let codex = discovered.first(where: { $0.agent == .codex }), codex.installed, codex.configured,
           environment.isEnabled(.codex), let previous = evidence[.codex]?.configurationFingerprint,
           previous == codex.fingerprint || previous.hasPrefix(codex.fingerprint + ":") {
            checkingCodexRow = rows.first { $0.agent == .codex }
        }
        entries = Dictionary(uniqueKeysWithValues: discovered.map { ($0.agent, $0) })
        for entry in discovered {
            let previous = evidence[entry.agent]
            let observed = observations[entry.agent.rawValue]
            evidence[entry.agent] = IntegrationSetupEvidence(
                installed: entry.installed || receivedThisRun.contains(entry.agent),
                enabled: environment.isEnabled(entry.agent), configured: entry.configured,
                configurationFingerprint: entry.fingerprint,
                observedFingerprint: observed?.fingerprint)
            // 检测进行中保留上一次已知阻断，不能短暂闪成“已接通”。
            if entry.agent == .codex, entry.configured {
                evidence[entry.agent]?.authorization = previous?.authorization ?? .unknown
                evidence[entry.agent]?.checkFailed = true
            }
        }
        rebuildRows()

        if let codex = entries[.codex], evidence[.codex]?.installed == true,
           evidence[.codex]?.enabled == true, codex.configured {
            codexProbeFingerprint = codex.fingerprint
            pendingCodexActivity = nil
            defer { codexProbeFingerprint = nil; pendingCodexActivity = nil }
            let snapshot: CodexHookTrustSnapshot
            if let binary = codex.codexBinary {
                snapshot = await environment.inspectCodex(binary)
            } else {
                snapshot = CodexHookTrustSnapshot(state: .unavailable, fingerprint: nil,
                    configuredCount: 0, trustedCount: 0, reason: nil)
            }
            guard isCurrent(generation) else { return }
            // 查询期间客户端设置可能改变；只读复核后才能把这次活动绑定到授权结果。
            let current = await environment.scan().first { $0.agent == .codex }
            guard isCurrent(generation) else { return }
            let enabled = environment.isEnabled(.codex)
            let pending = pendingCodexActivity
            codexProbeFingerprint = nil
            pendingCodexActivity = nil
            checkingCodexRow = nil
            if snapshot.state == .required {
                // 撤销授权后不能用撤销前的活动，在再次授权时直接恢复绿色。
                observations.removeValue(forKey: AgentType.codex.rawValue)
                saveObservations()
            }
            if let current, current.installed, current.configured, current.fingerprint == codex.fingerprint, enabled {
                entries[.codex] = current
                let fingerprint = codex.fingerprint + ":" + (snapshot.fingerprint ?? "unchecked")
                evidence[.codex]?.configurationFingerprint = fingerprint
                evidence[.codex]?.checkFailed = snapshot.state == .unavailable
                evidence[.codex]?.authorization = snapshot.state == .granted ? .granted
                    : snapshot.state == .required ? .required : .unknown
                evidence[.codex]?.authorizationFingerprint = snapshot.state == .granted ? fingerprint : nil
                evidence[.codex]?.observedFingerprint = observations[AgentType.codex.rawValue]?.fingerprint
                if snapshot.state == .granted, let pending, pending.fingerprint == current.fingerprint {
                    recordActivity(from: .codex, at: pending.date)
                }
            } else {
                entries[.codex] = current
                evidence[.codex] = IntegrationSetupEvidence(installed: current?.installed ?? false, enabled: enabled,
                    configured: current?.configured ?? false, configurationFingerprint: current?.fingerprint,
                    checkFailed: current?.configured == true && enabled)
            }
        }
        rebuildRows()
        for row in rows where row.phase == .connected || row.phase == .waitingForActivity {
            // 曾恢复正常的来源再次需要授权时，即使 hash 没变也应重新提醒。
            reminders.removeValue(forKey: row.id)
        }
        defaults.set(reminders, forKey: Key.reminders)
    }

    func configure(_ agent: AgentType) async {
        guard !Task.isCancelled, !isShuttingDown, !isRefreshing else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        await runOperation { [self] in
            let discovered = await environment.scan()
            guard isCurrent(generation), let entry = discovered.first(where: { $0.agent == agent }),
                  entry.installed, entry.canAutoConfigure, !entry.configured, environment.isEnabled(agent) else { return }
            await environment.prepareTools()
            guard isCurrent(generation), environment.isEnabled(agent) else { return }
            preparedTools = true
            await environment.configure(agent)
        }
        isRefreshing = false
        guard isCurrent(generation) || refreshPending else { return }
        if refreshPending {
            await refresh(prepareAutomatically: preparationPending, retryFailed: retryPreparationPending)
            return
        }
        await refresh()
    }

    func beginMonitoring() {
        guard !isShuttingDown else { return }
        isPresented = true
        guard monitoringTask == nil else { return }
        monitoringGeneration += 1
        let generation = monitoringGeneration
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled, self?.isPresented == true {
                await self?.refresh()
                guard self?.isPresented == true, !Task.isCancelled,
                      let wait = self?.environment.waitForRecheck else { break }
                do { try await wait() }
                catch { break }
            }
            if self?.monitoringGeneration == generation { self?.monitoringTask = nil }
        }
    }

    func endMonitoring() {
        isPresented = false
        cancelPendingWork()
    }

    func shutdown() {
        isShuttingDown = true
        resumesCancelledLicenseScan = false
        isPresented = false
        cancelPendingWork()
    }

    /// 授权恢复后允许重新检查接入，不重放暂停前已经取消的操作。
    func resumeAfterLicenseActivation() {
        resumesCancelledLicenseScan = isShuttingDown && isRefreshing
        isShuttingDown = false
    }

    private func cancelPendingWork() {
        refreshGeneration += 1
        monitoringGeneration += 1
        monitoringTask?.cancel()
        monitoringTask = nil
        cancelOperation?()
        refreshPending = false
        preparationPending = false
        retryPreparationPending = false
        presentationPending = false
        codexProbeFingerprint = nil
        pendingCodexActivity = nil
        checkingCodexRow = nil
    }

    func recordActivity(from agent: AgentType, at date: Date = Date()) {
        guard !isShuttingDown, agent.isSupported, agent != .glm, var state = evidence[agent], state.enabled, environment.isEnabled(agent) else { return }
        if agent == .codex, let fingerprint = codexProbeFingerprint {
            guard state.configured, state.configurationFingerprint == fingerprint else { return }
            pendingCodexActivity = (fingerprint, date)
            return
        }
        guard !state.checkFailed, state.authorization != .required, state.authorization != .failed,
              let fingerprint = state.configurationFingerprint else { return }
        if agent == .codex {
            guard state.configured, state.authorization == .granted,
                  state.authorizationFingerprint == fingerprint else { return }
        }
        if let previous = observations[agent.rawValue], previous.fingerprint == fingerprint,
           state.observedFingerprint == fingerprint, date.timeIntervalSince(previous.lastSeen) < 10 { return }
        receivedThisRun.insert(agent)
        state.installed = true
        state.observedFingerprint = fingerprint
        evidence[agent] = state
        observations[agent.rawValue] = ObservationRecord(fingerprint: fingerprint, lastSeen: date)
        reminders.removeValue(forKey: agent.rawValue)
        introductions[agent.rawValue] = fingerprint
        saveObservations()
        defaults.set(reminders, forKey: Key.reminders)
        defaults.set(introductions, forKey: Key.introductions)
        rebuildRows()
    }

    func markPresented() {
        // 窗口可在检查期间关闭；应记住本轮最终结果，不能持久化临时的未检查指纹。
        if isRefreshing && operationGeneration == refreshGeneration { presentationPending = true; return }
        for row in rows where row.phase != .notInstalled && row.phase != .disabled {
            let fingerprint = evidence[row.agent]?.configurationFingerprint
            if row.phase == .connected || row.phase == .waitingForActivity {
                reminders.removeValue(forKey: row.id)
            } else {
                reminders[row.id] = IntegrationSetupReminderPolicy.reminderToken(phase: row.phase, fingerprint: fingerprint)
            }
            if let fingerprint { introductions[row.id] = fingerprint }
        }
        defaults.set(reminders, forKey: Key.reminders)
        defaults.set(introductions, forKey: Key.introductions)
    }

    func appURL(for agent: AgentType) -> URL? { entries[agent]?.appURL }

    func prepareFiles(for agent: AgentType) async -> URL? {
        guard !Task.isCancelled, !isShuttingDown, !isRefreshing, let entry = entries[agent], entry.installed, environment.isEnabled(agent),
              [.workBuddy, .kiro].contains(agent) else { return nil }
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        let result = await runOperation { [self] in
            await prepareArtifact(for: agent, generation: generation)
        }
        isRefreshing = false
        guard isCurrent(generation) else {
            if refreshPending {
                await refresh(prepareAutomatically: preparationPending, retryFailed: retryPreparationPending)
            }
            return nil
        }
        rebuildRows()
        return result
    }

    private func prepareArtifact(for agent: AgentType, generation: Int) async -> URL? {
        guard isCurrent(generation) else { return nil }
        if !preparedTools {
            await environment.prepareTools()
            guard isCurrent(generation) else { return nil }
            preparedTools = true
        }
        guard environment.isEnabled(agent) else { return nil }
        do {
            let url = try await environment.prepareArtifact(agent)
            guard isCurrent(generation), environment.isEnabled(agent) else { return nil }
            preparedArtifacts[agent] = url
            artifactFailures.remove(agent)
            return url
        } catch {
            guard isCurrent(generation), !(error is CancellationError) else { return nil }
            artifactFailures.insert(agent)
            return nil
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && !isShuttingDown && generation == refreshGeneration
    }

    private func runOperation<Result: Sendable>(_ operation: @escaping @MainActor () async -> Result) async -> Result {
        let work = Task { @MainActor in await operation() }
        cancelOperation = { work.cancel() }
        operationGeneration = refreshGeneration
        defer { cancelOperation = nil; operationGeneration = nil }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func rebuildRows() {
        rows = IntegrationSetupDescriptor.all.map { baseDescriptor in
            // 回查期间保留同一配置的最近结果，避免每八秒把一行挪到“检查失败”分组。
            if baseDescriptor.agent == .codex, let checkingCodexRow { return checkingCodexRow }
            var descriptor = baseDescriptor
            let entry = entries[descriptor.agent]
            if let entry {
                if descriptor.canAutoConfigure && !entry.canAutoConfigure { descriptor.requiresManualSetup = true }
                descriptor.canAutoConfigure = entry.canAutoConfigure
            }
            let state = evidence[descriptor.agent] ?? IntegrationSetupEvidence()
            let phase = IntegrationSetupState.phase(descriptor: descriptor, evidence: state)
            var detail = entry?.detail ?? descriptor.authorizationGuidance
            if phase == .checkFailed {
                detail = text("暂时无法确认客户端授权。请确认软件已安装且支持 hooks，完成原客户端设置后重新检查。",
                              "Client authorization could not be checked. Confirm the app supports hooks, complete its setup, then check again.")
            } else if phase == .connected {
                detail = text("已收到此配置下的真实活动。不同客户端版本的具体能力请参阅接入说明。",
                              "Activity received with this configuration. See the guide for capabilities in your client version.")
            }
            if artifactFailures.contains(descriptor.agent) {
                detail = text("接入文件未能准备，已有文件会保留。请检查 X Island 接入文件目录的权限或修改内容后重试。",
                              "Setup files could not be prepared. Existing files were kept. Check the X Island setup folder's permissions or modified files, then retry.")
            } else if preparedArtifacts[descriptor.agent] != nil && phase != .connected {
                detail = text("接入文件已准备，点击「查看接入文件」取用；仍需按步骤在客户端启用。",
                              "Setup files are ready. Choose Show setup files, then follow the steps to enable them in the client.")
                    + " " + descriptor.authorizationGuidance
            }
            return IntegrationSetupRow(agent: descriptor.agent, phase: phase, detail: detail,
                canConfigure: entry?.canAutoConfigure ?? descriptor.canAutoConfigure,
                lastSeen: phase == .connected ? observations[descriptor.agent.rawValue]?.lastSeen : nil)
        }
    }

    private func saveObservations() {
        if let data = try? JSONEncoder().encode(observations) { defaults.set(data, forKey: Key.observations) }
    }

    private func text(_ zh: String, _ en: String) -> String { L10n.effectiveLanguage.hasPrefix("zh") ? zh : en }
}
