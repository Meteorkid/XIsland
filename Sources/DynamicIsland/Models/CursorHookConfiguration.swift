import Foundation
import CoreFoundation

enum CursorHookConfiguration {
    static let relativeConfigPath = ".cursor/hooks.json"
    static let events = ["sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure",
                         "afterAgentResponse", "stop", "preCompact", "sessionEnd"]
    enum ConfigurationError: Error { case invalidPath, invalidStructure(String) }

    static func merging(into configuration: [String: Any], bridgePath: String) throws -> [String: Any] {
        guard bridgePath.hasPrefix("/"), !bridgePath.utf8.contains(0) else { throw ConfigurationError.invalidPath }
        var result = try removing(from: configuration)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.append(handler(event: event, bridgePath: bridgePath))
            hooks[event] = entries
        }
        result["version"] = 1
        result["hooks"] = hooks
        return result
    }

    static func removing(from configuration: [String: Any]) throws -> [String: Any] {
        var hooks = try eventMap(configuration)
        guard configuration["hooks"] != nil else { return configuration }
        for event in Array(hooks.keys) {
            let entries = hooks[event] as? [[String: Any]] ?? []
            let retained = entries.filter { !isOwned($0, event: event) }
            if retained.isEmpty, !entries.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = retained }
        }
        var result = configuration
        result["hooks"] = hooks
        return result
    }

    static func isConfigured(in configuration: [String: Any], bridgePath: String) -> Bool {
        guard let hooks = try? eventMap(configuration),
              let expected = try? merging(into: [:], bridgePath: bridgePath),
              let expectedHooks = expected["hooks"] as? [String: Any],
              (configuration["version"] as? NSNumber)?.intValue == 1 else { return false }
        let count = hooks.reduce(0) { sum, item in
            sum + (item.value as? [[String: Any]] ?? []).filter { isOwned($0, event: item.key) }.count
        }
        return count == events.count && events.allSatisfy { event in
            guard let expected = (expectedHooks[event] as? [[String: Any]])?.first else { return false }
            return (hooks[event] as? [[String: Any]] ?? []).contains { NSDictionary(dictionary: $0).isEqual(to: expected) }
        }
    }

    private static func handler(event: String, bridgePath: String) -> [String: Any] {
        ["command": quote(bridgePath) + suffix(event), "timeout": 5]
    }

    private static func suffix(_ event: String) -> String {
        let output = event == "preToolUse" ? "{\"permission\":\"allow\"}"
            : event == "beforeSubmitPrompt" ? "{\"continue\":true}" : "{}"
        // Cursor 对权限hook的空JSON会阻断。观察命令丢弃bridge输出并返回固定的本hook放行结果。
        return " --agent cursor --hook \(event) >/dev/null; printf '%s\\n' '\(output)' # XIsland:Cursor:\(event)"
    }

    private static func isOwned(_ entry: [String: Any], event: String) -> Bool {
        guard entry["type"] == nil || entry["type"] as? String == "command",
              let command = entry["command"] as? String else { return false }
        let ending = suffix(event)
        if command.hasSuffix(ending) {
            let quoted = String(command.dropLast(ending.count))
            guard quoted.hasPrefix("'"), quoted.hasSuffix("'"), quoted.count >= 2 else { return false }
            let path = String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
            return path.hasPrefix("/") && !path.utf8.contains(0) && quote(path) == quoted
        }
        let legacyArguments: [String: String] = [
            "beforeSubmitPrompt": "session_start", "afterAgentResponse": "notification", "afterAgentThought": "notification",
            "beforeReadFile": "PreToolUse --tool Read", "afterFileEdit": "PostToolUse --tool FileEdit",
            "beforeShellExecution": "PreToolUse --tool Shell", "afterShellExecution": "PostToolUse --tool Shell",
            "beforeMCPExecution": "PreToolUse --tool MCP", "afterMCPExecution": "PostToolUse --tool MCP", "stop": "session_end",
        ]
        guard let arguments = legacyArguments[event] else { return false }
        let legacySuffix = " --agent cursor --hook \(arguments)"
        guard command.hasSuffix(legacySuffix) else { return false }
        let path = String(command.dropLast(legacySuffix.count))
        let forbidden = CharacterSet(charactersIn: "\n\r\0;|&$`<>\\\"'")
        return path.hasPrefix("/") && (path as NSString).lastPathComponent == "di-bridge"
            && path.rangeOfCharacter(from: forbidden) == nil
    }

    private static func eventMap(_ configuration: [String: Any]) throws -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(configuration) else { throw ConfigurationError.invalidStructure("root") }
        if let value = configuration["version"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == 1 else {
                throw ConfigurationError.invalidStructure("version")
            }
        }
        guard let value = configuration["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw ConfigurationError.invalidStructure("hooks") }
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { throw ConfigurationError.invalidStructure(event) }
            for entry in entries {
                let field = entry["type"] as? String == "prompt" ? "prompt" : "command"
                guard let command = entry[field] as? String, !command.isEmpty, !command.utf8.contains(0) else {
                    throw ConfigurationError.invalidStructure(event + "." + field)
                }
                if let value = entry["timeout"] {
                    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue.isFinite, number.doubleValue > 0 else { throw ConfigurationError.invalidStructure(event + ".timeout") }
                }
            }
        }
        return hooks
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
