import Foundation

/// 只变换明确选中的 custom Agent 条目；调用方自行审查并写回编辑器的 agent_servers。
public enum ACPCustomAgentConfiguration {
    public enum ConfigurationError: Error { case invalidEntry, invalidBridge, invalidSource, notCustomAgent }

    public static func wrapping(_ entry: [String: Any], host: String, source: String, bridgePath: String) throws -> [String: Any] {
        guard ["zed", "jetbrains_ai"].contains(host), !source.isEmpty, source.utf8.count <= 4096,
              !source.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ConfigurationError.invalidSource }
        guard bridgePath.hasPrefix("/"), !bridgePath.utf8.contains(0), isBridge(bridgePath) else { throw ConfigurationError.invalidBridge }
        guard JSONSerialization.isValidJSONObject(entry), let command = entry["command"] as? String,
              !command.isEmpty, !command.utf8.contains(0), !command.hasPrefix("~") else { throw ConfigurationError.invalidEntry }
        if host == "zed", entry["type"] as? String != "custom" { throw ConfigurationError.notCustomAgent }
        if let type = entry["type"] as? String, type != "custom" { throw ConfigurationError.notCustomAgent }
        if let value = entry["args"], !(value is [String]) { throw ConfigurationError.invalidEntry }
        let arguments = entry["args"] as? [String] ?? []
        guard arguments.allSatisfy({ !$0.utf8.contains(0) }) else { throw ConfigurationError.invalidEntry }
        var result = try unwrapping(entry, host: host, source: source)
        let originalCommand = result["command"] as! String
        guard !isBridge(originalCommand) else { throw ConfigurationError.invalidEntry }
        let originalArguments = result["args"] as? [String] ?? []
        result["command"] = bridgePath
        result["args"] = ["acp", "--host", host, "--source", source, "--", originalCommand] + originalArguments
        return result
    }

    public static func unwrapping(_ entry: [String: Any], host: String, source: String) throws -> [String: Any] {
        guard let command = entry["command"] as? String, isBridge(command),
              let arguments = entry["args"] as? [String], arguments.count >= 7,
              Array(arguments.prefix(6)) == ["acp", "--host", host, "--source", source, "--"] else { return entry }
        guard !arguments[6].isEmpty, !arguments[6].utf8.contains(0), !isBridge(arguments[6]) else { throw ConfigurationError.invalidEntry }
        var result = entry
        result["command"] = arguments[6]
        result["args"] = Array(arguments.dropFirst(7))
        return result
    }

    private static func isBridge(_ command: String) -> Bool {
        command.hasPrefix("/") && ["di-bridge", "DIBridge"].contains((command as NSString).lastPathComponent)
    }
}
