import SwiftUI

struct AgentMeta {
    let displayName: String
    let shortName: String
    let color: Color
    let iconSymbol: String
    let bundleIds: [String]
    let processNames: [String]
    let isDesktopApp: Bool
    let sendsSessionEnd: Bool
    let aliases: [String]
}

extension AgentType {
    static let registry: [AgentType: AgentMeta] = [
        .claudeCode: AgentMeta(
            displayName: "Claude Code", shortName: "Claude",
            color: Color(red: 0.85, green: 0.45, blue: 0.25),
            iconSymbol: "brain.head.profile",
            bundleIds: [], processNames: ["claude"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["claude", "claude-code", "claudecode"]
        ),
        .codex: AgentMeta(
            displayName: "Codex", shortName: "Codex",
            color: Color(red: 0.2, green: 0.8, blue: 0.4),
            iconSymbol: "terminal",
            bundleIds: ["com.openai.codex"], processNames: ["Codex"],
            isDesktopApp: false, sendsSessionEnd: false,
            aliases: ["codex-cli", "codex_cli"]
        ),
        .geminiCli: AgentMeta(
            displayName: "Gemini CLI", shortName: "Gemini",
            color: Color(red: 0.3, green: 0.5, blue: 0.95),
            iconSymbol: "sparkles",
            // 2026-06-18 起个人版停止服务，仅企业 Gemini Code Assist 与付费 API Key 仍可用；
            // 个人用户的继任者是 Antigravity CLI（agy）。
            bundleIds: [], processNames: ["gemini"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["gemini", "gemini-cli", "gemini_cli"]
        ),
        .antigravity: AgentMeta(
            displayName: "Antigravity", shortName: "Antigravity",
            color: Color(red: 0.30, green: 0.72, blue: 0.90),
            iconSymbol: "atom",
            // 2026-05-19 起 Google 将 Gemini CLI 的个人版迁到 Antigravity CLI（agy）。
            bundleIds: ["com.google.antigravity"],
            processNames: ["Antigravity", "agy"],
            isDesktopApp: true, sendsSessionEnd: false,
            aliases: ["antigravity", "antigravity-cli", "antigravity cli", "agy"]
        ),
        .cursor: AgentMeta(
            displayName: "Cursor", shortName: "Cursor",
            color: Color(red: 0.6, green: 0.4, blue: 0.9),
            iconSymbol: "cursorarrow.rays",
            bundleIds: ["com.todesktop.230313mzl4w4u92"],
            processNames: ["Cursor"],
            isDesktopApp: true, sendsSessionEnd: true,
            aliases: []
        ),
        .trae: AgentMeta(
            displayName: "Trae", shortName: "Trae",
            color: Color(red: 0.2, green: 0.7, blue: 0.95),
            iconSymbol: "sparkle.magnifyingglass",
            // TRAE Work 已于 2026-08 并入豆包工作，由 .doubaoWork 接管。
            bundleIds: ["com.trae.app", "cn.trae.app", "cn.trae.solo.app"],
            processNames: ["Trae", "Trae CN", "TRAE SOLO CN"],
            isDesktopApp: true, sendsSessionEnd: true,
            aliases: ["trae", "trae cn", "trae-cn", "traecn", "trae solo cn", "trae-aicc"]
        ),
        .doubaoWork: AgentMeta(
            displayName: "豆包工作", shortName: "豆包",
            color: Color(red: 0.18, green: 0.49, blue: 0.98),
            iconSymbol: "bubble.left.fill",
            // 已核实：豆包电脑版 com.bot.pc.doubao 内的「工作」入口。
            // 独立客户端安装为 /Applications/DoubaoWork.app（可执行文件 DoubaoWork），
            // 官方帮助中心未公布 bundle id，故只按应用名与进程名识别，不虚构标识。
            bundleIds: ["com.bot.pc.doubao"],
            processNames: ["Doubao", "DoubaoWork", "豆包", "豆包工作"],
            isDesktopApp: true, sendsSessionEnd: false,
            aliases: ["doubao work", "doubao_work", "doubao-work", "豆包", "豆包工作",
                      "trae work", "trae work cn", "traework"]
        ),
        .openCode: AgentMeta(
            displayName: "OpenCode", shortName: "OpenCode",
            color: Color(red: 0.95, green: 0.7, blue: 0.2),
            iconSymbol: "chevron.left.forwardslash.chevron.right",
            bundleIds: [], processNames: ["opencode"],
            isDesktopApp: false, sendsSessionEnd: false,
            aliases: ["open-code", "open_code"]
        ),
        .droid: AgentMeta(
            displayName: "Droid", shortName: "Droid",
            color: Color(red: 0.3, green: 0.85, blue: 0.8),
            iconSymbol: "cpu",
            bundleIds: [], processNames: [],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: []
        ),
        .qoder: AgentMeta(
            displayName: "Qoder CN", shortName: "Qoder",
            color: Color(red: 0.9, green: 0.3, blue: 0.5),
            iconSymbol: "qrcode",
            // 通义灵码于 2026-05-20 更名为 Qoder CN 系列；IDE/CLI 仍独立存在，
            // QoderWork 那一支已并入千问办公，不与本入口混用。
            bundleIds: [], processNames: [],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["qoder", "qoder cn", "qoder-cn", "lingma", "通义灵码"]
        ),
        .copilot: AgentMeta(
            displayName: "Copilot", shortName: "Copilot",
            color: Color(red: 0.4, green: 0.7, blue: 0.9),
            iconSymbol: "airplane",
            bundleIds: ["com.microsoft.VSCode"], processNames: ["Code"],
            isDesktopApp: true, sendsSessionEnd: false,
            aliases: []
        ),
        .codeBuddy: AgentMeta(
            displayName: "CodeBuddy", shortName: "CodeBuddy",
            color: Color(red: 0.7, green: 0.9, blue: 0.3),
            iconSymbol: "person.2",
            bundleIds: [], processNames: [],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["code-buddy", "codebuddy"]
        ),
        .workBuddy: AgentMeta(
            displayName: "WorkBuddy", shortName: "WorkBuddy",
            color: Color(red: 0.25, green: 0.65, blue: 0.95),
            iconSymbol: "w.circle",
            bundleIds: ["com.tencent.workbuddy.mac"], processNames: [],
            isDesktopApp: true, sendsSessionEnd: false,
            aliases: ["work-buddy", "work_buddy"]
        ),
        .qwen: AgentMeta(
            displayName: "Qwen Code", shortName: "Qwen",
            color: Color(red: 0.35, green: 0.55, blue: 0.95),
            iconSymbol: "q.circle",
            bundleIds: [], processNames: ["qwen"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["qwen", "qwen-code", "qwen_code"]
        ),
        .kimi: AgentMeta(
            displayName: "Kimi Code", shortName: "Kimi",
            color: Color(red: 0.95, green: 0.35, blue: 0.45),
            iconSymbol: "k.circle",
            bundleIds: [], processNames: ["kimi", "kimi-code"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["kimi", "kimi-code", "kimi_code"]
        ),
        .deepseek: AgentMeta(
            displayName: "Codewhale / DeepSeek-TUI", shortName: "Codewhale",
            color: Color(red: 0.25, green: 0.75, blue: 0.55),
            iconSymbol: "d.circle",
            bundleIds: [], processNames: ["codewhale", "deepseek"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["codewhale", "codew", "deepseek", "deepseek-tui", "deepseek_tui"]
        ),
        .kiro: AgentMeta(
            displayName: "Kiro", shortName: "Kiro",
            color: Color(red: 0.6, green: 0.5, blue: 0.85),
            iconSymbol: "k.square",
            // Amazon Q Developer CLI 于 2025-11-17 更名为 Kiro CLI，2026 起旧入口只保留历史记录。
            bundleIds: [], processNames: [],
            isDesktopApp: false, sendsSessionEnd: false,
            aliases: ["kiro", "kiro-cli", "amazon q", "amazon-q", "q developer", "qchat"]
        ),
        .amp: AgentMeta(
            displayName: "Amp", shortName: "Amp",
            color: Color(red: 0.9, green: 0.6, blue: 0.2),
            iconSymbol: "bolt.fill",
            bundleIds: [], processNames: ["amp"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["amp"]
        ),
        .pi: AgentMeta(
            displayName: "Pi Agent", shortName: "Pi",
            color: Color(red: 0.5, green: 0.8, blue: 0.95),
            iconSymbol: "p.circle",
            bundleIds: [], processNames: ["pi"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["pi", "pi-agent", "pi_agent"]
        ),
        .kiloCode: AgentMeta(
            displayName: "Kilo Code", shortName: "Kilo",
            color: Color(red: 0.05, green: 0.80, blue: 0.55),
            iconSymbol: "k.circle.fill",
            bundleIds: [], processNames: ["kilo"],
            isDesktopApp: false, sendsSessionEnd: false,
            // 2026 年从 Roo Code 分支重建为 OpenCode 内核；CLI 与 VS Code 扩展
            // 共用 ~/.config/kilo/plugin 的原生插件，不虚构 hooks 通道。
            aliases: ["kilo", "kilo code", "kilo-code", "kilocode", "kilo_code"]
        ),
        .hermes: AgentMeta(
            displayName: "Hermes", shortName: "Hermes",
            color: Color(red: 0.75, green: 0.75, blue: 0.75),
            iconSymbol: "h.circle",
            bundleIds: [], processNames: [],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["hermes"]
        ),
        .glm: AgentMeta(
            displayName: "GLM (Zhipu)", shortName: "GLM",
            color: Color(red: 0.25, green: 0.45, blue: 0.95),
            iconSymbol: "g.circle",
            bundleIds: [], processNames: [],
            isDesktopApp: false, sendsSessionEnd: false,
            aliases: ["glm", "zhipu", "glm-code", "glm_code"]
        ),
        .aider: AgentMeta(
            displayName: "Aider", shortName: "AI",
            color: Color(red: 0.95, green: 0.5, blue: 0.25),
            iconSymbol: "a.circle",
            bundleIds: [], processNames: [],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["aider"]
        ),
        .windsurf: AgentMeta(
            displayName: "Windsurf", shortName: "Windsurf",
            color: Color(red: 0.2, green: 0.6, blue: 0.9),
            iconSymbol: "wind",
            // 仅保留历史身份：产品已于 2026-06-02 自动更新为 Cognition 的 Devin Desktop。
            bundleIds: [], processNames: [],
            isDesktopApp: false, sendsSessionEnd: false,
            aliases: []
        ),
        .devin: AgentMeta(
            displayName: "Devin Desktop", shortName: "Devin",
            color: Color(red: 0.4, green: 0.4, blue: 0.9),
            iconSymbol: "person.fill.checkmark",
            // 沿用原 Windsurf 应用的 bundle id（Cognition 的自动更新会保留同一应用身份），
            // CLI 仍是 devin；Cascade 品牌已退役。
            bundleIds: ["com.codeium.windsurf"], processNames: ["Devin", "Devin Desktop", "Windsurf"],
            isDesktopApp: true, sendsSessionEnd: true,
            aliases: ["devin", "cognition", "devin desktop", "devin-desktop", "windsurf desktop"]
        ),
        .amazonQ: AgentMeta(
            displayName: "Amazon Q", shortName: "Q",
            color: Color(red: 0.95, green: 0.6, blue: 0.1),
            iconSymbol: "q.square",
            // Q Developer CLI 已更名为 Kiro CLI；旧 qchat 1.19.7 包装器只保留历史会话。
            bundleIds: [], processNames: [],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["amazon q cli", "codewhisperer", "amazon-q"]
        ),
        .tabnine: AgentMeta(
            displayName: "Tabnine", shortName: "Tabnine",
            color: Color(red: 0.3, green: 0.3, blue: 0.9),
            iconSymbol: "t.circle",
            // 2026-07-30 被 Tricentis 收购；6.x CLI 已改为 OpenCode 托管分支。
            // 现有自动配置仅覆盖旧版 Tabnine CLI 的 settings.json。
            bundleIds: [], processNames: ["tabnine"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["tabnine", "tricentis tabnine"]
        ),
        .cody: AgentMeta(
            displayName: "Cody", shortName: "Cody",
            color: Color(red: 0.8, green: 0.3, blue: 0.5),
            iconSymbol: "c.circle",
            // 2026-11-09 Sourcegraph 宣布 Cody 于 2027-01-31 停止支持，仅企业版可用；
            // Amp 已拆分为独立公司，不是 Cody 的续任入口。
            bundleIds: [], processNames: [],
            isDesktopApp: false, sendsSessionEnd: false,
            aliases: ["cody", "sourcegraph"]
        ),
        .cline: AgentMeta(
            displayName: "Cline", shortName: "Cline",
            color: Color(red: 0.2, green: 0.8, blue: 0.6),
            iconSymbol: "l.circle",
            // 当前接入的是 VS Code 扩展；不存在同名 CLI 进程不代表扩展会话已结束。
            bundleIds: [], processNames: [],
            isDesktopApp: false, sendsSessionEnd: false,
            aliases: ["cline"]
        ),
        .`continue`: AgentMeta(
            displayName: "Continue", shortName: "Continue",
            color: Color(red: 0.5, green: 0.5, blue: 0.9),
            iconSymbol: "arrow.right.circle",
            // 2026-06 被 Cursor 收购，仓库只读，最后版本 v2.0.0-vscode（2026-06-19）。
            bundleIds: [], processNames: [],
            isDesktopApp: false, sendsSessionEnd: false,
            aliases: []
        ),
        .copilotCli: AgentMeta(
            displayName: "Copilot CLI", shortName: "Copilot",
            color: Color(red: 0.3, green: 0.7, blue: 0.9),
            iconSymbol: "terminal.fill",
            bundleIds: [], processNames: ["copilot"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["copilot cli", "github copilot"]
        ),
        .rooCode: AgentMeta(
            displayName: "Roo Code", shortName: "Roo",
            color: Color(red: 0.85, green: 0.3, blue: 0.5),
            iconSymbol: "r.circle",
            // 2026-05-15 全部产品停运，仓库归档；团队转向 Roomote，社区继任者是 Cline / Kilo Code。
            bundleIds: [], processNames: [],
            isDesktopApp: false, sendsSessionEnd: false,
            aliases: ["roo", "roo-code", "roo_code", "roo-cline", "roocline", "roo code"]
        ),
        .pearai: AgentMeta(
            displayName: "PearAI", shortName: "Pear",
            color: Color(red: 0.4, green: 0.9, blue: 0.6),
            iconSymbol: "leaf",
            bundleIds: ["dev.pearai", "com.pearai.app"], processNames: ["PearAI"],
            isDesktopApp: true, sendsSessionEnd: false,
            aliases: ["pearai", "pear-ai", "pear_ai"]
        ),
        .zed: AgentMeta(
            displayName: "Zed AI", shortName: "Zed",
            color: Color(red: 0.85, green: 0.2, blue: 0.95),
            iconSymbol: "z.circle",
            bundleIds: ["dev.zed.Zed", "dev.zed.Zed-Preview"], processNames: ["Zed", "Zed Preview"],
            isDesktopApp: true, sendsSessionEnd: true,
            aliases: ["zed", "zed-ai", "zed_ai", "zed.dev"]
        ),
        .jetbrainsAi: AgentMeta(
            displayName: "JetBrains AI", shortName: "JB AI",
            color: Color(red: 0.95, green: 0.4, blue: 0.3),
            iconSymbol: "j.circle",
            // JetBrains AI 是跑在 IntelliJ/PyCharm 等宿主 IDE 里的插件，没有自己的 bundle id。
            // 此前标 isDesktopApp: true 但 bundleIds 为空，bundleId 恒为 nil，
            // 所有依赖 bundleId 的桌面应用逻辑对它都是空转。与同为扩展的 Roo Code 保持一致。
            bundleIds: [], processNames: [],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["jetbrains", "jetbrains-ai", "jetbrains_ai", "intellij", "idea"]
        ),
    ]

    /// registry 漏配条目时的兜底。此前是 fatalError——新增 case 而忘记登记就是运行时崩溃，
    /// 且编译器不会提示。AgentRegistryFallbackTests 会在 CI 上先一步失败，运行期不必再赔上崩溃。
    static func fallbackMeta(for type: AgentType) -> AgentMeta {
        AgentMeta(
            displayName: type.rawValue, shortName: type.rawValue,
            color: .gray,
            iconSymbol: "questionmark.circle",
            bundleIds: [], processNames: [],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: []
        )
    }

    var meta: AgentMeta {
        Self.registry[self] ?? Self.fallbackMeta(for: self)
    }
}
