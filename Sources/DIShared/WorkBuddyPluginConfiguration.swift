import Foundation

/// 仅生成可审阅的插件文件内容，不安装、启用插件或修改客户端信任。
public enum WorkBuddyPluginConfiguration {
    public enum ConfigurationError: Error { case invalidBridgePath }
    public static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                                "Stop", "FinalStop", "SessionEnd", "SubagentStart", "SubagentStop", "Notification"]

    public static func files(bridgePath: String) throws -> [String: Data] {
        guard bridgePath.hasPrefix("/"), !bridgePath.utf8.contains(0), !bridgePath.contains("\n") else {
            throw ConfigurationError.invalidBridgePath
        }
        let quotedPath = "'" + bridgePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let hooks = Dictionary(uniqueKeysWithValues: events.map { event in
            (event, [["hooks": [["type": "command", "command": quotedPath
                + " --agent workbuddy --adapter workbuddy_5_7_6 --hook " + event, "timeout": 3]]]])
        })
        let manifest = ["name": "xisland-workbuddy-observer", "version": "0.1.0",
            "description": "XIsland observation contract reviewed against WorkBuddy 5.7.6 and 5.7.7. Native client acceptance pending; no permission decisions."]
        let marketplace: [String: Any] = ["name": "xisland-workbuddy-local", "owner": ["name": "XIsland"],
            "plugins": [["name": manifest["name"]!, "source": "./", "version": manifest["version"]!,
                         "description": manifest["description"]!]]]
        return [".codebuddy-plugin/plugin.json": try encode(manifest), "hooks/hooks.json": try encode(["hooks": hooks]),
                ".codebuddy-plugin/marketplace.json": try encode(marketplace)]
    }

    private static func encode(_ object: Any) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(10)
        return data
    }
}
