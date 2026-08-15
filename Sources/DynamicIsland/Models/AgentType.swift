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
    case windsurf = "windsurf"
    case devin = "devin"
    case amazonQ = "amazon_q"
    case tabnine = "tabnine"
    case cody = "cody"
    case cline = "cline"
    case `continue` = "continue"
    case copilotCli = "copilot_cli"
    case rooCode = "roo_code"
    case pearai = "pearai"
    case zed = "zed"
    case jetbrainsAi = "jetbrains_ai"

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
            for alias in type.meta.aliases where containsAsWord(lower, alias) {
                return type
            }
        }
        if lower.contains("cursor") { return .cursor }
        if lower.contains("windsurf") { return .windsurf }
        if lower.contains("claude") { return .claudeCode }
        if lower.contains("codex") { return .codex }
        if lower.contains("trae") { return .trae }
        if lower.contains("aider") { return .aider }
        if lower.contains("devin") { return .devin }
        if lower.contains("amazon") || lower.contains("q developer") { return .amazonQ }
        if lower.contains("tabnine") { return .tabnine }
        if lower.contains("cody") { return .cody }
        if lower.contains("cline") { return .cline }
        if lower.contains("continue") { return .`continue` }
        if lower.contains("copilot") { return .copilot }
        if lower.contains("roo code") || lower.contains("roo-code") || lower.contains("roocode") || lower.contains("roo-cline") || lower.contains("roocline") { return .rooCode }
        if lower.contains("pearai") { return .pearai }
        if lower == "zed" || lower.contains("zed ai") || lower.hasPrefix("zed-") || lower.contains("zed.dev") { return .zed }
        if lower.contains("jetbrains") || lower.contains("intellij") || lower.contains("webstorm") || lower.contains("goland") || lower.contains("pycharm") || lower.contains("rustrover") || lower.contains("phpstorm") || lower.contains("rubymine") || lower.contains("clion") || lower.contains("rider") { return .jetbrainsAi }

        return nil
    }

    /// 子串回退时要求别名落在词边界上（前后不是字母）。
    /// 直接用 contains 会让 "zed"/"roo"/"pi" 这类短别名吃掉 "optimized"/"root"/"copilot"；
    /// 数字不算边界字符，"qwen3"、"claude2" 这类带版本号的输入仍能匹配。
    static func containsAsWord(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let precededByLetter = range.lowerBound > haystack.startIndex
                && haystack[haystack.index(before: range.lowerBound)].isLetter
            let followedByLetter = range.upperBound < haystack.endIndex
                && haystack[range.upperBound].isLetter
            if !precededByLetter && !followedByLetter {
                return true
            }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return false
    }

    static func fromBundleId(_ bundleId: String) -> AgentType? {
        let lower = bundleId.lowercased()
        return allCases.first { $0.bundleIds.contains(where: { $0.lowercased() == lower }) }
    }
}
