import Foundation
import CoreFoundation

/// Devin CLI 全局配置；事件与 timeout（秒）依据官方 hooks 文档。
enum DevinHookConfiguration {
    static let relativeConfigPath = ".config/devin/config.json"
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Stop", "PostCompaction", "SessionEnd",
    ]

    enum ConfigurationError: Error, Equatable {
        case invalidBridgePath
        case invalidStructure(String)
    }

    static func merging(into config: [String: Any], bridgePath: String) throws -> [String: Any] {
        guard bridgePath.hasPrefix("/"), !bridgePath.utf8.contains(0) else {
            throw ConfigurationError.invalidBridgePath
        }
        var result = try removing(from: config)
        var hooks = result["hooks"] as? [String: Any] ?? [:]

        for event in events {
            var retainedGroups = hooks[event] as? [[String: Any]] ?? []
            let command = "\(shellQuote(bridgePath)) --agent devin --hook \(event)"
            let reportingCommand = event == "PermissionRequest" ? command : "\(command) || true"
            retainedGroups.append([
                "hooks": [[
                    "type": "command",
                    "command": reportingCommand + marker(for: event),
                    "timeout": event == "PermissionRequest" ? 300 : 5,
                ] as [String: Any]],
            ])
            hooks[event] = retainedGroups
        }

        result["hooks"] = hooks
        return result
    }

    static func removing(from config: [String: Any]) throws -> [String: Any] {
        var hooks = try validatedHooks(from: config)
        for event in Array(hooks.keys) {
            let groups = hooks[event] as? [[String: Any]] ?? []
            let retained = groups.compactMap { group -> [String: Any]? in
                let handlers = group["hooks"] as? [[String: Any]] ?? []
                let remaining = handlers.filter { !isOwned($0, event: event) }
                guard remaining.count != handlers.count else { return group }
                guard !remaining.isEmpty else { return nil }
                var updated = group
                updated["hooks"] = remaining
                return updated
            }
            if retained.isEmpty && !groups.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = retained }
        }
        var result = config
        if config["hooks"] != nil { result["hooks"] = hooks }
        return result
    }

    static func isConfigured(in config: [String: Any], bridgePath: String) -> Bool {
        guard let hooks = try? validatedHooks(from: config),
              let expected = try? merging(into: [:], bridgePath: bridgePath),
              let expectedHooks = expected["hooks"] as? [String: Any] else { return false }
        var count = 0
        for (event, value) in hooks {
            let groups = value as? [[String: Any]] ?? []
            count += groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .filter { isOwned($0, event: event) }.count
        }
        guard count == events.count else { return false }
        return events.allSatisfy { event in
            guard let expectedGroup = (expectedHooks[event] as? [[String: Any]])?.last else { return false }
            return (hooks[event] as? [[String: Any]] ?? []).contains { NSDictionary(dictionary: $0).isEqual(to: expectedGroup) }
        }
    }

    private static func validatedHooks(from config: [String: Any]) throws -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(config) else {
            throw ConfigurationError.invalidStructure("config")
        }
        var hooks: [String: Any] = [:]
        if let existing = config["hooks"] {
            guard let dictionary = existing as? [String: Any] else {
                throw ConfigurationError.invalidStructure("hooks")
            }
            hooks = dictionary
        }

        // 先完整校验再合并，损坏配置不能被当成空字典覆盖。
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                throw ConfigurationError.invalidStructure("hooks.\(event)")
            }
            for group in groups {
                guard group["matcher"] == nil || group["matcher"] is String,
                      let handlers = group["hooks"] as? [[String: Any]] else {
                    throw ConfigurationError.invalidStructure("hooks.\(event).hooks")
                }
                for handler in handlers {
                    guard let type = handler["type"] as? String, !type.isEmpty else {
                        throw ConfigurationError.invalidStructure("hooks.\(event).hooks.type")
                    }
                    if type == "command", (handler["command"] as? String)?.isEmpty != false {
                        throw ConfigurationError.invalidStructure("hooks.\(event).hooks.command")
                    }
                    if type == "prompt", (handler["prompt"] as? String)?.isEmpty != false {
                        throw ConfigurationError.invalidStructure("hooks.\(event).hooks.prompt")
                    }
                    if let timeout = handler["timeout"] {
                        guard let number = timeout as? NSNumber,
                              CFGetTypeID(number) != CFBooleanGetTypeID(),
                              number.doubleValue.isFinite, number.doubleValue > 0 else {
                            throw ConfigurationError.invalidStructure("hooks.\(event).hooks.timeout")
                        }
                    }
                }
            }
        }

        return hooks
    }

    private static func marker(for event: String) -> String {
        " # XIsland:Devin:\(event)"
    }

    /// 只移除带本适配器专属标记的 command；不按 di-bridge 子串删除第三方脚本。
    private static func isOwned(_ handler: [String: Any], event: String) -> Bool {
        guard handler["type"] as? String == "command",
              let command = handler["command"] as? String else { return false }
        let arguments = " --agent devin --hook \(event)"
        let suffixes = [arguments + marker(for: event), arguments + " || true" + marker(for: event)]
        guard let suffix = suffixes.first(where: { command.hasSuffix($0) }) else { return false }
        let quoted = String(command.dropLast(suffix.count))
        guard quoted.hasPrefix("'"), quoted.hasSuffix("'"), quoted.count >= 2 else { return false }
        let path = String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        return path.hasPrefix("/") && !path.utf8.contains(0) && shellQuote(path) == quoted
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
