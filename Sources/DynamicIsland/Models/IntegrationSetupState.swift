import Foundation

enum IntegrationSetupPhase: String, Codable, CaseIterable, Sendable {
    case notInstalled
    case disabled
    case needsConfiguration
    case needsAuthorization
    case needsSetup
    case waitingForActivity
    case connected
    case checkFailed
}

enum IntegrationSetupAuthorization: String, Codable, Sendable {
    case unknown
    case notRequired
    case required
    case granted
    case failed
}

struct IntegrationSetupDescriptor: Sendable {
    let agent: AgentType
    var requiresManualSetup: Bool
    var authorizationGuidance: String
    var setupURL: URL?
    var canAutoConfigure: Bool

    static var all: [Self] {
        AgentType.allCases.filter(\.isSupported).map { descriptor(for: $0) }
    }

    static func descriptor(for agent: AgentType) -> Self {
        descriptor(for: agent, language: L10n.effectiveLanguage)
    }

    static func descriptor(for agent: AgentType, language: String) -> Self {
        let chinese = language.hasPrefix("zh")
        func text(_ zh: String, _ en: String) -> String { chinese ? zh : en }
        var manual = false
        var automatic = true
        var guide = "docs/compatibility/README.md"
        let guidance: String

        switch agent {
        case .claudeCode, .cursor, .droid, .qoder, .qwen, .amp,
             .devin, .copilotCli, .antigravity:
            guidance = text(
                "配置后请在原客户端开始一条任务。若客户端要求启用或信任 X Island hooks，请先审阅命令，再由你确认。",
                "Start a task in the original client after configuration. If it asks you to enable or trust X Island hooks, review the commands and confirm there.")
        case .geminiCli:
            guidance = text(
                "Gemini CLI 自 2026-06-18 起已停止为个人版与 Gemini Code Assist 个人版提供服务，仅企业 Gemini Code Assist 与付费 API Key 仍可使用。个人用户请改用 Antigravity（agy）接入。",
                "Since 2026-06-18 Gemini CLI no longer serves individuals or Gemini Code Assist for individuals; only enterprise Gemini Code Assist and paid API keys remain. Individual users should use Antigravity (agy) instead.")
        case .doubaoWork:
            manual = true
            automatic = false
            guide = "docs/compatibility/doubao-work-setup.md"
            guidance = text(
                "豆包工作没有公开的原生 hooks。当前接入是“自定义连接器 + 活动上报”：在豆包工作（本地电脑模式）的插件页新建 STDIO 连接器，命令填 ~/.xisland/bin/di-bridge、参数填 doubao-work-mcp。连接器连接期间，显式调用 xisland_activity 的动作会显示在岛上；完整任务、审批和问答仍在豆包工作内完成。",
                "Doubao Work has no public native hooks. This route is a custom connector plus activity reporting: add a STDIO connector in Doubao Work (Local Computer mode) with command ~/.xisland/bin/di-bridge and arguments doubao-work-mcp. While attached, explicit xisland_activity calls appear in the island. Task control, approvals and questions stay in Doubao Work.")
        case .codex:
            guidance = text(
                "在 Codex 输入区（Composer）打开 Review hooks，核对命令并仅勾选 X Island 项，点击 Allow selected 一次确认。X Island 自动回查授权，收到真实活动后才显示已接入；配置未变且授权有效时无需重复确认。配置改变或授权撤销后按提示重新审阅。",
                "In the Codex Composer, open Review hooks, review the commands and select only the X Island entries, then click Allow selected once. X Island checks authorization automatically and shows Connected after real activity. Unchanged, authorized hooks need no repeat confirmation; review them again after configuration changes or revoked authorization.")
        case .trae:
            guidance = text(
                "当前自动配置面向 Trae CN。请在对应客户端开始一条任务；国际版和 Solo 需分别核对接入，不能沿用 CN 的连接结果。TRAE Work 已于 2026-08 并入豆包工作，请改用豆包工作入口。",
                "Automatic configuration currently targets Trae CN. Start a task there; international and Solo editions need their own integration checks. TRAE Work was merged into Doubao Work in 2026-08; use the Doubao Work route instead.")
        case .openCode, .pi:
            guidance = text(
                "配置后请让客户端重新加载 X Island 插件或扩展，再开始一条任务。若出现启用或信任提示，请在原客户端审阅确认。",
                "Reload the X Island plugin or extension in the client, then start a task. Review any enablement or trust prompt in that client.")
        case .kiloCode:
            guide = "docs/compatibility/kilo-setup.md"
            guidance = text(
                "配置会写入 ~/.config/kilo/plugin/xisland.js，CLI 与 VS Code 扩展共用。请重启 Kilo 或重新加载窗口再开始任务；插件只观察会话与工具活动，权限确认、回答和取消仍在 Kilo 内完成。",
                "Configuration writes ~/.config/kilo/plugin/xisland.js, shared by the CLI and VS Code extension. Restart Kilo or reload the window, then start a task. The plugin only observes sessions and tool activity; approvals, answers and cancellation stay in Kilo.")
        case .copilot:
            guidance = text(
                "当前入口为 VS Code Copilot Local hooks。请在 Local 会话开始任务；Agent Host、Remote 和自定义目录需要另行核对。",
                "This route uses VS Code Copilot Local hooks. Start a task in a Local session; Agent Host, Remote and custom directories require separate checks.")
        case .codeBuddy:
            guidance = text(
                "当前自动配置面向 CodeBuddy Code CLI。请在 CLI 开始一条任务；WorkBuddy 使用单独的插件接入。",
                "Automatic configuration targets CodeBuddy Code CLI. Start a task in the CLI; WorkBuddy uses its separate plugin integration.")
        case .kimi:
            guidance = text(
                "请核对正在使用的 Kimi CLI 版本与配置路径，并在新会话开始一条任务。Python 与 Node 版本使用各自的接入方式。",
                "Check the active Kimi CLI version and configuration path, then start a task in a new session. Python and Node versions use separate integration routes.")
        case .deepseek:
            guide = "docs/compatibility/aider-codewhale-usage.md"
            guidance = text(
                "自动配置仅覆盖已核对的 Codewhale 0.10.0。请确认版本和实际配置路径，再开始任务；它不是 DeepSeek 官方聊天应用。",
                "Automatic configuration covers the verified Codewhale 0.10.0 route. Check its version and active configuration path, then start a task; this is not the official DeepSeek chat app.")
        case .aider:
            manual = true
            guide = "docs/compatibility/aider-codewhale-usage.md"
            guidance = text(
                "入口可自动准备。请使用 ~/.xisland/bin/xisland-aider 启动 Aider；普通 aider 启动不会自动经过该入口。原有参数可继续使用。",
                "X Island can prepare the launcher. Start Aider with ~/.xisland/bin/xisland-aider and your usual arguments; a regular aider launch does not use this route.")
        case .tabnine:
            guidance = text(
                "Tabnine 已于 2026-07-30 被 Tricentis 收购，6.x CLI 改为 OpenCode 托管分支，公开价目页已下线。当前自动配置仅覆盖旧版 Tabnine CLI 的 settings.json；6.x 请按 OpenCode 插件方式核对。",
                "Tabnine was acquired by Tricentis on 2026-07-30 and its 6.x CLI is a managed OpenCode branch. Automatic configuration covers the legacy Tabnine CLI settings only; check the OpenCode plugin route for 6.x.")
        case .cline:
            guidance = text(
                "请在 Cline VS Code 扩展中核对 X Island 事件脚本，并按客户端提示启用或信任，再开始任务。独立 CLI 与 SDK 需另行核对。",
                "Check the X Island event scripts in the Cline VS Code extension, follow any enablement or trust prompt, then start a task. Standalone CLI and SDK routes require separate checks.")
        case .workBuddy:
            manual = true
            automatic = false
            guide = "docs/compatibility/workbuddy-setup.md"
            guidance = text(
                "点击“查看接入文件”，在 WorkBuddy 的“添加市场”中选择准备好的插件目录，核对命令后完成启用与信任，再开始任务。文件已准备不代表客户端已经加载或授权。",
                "Choose Show setup files, select the prepared plugin directory in WorkBuddy's Add Marketplace flow, review its commands, enable and trust it, then start a task. Prepared files do not mean the client has loaded or authorized them.")
        case .kiro:
            manual = true
            automatic = false
            guide = "docs/compatibility/kiro-setup.md"
            guidance = text(
                "点击“查看接入文件”取得 Kiro CLI 2.31.0 V3 模板；该版本是模板基线，请自行核对实际版本。按说明放置独立 hooks 文件，用 kiro-cli chat --v3 启动，在 /config 核对来源后提交任务。",
                "Choose Show setup files to get the Kiro CLI 2.31.0 V3 template. This is the template baseline; verify your installed version. Place the standalone hooks file as instructed, start kiro-cli chat --v3, check its source in /config, then submit a task.")
        case .rooCode:
            manual = true
            automatic = false
            guide = "docs/compatibility/README.md"
            guidance = text(
                "Roo Code 已于 2026-05-15 停运并归档仓库，原团队转向 Roomote；开源替代可选 Cline 或 Kilo Code，仍有社区分支 Zoo Code。旧会话仍在历史中保留。",
                "Roo Code shut down on 2026-05-15 and its repository is archived; the team moved to Roomote. Cline, Kilo Code, or the community fork Zoo Code are the practical alternatives; existing sessions stay in history.")
        case .pearai:
            manual = true
            automatic = false
            guide = "Sources/XIslandVSCode/README.md"
            guidance = text(
                "在对应编辑器安装 X Island Bridge，并显式启用 PearAI 实验观察来源。仅覆盖已核对的 Roo fork；Continue fork 不属于此入口。随后开始一条任务。",
                "Install X Island Bridge in the editor and explicitly enable the experimental PearAI observer. It covers the verified Roo fork, not the Continue fork. Then start a task.")
        case .zed, .jetbrainsAi:
            manual = true
            automatic = false
            guide = "docs/compatibility/acp-setup.md"
            guidance = text(
                "按说明包装一个已经可用的外部 ACP Agent，在编辑器中选中它并开始任务。该入口不自动接管编辑器的内置 AI；权限仍在编辑器中处理。",
                "Follow the guide to wrap an existing external ACP agent, select it in the editor, and start a task. This route does not take over built-in AI; permissions stay in the editor.")
        case .cody:
            manual = true
            automatic = false
            guide = "docs/compatibility/cody-setup.md"
            guidance = text(
                "Sourcegraph 已宣布 Cody 于 2027-01-31 停止支持，新注册自 2025 年起仅限企业版。可按说明继续使用 JSON-RPC 包装器至停止支持；面向个人的继任产品 Amp 已拆分为独立公司，需另行接入。",
                "Sourcegraph will end of life Cody on 2027-01-31; new sign-ups have been enterprise-only since 2025. The JSON-RPC wrapper remains usable until then. Amp, the individual-focused successor, is now a separate company and needs its own integration.")
        case .`continue`:
            manual = true
            automatic = false
            guide = "docs/compatibility/README.md"
            guidance = text(
                "Continue 已于 2026-06 被 Cursor 收购，仓库转为只读，最后版本 v2.0.0-vscode（2026-06-19）。请改用 Cursor 接入；旧 cn serve 观察路线不再维护。",
                "Continue was acquired by Cursor in 2026-06; its repository is read-only and the final build is v2.0.0-vscode (2026-06-19). Use the Cursor integration instead; the cn serve observer is no longer maintained.")
        case .amazonQ:
            manual = true
            automatic = false
            guide = "docs/compatibility/kiro-setup.md"
            guidance = text(
                "Amazon Q Developer CLI 已于 2025-11-17 更名为 Kiro CLI，旧 qchat 1.19.7 包装器仅保留历史会话。请改用 Kiro 接入；Q IDE 插件将于 2027-04-30 停止支持。",
                "Amazon Q Developer CLI was rebranded to Kiro CLI on 2025-11-17; the old qchat 1.19.7 wrapper only remains for history. Use the Kiro integration instead; Q IDE plugins reach end of support on 2027-04-30.")
        case .windsurf:
            manual = true
            automatic = false
            guide = "docs/compatibility/README.md"
            guidance = text(
                "Windsurf 已于 2026-06-02 由 Cognition 自动更新为 Devin Desktop，Cascade 品牌退役。请使用 Devin Desktop 接入；旧 Windsurf 会话仍可在历史中查看。",
                "Windsurf was renamed to Devin Desktop by Cognition on 2026-06-02 and the Cascade brand retired. Use the Devin Desktop integration; existing Windsurf sessions remain in history.")
        case .glm:
            manual = true
            automatic = false
            guide = "docs/compatibility/glm-setup.md"
            guidance = text(
                "GLM 是模型来源。请在 Claude Code、OpenCode、Cline 或 Pi 中选择 GLM 并接入该客户端；X Island 按客户端上报的模型显示和筛选，不创建独立 GLM 连接。",
                "GLM is a model source. Select GLM in Claude Code, OpenCode, Cline or Pi and connect that client. X Island displays and filters the reported model without creating a separate GLM connection.")
        case .hermes:
            manual = true
            automatic = false
            guidance = text("此来源不在当前支持的接入目录中。", "This source is outside the current supported integration catalog.")
        }

        let privacy = text("X Island 接入无需输入密码或 API 密钥。", "No password or API key is needed for the X Island integration.")
        return Self(agent: agent, requiresManualSetup: manual,
                    authorizationGuidance: guidance + " " + privacy,
                    setupURL: URL(string: "https://github.com/Meteorkid/XIsland/blob/main/\(guide)"),
                    canAutoConfigure: automatic)
    }
}

