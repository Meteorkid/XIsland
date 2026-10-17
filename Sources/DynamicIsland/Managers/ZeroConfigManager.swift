import Foundation
import DIShared

enum HookInstallStatus {
    case active
    case inactive
    case externalExtension
    case unverified
    case externalAgent
    case externalObserver
    case externalCody
    case externalAmazonQ
    case externalWorkBuddy
    case modelSource
    case externalKiro
}

enum ZeroConfigManager {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static let autoConfigKeyPrefix = "autoConfigure."

    @MainActor
    static func configureAllAgents(agents: Set<AgentType>? = nil) {
        let detected = IntegrationSetupDiscovery.automaticAgents(in: IntegrationSetupDiscovery.scan(), requested: agents)
        guard !detected.isEmpty else { return }
        syncCommandLineTools()
        for agent in AgentType.allCases where detected.contains(agent) && isAutoConfigEnabled(for: agent) {
            configure(agent)
        }
        print("[ZeroConfig] Supported agent configurations checked")
    }

    /// 穷尽 switch，不留 default：新增 AgentType 时编译器会强制在这里做出选择。
    /// v1.13.0 新增的 4 个工具正是因为 default 分支而被静默漏配。
    static func configure(_ agent: AgentType) {
        if usesCompanionExtension(agent) || usesACPBridge(agent) || usesStateObserver(agent) || usesCodyBridge(agent) || usesAmazonQWrapper(agent) || usesWorkBuddyPlugin(agent) || hasUnverifiedIntegration(agent) { return }
        if let profile = effectiveNativeProfile(for: agent) {
            let url = URL(fileURLWithPath: home).appendingPathComponent(profile.relativeConfigPath)
            do {
                try HookConfigurationFile.update(at: url) { try profile.merging(into: $0, bridgePath: bridgePath) }
            } catch {
                print("[ZeroConfig] \(agent.rawValue) hook configuration failed: \(error.localizedDescription)")
            }
            return
        }
        if agent == .devin {
            let url = URL(fileURLWithPath: home).appendingPathComponent(DevinHookConfiguration.relativeConfigPath)
            do {
                try HookConfigurationFile.update(at: url) { try DevinHookConfiguration.merging(into: $0, bridgePath: bridgePath) }
            } catch {
                print("[ZeroConfig] Devin hook configuration failed: \(error.localizedDescription)")
            }
            return
        }
        if agent == .windsurf {
            let url = URL(fileURLWithPath: home).appendingPathComponent(WindsurfHookConfiguration.relativeConfigPath)
            do {
                try HookConfigurationFile.update(at: url) { try WindsurfHookConfiguration.merging(into: $0, bridgePath: bridgePath) }
            } catch {
                print("[ZeroConfig] Windsurf hook configuration failed: \(error.localizedDescription)")
            }
            return
        }
        if agent == .copilotCli {
            let url = CopilotCliHookConfiguration.configURL(homeDirectory: home, environment: ProcessInfo.processInfo.environment)
            do {
                try HookConfigurationFile.update(at: url) { try CopilotCliHookConfiguration.merging(into: $0, bridgePath: bridgePath) }
            } catch {
                print("[ZeroConfig] Copilot CLI hook configuration failed: \(error.localizedDescription)")
            }
            return
        }
        if agent == .cursor {
            let url = URL(fileURLWithPath: home).appendingPathComponent(CursorHookConfiguration.relativeConfigPath)
            do {
                try HookConfigurationFile.update(at: url) { try CursorHookConfiguration.merging(into: $0, bridgePath: bridgePath) }
            } catch {
                print("[ZeroConfig] Cursor hook configuration failed: \(error.localizedDescription)")
            }
            return
        }
        if agent == .trae {
            let url = URL(fileURLWithPath: home).appendingPathComponent(TraeHookConfiguration.relativeConfigPath)
            do {
                try HookConfigurationFile.update(at: url) { try TraeHookConfiguration.merging(into: $0, bridgePath: bridgePath) }
            } catch {
                print("[ZeroConfig] Trae CN hook configuration failed: \(error.localizedDescription)")
            }
            return
        }
        if agent == .codeBuddy {
            let url = URL(fileURLWithPath: home).appendingPathComponent(CodeBuddyHookConfiguration.relativeConfigPath)
            do { try HookConfigurationFile.update(at: url) { try CodeBuddyHookConfiguration.merging(into: $0, bridgePath: bridgePath) } }
            catch { print("[ZeroConfig] CodeBuddy hook configuration failed: \(error.localizedDescription)") }
            return
        }
        if agent == .cline {
            let directory = clineHooksDirectory
            do { try ClineHookConfiguration.install(in: directory, bridgePath: bridgePath) }
            catch { print("[ZeroConfig] Cline hook configuration failed: \(error.localizedDescription)") }
            return
        }
        switch agent {
        case .windsurf, .amazonQ, .cody, .cline, .`continue`, .copilotCli,
             .rooCode, .pearai, .zed, .jetbrainsAi:
            configureArrayHooks(agent)
        case .claudeCode: configureClaudeCode()
        case .codex: configureCodex()
        case .qwen, .codeBuddy, .droid, .geminiCli, .kiro:
            configureSettingsHooks(agent)
        case .cursor: configureCursor()
        case .trae: configureTrae()
        case .openCode: configureOpenCode()
        case .qoder: configureQoder()
        case .copilot: configureCopilot()
        case .kimi: configureKimi()
        case .deepseek: configureDeepSeek()
        case .amp: configureAmp()
        case .pi: configurePi()
        case .hermes: configureHermes()
        case .glm: break // 模型来源尚无独立客户端协议，不生成配置。
        case .workBuddy: break // 独立插件尚未通过客户端验收，不自动写入配置。
        case .aider: configureAider()
        case .devin: configureDevin()
        case .tabnine: configureTabnine()
        }
    }

    /// Factory 仍支持 settings.json 回退；不新建更高优先级文件去遮蔽用户既有 hooks。
    static func effectiveNativeProfile(for agent: AgentType, homeDirectory: String? = nil) -> NativeHookProfile? {
        guard let profile = NativeHookProfile.profile(for: agent) else { return nil }
        let directory = homeDirectory ?? home
        if agent == .droid,
           !FileManager.default.fileExists(atPath: "\(directory)/\(profile.relativeConfigPath)"),
           FileManager.default.fileExists(atPath: "\(directory)/.factory/settings.json") {
            return NativeHookProfile(agent: agent, relativeConfigPath: ".factory/settings.json", hooksAreAtRoot: false,
                                     timeoutUnit: profile.timeoutUnit, bindings: profile.bindings)
        }
        return profile
    }

    /// 模板式 hooks.json 的配置位置与 session 前缀。
    /// 这些工具共用同一套「hooks 数组 + xisland_ 前缀条目」格式，配置、检测、移除三条路径都以本表为准，
    /// 避免像此前那样出现「写得进去、却检测不出来」的分叉。
    /// settings.json 型零配置：hooks 是「事件名 → 条目数组」的字典。
    /// Claude Code 系的 CLI 多沿用这套格式，此前每个工具各抄一份约 55 行的相同实现
    /// （Qwen / CodeBuddy / Droid 三份逐字相同），改一处漏三处，且 removeConfiguration 一直没跟上。
    private struct SettingsHookBinding {
        let event: String     // settings.json 里的事件名
        let hookArg: String   // 传给 di-bridge 的 --hook 参数
        let timeout: Int
    }

