import SwiftUI

enum AgentType: String, CaseIterable, Codable, Identifiable, Sendable {
    case claudeCode = "claude_code"
    case codex = "codex"
    case geminiCli = "gemini_cli"
    case cursor = "cursor"
    case trae = "trae"
    case openCode = "opencode"
    case droid = "droid"
    case qoder = "qoder"
    case copilot = "copilot"
    case codeBuddy = "code_buddy"
    case qwen = "qwen"
    case kimi = "kimi"
    case deepseek = "deepseek"
    case kiro = "kiro"
    case amp = "amp"
    case pi = "pi"
    case hermes = "hermes"
    case glm = "glm"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .geminiCli: "Gemini CLI"
        case .cursor: "Cursor"
        case .trae: "Trae"
        case .openCode: "OpenCode"
        case .droid: "Droid"
        case .qoder: "Qoder"
        case .copilot: "Copilot"
        case .codeBuddy: "CodeBuddy"
        case .qwen: "Qwen Code"
        case .kimi: "Kimi Code"
        case .deepseek: "DeepSeek-TUI"
        case .kiro: "Kiro"
        case .amp: "Amp"
        case .pi: "Pi Agent"
        case .hermes: "Hermes"
        case .glm: "GLM (Zhipu)"
        }
    }

    var shortName: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        case .geminiCli: "Gemini"
        case .cursor: "Cursor"
        case .trae: "Trae"
        case .openCode: "OpenCode"
        case .droid: "Droid"
        case .qoder: "Qoder"
        case .copilot: "Copilot"
        case .codeBuddy: "CodeBuddy"
        case .qwen: "Qwen"
        case .kimi: "Kimi"
        case .deepseek: "DeepSeek"
        case .kiro: "Kiro"
        case .amp: "Amp"
        case .pi: "Pi"
        case .hermes: "Hermes"
        case .glm: "GLM"
        }
    }

    var color: Color {
        switch self {
        case .claudeCode: Color(red: 0.85, green: 0.45, blue: 0.25)
        case .codex: Color(red: 0.2, green: 0.8, blue: 0.4)
        case .geminiCli: Color(red: 0.3, green: 0.5, blue: 0.95)
        case .cursor: Color(red: 0.6, green: 0.4, blue: 0.9)
        case .trae: Color(red: 0.2, green: 0.7, blue: 0.95)
        case .openCode: Color(red: 0.95, green: 0.7, blue: 0.2)
        case .droid: Color(red: 0.3, green: 0.85, blue: 0.8)
        case .qoder: Color(red: 0.9, green: 0.3, blue: 0.5)
        case .copilot: Color(red: 0.4, green: 0.7, blue: 0.9)
        case .codeBuddy: Color(red: 0.7, green: 0.9, blue: 0.3)
        case .qwen: Color(red: 0.35, green: 0.55, blue: 0.95)
        case .kimi: Color(red: 0.95, green: 0.35, blue: 0.45)
        case .deepseek: Color(red: 0.25, green: 0.75, blue: 0.55)
        case .kiro: Color(red: 0.6, green: 0.5, blue: 0.85)
        case .amp: Color(red: 0.9, green: 0.6, blue: 0.2)
        case .pi: Color(red: 0.5, green: 0.8, blue: 0.95)
        case .hermes: Color(red: 0.75, green: 0.75, blue: 0.75)
        case .glm: Color(red: 0.25, green: 0.45, blue: 0.95)
        }
    }

    var iconSymbol: String {
        switch self {
        case .claudeCode: "brain.head.profile"
        case .codex: "terminal"
        case .geminiCli: "sparkles"
        case .cursor: "cursorarrow.rays"
        case .trae: "sparkle.magnifyingglass"
        case .openCode: "chevron.left.forwardslash.chevron.right"
        case .droid: "cpu"
        case .qoder: "qrcode"
        case .copilot: "airplane"
        case .codeBuddy: "person.2"
        case .qwen: "q.circle"
        case .kimi: "k.circle"
        case .deepseek: "d.circle"
        case .kiro: "k.square"
        case .amp: "bolt.fill"
        case .pi: "p.circle"
        case .hermes: "h.circle"
        case .glm: "g.circle"
        }
    }

    var bundleId: String? {
        switch self {
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .trae: "com.trae.app"
        case .codex: "com.openai.codex"
        case .copilot: "com.microsoft.VSCode"
        default: nil
        }
    }

    var bundleIds: [String] {
        switch self {
        case .cursor:
            [
                "com.todesktop.230313mzl4w4u92", // Cursor
                "com.codeium.windsurf"           // Windsurf
            ]
        case .trae:
            [
                "com.trae.app",                  // Trae
                "cn.trae.app"                    // Trae CN
            ]
        case .codex:
            ["com.openai.codex"]
        case .copilot:
            ["com.microsoft.VSCode"]
        default:
            []
        }
    }

    var processNames: [String] {
        switch self {
        case .claudeCode: ["claude"]
        case .geminiCli: ["gemini"]
        case .openCode: ["opencode"]
        case .cursor: ["Cursor"]
        case .trae: ["Trae", "Trae CN"]
        case .codex: ["Codex"]
        case .copilot: ["Code"]
        case .qwen: ["qwen"]
        case .kimi: ["kimi"]
        case .deepseek: ["deepseek"]
        case .amp: ["amp"]
        case .pi: ["pi"]
        case .glm: ["glm", "zhipu"]
        default: []
        }
    }

    var isDesktopApp: Bool {
        switch self {
        case .cursor, .trae, .copilot: true
        default: false
        }
    }

    var sendsSessionEnd: Bool {
        switch self {
        case .codex, .openCode: false
        default: true
        }
    }

    var isSupported: Bool {
        switch self {
        case .kiro, .hermes: false
        default: true
        }
    }

    static func from(_ string: String?) -> AgentType? {
        guard let raw = string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let lower = raw.lowercased()

        if let direct = AgentType(rawValue: lower) {
            return direct
        }

        if let byDisplay = AgentType.allCases.first(where: { $0.displayName.lowercased() == lower }) {
            return byDisplay
        }

        switch lower {
        case "claude", "claude-code", "claudecode":
            return .claudeCode
        case "codex-cli", "codex_cli":
            return .codex
        case "gemini", "gemini-cli", "gemini_cli":
            return .geminiCli
        case "open-code", "open_code":
            return .openCode
        case "code-buddy", "codebuddy":
            return .codeBuddy
        case "trae", "trae cn", "trae-cn", "traecn":
            return .trae
        case "windsurf":
            return .cursor
        case "qwen", "qwen-code", "qwen_code":
            return .qwen
        case "kimi", "kimi-code", "kimi_code":
            return .kimi
        case "deepseek", "deepseek-tui", "deepseek_tui":
            return .deepseek
        case "kiro":
            return .kiro
        case "amp":
            return .amp
        case "pi", "pi-agent", "pi_agent":
            return .pi
        case "hermes":
            return .hermes
        case "glm", "zhipu", "glm-code", "glm_code":
            return .glm
        default:
            break
        }

        if lower.contains("trae") {
            return .trae
        }
        if lower.contains("cursor") || lower.contains("windsurf") {
            return .cursor
        }
        if lower.contains("codex") {
            return .codex
        }
        if lower.contains("claude") {
            return .claudeCode
        }
        if lower.contains("qwen") {
            return .qwen
        }
        if lower.contains("kimi") {
            return .kimi
        }
        if lower.contains("deepseek") {
            return .deepseek
        }
        if lower.contains("hermes") {
            return .hermes
        }
        if lower.contains("glm") || lower.contains("zhipu") {
            return .glm
        }

        return nil
    }

    static func fromBundleId(_ bundleId: String) -> AgentType? {
        let lower = bundleId.lowercased()
        return allCases.first { $0.bundleIds.contains(where: { $0.lowercased() == lower }) }
    }
}