struct IntegrationSetupEvidence: Equatable, Sendable {
    var installed: Bool
    var enabled: Bool
    var configured: Bool
    var configurationFingerprint: String?
    var authorization: IntegrationSetupAuthorization
    var authorizationFingerprint: String?
    var observedFingerprint: String?
    var checkFailed: Bool

    init(installed: Bool = false, enabled: Bool = true, configured: Bool = false,
         configurationFingerprint: String? = nil,
         authorization: IntegrationSetupAuthorization = .unknown,
         authorizationFingerprint: String? = nil, observedFingerprint: String? = nil,
         checkFailed: Bool = false) {
        self.installed = installed
        self.enabled = enabled
        self.configured = configured
        self.configurationFingerprint = configurationFingerprint
        self.authorization = authorization
        self.authorizationFingerprint = authorizationFingerprint
        self.observedFingerprint = observedFingerprint
        self.checkFailed = checkFailed
    }
}

enum IntegrationSetupState {
    static func phase(descriptor: IntegrationSetupDescriptor, evidence: IntegrationSetupEvidence) -> IntegrationSetupPhase {
        guard evidence.installed else { return .notInstalled }
        guard evidence.enabled else { return .disabled }
        guard !evidence.checkFailed else { return .checkFailed }
        guard descriptor.agent.isSupported, descriptor.agent != .glm else { return .needsSetup }

        if evidence.authorization == .required || evidence.authorization == .failed {
            return .needsAuthorization
        }

        if descriptor.canAutoConfigure, !evidence.configured { return .needsConfiguration }

        // 只接受当前配置版本的真实接收事件；nil == nil 不能证明连接成功。
        if let fingerprint = nonempty(evidence.configurationFingerprint),
           fingerprint == evidence.observedFingerprint {
            return .connected
        }

        guard evidence.configured else {
            return descriptor.canAutoConfigure ? .needsConfiguration : .needsSetup
        }

        // 旧版本的授权记录不能继承给新命令，缺少版本的旧记录也需要重新核对。
        if evidence.authorization == .granted {
            guard let fingerprint = nonempty(evidence.configurationFingerprint),
                  fingerprint == evidence.authorizationFingerprint else { return .needsAuthorization }
        }

        return descriptor.requiresManualSetup ? .needsSetup : .waitingForActivity
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

enum IntegrationSetupReminderPolicy {
    static func reminderToken(phase: IntegrationSetupPhase, fingerprint: String?) -> String {
        if let fingerprint, !fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(phase.rawValue):\(fingerprint)"
        }
        return "\(phase.rawValue):unconfigured"
    }

    static func shouldPrompt(agent: AgentType, phase: IntegrationSetupPhase, fingerprint: String?,
                             lastPrompted: [String: String]) -> Bool {
        guard agent.isSupported, agent != .glm else { return false }
        switch phase {
        case .notInstalled, .disabled, .connected, .waitingForActivity:
            return false
        case .needsConfiguration, .needsAuthorization, .needsSetup, .checkFailed:
            return lastPrompted[agent.rawValue] != reminderToken(phase: phase, fingerprint: fingerprint)
        }
    }
}
