import CryptoKit
import Foundation
import DIShared

/// Adds the local approval-graph MCP server to clients whose configuration
/// formats are stable and can be edited without replacing unrelated entries.
enum MCPConfigurationManager {
    enum ConfigurationError: LocalizedError, Equatable {
        case unsupportedClient
        case invalidContainer
        case userOwnedEntry
        case missingClientDirectory
        case consentRequired

        var errorDescription: String? {
            switch self {
            case .unsupportedClient: return "This client does not support automatic MCP configuration."
            case .invalidContainer: return "The client's MCP configuration container has an unexpected shape."
            case .userOwnedEntry: return "A non-X Island MCP entry already uses this server name."
            case .missingClientDirectory: return "The client configuration directory does not exist."
            case .consentRequired: return "MCP registration requires explicit user consent for this server definition."
            }
        }
    }

    private enum Format {
        case json(url: URL, key: String, openCode: Bool = false)
        case codexTOML(url: URL)
    }

    private struct Target {
        let agent: AgentType
        let format: Format
        let clientDirectory: URL
    }

    static let serverName = "xisland_approval_graph"
    static let consentKeyPrefix = "approvalGraphMCPConsent."
    static let declinedKeyPrefix = "approvalGraphMCPDeclined."
    private static let beginMarker = "# BEGIN X Island approval graph MCP"
    private static let endMarker = "# END X Island approval graph MCP"
    private static let automaticAgents: [AgentType] = [
        .codex, .claudeCode, .geminiCli, .cursor, .qwen
    ]
    private static let cleanupAgents: [AgentType] = automaticAgents + [.openCode]

    static func supportedAgents(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                                environment: [String: String] = ProcessInfo.processInfo.environment)
        -> [AgentType] {
        automaticAgents.filter {
            target(for: $0, homeDirectory: homeDirectory, environment: environment) != nil
        }
    }

    static func isSupported(_ agent: AgentType) -> Bool {
        supportedAgents().contains(agent)
    }

