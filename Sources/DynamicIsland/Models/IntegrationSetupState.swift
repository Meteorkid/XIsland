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
        case .claudeCode, .geminiCli, .cursor, .droid, .qoder, .qwen, .amp,
             .windsurf, .devin, .copilotCli:
            guidance = text(
                "配置后请在原客户端开始一条任务。若客户端要求启用或信任 X Island hooks，请先审阅命令，再由你确认。",
                "Start a task in the original client after configuration. If it asks you to enable or trust X Island hooks, review the commands and confirm there.")
        case .codex:
            guidance = text(
                "在 Codex 输入区（Composer）打开 Review hooks，核对命令并仅勾选 X Island 项，点击 Allow selected 一次确认。X Island 自动回查授权，收到真实活动后才显示已接入；配置未变且授权有效时无需重复确认。配置改变或授权撤销后按提示重新审阅。",
                "In the Codex Composer, open Review hooks, review the commands and select only the X Island entries, then click Allow selected once. X Island checks authorization automatically and shows Connected after real activity. Unchanged, authorized hooks need no repeat confirmation; review them again after configuration changes or revoked authorization.")
        case .trae:
            guidance = text(
                "当前自动配置面向 Trae CN。请在对应客户端开始一条任务；国际版和 Solo 需分别核对接入，不能沿用 CN 的连接结果。",
                "Automatic configuration currently targets Trae CN. Start a task there; international and Solo editions need their own integration checks.")
        case .openCode, .pi:
            guidance = text(
                "配置后请让客户端重新加载 X Island 插件或扩展，再开始一条任务。若出现启用或信任提示，请在原客户端审阅确认。",
                "Reload the X Island plugin or extension in the client, then start a task. Review any enablement or trust prompt in that client.")
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
                "当前自动配置面向 Tabnine CLI hooks。请在 CLI 开始任务；IDE 和后继宿主插件需要分别核对。",
                "Automatic configuration targets Tabnine CLI hooks. Start a CLI task; IDE and successor host plugins require separate checks.")
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
        case .rooCode, .pearai:
            manual = true
            automatic = false
            guide = "Sources/XIslandVSCode/README.md"
            guidance = agent == .pearai ? text(
                "在对应编辑器安装 X Island Bridge，并显式启用 PearAI 实验观察来源。仅覆盖已核对的 Roo fork；Continue fork 不属于此入口。随后开始一条任务。",
                "Install X Island Bridge in the editor and explicitly enable the experimental PearAI observer. It covers the verified Roo fork, not the Continue fork. Then start a task.") : text(
                "在对应编辑器安装 X Island Bridge，并启用 Roo Code 观察来源，再开始一条任务。原客户端继续处理权限和问答。",
                "Install X Island Bridge in the editor, enable the Roo Code observer, then start a task. Permissions and questions stay in the original client.")
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
                "在能选择 Agent 启动命令的客户端中，按说明使用 Cody JSON-RPC 包装器。它不能接管已打开的 VS Code 会话；登录与交互仍在原客户端完成。",
                "Use the Cody JSON-RPC wrapper in a client that lets you select the agent launch command. It cannot attach to an existing VS Code session; sign-in and interactions stay in the original client.")
        case .`continue`:
            manual = true
            automatic = false
            guide = "docs/compatibility/continue-setup.md"
            guidance = text(
                "先自行启动 cn serve，再按说明对它的本机地址运行状态观察命令。此入口不启动服务，也不覆盖普通 TUI 或 IDE 插件；审批仍在 Continue 完成。",
                "Start cn serve yourself, then run the state observer for its local address as described in the guide. This route does not start the service or cover ordinary TUI or IDE sessions; approvals stay in Continue.")
        case .amazonQ:
            manual = true
            automatic = false
            guide = "docs/compatibility/amazonq-setup.md"
            guidance = text(
                "仅限 qchat 1.19.7。按说明审阅并合并选定 agent 的观察 hooks，再通过专用包装器启动。Kiro、q 前端与 IDE 不共用此入口。",
                "This route is limited to qchat 1.19.7. Review and merge the observer hooks for your selected agent, then use the dedicated launcher. Kiro, the q frontend and IDE integrations use different routes.")
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
