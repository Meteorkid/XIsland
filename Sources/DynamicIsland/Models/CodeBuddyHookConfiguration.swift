import Foundation

/// 仅适用于 CodeBuddy Code CLI；IDE 与 WorkBuddy 的 hook 协议尚未核实。
enum CodeBuddyHookConfiguration {
    static let relativeConfigPath = ".codebuddy/settings.json"
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification",
        "Stop", "SubagentStop", "PreCompact", "PostCompact", "SessionEnd",
    ]

    enum ConfigurationError: Error, Equatable {
        case invalidJSON
    }

    private static var profile: NativeHookProfile {
        NativeHookProfile(
            agent: .codeBuddy,
            relativeConfigPath: relativeConfigPath,
            hooksAreAtRoot: false,
            timeoutUnit: .seconds,
            // 所有前置事件只观察；没有完整 PermissionRequest 合同就不注册权限接管。
            bindings: events.map { .init(event: $0, bridgeHook: $0, timeout: $0 == "SessionEnd" ? 1 : 5) }
        )
    }

    static func merging(into configuration: [String: Any], bridgePath: String) throws -> [String: Any] {
        try validateJSON(configuration)
        return try profile.merging(into: configuration, bridgePath: bridgePath)
    }

    static func removing(from configuration: [String: Any]) throws -> [String: Any] {
        try validateJSON(configuration)
        return try profile.removing(from: configuration)
    }

    /// 文件就绪不代表客户端已经过 /hooks 审核或真实会话验收。
    static func isConfigured(in configuration: [String: Any], bridgePath: String) -> Bool {
        guard (try? validateJSON(configuration)) != nil else { return false }
        return profile.isConfigured(in: configuration, bridgePath: bridgePath)
    }

    private static func validateJSON(_ configuration: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(configuration) else { throw ConfigurationError.invalidJSON }
    }
}