    private struct SettingsHookTarget {
        let configDir: String
        let bindings: [SettingsHookBinding]
        /// 早期版本写入、现已废弃的顶层键，配置时顺带清掉
        let legacyKeys: [String]
    }

    /// 与 Claude Code 事件名一致的通用映射
    private static let standardHookBindings: [SettingsHookBinding] = [
        SettingsHookBinding(event: "PreToolUse", hookArg: "PreToolUse", timeout: 5),
        SettingsHookBinding(event: "PostToolUse", hookArg: "PostToolUse", timeout: 5),
        SettingsHookBinding(event: "UserPromptSubmit", hookArg: "session_start", timeout: 5),
        SettingsHookBinding(event: "SessionStart", hookArg: "session_start", timeout: 5),
        SettingsHookBinding(event: "SessionEnd", hookArg: "session_end", timeout: 5),
        SettingsHookBinding(event: "Stop", hookArg: "notification", timeout: 5),
        SettingsHookBinding(event: "SubagentStart", hookArg: "subagent_start", timeout: 5),
        SettingsHookBinding(event: "SubagentStop", hookArg: "subagent_end", timeout: 5),
        SettingsHookBinding(event: "PreCompact", hookArg: "compact", timeout: 5),
        SettingsHookBinding(event: "Notification", hookArg: "Notification", timeout: 5),
        SettingsHookBinding(event: "PermissionRequest", hookArg: "PermissionRequest", timeout: 300),
    ]

    private static func settingsHookTarget(for agent: AgentType) -> SettingsHookTarget? {
        switch agent {
        case .qwen:
            SettingsHookTarget(configDir: "\(home)/.qwen", bindings: standardHookBindings, legacyKeys: [])
        case .codeBuddy:
            SettingsHookTarget(configDir: "\(home)/.codebuddy", bindings: standardHookBindings, legacyKeys: [])
        case .droid:
            SettingsHookTarget(configDir: "\(home)/.factory", bindings: standardHookBindings, legacyKeys: [])
        case .geminiCli:
            SettingsHookTarget(configDir: "\(home)/.gemini", bindings: standardHookBindings, legacyKeys: ["xisland_hook"])
        default:
            nil
        }
    }

    private static func settingsPath(for agent: AgentType) -> String? {
        settingsHookTarget(for: agent).map { "\($0.configDir)/settings.json" }
    }

