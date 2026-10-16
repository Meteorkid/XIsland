import Foundation
import CoreFoundation

/// 通过 chat.hookFilesLocations 精确注册；避免 Copilot CLI 加载共用目录的 Local 文件。
enum VSCodeHookConfiguration {
    static let relativeConfigPath = ".xisland/hooks/vscode-local.json"
    static let registeredPath = "~/.xisland/hooks/vscode-local.json"
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                         "Stop", "SubagentStart", "SubagentStop", "PreCompact"]
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
              let expectedHooks = expected["hooks"] as? [String: Any] else { return false }
        let count = hooks.reduce(0) { sum, item in
            sum + (item.value as? [[String: Any]] ?? []).filter { isOwned($0, event: item.key) }.count
        }
        return count == events.count && events.allSatisfy { event in
            guard let expected = (expectedHooks[event] as? [[String: Any]])?.first else { return false }
            return (hooks[event] as? [[String: Any]] ?? []).contains { NSDictionary(dictionary: $0).isEqual(to: expected) }
        }
    }

    private static func handler(event: String, bridgePath: String) -> [String: Any] {
        ["type": "command", "command": quote(bridgePath) + suffix(event), "timeout": 5]
    }

    private static func suffix(_ event: String) -> String {
        // 纯观察输出保持空白，不覆盖宿主的审批策略或其他 hook 决定。
        " --agent copilot --adapter vscode_local --hook \(event) >/dev/null || true # XIsland:VSCodeLocal:\(event)"
    }

    private static func isOwned(_ entry: [String: Any], event: String) -> Bool {
        guard entry["type"] as? String == "command", let command = entry["command"] as? String,
              command.hasSuffix(suffix(event)) else { return false }
        let quoted = String(command.dropLast(suffix(event).count))
        guard quoted.hasPrefix("'"), quoted.hasSuffix("'"), quoted.count >= 2 else { return false }
        let path = String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        return path.hasPrefix("/") && !path.utf8.contains(0) && quote(path) == quoted
    }

    private static func eventMap(_ configuration: [String: Any]) throws -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(configuration), configuration["version"] == nil else {
            throw ConfigurationError.invalidStructure("Local format must not have version")
        }
        guard let value = configuration["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw ConfigurationError.invalidStructure("hooks") }
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { throw ConfigurationError.invalidStructure(event) }
            for entry in entries {
                guard entry["type"] as? String == "command",
                      ["command", "osx", "linux", "windows"].contains(where: { (entry[$0] as? String)?.isEmpty == false }) else {
                    throw ConfigurationError.invalidStructure(event + ".command")
                }
                for key in ["command", "osx", "linux", "windows", "cwd"] where entry[key] != nil {
                    guard let text = entry[key] as? String, !text.utf8.contains(0) else {
                        throw ConfigurationError.invalidStructure(event + "." + key)
                    }
                }
                if let env = entry["env"], !(env is [String: String]) { throw ConfigurationError.invalidStructure(event + ".env") }
                if let value = entry["timeout"] {
                    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue.isFinite, number.doubleValue > 0 else {
                        throw ConfigurationError.invalidStructure(event + ".timeout")
                    }
                }
            }
        }
        return hooks
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