    static func consentFingerprint(for agent: AgentType, bridgePath: String,
                                   homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let server = jsonServer(agent: agent, bridgePath: bridgePath, openCode: agent == .openCode)
        let definition = (try? JSONSerialization.data(withJSONObject: server, options: [.sortedKeys])) ?? Data()
        let path = configurationPath(for: agent, homeDirectory: homeDirectory,
                                     environment: environment) ?? "unsupported"
        let data = Data(agent.rawValue.utf8) + Data([0]) + Data(path.utf8) + Data([0]) + definition
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isConsentGranted(for agent: AgentType, bridgePath: String,
                                 homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 environment: [String: String] = ProcessInfo.processInfo.environment,
                                 defaults: UserDefaults = AppPreferences.defaults) -> Bool {
        defaults.string(forKey: consentKeyPrefix + agent.rawValue)
            == consentFingerprint(for: agent, bridgePath: bridgePath,
                                  homeDirectory: homeDirectory, environment: environment)
    }

    static func consentDecision(for agent: AgentType, bridgePath: String,
                                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                                environment: [String: String] = ProcessInfo.processInfo.environment,
                                defaults: UserDefaults = AppPreferences.defaults) -> Bool? {
        let fingerprint = consentFingerprint(for: agent, bridgePath: bridgePath,
                                             homeDirectory: homeDirectory, environment: environment)
        if defaults.string(forKey: consentKeyPrefix + agent.rawValue) == fingerprint { return true }
        if defaults.string(forKey: declinedKeyPrefix + agent.rawValue) == fingerprint { return false }
        return nil
    }

    static func recordConsent(_ granted: Bool, for agents: [AgentType], bridgePath: String,
                              homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              defaults: UserDefaults = AppPreferences.defaults) {
        for agent in agents {
            let fingerprint = consentFingerprint(for: agent, bridgePath: bridgePath,
                                                 homeDirectory: homeDirectory, environment: environment)
            let consentKey = consentKeyPrefix + agent.rawValue
            let declinedKey = declinedKeyPrefix + agent.rawValue
            if granted {
                defaults.set(fingerprint, forKey: consentKey)
                defaults.removeObject(forKey: declinedKey)
            } else {
                defaults.removeObject(forKey: consentKey)
                defaults.set(fingerprint, forKey: declinedKey)
            }
        }
    }

    static func removeConsent(for agent: AgentType, defaults: UserDefaults = AppPreferences.defaults) {
        defaults.removeObject(forKey: consentKeyPrefix + agent.rawValue)
        defaults.removeObject(forKey: declinedKeyPrefix + agent.rawValue)
    }

    static func canRemove(_ agent: AgentType) -> Bool {
        cleanupAgents.contains(agent)
    }

    static func presentClientAgents(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                                    environment: [String: String] = ProcessInfo.processInfo.environment)
        -> [AgentType] {
        supportedAgents(homeDirectory: homeDirectory, environment: environment).filter {
            guard let target = target(for: $0, homeDirectory: homeDirectory, environment: environment) else {
                return false
            }
            return FileManager.default.fileExists(atPath: target.clientDirectory.path)
        }
    }

    static func configurationPath(for agent: AgentType,
                                  homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let target = target(for: agent, homeDirectory: homeDirectory, environment: environment) else {
            return nil
        }
        switch target.format {
        case let .json(url, _, _), let .codexTOML(url):
            return url.path
        }
    }

    static func isConfigured(for agent: AgentType,
                             bridgePath: String,
                             homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let target = target(for: agent, homeDirectory: homeDirectory,
                                  environment: environment) else { return false }
        switch target.format {
        case let .json(url, key, openCode):
            guard let config = try? HookConfigurationFile.read(at: url),
                  let servers = config[key] as? [String: Any],
                  let entry = servers[serverName] as? [String: Any] else { return false }
            return isOwned(entry, agent: agent, bridgePath: bridgePath, openCode: openCode)
        case let .codexTOML(url):
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return codexEntryIsExact(in: text, bridgePath: bridgePath, agent: agent)
        }
    }

    @discardableResult
    static func configure(_ agent: AgentType, bridgePath: String,
                          homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                          environment: [String: String] = ProcessInfo.processInfo.environment,
                          defaults: UserDefaults = AppPreferences.defaults,
                          requireConsent: Bool = true) throws -> Bool {
        guard !Task.isCancelled else { return false }
        guard requireConsent == false || isConsentGranted(
            for: agent, bridgePath: bridgePath, homeDirectory: homeDirectory,
            environment: environment, defaults: defaults
        ) else { throw ConfigurationError.consentRequired }
        guard let target = target(for: agent, homeDirectory: homeDirectory, environment: environment) else {
            throw ConfigurationError.unsupportedClient
        }
        guard FileManager.default.fileExists(atPath: target.clientDirectory.path) else {
            throw ConfigurationError.missingClientDirectory
        }
        if isConfigured(for: agent, bridgePath: bridgePath, homeDirectory: homeDirectory,
                        environment: environment) {
            return false
        }
        switch target.format {
        case let .json(url, key, openCode):
            return try HookConfigurationFile.update(at: url, preservingTopLevelKey: key) { config in
                var config = config
                if let existing = config[key], !(existing is [String: Any]) {
                    throw ConfigurationError.invalidContainer
                }
                var servers = config[key] as? [String: Any] ?? [:]
                let desired = jsonServer(agent: agent, bridgePath: bridgePath, openCode: openCode)
                if let existing = servers[serverName] as? [String: Any],
                   !isOwned(existing, agent: agent, bridgePath: bridgePath, openCode: openCode) {
                    throw ConfigurationError.userOwnedEntry
                }
                servers[serverName] = desired
                config[key] = servers
                return config
            }
        case let .codexTOML(url):
            return try HookConfigurationFile.updateText(at: url) { original in
                let expected = codexEntry(bridgePath: bridgePath, agent: agent)
                if codexEntryIsExact(in: original, bridgePath: bridgePath, agent: agent) { return original }
                let withoutOwned = removingCodexEntry(from: original, bridgePath: bridgePath, agent: agent)
                if withoutOwned != original,
                   withoutOwned.contains("[mcp_servers.\(serverName)]") {
                    throw ConfigurationError.userOwnedEntry
                }
                if original.contains(beginMarker) || original.contains(endMarker)
                    || original.contains("[mcp_servers.\(serverName)]") {
                    throw ConfigurationError.userOwnedEntry
                }
                let separator = withoutOwned.isEmpty || withoutOwned.hasSuffix("\n") ? "" : "\n"
                return withoutOwned + separator + expected
            }
        }
    }

    @discardableResult
    static func remove(_ agent: AgentType,
                       homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                       environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Bool {
        guard let target = target(for: agent, homeDirectory: homeDirectory,
                                  environment: environment) else { return false }
        switch target.format {
        case let .json(url, key, openCode):
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            return try HookConfigurationFile.update(at: url, preservingTopLevelKey: key) { config in
                var config = config
                guard var servers = config[key] as? [String: Any],
                      let existing = servers[serverName] as? [String: Any] else { return config }
                guard isOwned(existing, agent: agent, bridgePath: bridgePath(homeDirectory: homeDirectory),
                              openCode: openCode) else { return config }
                servers.removeValue(forKey: serverName)
                config[key] = servers
                return config
            }
        case let .codexTOML(url):
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            return try HookConfigurationFile.updateText(at: url) {
                removingCodexEntry(from: $0, bridgePath: bridgePath(homeDirectory: homeDirectory), agent: agent)
            }
        }
    }

    static func expectedDefinition(for agent: AgentType, bridgePath: String,
                                   homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let target = target(for: agent, homeDirectory: homeDirectory,
                                  environment: environment) else { return nil }
        switch target.format {
        case .json(_, _, let openCode):
            let value = jsonServer(agent: agent, bridgePath: bridgePath, openCode: openCode)
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        case .codexTOML:
            return codexEntry(bridgePath: bridgePath, agent: agent)
        }
    }

    private static func target(for agent: AgentType, homeDirectory: URL,
                               environment: [String: String]) -> Target? {
        let home = homeDirectory
        switch agent {
        case .codex:
            let directory = absoluteEnvironmentPath("CODEX_HOME", environment: environment)
                ?? home.appendingPathComponent(".codex", isDirectory: true)
            return Target(agent: agent,
                          format: .codexTOML(url: directory.appendingPathComponent("config.toml")),
                          clientDirectory: directory)
        case .claudeCode:
            let override = absoluteEnvironmentPath("CLAUDE_CONFIG_DIR", environment: environment)
            return Target(agent: agent,
                          format: .json(url: override?.appendingPathComponent(".claude.json")
                            ?? home.appendingPathComponent(".claude.json"), key: "mcpServers"),
                          clientDirectory: override ?? home.appendingPathComponent(".claude", isDirectory: true))
        case .geminiCli:
            return Target(agent: agent,
                          format: .json(url: home.appendingPathComponent(".gemini/settings.json"), key: "mcpServers"),
                          clientDirectory: home.appendingPathComponent(".gemini", isDirectory: true))
        case .cursor:
            return Target(agent: agent,
                          format: .json(url: home.appendingPathComponent(".cursor/mcp.json"), key: "mcpServers"),
                          clientDirectory: home.appendingPathComponent(".cursor", isDirectory: true))
        case .qwen:
            return Target(agent: agent,
                          format: .json(url: home.appendingPathComponent(".qwen/settings.json"), key: "mcpServers"),
                          clientDirectory: home.appendingPathComponent(".qwen", isDirectory: true))
        case .openCode:
            return Target(agent: agent,
                          format: .json(url: home.appendingPathComponent(".config/opencode/opencode.json"),
                                        key: "mcp", openCode: true),
                          clientDirectory: home.appendingPathComponent(".config/opencode", isDirectory: true))
        default:
            return nil
        }
    }

    private static func absoluteEnvironmentPath(_ key: String,
                                                environment: [String: String]) -> URL? {
        guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }

    private static func jsonServer(agent: AgentType, bridgePath: String,
                                   openCode: Bool) -> [String: Any] {
        if openCode {
            return [
                "type": "local",
                "command": [bridgePath, "mcp-server", "--agent", agent.rawValue],
                "enabled": true,
            ]
        }
        return [
            "type": "stdio",
            "command": bridgePath,
            "args": ApprovalGraphMCPIdentity.arguments(agent: agent.rawValue),
        ]
    }

    private static func isOwned(_ entry: [String: Any], agent: AgentType,
                                bridgePath: String, openCode: Bool) -> Bool {
        let expected = jsonServer(agent: agent, bridgePath: bridgePath, openCode: openCode)
        return NSDictionary(dictionary: entry).isEqual(to: expected)
    }

    private static func bridgePath(homeDirectory: URL) -> String {
        homeDirectory.appendingPathComponent(".xisland/bin/di-bridge").path
    }

    private static func codexEntry(bridgePath: String, agent: AgentType) -> String {
        let escaped = tomlString(bridgePath)
        return """
        \(beginMarker)
        [mcp_servers.\(serverName)]
        command = "\(escaped)"
        args = ["mcp-server", "--agent", "\(agent.rawValue)"]
        \(endMarker)
        """
    }

    private static func removingCodexEntry(from text: String, bridgePath: String,
                                           agent: AgentType) -> String {
        let exact = codexEntry(bridgePath: bridgePath, agent: agent)
        if let range = text.range(of: exact),
           text.components(separatedBy: exact).count == 2 {
            var result = text
            result.removeSubrange(range)
            return result
        }

        // Do not overwrite a table that may have been authored independently.
        // Only remove a legacy X Island table whose command and args are exact.
        let lines = text.components(separatedBy: "\n")
        guard let headerIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "[mcp_servers.\(serverName)]"
        }) else { return text }
        var endIndex = lines.count
        for index in (headerIndex + 1)..<lines.count where lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            endIndex = index
            break
        }
        let body = lines[(headerIndex + 1)..<endIndex].joined(separator: "\n")
        guard body.contains("command = \"\(tomlString(bridgePath))\""),
              body.contains("args = [\"mcp-server\", \"--agent\", \"\(agent.rawValue)\"]") else {
            return text
        }
        let remaining = Array(lines[..<headerIndex] + lines[endIndex...])
        return remaining.joined(separator: "\n")
    }

    private static func codexEntryIsExact(in text: String, bridgePath: String,
                                          agent: AgentType) -> Bool {
        let expected = codexEntry(bridgePath: bridgePath, agent: agent)
        return text.components(separatedBy: expected).count == 2
            && text.components(separatedBy: "[mcp_servers.\(serverName)]").count == 2
    }

    private static func tomlString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
