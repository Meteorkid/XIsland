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
            bundleIds: [], processNames: ["gemini"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["gemini", "gemini-cli", "gemini_cli"]
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
            bundleIds: ["com.trae.app", "cn.trae.app", "cn.trae.solo.app", "cn.trae.work.app"],
            processNames: ["Trae", "Trae CN", "TRAE SOLO CN", "TRAE WORK CN"],
            isDesktopApp: true, sendsSessionEnd: true,
            aliases: ["trae", "trae cn", "trae-cn", "traecn", "trae work cn", "trae solo cn", "trae-aicc", "trae work"]
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
            displayName: "Qoder", shortName: "Qoder",
            color: Color(red: 0.9, green: 0.3, blue: 0.5),
            iconSymbol: "qrcode",
            bundleIds: [], processNames: [],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: []
        ),
        .copilot: AgentMeta(
            displayName: "Copilot", shortName: "Copilot",
            color: Color(red: 0.4, green: 0.7, blue: 0.9),
            iconSymbol: "airplane",
            bundleIds: ["com.microsoft.VSCode"], processNames: ["Code"],
            isDesktopApp: true, sendsSessionEnd: true,
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
            bundleIds: [], processNames: ["kimi"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["kimi", "kimi-code", "kimi_code"]
        ),
        .deepseek: AgentMeta(
            displayName: "DeepSeek-TUI", shortName: "DeepSeek",
            color: Color(red: 0.25, green: 0.75, blue: 0.55),
            iconSymbol: "d.circle",
            bundleIds: [], processNames: ["deepseek"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["deepseek", "deepseek-tui", "deepseek_tui"]
        ),
        .kiro: AgentMeta(
            displayName: "Kiro", shortName: "Kiro",
            color: Color(red: 0.6, green: 0.5, blue: 0.85),
            iconSymbol: "k.square",
            bundleIds: [], processNames: [],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["kiro"]
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
            bundleIds: [], processNames: ["glm", "zhipu"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["glm", "zhipu", "glm-code", "glm_code"]
        ),
        .aider: AgentMeta(
            displayName: "Aider", shortName: "AI",
            color: Color(red: 0.95, green: 0.5, blue: 0.25),
            iconSymbol: "a.circle",
            bundleIds: [], processNames: ["aider"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["aider"]
        ),
        .windsurf: AgentMeta(
            displayName: "Windsurf", shortName: "Windsurf",
            color: Color(red: 0.2, green: 0.6, blue: 0.9),
            iconSymbol: "wind",
            bundleIds: ["com.codeium.windsurf"], processNames: ["Windsurf"],
            isDesktopApp: true, sendsSessionEnd: true,
            aliases: ["windsurf"]
        ),
        .devin: AgentMeta(
            displayName: "Devin", shortName: "Devin",
            color: Color(red: 0.4, green: 0.4, blue: 0.9),
            iconSymbol: "person.fill.checkmark",
            bundleIds: [], processNames: ["devin"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["devin", "cognition"]
        ),
        .amazonQ: AgentMeta(
            displayName: "Amazon Q", shortName: "Q",
            color: Color(red: 0.95, green: 0.6, blue: 0.1),
            iconSymbol: "q.square",
            bundleIds: [], processNames: ["q", "amazon-q"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["amazon q", "q developer", "codewhisperer", "amazon-q"]
        ),
        .tabnine: AgentMeta(
            displayName: "Tabnine", shortName: "Tabnine",
            color: Color(red: 0.3, green: 0.3, blue: 0.9),
            iconSymbol: "t.circle",
            bundleIds: [], processNames: ["tabnine"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["tabnine"]
        ),
        .cody: AgentMeta(
            displayName: "Cody", shortName: "Cody",
            color: Color(red: 0.8, green: 0.3, blue: 0.5),
            iconSymbol: "c.circle",
            bundleIds: [], processNames: ["cody"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["cody", "sourcegraph"]
        ),
        .cline: AgentMeta(
            displayName: "Cline", shortName: "Cline",
            color: Color(red: 0.2, green: 0.8, blue: 0.6),
            iconSymbol: "l.circle",
            bundleIds: [], processNames: ["cline"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["cline"]
        ),
        .`continue`: AgentMeta(
            displayName: "Continue", shortName: "Continue",
            color: Color(red: 0.5, green: 0.5, blue: 0.9),
            iconSymbol: "arrow.right.circle",
            bundleIds: [], processNames: ["continue"],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["continue"]
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
            bundleIds: [], processNames: [],
            isDesktopApp: false, sendsSessionEnd: true,
            aliases: ["roo", "roo-code", "roo_code", "roo-cline", "roocline", "roo code"]
        ),
        .pearai: AgentMeta(
            displayName: "PearAI", shortName: "Pear",
            color: Color(red: 0.4, green: 0.9, blue: 0.6),
            iconSymbol: "leaf",
            bundleIds: ["dev.pearai", "com.pearai.app"], processNames: ["PearAI"],
            isDesktopApp: true, sendsSessionEnd: true,
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
            bundleIds: [], processNames: [],
            isDesktopApp: true, sendsSessionEnd: true,
            aliases: ["jetbrains", "jetbrains-ai", "jetbrains_ai", "intellij", "idea"]
        ),
    ]

    var meta: AgentMeta {
        guard let m = Self.registry[self] else {
            fatalError("AgentMeta missing for \(self.rawValue)")
        }
        return m
    }
}
