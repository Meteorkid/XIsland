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
    case aider = "aider"

    var id: String { rawValue }

    var displayName: String { meta.displayName }
    var shortName: String { meta.shortName }
    var color: Color { meta.color }
    var iconSymbol: String { meta.iconSymbol }
    var bundleIds: [String] { meta.bundleIds }
    var processNames: [String] { meta.processNames }
    var isDesktopApp: Bool { meta.isDesktopApp }
    var sendsSessionEnd: Bool { meta.sendsSessionEnd }

    var bundleId: String? { meta.bundleIds.first }

    var isSupported: Bool {
        self != .hermes
    }

    static func from(_ string: String?) -> AgentType? {
        guard let raw = string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let lower = raw.lowercased()

        // 1. Direct rawValue match
        if let direct = AgentType(rawValue: lower) {
            return direct
        }

        // 2. Display name match
        if let byDisplay = AgentType.allCases.first(where: { $0.displayName.lowercased() == lower }) {
            return byDisplay
        }

        // 3. Alias lookup from registry
        if let byAlias = AgentType.allCases.first(where: { type in
            type.meta.aliases.contains(lower)
        }) {
            return byAlias
        }

        // 4. Substring fallback
        for type in AgentType.allCases {
            for alias in type.meta.aliases where lower.contains(alias) {
                return type
            }
        }
        if lower.contains("cursor") || lower.contains("windsurf") { return .cursor }
        if lower.contains("claude") { return .claudeCode }
        if lower.contains("codex") { return .codex }
        if lower.contains("trae") { return .trae }
        if lower.contains("aider") { return .aider }

        return nil
    }

    static func fromBundleId(_ bundleId: String) -> AgentType? {
        let lower = bundleId.lowercased()
        return allCases.first { $0.bundleIds.contains(where: { $0.lowercased() == lower }) }
    }
}
