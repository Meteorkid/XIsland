import Foundation
import CoreFoundation

/// 已核实的 Trae hooks 配置：国内版读写 `~/.trae-cn/hooks.json`，国际版为 `~/.trae/hooks.json`。
/// 两版共用同一套 `version: 1` + 六个事件的新协议。
enum TraeHookConfiguration {
    static let relativeConfigPath = ".trae-cn/hooks.json"
    /// 国内版在前，国际版在后；写入时只为已安装（目录存在）的发行版创建配置。
    static let relativeConfigPaths = [relativeConfigPath, ".trae/hooks.json"]
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
        for event in oldArguments.keys {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            let retained = try entries.filter { entry in
                // 已合法使用新分组形式的未知事件保持原样；仅认领旧版完整命令形状。
                if entry["hooks"] != nil { return true }
                // 旧版各事件的 --hook 参数并不统一（例如 stop 曾写 notification），
                // 只要命令确实指向本桥接的 trae agent 就认领，避免迁移因参数差异整体失败。
                guard let command = entry["command"] as? String,
                      let range = command.range(of: " --agent trae --hook") else {
                    throw ConfigurationError.unsupportedLegacyEntry
                }
                let path = String(command[..<range.lowerBound])
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
