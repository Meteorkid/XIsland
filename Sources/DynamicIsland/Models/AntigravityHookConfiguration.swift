import Foundation
import CoreFoundation

/// Antigravity 全局 hooks。
///
/// 官方文档（antigravity.google/docs/hooks）说明：App、CLI（agy）与 IDE 的全局 hooks
/// 都读取 `~/.gemini/config/hooks.json`，文件按「hook 名称 → 事件」分组；
/// `PreToolUse` / `PostToolUse` 使用 matcher 分组，其余事件直接放 handler 列表。
/// timeout 以秒为单位（默认 30）。
enum AntigravityHookConfiguration {
    static let relativeConfigPath = ".gemini/config/hooks.json"
    static let hookName = "xisland"

    enum ConfigurationError: Error, Equatable {
        case invalidBridgePath
        case invalidStructure(String)
    }

    /// 与官方事件表一致；不复用 Gemini CLI 的 BeforeAgent/AfterAgent 名称。
    static let events = ["SessionStart", "PreInvocation", "PreToolUse", "PostToolUse", "Stop"]

    static func hooksFile(bridgePath: String) throws -> [String: Any] {
        try merging(into: [:], bridgePath: bridgePath)
    }

    static func merging(into configuration: [String: Any], bridgePath: String) throws -> [String: Any] {
        try validateBridgePath(bridgePath)
        var result = try removing(from: configuration)
        result[hookName] = entry(bridgePath: bridgePath)
        return result
    }

    static func removing(from configuration: [String: Any]) throws -> [String: Any] {
        guard !configuration.isEmpty else { return [:] }
        guard JSONSerialization.isValidJSONObject(configuration) else {
            throw ConfigurationError.invalidStructure("hooks.json")
        }
        var result = configuration
        result.removeValue(forKey: hookName)
        return result
    }

    static func isConfigured(in configuration: [String: Any], bridgePath: String) -> Bool {
        guard let file = try? hooksFile(bridgePath: bridgePath),
              let expected = file[hookName] as? [String: Any],
              let existing = configuration[hookName] as? [String: Any],
              NSDictionary(dictionary: existing).isEqual(to: expected) else { return false }
        return true
    }

    private static func entry(bridgePath: String) -> [String: Any] {
        var entry: [String: Any] = [:]
        for event in events {
            let command = "\(shellQuote(bridgePath)) --agent antigravity --hook \(event) || true"
            let handler: [String: Any] = ["type": "command", "command": command, "timeout": 5]
            if event == "PreToolUse" || event == "PostToolUse" {
                // 工具事件必须带 matcher；"*" 才覆盖全部工具。
                entry[event] = [["matcher": "*", "hooks": [handler]]]
            } else {
                entry[event] = [handler]
            }
        }
        return entry
    }

    private static func validateBridgePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw ConfigurationError.invalidBridgePath
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
