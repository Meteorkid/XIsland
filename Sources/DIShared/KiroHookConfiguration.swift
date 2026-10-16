import Foundation
import CoreFoundation

/// V3 独立 hook 文件的显式导出；不探测、执行 CLI 或写入用户配置。
public enum KiroHookConfiguration {
    public static let documentedCLIVersion = "2.31.0"
    public static let fileName = "xisland-observer.json"
    public static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"]

    public enum ConfigurationError: Error, Equatable {
        case unsupportedRuntime
        case invalidBridgePath
        case invalidDocument
        case modifiedOwnedHook(String)
    }

    /// 版本为使用者明确选择的文档基线，不代表此机已安装或加载该版本。
    public static func merging(into document: [String: Any], bridgePath: String,
                               cliVersion: String, engine: String) throws -> [String: Any] {
        guard cliVersion == documentedCLIVersion, engine == "v3" else {
            throw ConfigurationError.unsupportedRuntime
        }
        try validateBridgePath(bridgePath)
        var result = try removing(from: document)
        var hooks = result["hooks"] as? [[String: Any]] ?? []
        hooks += events.map { hook(for: $0, bridgePath: bridgePath) }
        result["version"] = "v1"
        result["hooks"] = hooks
        return result
    }

    public static func removing(from document: [String: Any]) throws -> [String: Any] {
        let hooks = try validatedHooks(in: document)
        let retained = try hooks.filter { entry in
            guard let name = entry["name"] as? String, name.hasPrefix("XIsland:KiroV3:") else { return true }
            guard let event = entry["trigger"] as? String, events.contains(event),
                  let action = entry["action"] as? [String: Any],
                  let command = action["command"] as? String,
                  let path = ownedBridgePath(in: command, event: event),
                  NSDictionary(dictionary: entry).isEqual(to: hook(for: event, bridgePath: path)) else {
                // 同名条目被手改后不猜测所有权，也不加一份重复的观察 hook。
                throw ConfigurationError.modifiedOwnedHook(name)
            }
            return false
        }
        var result = document
        if document["hooks"] != nil { result["hooks"] = retained }
        return result
    }

    public static func isConfigured(in document: [String: Any], bridgePath: String) -> Bool {
        guard (try? validateBridgePath(bridgePath)) != nil,
              let hooks = try? validatedHooks(in: document),
              let cleaned = try? removing(from: document),
              hooks.count - ((cleaned["hooks"] as? [[String: Any]])?.count ?? 0) == events.count else { return false }
        return events.allSatisfy { event in
            hooks.contains { NSDictionary(dictionary: $0).isEqual(to: hook(for: event, bridgePath: bridgePath)) }
        }
    }

    private static func hook(for event: String, bridgePath: String) -> [String: Any] {
        ["name": "XIsland:KiroV3:\(event)", "trigger": event, "enabled": true,
         "action": ["type": "command", "command": command(for: event, bridgePath: bridgePath)]]
    }

    private static func command(for event: String, bridgePath: String) -> String {
        // 观察失败不阻断原生动作；空 stdout 不注入提示或提供审批决定。
        "\(shellQuote(bridgePath)) --agent kiro --adapter kiro_cli --hook \(event) >/dev/null || true"
    }

    private static func ownedBridgePath(in command: String, event: String) -> String? {
        let suffix = " --agent kiro --adapter kiro_cli --hook \(event) >/dev/null || true"
        guard command.hasSuffix(suffix) else { return nil }
        let quoted = String(command.dropLast(suffix.count))
        guard quoted.hasPrefix("'"), quoted.hasSuffix("'"), quoted.count >= 2 else { return nil }
        let path = String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        guard (try? validateBridgePath(path)) != nil, shellQuote(path) == quoted else { return nil }
        return path
    }

    private static func validateBridgePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ConfigurationError.invalidBridgePath
        }
    }

    private static func validatedHooks(in document: [String: Any]) throws -> [[String: Any]] {
        guard JSONSerialization.isValidJSONObject(document),
              document["version"] == nil || document["version"] as? String == "v1" else {
            throw ConfigurationError.invalidDocument
        }
        guard let raw = document["hooks"] else { return [] }
        guard let hooks = raw as? [[String: Any]], document["version"] as? String == "v1" else {
            throw ConfigurationError.invalidDocument
        }
        for hook in hooks {
            guard let name = hook["name"] as? String, !name.isEmpty,
                  let trigger = hook["trigger"] as? String, !trigger.isEmpty,
                  let action = hook["action"] as? [String: Any],
                  let type = action["type"] as? String,
                  (type == "command" && action["command"] is String)
                    || (type == "agent" && action["prompt"] is String) else {
                throw ConfigurationError.invalidDocument
            }
            if let enabled = hook["enabled"] {
                guard let value = enabled as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                    throw ConfigurationError.invalidDocument
                }
            }
        }
        return hooks
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