    private static func configureSettingsHooks(_ agent: AgentType) {
        guard let target = settingsHookTarget(for: agent),
              let path = settingsPath(for: agent) else { return }
        ensureDir(target.configDir)

        var settings = readJSON(path) ?? [String: Any]()
        for key in target.legacyKeys {
            settings.removeValue(forKey: key)
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for binding in target.bindings {
            var hookList = hooks[binding.event] as? [[String: Any]] ?? []
            hookList.removeAll { entryContainsBridge($0) }

            let guardedCmd = bridgeHookCommand(
                bridgePath: bridgePath, agent: agent, hookArg: binding.hookArg
            )

            hookList.append([
                "matcher": "*",
                "hooks": [
                    [
                        "type": "command",
                        "command": guardedCmd,
                        "timeout": binding.timeout
                    ] as [String: Any]
                ]
            ] as [String: Any])
            hooks[binding.event] = hookList
        }

        settings["hooks"] = hooks
        writeJSON(path, settings)
    }

    /// PermissionRequest 要靠退出码把用户的选择回传给工具，不能用 || true 吞掉；
    /// 其余事件只是上报状态，失败不该阻塞工具本身运行。
    static func bridgeHookCommand(bridgePath: String, agent: AgentType, hookArg: String) -> String {
        let base = "\(bridgePath) --agent \(agent.rawValue) --hook \(hookArg)"
        return hookArg == "PermissionRequest" ? base : "\(base) || true"
    }

    private static func hasSettingsHooks(for agent: AgentType) -> Bool {
        guard let path = settingsPath(for: agent),
              let settings = readJSON(path),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooksContainBridge(hooks)
    }

    private static func removeSettingsHooks(for agent: AgentType) {
        guard let target = settingsHookTarget(for: agent),
              let path = settingsPath(for: agent),
              var settings = readJSON(path) else { return }
        for key in target.legacyKeys {
            settings.removeValue(forKey: key)
        }
        if var hooks = settings["hooks"] as? [String: Any] {
            for (event, list) in hooks {
                guard var entries = list as? [[String: Any]] else { continue }
                entries.removeAll { entryContainsBridge($0) }
                hooks[event] = entries
            }
            settings["hooks"] = hooks
        }
        writeJSON(path, settings)
    }

    private static func entryContainsBridge(_ entry: [String: Any]) -> Bool {
        let cmds = entry["hooks"] as? [[String: Any]] ?? []
        return cmds.contains { ($0["command"] as? String)?.contains("di-bridge") == true }
    }

    private struct ArrayHookTarget {
        let path: String
        let sessionPrefix: String
    }

    private static func arrayHookTarget(for agent: AgentType) -> ArrayHookTarget? {
        switch agent {
        case .windsurf: ArrayHookTarget(path: "\(home)/.windsurf/hooks.json", sessionPrefix: "windsurf")
        case .amazonQ: ArrayHookTarget(path: "\(home)/.amazonq/hooks.json", sessionPrefix: "amazonq")
        case .cody: ArrayHookTarget(path: "\(home)/.cody/hooks.json", sessionPrefix: "cody")
        case .cline: ArrayHookTarget(path: "\(home)/.cline/hooks.json", sessionPrefix: "cline")
        case .`continue`: ArrayHookTarget(path: "\(home)/.continue/hooks.json", sessionPrefix: "continue")
        case .copilotCli: ArrayHookTarget(path: "\(home)/.copilot/hooks.json", sessionPrefix: "copilot")
        case .rooCode: ArrayHookTarget(path: "\(home)/.roo/hooks.json", sessionPrefix: "roo")
        case .pearai: ArrayHookTarget(path: "\(home)/.pearai/hooks.json", sessionPrefix: "pearai")
        case .zed: ArrayHookTarget(path: "\(home)/.config/zed/hooks.json", sessionPrefix: "zed")
        case .jetbrainsAi: ArrayHookTarget(path: "\(home)/.jetbrains/hooks.json", sessionPrefix: "jetbrains")
        default: nil
        }
    }

    private static func configureArrayHooks(_ agent: AgentType) {
        guard let target = arrayHookTarget(for: agent) else { return }
        // writeJSON 不建父目录，目录不存在时会静默写不进去。
        // 这里不主动创建：目录不存在即视为工具未安装，直接跳过，
        // 避免为用户没装的工具在家目录里凭空造一堆配置目录（装上并运行一次后，下次启动会自动配置）。
        let directory = (target.path as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: directory) else {
            return
        }

        var config = readJSON(target.path) ?? [:]
        var hooks = config["hooks"] as? [[String: Any]] ?? []
        let session = "\(target.sessionPrefix)-$(pwd | md5)"

        let startHook: [String: Any] = [
            "name": "xisland_session_start",
            "command": "~/.xisland/bin/di-bridge --agent \(agent.rawValue) --hook session_start --session \(session)",
            "event": "onIdle"
        ]
        let endHook: [String: Any] = [
            "name": "xisland_session_end",
            "command": "~/.xisland/bin/di-bridge --agent \(agent.rawValue) --hook session_end --session \(session)",
            "event": "afterCommand"
        ]

        hooks.removeAll { isXIslandHook($0) }
        hooks.append(contentsOf: [startHook, endHook])
        config["hooks"] = hooks
        writeJSON(target.path, config)
        print("[ZeroConfig] \(agent.displayName) hooks configured at \(target.path)")
    }

    private static func isXIslandHook(_ entry: [String: Any]) -> Bool {
        (entry["name"] as? String)?.hasPrefix("xisland_") == true
    }

    private static func hasArrayHooks(at path: String) -> Bool {
        guard let config = readJSON(path),
              let hooks = config["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { entry in
            isXIslandHook(entry) && (entry["command"] as? String)?.contains("di-bridge") == true
        }
    }

    private static func removeArrayHooks(at path: String) {
        guard var config = readJSON(path),
              var hooks = config["hooks"] as? [[String: Any]] else { return }
        hooks.removeAll { isXIslandHook($0) }
        config["hooks"] = hooks
        writeJSON(path, config)
    }

    static func isAutoConfigEnabled(for agent: AgentType) -> Bool {
        let defaults = AppPreferences.defaults
        let key = autoConfigKey(for: agent)
        if defaults.object(forKey: key) == nil { return true }
        return defaults.bool(forKey: key)
    }

    static func setAutoConfigEnabled(_ enabled: Bool, for agent: AgentType) {
        AppPreferences.defaults.set(enabled, forKey: autoConfigKey(for: agent))
        if enabled {
            configure(agent)
        } else {
            removeConfiguration(for: agent)
        }
    }

    static func hookStatus(for agent: AgentType) -> HookInstallStatus {
        if agent == .glm { return .modelSource }
        if agent == .kiro { return .externalKiro }
        if usesWorkBuddyPlugin(agent) { return .externalWorkBuddy }
        if usesAmazonQWrapper(agent) { return .externalAmazonQ }
        if usesCodyBridge(agent) { return .externalCody }
        if usesStateObserver(agent) { return .externalObserver }
        if usesACPBridge(agent) { return .externalAgent }
        if hasUnverifiedIntegration(agent) { return .unverified }
        if usesCompanionExtension(agent) { return .externalExtension }
        return hasConfiguration(for: agent) ? .active : .inactive
    }

    static func usesCompanionExtension(_ agent: AgentType) -> Bool {
        agent == .rooCode || agent == .pearai
    }

    static func hasUnverifiedIntegration(_ agent: AgentType) -> Bool {
        agent == .kiro
    }

    static func usesWorkBuddyPlugin(_ agent: AgentType) -> Bool { agent == .workBuddy }

    static func usesAmazonQWrapper(_ agent: AgentType) -> Bool { agent == .amazonQ }

    static func usesCodyBridge(_ agent: AgentType) -> Bool { agent == .cody }

    static func usesStateObserver(_ agent: AgentType) -> Bool { agent == .`continue` }

    static func usesACPBridge(_ agent: AgentType) -> Bool { agent == .zed || agent == .jetbrainsAi }

    /// 仅检查已有文件；轮询修复不为未安装的软件创建配置目录。
    static func shouldRepairNativeHooks(for agent: AgentType, homeDirectory: String) -> Bool {
        if hasUnverifiedIntegration(agent) || usesCompanionExtension(agent) || usesACPBridge(agent) || usesStateObserver(agent) || usesCodyBridge(agent) || usesAmazonQWrapper(agent) || usesWorkBuddyPlugin(agent) { return false }
        if agent == .deepseek {
            return DeepSeekHookInstallation.shouldRepair(homeDirectory: homeDirectory, bridgePath: "\(homeDirectory)/.xisland/bin/di-bridge",
                                                        environment: ProcessInfo.processInfo.environment)
        }
        if agent == .aider {
            let url = URL(fileURLWithPath: homeDirectory).appendingPathComponent(AiderWrapperConfiguration.relativePath)
            return AiderWrapperConfiguration.shouldRepair(at: url, bridgePath: "\(homeDirectory)/.xisland/bin/di-bridge")
        }
        if agent == .copilot {
            return VSCodeHookInstallation.shouldRepair(homeDirectory: homeDirectory, bridgePath: "\(homeDirectory)/.xisland/bin/di-bridge")
        }
        if agent == .cline {
            let directory = homeDirectory == home ? clineHooksDirectory
                : URL(fileURLWithPath: homeDirectory).appendingPathComponent(ClineHookConfiguration.relativeHooksDirectory)
            return ClineHookConfiguration.shouldRepair(in: directory, bridgePath: "\(homeDirectory)/.xisland/bin/di-bridge")
        }
        if agent == .kimi {
            return KimiHookInstallation.shouldRepair(homeDirectory: homeDirectory, bridgePath: "\(homeDirectory)/.xisland/bin/di-bridge",
                                                      environment: ProcessInfo.processInfo.environment)
        }
        let profile = effectiveNativeProfile(for: agent, homeDirectory: homeDirectory)
        let relativePath: String
        if let profile { relativePath = profile.relativeConfigPath }
        else if agent == .devin { relativePath = DevinHookConfiguration.relativeConfigPath }
        else if agent == .windsurf { relativePath = WindsurfHookConfiguration.relativeConfigPath }
        else if agent == .cursor { relativePath = CursorHookConfiguration.relativeConfigPath }
        else if agent == .trae { relativePath = TraeHookConfiguration.relativeConfigPath }
        else if agent == .codeBuddy { relativePath = CodeBuddyHookConfiguration.relativeConfigPath }
        else if agent == .copilotCli {
            let url = CopilotCliHookConfiguration.configURL(homeDirectory: homeDirectory, environment: ProcessInfo.processInfo.environment)
            guard FileManager.default.fileExists(atPath: url.path), let config = try? HookConfigurationFile.read(at: url) else { return false }
            return !CopilotCliHookConfiguration.isConfigured(in: config, bridgePath: "\(homeDirectory)/.xisland/bin/di-bridge")
        }
        else { return false }
        let url = URL(fileURLWithPath: homeDirectory).appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path),
              let config = try? HookConfigurationFile.read(at: url) else { return false }
        let bridge = "\(homeDirectory)/.xisland/bin/di-bridge"
        if let profile { return !profile.isConfigured(in: config, bridgePath: bridge) }
        if agent == .devin { return !DevinHookConfiguration.isConfigured(in: config, bridgePath: bridge) }
        if agent == .cursor { return !CursorHookConfiguration.isConfigured(in: config, bridgePath: bridge) }
        if agent == .trae { return !TraeHookConfiguration.isConfigured(in: config, bridgePath: bridge) }
        if agent == .codeBuddy { return !CodeBuddyHookConfiguration.isConfigured(in: config, bridgePath: bridge) }
        return !WindsurfHookConfiguration.isConfigured(in: config, bridgePath: bridge)
    }

