import AppKit
import Foundation
import Observation

/// 配置存在、客户端授权和实际收到活动是三份不同的证据。
@MainActor
@Observable
final class IntegrationSetupManager {
    @MainActor
    struct Environment {
        var scan: () -> [IntegrationSetupDiscoveryEntry]
        var isEnabled: (AgentType) -> Bool
        var configure: (AgentType) -> Void
        var prepareTools: () -> Void
        var inspectCodex: (URL) async -> CodexHookTrustSnapshot
        var prepareArtifact: (AgentType) throws -> URL? = { _ in nil }

        static var live: Self {
            Self(scan: { IntegrationSetupDiscovery.scan() },
                 isEnabled: { ZeroConfigManager.isAutoConfigEnabled(for: $0) },
                 configure: { ZeroConfigManager.setAutoConfigEnabled(true, for: $0) },
                 prepareTools: { ZeroConfigManager.syncCommandLineTools() },
                 inspectCodex: { binary in
                    await CodexHookTrustProbe.inspect(binary: binary,
                        cwd: FileManager.default.homeDirectoryForCurrentUser,
                        expectedCommands: IntegrationSetupDiscovery.codexExpectedCommands())
                 }, prepareArtifact: { agent in
                    let home = FileManager.default.homeDirectoryForCurrentUser
                    return try IntegrationSetupArtifacts.prepare(for: agent,
                        directory: home.appendingPathComponent(".xisland/integrations"),
                        bridgeURL: home.appendingPathComponent(".xisland/bin/di-bridge"))
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
    private var presentationPending = false
    private var preparedArtifacts: [AgentType: URL] = [:]
    private var artifactFailures: Set<AgentType> = []
    private var codexProbeFingerprint: String?
    private var pendingCodexActivity: (fingerprint: String, date: Date)?

    init(defaults: UserDefaults = AppPreferences.defaults, environment: Environment? = nil) {
        self.defaults = defaults
        self.environment = environment ?? (AppPreferences.isIsolated ? .isolated : .live)
        self.attempts = defaults.dictionary(forKey: Key.attempts) as? [String: String] ?? [:]
        self.reminders = defaults.dictionary(forKey: Key.reminders) as? [String: String] ?? [:]
        self.introductions = defaults.dictionary(forKey: Key.introductions) as? [String: String] ?? [:]
        self.observations = defaults.data(forKey: Key.observations)
            .flatMap { try? JSONDecoder().decode([String: ObservationRecord].self, from: $0) } ?? [:]
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
        if isRefreshing {
            refreshPending = true
            preparationPending = preparationPending || prepareAutomatically
            if !environment.isEnabled(.codex) {
                codexProbeFingerprint = nil
                pendingCodexActivity = nil
            }
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        var prepare = prepareAutomatically
        repeat {
            refreshPending = false
            preparationPending = false
            await performRefresh(prepareAutomatically: prepare)
            prepare = preparationPending
        } while refreshPending && !Task.isCancelled
        isRefreshing = false
        guard !Task.isCancelled else { return }
        if presentationPending {
            presentationPending = false
            markPresented()
        }
        if hasUnpresentedReminder { onNeedsAttention?() }
    }

    private func performRefresh(prepareAutomatically: Bool) async {
        var discovered = environment.scan()
        if prepareAutomatically {
            let eligible = discovered.filter { $0.installed && $0.canAutoConfigure && environment.isEnabled($0.agent) }
            if !eligible.isEmpty && !preparedTools {
                environment.prepareTools()
                preparedTools = true
            }
            var changed = false
            for entry in eligible where !entry.configured && attempts[entry.agent.rawValue] != entry.fingerprint {
                // 失败也记住本次尝试，避免每次启动反复覆盖/写入。用户可在面板中明确重试。
                attempts[entry.agent.rawValue] = entry.fingerprint
                defaults.set(attempts, forKey: Key.attempts)
                environment.configure(entry.agent)
                changed = true
            }
            if changed { discovered = environment.scan() }
            for entry in discovered where entry.installed && environment.isEnabled(entry.agent)
                && [.workBuddy, .kiro].contains(entry.agent)
                && preparedArtifacts[entry.agent] == nil && !artifactFailures.contains(entry.agent) {
                _ = prepareArtifact(for: entry.agent)
            }
        }

        // 只保留失败尝试；成功后客户端若重写配置，仍应允许自动补回。
        let recovered = discovered.filter { $0.configured && attempts[$0.agent.rawValue] != nil }
        if !recovered.isEmpty {
            for entry in recovered { attempts.removeValue(forKey: entry.agent.rawValue) }
            defaults.set(attempts, forKey: Key.attempts)
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
            guard !Task.isCancelled else { return }
            // 查询期间客户端设置可能改变；只读复核后才能把这次活动绑定到授权结果。
            let current = environment.scan().first { $0.agent == .codex }
            let enabled = environment.isEnabled(.codex)
            let pending = pendingCodexActivity
            codexProbeFingerprint = nil
            pendingCodexActivity = nil
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
        guard !isRefreshing, let entry = entries[agent], entry.installed, entry.canAutoConfigure else { return }
        environment.prepareTools()
        preparedTools = true
        environment.configure(agent)
        await refresh()
    }

    func recordActivity(from agent: AgentType, at date: Date = Date()) {
        guard agent.isSupported, agent != .glm, var state = evidence[agent], state.enabled, environment.isEnabled(agent) else { return }
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
        if isRefreshing { presentationPending = true; return }
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

    func prepareFiles(for agent: AgentType) -> URL? {
        guard let entry = entries[agent], entry.installed, environment.isEnabled(agent),
              [.workBuddy, .kiro].contains(agent) else { return nil }
        let result = prepareArtifact(for: agent)
        rebuildRows()
        return result
    }

    private func prepareArtifact(for agent: AgentType) -> URL? {
        if !preparedTools { environment.prepareTools(); preparedTools = true }
        do {
            let url = try environment.prepareArtifact(agent)
            preparedArtifacts[agent] = url
            artifactFailures.remove(agent)
            return url
        } catch {
            artifactFailures.insert(agent)
            return nil
        }
    }

    private func rebuildRows() {
        rows = IntegrationSetupDescriptor.all.map { baseDescriptor in
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
