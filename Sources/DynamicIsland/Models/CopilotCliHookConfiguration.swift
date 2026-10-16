import Foundation
import CoreFoundation

/// Copilot CLI 的 camelCase hooks；与 VS Code 的 PascalCase/snake_case 协议分开。
enum CopilotCliHookConfiguration {
    static let events = [
        "sessionStart", "sessionEnd", "userPromptSubmitted", "preToolUse", "postToolUse",
        "postToolUseFailure", "agentStop", "subagentStart", "subagentStop", "errorOccurred",
        "preCompact", "notification",
    ]

    enum ConfigurationError: Error { case invalidBridgePath, invalidStructure(String) }

    static func configURL(homeDirectory: String, environment: [String: String]) -> URL {
        let configured = environment["COPILOT_HOME"]
        let base = configured.flatMap { $0.hasPrefix("/") && !$0.utf8.contains(0) ? $0 : nil }
            ?? "\(homeDirectory)/.copilot"
        return URL(fileURLWithPath: base).appendingPathComponent("hooks/xisland.json")
    }

    static func merging(into configuration: [String: Any], bridgePath: String) throws -> [String: Any] {
        guard bridgePath.hasPrefix("/"), !bridgePath.utf8.contains(0) else { throw ConfigurationError.invalidBridgePath }
        var result = try removing(from: configuration)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var commands = hooks[event] as? [[String: Any]] ?? []
            commands.append(handler(event: event, bridgePath: bridgePath))
            hooks[event] = commands
        }
        result["version"] = 1
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
        guard let hooks = try? eventMap(in: configuration),
              let expected = try? merging(into: [:], bridgePath: bridgePath),
              let expectedHooks = expected["hooks"] as? [String: Any],
              (configuration["version"] as? NSNumber)?.intValue == 1 else { return false }
        let count = hooks.reduce(0) { sum, item in
            sum + (item.value as? [[String: Any]] ?? []).filter { isOwned($0, event: item.key) }.count
        }
        return count == events.count && events.allSatisfy { event in
            guard let expectedHandler = (expectedHooks[event] as? [[String: Any]])?.first else { return false }
            return (hooks[event] as? [[String: Any]] ?? []).contains { NSDictionary(dictionary: $0).isEqual(to: expectedHandler) }
        }
    }

    private static func handler(event: String, bridgePath: String) -> [String: Any] {
        // preToolUse 的非零退出会阻断工具；观察失败必须回到宿主正常流程。
        ["type": "command", "bash": quote(bridgePath) + suffix(event: event), "timeoutSec": 5]
    }

    private static func suffix(event: String) -> String {
        " --agent copilot_cli --hook \(event) || true # XIsland:CopilotCLI:\(event)"
    }

    private static func isOwned(_ handler: [String: Any], event: String) -> Bool {
        guard handler["type"] as? String == "command", handler["exec"] == nil,
              let command = handler["bash"] as? String, command.hasSuffix(suffix(event: event)) else { return false }
        let quoted = String(command.dropLast(suffix(event: event).count))
        guard quoted.hasPrefix("'"), quoted.hasSuffix("'"), quoted.count >= 2 else { return false }
        let path = String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        return path.hasPrefix("/") && !path.utf8.contains(0) && quote(path) == quoted
    }

    private static func eventMap(in configuration: [String: Any]) throws -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(configuration) else { throw ConfigurationError.invalidStructure("root") }
        if let version = configuration["version"] {
            guard let number = version as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == 1 else {
                throw ConfigurationError.invalidStructure("version")
            }
        }
        guard let value = configuration["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw ConfigurationError.invalidStructure("hooks") }
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { throw ConfigurationError.invalidStructure(event) }
            for entry in entries {
                if let type = entry["type"], !(type is String) { throw ConfigurationError.invalidStructure(event + ".type") }
                let type = entry["type"] as? String ?? "command"
                let required = type == "http" ? ["url"] : type == "prompt" ? ["prompt"] : ["exec", "bash", "powershell", "command"]
                guard required.contains(where: { (entry[$0] as? String)?.isEmpty == false }) else {
                    throw ConfigurationError.invalidStructure(event + ".handler")
                }
                if let args = entry["args"], !(args is [String]) { throw ConfigurationError.invalidStructure(event + ".args") }
                for key in ["timeoutSec", "timeout"] where entry[key] != nil {
                    guard let number = entry[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue.isFinite, number.doubleValue > 0 else { throw ConfigurationError.invalidStructure(event + "." + key) }
                }
            }
        }
        return hooks
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