    @MainActor
    static func repairHooksIfNeeded(agents: Set<AgentType>? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let detected = IntegrationSetupDiscovery.automaticAgents(in: IntegrationSetupDiscovery.scan(), requested: agents)

        // 按完整事件集合检测；只剩一条旧命令不能视为配置正常。
        for agent in AgentType.allCases where detected.contains(agent) && isAutoConfigEnabled(for: agent) {
            if shouldRepairNativeHooks(for: agent, homeDirectory: home) {
                configure(agent)
            }
        }

        // Plugin/script file agents
        let fileAgents: [(AgentType, String)] = [
            (.openCode, openCodePluginURL.path),
            (.amp, ampPluginURL.path),
            (.pi, piPluginURL.path),
        ]

        for (agent, path) in fileAgents {
            guard detected.contains(agent), isAutoConfigEnabled(for: agent) else { continue }
            if let text = try? String(contentsOfFile: path, encoding: .utf8),
               ([AgentType.amp, .pi, .openCode].contains(agent) ? !hasConfiguration(for: agent) : !text.contains("di-bridge")) {
                configure(agent)
                print("[ZeroConfig] Repaired \(agent.displayName) plugin at \(path)")
            }
        }

        // Shell wrapper agents
        let wrapperAgents: [(AgentType, String)] = [
            (.hermes, "\(home)/.xisland/bin/hermes-bridge"),
        ]

        for (agent, path) in wrapperAgents {
            guard detected.contains(agent), isAutoConfigEnabled(for: agent),
                  !FileManager.default.fileExists(atPath: path) else { continue }
            configure(agent)
            print("[ZeroConfig] Repaired \(agent.displayName) wrapper at \(path)")
        }
    }

    private static var bridgePath: String {
        let stable = "\(home)/.xisland/bin/di-bridge"
        let bundled = Bundle.main.bundlePath + "/Contents/MacOS/di-bridge"
        syncBundledFileIfNeeded(bundled: bundled, stable: stable)
        return stable
    }

    static func syncCommandLineTools() {
        let binDir = "\(home)/.xisland/bin"
        ensureDir(binDir)
        ensureDir("\(binDir)/lib")

        syncBundledFileIfNeeded(
            bundled: Bundle.main.bundlePath + "/Contents/MacOS/di-bridge",
            stable: "\(binDir)/di-bridge"
        )
        syncBundledFileIfNeeded(
            bundled: Bundle.main.bundlePath + "/Contents/Resources/cli/xisland",
            stable: "\(binDir)/xisland"
        )
        syncBundledFileIfNeeded(
            bundled: Bundle.main.bundlePath + "/Contents/Resources/cli/lib/xisland-cli.sh",
            stable: "\(binDir)/lib/xisland-cli.sh"
        )
    }

    private static func syncBundledFileIfNeeded(bundled: String, stable: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundled) else { return }

        ensureDir((stable as NSString).deletingLastPathComponent)

        let shouldCopy: Bool
        if fm.fileExists(atPath: stable),
           let stableAttr = try? fm.attributesOfItem(atPath: stable),
           let bundledAttr = try? fm.attributesOfItem(atPath: bundled),
           let stableMod = stableAttr[.modificationDate] as? Date,
           let bundledMod = bundledAttr[.modificationDate] as? Date {
            shouldCopy = bundledMod > stableMod
        } else {
            shouldCopy = true
        }

