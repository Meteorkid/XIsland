import Foundation
import CoreFoundation

/// Cascade 原生 hooks：事件下直接放 command，不使用 Claude 的 matcher/hooks 分组。
enum WindsurfHookConfiguration {
    static let relativeConfigPath = ".codeium/windsurf/hooks.json"
    static let events = [
        "pre_user_prompt", "pre_read_code", "post_read_code",
        "pre_write_code", "post_write_code", "pre_run_command", "post_run_command",
        "pre_mcp_tool_use", "post_mcp_tool_use", "post_cascade_response",
    ]

    enum ConfigurationError: Error, Equatable {
        case invalidBridgePath
        case invalidStructure(String)
    }

    static func merging(into configuration: [String: Any], bridgePath: String) throws -> [String: Any] {
        try validateBridgePath(bridgePath)
        var result = try removing(from: configuration)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var commands = hooks[event] as? [[String: Any]] ?? []
            commands.append(handler(event: event, bridgePath: bridgePath))
            hooks[event] = commands
        }
        result["hooks"] = hooks
        return result
    }

    static func removing(from configuration: [String: Any]) throws -> [String: Any] {
        var hooks = try eventMap(in: configuration)
        guard configuration["hooks"] != nil else { return configuration }
        for event in Array(hooks.keys) {
            let commands = hooks[event] as? [[String: Any]] ?? []
            let retained = commands.filter { !isOwned($0, event: event) }
            if retained.isEmpty, !commands.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = retained }
        }
        var result = configuration
        result["hooks"] = hooks
        return result
    }

    static func isConfigured(in configuration: [String: Any], bridgePath: String) -> Bool {
        guard (try? validateBridgePath(bridgePath)) != nil,
              let hooks = try? eventMap(in: configuration) else { return false }
        let ownedCount = hooks.reduce(0) { count, entry in
            count + (entry.value as? [[String: Any]] ?? []).filter { isOwned($0, event: entry.key) }.count
        }
        return ownedCount == events.count && events.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains {
                NSDictionary(dictionary: $0).isEqual(to: handler(event: event, bridgePath: bridgePath))
            }
        }
    }

    private static func handler(event: String, bridgePath: String) -> [String: Any] {
        // 观察链路的错误不能变成 Cascade 的前置阻断（exit 2）。
        ["command": shellQuote(bridgePath) + suffix(event: event), "show_output": false]
    }

    private static func suffix(event: String) -> String {
        " --agent windsurf --hook \(event) || true # XIsland:Windsurf:\(event)"
    }

    private static func isOwned(_ handler: [String: Any], event: String) -> Bool {
        guard let command = handler["command"] as? String,
              command.hasSuffix(suffix(event: event)) else { return false }
        let quotedPath = String(command.dropLast(suffix(event: event).count))
        guard quotedPath.hasPrefix("'"), quotedPath.hasSuffix("'"), quotedPath.count >= 2 else { return false }
        let path = String(quotedPath.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        // 校验整个调用形状，防止把包装脚本或包含 di-bridge 字样的第三方命令认领为自身。
        return path.hasPrefix("/") && !path.utf8.contains(0) && shellQuote(path) == quotedPath
    }

    private static func validateBridgePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw ConfigurationError.invalidBridgePath }
    }

    private static func eventMap(in configuration: [String: Any]) throws -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(configuration) else { throw ConfigurationError.invalidStructure("config") }
        guard let value = configuration["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw ConfigurationError.invalidStructure("hooks") }
        for (event, value) in hooks {
            guard let commands = value as? [[String: Any]] else {
                throw ConfigurationError.invalidStructure("hooks.\(event)")
            }
            for command in commands {
                let fields = ["command", "powershell"]
                guard fields.contains(where: { (command[$0] as? String)?.isEmpty == false }) else {
                    throw ConfigurationError.invalidStructure("hooks.\(event).command")
                }
                for field in fields + ["working_directory"] where command[field] != nil {
                    guard let value = command[field] as? String, !value.isEmpty, !value.utf8.contains(0) else {
                        throw ConfigurationError.invalidStructure("hooks.\(event).\(field)")
                    }
                }
                if let output = command["show_output"] {
                    guard let number = output as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                        throw ConfigurationError.invalidStructure("hooks.\(event).show_output")
                    }
                }
            }
        }
        return hooks
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
