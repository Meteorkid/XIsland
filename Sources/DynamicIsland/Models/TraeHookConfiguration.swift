import Foundation
import CoreFoundation

/// 已核实的 Trae CN 配置；国际版与其他发行形态需要独立验收。
enum TraeHookConfiguration {
    static let relativeConfigPath = ".trae-cn/hooks.json"
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Notification"]
    enum ConfigurationError: Error { case invalidVersion, unsupportedLegacyEntry }

    private static var profile: NativeHookProfile {
        NativeHookProfile(agent: .trae, relativeConfigPath: relativeConfigPath, hooksAreAtRoot: false,
                          timeoutUnit: .seconds, bindings: events.map { .init(event: $0, bridgeHook: $0, timeout: 5) })
    }

    static func merging(into configuration: [String: Any], bridgePath: String) throws -> [String: Any] {
        var result = try profile.merging(into: normalized(configuration), bridgePath: bridgePath)
        result["version"] = 1
        return result
    }

    static func removing(from configuration: [String: Any]) throws -> [String: Any] {
        try profile.removing(from: normalized(configuration))
    }

    static func isConfigured(in configuration: [String: Any], bridgePath: String) -> Bool {
        guard let normalized = try? normalized(configuration),
              NSDictionary(dictionary: normalized).isEqual(to: configuration) else { return false }
        return profile.isConfigured(in: normalized, bridgePath: bridgePath)
    }

    private static func normalized(_ configuration: [String: Any]) throws -> [String: Any] {
        if let version = configuration["version"] {
            guard let number = version as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == 1 else {
                throw ConfigurationError.invalidVersion
            }
        }
        guard var hooks = configuration["hooks"] as? [String: Any] else { return configuration }
        let oldArguments = ["beforeSubmitPrompt": "session_start", "afterAgentResponse": "notification", "afterAgentThought": "notification",
                            "beforeReadFile": "PreToolUse --tool Read", "afterFileEdit": "PostToolUse --tool FileEdit",
                            "beforeShellExecution": "PreToolUse --tool Shell", "afterShellExecution": "PostToolUse --tool Shell",
                            "beforeMCPExecution": "PreToolUse --tool MCP", "afterMCPExecution": "PostToolUse --tool MCP", "stop": "session_end"]
        for (event, arguments) in oldArguments {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            let suffix = " --agent trae --hook \(arguments)"
            let retained = try entries.filter { entry in
                // 已合法使用新分组形式的未知事件保持原样；仅认领旧版完整命令形状。
                if entry["hooks"] != nil { return true }
                guard let command = entry["command"] as? String, command.hasSuffix(suffix) else {
                    throw ConfigurationError.unsupportedLegacyEntry
                }
                let path = String(command.dropLast(suffix.count))
                let forbidden = CharacterSet(charactersIn: "\n\r\0;|&$`<>\\\"'")
                guard path.hasPrefix("/"), (path as NSString).lastPathComponent == "di-bridge",
                      path.rangeOfCharacter(from: forbidden) == nil else { throw ConfigurationError.unsupportedLegacyEntry }
                return false
            }
            if retained.isEmpty, !entries.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = retained }
        }
        var result = configuration
        result["hooks"] = hooks
        return result
    }
}