        guard shouldCopy else { return }
        try? fm.removeItem(atPath: stable)
        try? fm.copyItem(atPath: bundled, toPath: stable)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stable)
    }

    // MARK: - Claude Code

    private static func configureClaudeCode() {
        let configDir = "\(home)/.claude"
        let settingsPath = "\(configDir)/settings.json"
        ensureDir(configDir)

        var settings = readJSON(settingsPath) ?? [String: Any]()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let hookMapping: [(String, String, Int)] = [
            ("PreToolUse", "PreToolUse", 5),
            ("PostToolUse", "PostToolUse", 5),
            ("PreCompact", "compact", 5),
            ("Notification", "Notification", 5),
            ("PermissionRequest", "PermissionRequest", 300),
            ("Stop", "Stop", 5),
            ("SessionStart", "session_start", 5),
            ("SessionEnd", "session_end", 5),
            ("SubagentStart", "subagent_start", 5),
            ("SubagentStop", "subagent_end", 5),
            ("UserPromptSubmit", "session_start", 5),
        ]

        for (hookType, hookArg, timeout) in hookMapping {
            var hookList = hooks[hookType] as? [[String: Any]] ?? []

            hookList.removeAll { entry in
                let cmds = entry["hooks"] as? [[String: Any]] ?? []
                return cmds.contains {
                    guard let cmd = $0["command"] as? String else { return false }
                    return cmd.contains("di-bridge")
                }
            }

            let alreadyConfigured = false
            if !alreadyConfigured {
                // PermissionRequest must preserve di-bridge exit code so deny works;
                // other hooks are fire-and-forget so || true is safe.
                let guardedCmd: String
                if hookArg == "PermissionRequest" {
                    guardedCmd = "\(bridgePath) --agent claude_code --hook \(hookArg)"
                } else {
                    guardedCmd = "\(bridgePath) --agent claude_code --hook \(hookArg) || true"
                }
                hookList.append([
                    "matcher": "*",
                    "hooks": [
                        [
                            "type": "command",
                            "command": guardedCmd,
                            "timeout": timeout
                        ] as [String: Any]
                    ]
                ] as [String: Any])
                hooks[hookType] = hookList
            }
        }

        settings["hooks"] = hooks
        writeJSON(settingsPath, settings)
    }

    // MARK: - Codex

    private static func configureCodex() {
        let configDir = "\(home)/.codex"
        ensureDir(configDir)

        let hooksPath = "\(configDir)/hooks.json"
        var config = readJSON(hooksPath) ?? [String: Any]()
        var hooks = config["hooks"] as? [String: Any] ?? [:]

        // Remove stale di-bridge entries with wrong event names
        for staleKey in ["ToolUse", "PatchApply"] {
            if var hookList = hooks[staleKey] as? [[String: Any]] {
                hookList.removeAll { entry in
                    let cmds = entry["hooks"] as? [[String: Any]] ?? []
                    return cmds.contains { ($0["command"] as? String)?.contains("di-bridge") == true }
                }
                if hookList.isEmpty {
                    hooks.removeValue(forKey: staleKey)
                } else {
                    hooks[staleKey] = hookList
                }
            }
        }

        // Codex fires Stop after every agent response (not just session end),
        // so we map it to notification instead of session_end to capture assistant replies.
        let hookMapping: [(String, String, Int)] = [
            ("SessionStart", "session_start", 5),
            ("PreToolUse", "PreToolUse", 5),
            ("PostToolUse", "PostToolUse", 5),
            ("UserPromptSubmit", "session_start", 5),
            ("PermissionRequest", "PermissionRequest", 300),
            ("Stop", "notification", 5),
        ]

        for (hookType, hookArg, timeout) in hookMapping {
            var hookList = hooks[hookType] as? [[String: Any]] ?? []
            hookList.removeAll { entry in
                let cmds = entry["hooks"] as? [[String: Any]] ?? []
                return cmds.contains { ($0["command"] as? String)?.contains("di-bridge") == true }
            }
            hookList.append([
                "matcher": "*",
                "hooks": [
                    [
                        "type": "command",
                        "command": "\(bridgePath) --agent codex --hook \(hookArg)",
                        "timeout": timeout
                    ] as [String: Any]
                ]
            ] as [String: Any])
            hooks[hookType] = hookList
        }

        config["hooks"] = hooks
        writeJSON(hooksPath, config)
    }

    // MARK: - Gemini CLI


    // MARK: - Cursor

    private static func configureCursor() {
        configureCursorFamily(agent: .cursor)
    }

    private static func configureTrae() {
        configureCursorFamily(agent: .trae)
        configureTraeIDEClaudeCodeHooks()
    }

    private static func configureCursorFamily(agent: AgentType) {
        for target in cursorHookTargets where target.agent == agent {
            ensureDir((target.path as NSString).deletingLastPathComponent)
            let config = readJSON(target.path) ?? [String: Any]()
            let updatedConfig = sanitizeCursorConfig(config, bridgePath: bridgePath, agent: agent.rawValue)
            writeJSON(target.path, updatedConfig)
        }
    }

    static func sanitizeCursorConfig(_ config: [String: Any], bridgePath: String, agent: String = AgentType.cursor.rawValue) -> [String: Any] {
        var config = config
        var hooks = config["hooks"] as? [String: Any] ?? [:]

        if let dynamicIslandCommand = config["dynamic_island"] as? String,
           isLegacyCursorHookCommand(dynamicIslandCommand) {
            config.removeValue(forKey: "dynamic_island")
        }

        let hookMapping: [(String, String)] = [
            ("beforeSubmitPrompt", "--hook session_start"),
            ("afterAgentResponse", "--hook notification"),
            ("afterAgentThought", "--hook notification"),
            ("beforeReadFile", "--hook PreToolUse --tool Read"),
            ("afterFileEdit", "--hook PostToolUse --tool FileEdit"),
            ("beforeShellExecution", "--hook PreToolUse --tool Shell"),
            ("afterShellExecution", "--hook PostToolUse --tool Shell"),
            ("beforeMCPExecution", "--hook PreToolUse --tool MCP"),
            ("afterMCPExecution", "--hook PostToolUse --tool MCP"),
            ("stop", "--hook session_end"),
        ]

        for (event, hookArgs) in hookMapping {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.removeAll { isLegacyCursorHookCommand($0["command"] as? String) }
            entries.append(["command": "\(bridgePath) --agent \(agent) \(hookArgs)"])
            hooks[event] = entries
        }

        if let oldEntries = hooks["preToolUse"] as? [[String: Any]] {
            let cleaned = oldEntries.filter {
                !isLegacyCursorHookCommand($0["command"] as? String)
            }
            hooks["preToolUse"] = cleaned
        }

        config["hooks"] = hooks
        if config["version"] == nil { config["version"] = 1 }
        return config
    }

    private static func configureTraeIDEClaudeCodeHooks() {
        for settingsPath in traeIDESettingsPaths where FileManager.default.fileExists(atPath: settingsPath) {
            let config = readJSON(settingsPath) ?? [String: Any]()
            let hooks = config["claudeCode.hooks"] as? [String: Any] ?? [:]
            var updatedConfig = config
            updatedConfig["claudeCode.hooks"] = sanitizeClaudeCodeHooksForIDE(
                hooks,
                bridgePath: bridgePath,
                agent: AgentType.trae.rawValue
            )
            writeJSON(settingsPath, updatedConfig)
        }
    }

    static func sanitizeClaudeCodeHooksForIDE(_ hooks: [String: Any], bridgePath: String, agent: String) -> [String: Any] {
        var hooks = hooks

        let hookMapping: [(String, String, Int)] = [
            ("PreToolUse", "PreToolUse", 5),
            ("PostToolUse", "PostToolUse", 5),
            ("PreCompact", "compact", 5),
            ("Notification", "Notification", 5),
            ("PermissionRequest", "PermissionRequest", 300),
            ("Stop", "session_end", 5),
            ("SessionStart", "session_start", 5),
            ("SessionEnd", "session_end", 5),
            ("SubagentStart", "subagent_start", 5),
            ("SubagentStop", "subagent_end", 5),
            ("UserPromptSubmit", "session_start", 5)
        ]

        for (hookType, hookArg, timeout) in hookMapping {
            var entries = hooks[hookType] as? [[String: Any]] ?? []
            entries.removeAll { entry in
                let commands = entry["hooks"] as? [[String: Any]] ?? []
                return commands.contains { ($0["command"] as? String)?.contains("di-bridge") == true }
            }

            let command: String
            if hookArg == "PermissionRequest" {
                command = "\(bridgePath) --agent \(agent) --hook \(hookArg)"
            } else {
                command = "\(bridgePath) --agent \(agent) --hook \(hookArg) || true"
            }

            entries.append([
                "matcher": "*",
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": timeout
                ]]
            ])

            hooks[hookType] = entries
        }

        return hooks
    }

    private static func isLegacyCursorHookCommand(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.contains("di-bridge") || command.contains("codeisland-state.py")
    }

    // MARK: - OpenCode

    private enum PluginConfigurationError: Error { case userOwnedFile }

    private static var openCodePluginURL: URL {
        OpenCodePluginConfiguration.pluginURL(homeDirectory: home, environment: ProcessInfo.processInfo.environment)
    }

    private static func configureOpenCode() {
        let url = openCodePluginURL
        do {
            let source = try OpenCodePluginConfiguration.source(bridgePath: bridgePath)
            try HookConfigurationFile.updateText(at: url) { existing in
                guard existing.isEmpty || OpenCodePluginConfiguration.isOwnedSource(existing) else {
                    throw PluginConfigurationError.userOwnedFile
                }
                return source
            }
            try removeOpenCodeLegacyRegistration(at: url)
        } catch {
            print("[ZeroConfig] OpenCode plugin configuration failed: \(error.localizedDescription)")
        }
    }


    private static func removeOpenCodeLegacyRegistration(at url: URL) throws {
        // 本地插件目录自动加载，安装/卸载均清理旧版的重复注册。
        let directory = url.deletingLastPathComponent().deletingLastPathComponent()
        let legacyURL = URL(fileURLWithPath: "\(home)/.config/opencode/plugins/xisland.js")
        var managedURLs = [url]
        if legacyURL != url, let text = try? String(contentsOf: legacyURL, encoding: .utf8),
           OpenCodePluginConfiguration.isOwnedSource(text) { managedURLs.append(legacyURL) }
        for name in ["config.json", "opencode.json"] {
            let configURL = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: configURL.path) else { continue }
            try HookConfigurationFile.update(at: configURL) { original in
                OpenCodePluginConfiguration.removingLegacyReferences(from: original, pluginURLs: managedURLs)
            }
        }
    }

    // MARK: - Droid


    // MARK: - Qoder

    private static func configureQoder() {
        // Qoder has no hook system — detection via process monitoring only.
        print("[ZeroConfig] Qoder does not support hook injection. X Island will monitor it via process detection.")
    }

    // MARK: - Copilot

    private static func configureCopilot() {
        do { try VSCodeHookInstallation.install(homeDirectory: home, bridgePath: bridgePath) }
        catch { print("[ZeroConfig] VS Code Local hook configuration failed: \(error.localizedDescription)") }
    }

    private static var clineHooksDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: home).appendingPathComponent("Documents")
        return documents.appendingPathComponent("Cline/Hooks", isDirectory: true)
    }

    // MARK: - CodeBuddy


    // MARK: - Qwen Code


    // MARK: - Kimi Code

    private static func configureKimi() {
        do {
            try KimiHookInstallation.install(homeDirectory: home, bridgePath: bridgePath,
                                             environment: ProcessInfo.processInfo.environment)
        } catch {
            print("[ZeroConfig] Kimi hook configuration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - DeepSeek-TUI

    private static func configureDeepSeek() {
        do {
            _ = try DeepSeekHookInstallation.install(homeDirectory: home, bridgePath: bridgePath,
                                                    environment: ProcessInfo.processInfo.environment)
        } catch { print("[ZeroConfig] Codewhale hook configuration failed: \(error.localizedDescription)") }
    }

    // MARK: - Kiro


    // MARK: - Amp

    private static var ampPluginURL: URL {
        AmpPluginConfiguration.pluginURL(homeDirectory: home, environment: ProcessInfo.processInfo.environment)
    }

    private static func configureAmp() {
        let url = ampPluginURL
        do {
            let source = try AmpPluginConfiguration.source(bridgePath: bridgePath)
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try String(contentsOf: url, encoding: .utf8)
                guard AmpPluginConfiguration.isOwnedSource(existing) else {
                    print("[ZeroConfig] Amp plugin path contains a user file; kept unchanged")
                    return
                }
                guard existing != source else { return }
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try source.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[ZeroConfig] Amp plugin configuration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Pi Agent

    private static var piPluginURL: URL {
        PiPluginConfiguration.pluginURL(homeDirectory: home)
    }

    private static func configurePi() {
        let url = piPluginURL
        do {
            let source = try PiPluginConfiguration.source(bridgePath: bridgePath)
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try String(contentsOf: url, encoding: .utf8)
                guard PiPluginConfiguration.isOwnedSource(existing) else {
                    print("[ZeroConfig] Pi extension path contains a user file; kept unchanged")
                    return
                }
                guard existing != source else { return }
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try source.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[ZeroConfig] Pi extension configuration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Hermes

    private static func configureHermes() {
        // Hermes does not have a formal hook system.
        // It only supports MCP / Quick Commands / Skills as indirect integration points.
        // We create a simple wrapper script that users can invoke via Quick Commands.
        let wrapperDir = "\(home)/.xisland/bin"
        let wrapperPath = "\(wrapperDir)/hermes-bridge"
        ensureDir(wrapperDir)

        let wrapper = #"""
        #!/bin/bash
        # Hermes X Island bridge wrapper
        # Usage: hermes-bridge <hook> [session_id]
        # Add this to Hermes Quick Commands to forward events to X Island.
        HOOK="${1:-notification}"
        SESSION="${2:-hermes-$(pwd)}"
        echo '{}' | /Users/$USER/.xisland/bin/di-bridge --agent hermes --hook "$HOOK" --session "$SESSION"
        """#

        try? wrapper.write(toFile: wrapperPath, atomically: true, encoding: String.Encoding.utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperPath)

        print("[ZeroConfig] Hermes wrapper installed at \(wrapperPath). Add it to Hermes Quick Commands for manual integration.")
    }

    // MARK: - Aider

    private static func configureAider() {
        let url = URL(fileURLWithPath: home).appendingPathComponent(AiderWrapperConfiguration.relativePath)
        do { try AiderWrapperConfiguration.install(at: url, bridgePath: bridgePath) }
        catch { print("[ZeroConfig] Aider wrapper configuration failed: \(error.localizedDescription)") }
    }

    // MARK: - New Agents Configuration


    private static func configureDevin() {
        // Devin uses its own config format
        let configPath = customBridgeConfigPath(for: .devin)
        ensureDir((configPath as NSString).deletingLastPathComponent)

        var config = readJSON(configPath) ?? [:]
        config["xisland_bridge"] = "~/.xisland/bin/di-bridge"
        config["xisland_agent"] = "devin"
        writeJSON(configPath, config)
        print("[ZeroConfig] Devin config updated at \(configPath)")
    }


    private static func configureTabnine() {
        // Tabnine uses its own config format
        let configPath = customBridgeConfigPath(for: .tabnine)
        ensureDir((configPath as NSString).deletingLastPathComponent)

        var config = readJSON(configPath) ?? [:]
        config["xisland_bridge"] = "~/.xisland/bin/di-bridge"
        config["xisland_agent"] = "tabnine"
        writeJSON(configPath, config)
        print("[ZeroConfig] Tabnine config updated at \(configPath)")
    }





    // MARK: - Helpers

    private static func ensureDir(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private static func readJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func writeJSON(_ path: String, _ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private static func autoConfigKey(for agent: AgentType) -> String {
        autoConfigKeyPrefix + agent.rawValue
    }

    private struct CursorHookTarget {
        let path: String
        let agent: AgentType
    }

    private static var cursorHookTargets: [CursorHookTarget] {
        [
            CursorHookTarget(path: "\(home)/.cursor/hooks.json", agent: .cursor),
            CursorHookTarget(path: "\(home)/.trae/hooks.json", agent: .trae),
            CursorHookTarget(path: "\(home)/.trae-cn/hooks.json", agent: .trae)
        ]
    }

    private static var cursorHookPaths: [String] {
        cursorHookTargets.map(\.path)
    }

    private static var traeIDESettingsPaths: [String] {
        [
            "\(home)/Library/Application Support/Trae/User/settings.json",
            "\(home)/Library/Application Support/Trae CN/User/settings.json",
            "\(home)/Library/Application Support/TRAE SOLO CN/User/settings.json"
        ]
    }

    static func hasConfiguration(for agent: AgentType) -> Bool {
        if usesCompanionExtension(agent) || usesACPBridge(agent) || usesStateObserver(agent) || usesCodyBridge(agent) || usesAmazonQWrapper(agent) || usesWorkBuddyPlugin(agent) || hasUnverifiedIntegration(agent) { return false }
        if agent == .codeBuddy {
            let url = URL(fileURLWithPath: home).appendingPathComponent(CodeBuddyHookConfiguration.relativeConfigPath)
            guard let config = try? HookConfigurationFile.read(at: url) else { return false }
            return CodeBuddyHookConfiguration.isConfigured(in: config, bridgePath: "\(home)/.xisland/bin/di-bridge")
        }
        if agent == .cline {
            let directory = clineHooksDirectory
            return ClineHookConfiguration.isConfigured(in: directory, bridgePath: "\(home)/.xisland/bin/di-bridge")
        }
        if let profile = effectiveNativeProfile(for: agent) {
            let url = URL(fileURLWithPath: home).appendingPathComponent(profile.relativeConfigPath)
            guard let config = try? HookConfigurationFile.read(at: url) else { return false }
            return profile.isConfigured(in: config, bridgePath: "\(home)/.xisland/bin/di-bridge")
        }
        if agent == .devin {
            let url = URL(fileURLWithPath: home).appendingPathComponent(DevinHookConfiguration.relativeConfigPath)
            guard let config = try? HookConfigurationFile.read(at: url) else { return false }
            return DevinHookConfiguration.isConfigured(in: config, bridgePath: "\(home)/.xisland/bin/di-bridge")
        }
        if agent == .windsurf {
            let url = URL(fileURLWithPath: home).appendingPathComponent(WindsurfHookConfiguration.relativeConfigPath)
            guard let config = try? HookConfigurationFile.read(at: url) else { return false }
            return WindsurfHookConfiguration.isConfigured(in: config, bridgePath: "\(home)/.xisland/bin/di-bridge")
        }
        if agent == .copilotCli {
            let url = CopilotCliHookConfiguration.configURL(homeDirectory: home, environment: ProcessInfo.processInfo.environment)
            guard let config = try? HookConfigurationFile.read(at: url) else { return false }
            return CopilotCliHookConfiguration.isConfigured(in: config, bridgePath: "\(home)/.xisland/bin/di-bridge")
        }
        if agent == .cursor {
            let url = URL(fileURLWithPath: home).appendingPathComponent(CursorHookConfiguration.relativeConfigPath)
            guard let config = try? HookConfigurationFile.read(at: url) else { return false }
            return CursorHookConfiguration.isConfigured(in: config, bridgePath: "\(home)/.xisland/bin/di-bridge")
        }
        if agent == .trae {
            let url = URL(fileURLWithPath: home).appendingPathComponent(TraeHookConfiguration.relativeConfigPath)
            guard let config = try? HookConfigurationFile.read(at: url) else { return false }
            return TraeHookConfiguration.isConfigured(in: config, bridgePath: "\(home)/.xisland/bin/di-bridge")
        }
        switch agent {
        case .windsurf, .amazonQ, .cody, .cline, .`continue`, .copilotCli,
             .rooCode, .pearai, .zed, .jetbrainsAi:
            guard let target = arrayHookTarget(for: agent) else { return false }
            return hasArrayHooks(at: target.path)
        case .qwen, .codeBuddy, .droid, .geminiCli, .kiro:
            return hasSettingsHooks(for: agent)
        case .claudeCode:
            let path = "\(home)/.claude/settings.json"
            guard let settings = readJSON(path),
                  let hooks = settings["hooks"] as? [String: Any] else { return false }
            return hooksContainBridge(hooks)
        case .codex:
            let path = "\(home)/.codex/hooks.json"
            guard let config = readJSON(path),
                  let hooks = config["hooks"] as? [String: Any] else { return false }
            return hooksContainBridge(hooks)
        case .cursor:
            for target in cursorHookTargets where target.agent == .cursor {
                let path = target.path
                guard let config = readJSON(path),
                      let hooks = config["hooks"] as? [String: Any] else { continue }
                if hooksContainBridge(hooks) { return true }
            }
            return false
        case .trae:
            for target in cursorHookTargets where target.agent == .trae {
                let path = target.path
                guard let config = readJSON(path),
                      let hooks = config["hooks"] as? [String: Any] else { continue }
                if hooksContainBridge(hooks) { return true }
            }
            for path in traeIDESettingsPaths {
                guard let config = readJSON(path),
                      let hooks = config["claudeCode.hooks"] as? [String: Any] else { continue }
                if hooksContainBridge(hooks) { return true }
            }
            return false
        case .openCode:
            guard let text = try? String(contentsOf: openCodePluginURL, encoding: .utf8),
                  let expected = try? OpenCodePluginConfiguration.source(bridgePath: "\(home)/.xisland/bin/di-bridge") else { return false }
            return text == expected
        case .qoder:
            // No hook system — always false
            return false
        case .copilot:
            return VSCodeHookInstallation.isConfigured(homeDirectory: home, bridgePath: "\(home)/.xisland/bin/di-bridge")
        case .kimi:
            return KimiHookInstallation.isConfigured(homeDirectory: home, bridgePath: "\(home)/.xisland/bin/di-bridge",
                                                      environment: ProcessInfo.processInfo.environment)
        case .deepseek:
            return DeepSeekHookInstallation.isConfigured(homeDirectory: home, bridgePath: "\(home)/.xisland/bin/di-bridge",
                                                        environment: ProcessInfo.processInfo.environment)
        case .amp:
            guard let text = try? String(contentsOf: ampPluginURL, encoding: .utf8),
                  let expected = try? AmpPluginConfiguration.source(bridgePath: "\(home)/.xisland/bin/di-bridge") else { return false }
            return text == expected
        case .pi:
            guard let text = try? String(contentsOf: piPluginURL, encoding: .utf8),
                  let expected = try? PiPluginConfiguration.source(bridgePath: "\(home)/.xisland/bin/di-bridge") else { return false }
            return text == expected
        case .hermes:
            let path = "\(home)/.xisland/bin/hermes-bridge"
            return FileManager.default.fileExists(atPath: path)
        case .glm:
            return false
        case .workBuddy:
            return false
        case .aider:
            let url = URL(fileURLWithPath: home).appendingPathComponent(AiderWrapperConfiguration.relativePath)
            return AiderWrapperConfiguration.isConfigured(at: url, bridgePath: "\(home)/.xisland/bin/di-bridge")
        case .devin, .tabnine:
            guard let config = readJSON(customBridgeConfigPath(for: agent)) else { return false }
            return (config["xisland_bridge"] as? String)?.contains("di-bridge") == true
        }
    }

    /// Devin / Tabnine 走各自的 config.json，只写入 xisland_bridge 标记而非 hooks 数组
    private static func customBridgeConfigPath(for agent: AgentType) -> String {
        agent == .devin ? "\(home)/.devin/config.json" : "\(home)/.tabnine/config.json"
    }

    private static func removeConfiguration(for agent: AgentType) {
        if usesCompanionExtension(agent) || usesACPBridge(agent) || usesStateObserver(agent) || usesCodyBridge(agent) || usesAmazonQWrapper(agent) || usesWorkBuddyPlugin(agent) || hasUnverifiedIntegration(agent) { return }
        if agent == .codeBuddy {
            let url = URL(fileURLWithPath: home).appendingPathComponent(CodeBuddyHookConfiguration.relativeConfigPath)
            do { try HookConfigurationFile.update(at: url) { try CodeBuddyHookConfiguration.removing(from: $0) } }
            catch { print("[ZeroConfig] CodeBuddy hook removal failed: \(error.localizedDescription)") }
            return
        }
        if agent == .cline {
            let directory = clineHooksDirectory
            do { try ClineHookConfiguration.remove(from: directory) }
            catch { print("[ZeroConfig] Cline hook removal failed: \(error.localizedDescription)") }
            return
        }
        if let profile = effectiveNativeProfile(for: agent) {
            let url = URL(fileURLWithPath: home).appendingPathComponent(profile.relativeConfigPath)
            do { try HookConfigurationFile.update(at: url) { try profile.removing(from: $0) } }
            catch { print("[ZeroConfig] \(agent.rawValue) hook removal failed: \(error.localizedDescription)") }
            return
        }
        if agent == .devin {
            let url = URL(fileURLWithPath: home).appendingPathComponent(DevinHookConfiguration.relativeConfigPath)
            do { try HookConfigurationFile.update(at: url) { try DevinHookConfiguration.removing(from: $0) } }
            catch { print("[ZeroConfig] Devin hook removal failed: \(error.localizedDescription)") }
            return
        }
        if agent == .windsurf {
            let url = URL(fileURLWithPath: home).appendingPathComponent(WindsurfHookConfiguration.relativeConfigPath)
            do { try HookConfigurationFile.update(at: url) { try WindsurfHookConfiguration.removing(from: $0) } }
            catch { print("[ZeroConfig] Windsurf hook removal failed: \(error.localizedDescription)") }
            return
        }
        if agent == .copilotCli {
            let url = CopilotCliHookConfiguration.configURL(homeDirectory: home, environment: ProcessInfo.processInfo.environment)
            do { try HookConfigurationFile.update(at: url) { try CopilotCliHookConfiguration.removing(from: $0) } }
            catch { print("[ZeroConfig] Copilot CLI hook removal failed: \(error.localizedDescription)") }
            return
        }
        if agent == .cursor {
            let url = URL(fileURLWithPath: home).appendingPathComponent(CursorHookConfiguration.relativeConfigPath)
            do { try HookConfigurationFile.update(at: url) { try CursorHookConfiguration.removing(from: $0) } }
            catch { print("[ZeroConfig] Cursor hook removal failed: \(error.localizedDescription)") }
            return
        }
        if agent == .trae {
            let url = URL(fileURLWithPath: home).appendingPathComponent(TraeHookConfiguration.relativeConfigPath)
            do { try HookConfigurationFile.update(at: url) { try TraeHookConfiguration.removing(from: $0) } }
            catch { print("[ZeroConfig] Trae CN hook removal failed: \(error.localizedDescription)") }
            return
        }
        switch agent {
        case .windsurf, .amazonQ, .cody, .cline, .`continue`, .copilotCli,
             .rooCode, .pearai, .zed, .jetbrainsAi:
            guard let target = arrayHookTarget(for: agent) else { return }
            removeArrayHooks(at: target.path)
        case .qwen, .codeBuddy, .droid, .geminiCli, .kiro:
            removeSettingsHooks(for: agent)
        case .devin, .tabnine:
            let path = customBridgeConfigPath(for: agent)
            guard var config = readJSON(path) else { return }
            config.removeValue(forKey: "xisland_bridge")
            config.removeValue(forKey: "xisland_agent")
            writeJSON(path, config)
        case .claudeCode:
            removeBridgeHooks(at: "\(home)/.claude/settings.json")
        case .codex:
            removeBridgeHooks(at: "\(home)/.codex/hooks.json")
        case .cursor:
            for target in cursorHookTargets where target.agent == .cursor {
                removeCursorBridgeHooks(at: target.path)
            }
        case .trae:
            for target in cursorHookTargets where target.agent == .trae {
                removeCursorBridgeHooks(at: target.path)
            }
            for path in traeIDESettingsPaths {
                removeBridgeHooks(at: path, hooksKey: "claudeCode.hooks")
            }
        case .openCode:
            do {
                let text = try String(contentsOf: openCodePluginURL, encoding: .utf8)
                if OpenCodePluginConfiguration.isOwnedSource(text) {
                    try removeOpenCodeLegacyRegistration(at: openCodePluginURL)
                    try FileManager.default.removeItem(at: openCodePluginURL)
                }
            } catch {
                print("[ZeroConfig] OpenCode plugin removal failed: \(error.localizedDescription)")
            }
        case .qoder:
            // No hook config — nothing to remove
            break
        case .copilot:
            do { try VSCodeHookInstallation.remove(homeDirectory: home) }
            catch { print("[ZeroConfig] VS Code Local hook removal failed: \(error.localizedDescription)") }
        case .kimi:
            do { try KimiHookInstallation.remove(homeDirectory: home, environment: ProcessInfo.processInfo.environment) }
            catch { print("[ZeroConfig] Kimi hook removal failed: \(error.localizedDescription)") }
        case .deepseek:
            do { try DeepSeekHookInstallation.remove(homeDirectory: home, environment: ProcessInfo.processInfo.environment) }
            catch { print("[ZeroConfig] Codewhale hook removal failed: \(error.localizedDescription)") }
        case .amp:
            do {
                let text = try String(contentsOf: ampPluginURL, encoding: .utf8)
                if AmpPluginConfiguration.isOwnedSource(text) { try FileManager.default.removeItem(at: ampPluginURL) }
            } catch {
                print("[ZeroConfig] Amp plugin removal failed: \(error.localizedDescription)")
            }
        case .pi:
            do {
                let text = try String(contentsOf: piPluginURL, encoding: .utf8)
                if PiPluginConfiguration.isOwnedSource(text) { try FileManager.default.removeItem(at: piPluginURL) }
            } catch {
                print("[ZeroConfig] Pi extension removal failed: \(error.localizedDescription)")
            }
        case .hermes:
            try? FileManager.default.removeItem(atPath: "\(home)/.xisland/bin/hermes-bridge")
        case .glm:
            break // 未经核实的旧路径不读取或删除用户配置。
        case .workBuddy:
            break
        case .aider:
            let url = URL(fileURLWithPath: home).appendingPathComponent(AiderWrapperConfiguration.relativePath)
            do { try AiderWrapperConfiguration.remove(at: url) }
            catch { print("[ZeroConfig] Aider wrapper removal failed: \(error.localizedDescription)") }
        }
    }

    private static func hooksContainBridge(_ hooks: [String: Any]) -> Bool {
        hooks.values.contains { hookList in
            guard let list = hookList as? [[String: Any]] else { return false }
            return list.contains { entry in
                let cmds = entry["hooks"] as? [[String: Any]] ?? []
                if cmds.contains(where: { ($0["command"] as? String)?.contains("di-bridge") == true }) {
                    return true
                }
                return (entry["command"] as? String)?.contains("di-bridge") == true
            }
        }
    }

    private static func configContainsBridge(path: String, key: String) -> Bool {
        guard let config = readJSON(path) else { return false }
        return (config[key] as? String)?.contains("di-bridge") == true
    }

    private static func removeBridgeHooks(at path: String, hooksKey: String = "hooks") {
        guard var config = readJSON(path),
              var hooks = config[hooksKey] as? [String: Any] else { return }
        for key in hooks.keys {
            guard var hookList = hooks[key] as? [[String: Any]] else { continue }
            hookList.removeAll { entry in
                let cmds = entry["hooks"] as? [[String: Any]] ?? []
                return cmds.contains { ($0["command"] as? String)?.contains("di-bridge") == true }
                    || (entry["command"] as? String)?.contains("di-bridge") == true
            }
            if hookList.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = hookList
            }
        }
        config[hooksKey] = hooks
        writeJSON(path, config)
    }

    private static func removeCursorBridgeHooks(at path: String) {
        guard var config = readJSON(path),
              var hooks = config["hooks"] as? [String: Any] else { return }
        for key in hooks.keys {
            guard var entries = hooks[key] as? [[String: Any]] else { continue }
            entries.removeAll { ($0["command"] as? String)?.contains("di-bridge") == true }
            if entries.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = entries
            }
        }
        config["hooks"] = hooks
        writeJSON(path, config)
    }


    private static func removeTOMLBlock(at path: String, marker: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let range = text.range(of: marker) else { return }
        var cleaned = text
        let rest = cleaned[range.lowerBound...]
        if let nextSection = rest.range(of: "\n[", options: .literal, range: rest.index(after: range.lowerBound)..<rest.endIndex) {
            cleaned.removeSubrange(range.lowerBound..<nextSection.lowerBound)
        } else {
            cleaned.removeSubrange(range.lowerBound...)
        }
        try? cleaned.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
