import Foundation
import Darwin

enum AmazonQAgentConfiguration {
    enum ConfigurationError: Error { case invalidAgent, invalidHooks, invalidBridge }
    static let events = ["agentSpawn", "userPromptSubmit", "preToolUse", "postToolUse", "stop"]

    static func addingObservation(to agent: [String: Any], bridgePath: String) throws -> [String: Any] {
        guard let name = agent["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              JSONSerialization.isValidJSONObject(agent) else { throw ConfigurationError.invalidAgent }
        guard bridgePath.hasPrefix("/"), !bridgePath.utf8.contains(0), !bridgePath.contains("\n") else { throw ConfigurationError.invalidBridge }
        var hooks: [String: Any] = [:]
        if let existing = agent["hooks"] {
            guard let dictionary = existing as? [String: Any] else { throw ConfigurationError.invalidHooks }
            hooks = dictionary
        }
        for event in events {
            let command = AiderLauncher.shellQuote(bridgePath) + " amazonq-hook-1-19-7 " + event
            var entries: [[String: Any]] = []
            if let existing = hooks[event] {
                guard let array = existing as? [[String: Any]], array.allSatisfy({ $0["command"] is String }) else {
                    throw ConfigurationError.invalidHooks
                }
                entries = array
            }
            if !entries.contains(where: { $0["command"] as? String == command }) {
                entries.append(["command": command, "timeout_ms": 1000, "max_output_size": 1024, "cache_ttl_seconds": 0])
            }
            hooks[event] = entries
        }
        var result = agent
        result["hooks"] = hooks
        return result
    }

    static func run(arguments: [String], bridgePath: String) -> Int32 {
        guard arguments.isEmpty, isatty(STDIN_FILENO) == 0 else { return 64 }
        do {
            var data = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 16_384), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= 1_048_576 else { throw ConfigurationError.invalidAgent }
            }
            guard let agent = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bridge = AiderLauncher.executablePath(bridgePath, environment: ProcessInfo.processInfo.environment) else {
                throw ConfigurationError.invalidAgent
            }
            let result = try addingObservation(to: agent, bridgePath: bridge)
            var output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            output.append(10)
            try FileHandle.standardOutput.write(contentsOf: output)
            return 0
        } catch {
            fputs("[XIsland] 无法生成旧 Q agent 观察配置；输入需为单个 agent JSON，未修改任何文件。\n", stderr)
            return 65
        }
    }
}
