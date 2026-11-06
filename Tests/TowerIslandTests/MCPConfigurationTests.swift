import Foundation
import XCTest
@testable import XIsland

final class MCPConfigurationTests: XCTestCase {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("xisland-mcp-config-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ value: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    func testJSONClientsAddOwnedEntryWithoutLosingExistingServers() throws {
        let cases: [(AgentType, String, String)] = [
            (.claudeCode, ".claude", ".claude.json"),
            (.geminiCli, ".gemini", ".gemini/settings.json"),
            (.cursor, ".cursor", ".cursor/mcp.json"),
            (.qwen, ".qwen", ".qwen/settings.json"),
        ]
        for (agent, directory, file) in cases {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try FileManager.default.createDirectory(at: home.appendingPathComponent(directory),
                                                    withIntermediateDirectories: true)
            let url = home.appendingPathComponent(file)
            try write(["mcpServers": ["other": ["command": "other-server"]]], to: url)
            let bridge = home.appendingPathComponent(".xisland/bin/di-bridge").path

            XCTAssertFalse(MCPConfigurationManager.isConfigured(for: agent, bridgePath: bridge, homeDirectory: home))
            XCTAssertTrue(try MCPConfigurationManager.configure(agent, bridgePath: bridge, homeDirectory: home,
                                                                 requireConsent: false))
            XCTAssertTrue(MCPConfigurationManager.isConfigured(for: agent, bridgePath: bridge, homeDirectory: home))
            let config = try HookConfigurationFile.read(at: url)
            let servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
            XCTAssertNotNil(servers["other"])
            XCTAssertNotNil(servers[MCPConfigurationManager.serverName])
            XCTAssertFalse(try MCPConfigurationManager.configure(agent, bridgePath: bridge, homeDirectory: home,
                                                                  requireConsent: false))

            XCTAssertTrue(try MCPConfigurationManager.remove(agent, homeDirectory: home))
            let cleaned = try HookConfigurationFile.read(at: url)
            let remaining = try XCTUnwrap(cleaned["mcpServers"] as? [String: Any])
            XCTAssertNotNil(remaining["other"])
            XCTAssertNil(remaining[MCPConfigurationManager.serverName])
        }
    }

    func testOpenCodeUsesLocalCommandArray() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".config/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("opencode.json")
        try write(["mcp": ["other": ["type": "local", "command": ["other"], "enabled": true]]], to: url)
        let bridge = home.appendingPathComponent(".xisland/bin/di-bridge").path

        XCTAssertTrue(try MCPConfigurationManager.configure(.openCode, bridgePath: bridge, homeDirectory: home,
                                                             requireConsent: false))
        let config = try HookConfigurationFile.read(at: url)
        let servers = try XCTUnwrap(config["mcp"] as? [String: Any])
        let entry = try XCTUnwrap(servers[MCPConfigurationManager.serverName] as? [String: Any])
        XCTAssertEqual(entry["command"] as? [String], [bridge, "mcp-server", "--agent", "opencode"])
        XCTAssertEqual(entry["type"] as? String, "local")
    }

    func testCodexTOMLIsIdempotentAndPreservesUnrelatedConfig() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.toml")
        try "model = \"gpt-test\"\n\n[mcp_servers.other]\ncommand = \"other\"\n".write(to: url, atomically: true, encoding: .utf8)
        let bridge = home.appendingPathComponent(".xisland/bin/di-bridge").path

        XCTAssertTrue(try MCPConfigurationManager.configure(.codex, bridgePath: bridge, homeDirectory: home,
                                                             requireConsent: false))
        XCTAssertTrue(MCPConfigurationManager.isConfigured(for: .codex, bridgePath: bridge, homeDirectory: home))
        XCTAssertFalse(try MCPConfigurationManager.configure(.codex, bridgePath: bridge, homeDirectory: home,
                                                              requireConsent: false))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("model = \"gpt-test\""))
        XCTAssertTrue(text.contains("[mcp_servers.other]"))
        XCTAssertEqual(text.components(separatedBy: "[mcp_servers.xisland_approval_graph]").count, 2)

        XCTAssertTrue(try MCPConfigurationManager.remove(.codex, homeDirectory: home))
        let cleaned = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(cleaned.contains("[mcp_servers.xisland_approval_graph]"))
        XCTAssertTrue(cleaned.contains("[mcp_servers.other]"))
    }

    func testExistingUserEntryWithSameNameIsPreserved() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"),
                                                withIntermediateDirectories: true)
        let url = home.appendingPathComponent(".claude.json")
        try write(["mcpServers": [MCPConfigurationManager.serverName: ["command": "custom"]]], to: url)
        XCTAssertThrowsError(try MCPConfigurationManager.configure(
            .claudeCode, bridgePath: "/tmp/di-bridge", homeDirectory: home, requireConsent: false
        )) {
            XCTAssertEqual($0 as? MCPConfigurationManager.ConfigurationError, .userOwnedEntry)
        }
        let config = try HookConfigurationFile.read(at: url)
        let servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
        let entry = try XCTUnwrap(servers[MCPConfigurationManager.serverName] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, "custom")
    }

    func testConsentIsBoundToServerDefinitionAndCanBeDeclined() {
        let suite = "dev.xisland.tests.mcp-consent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bridge = "/tmp/xisland/di-bridge"

        XCTAssertNil(MCPConfigurationManager.consentDecision(for: .codex, bridgePath: bridge, defaults: defaults))
        MCPConfigurationManager.recordConsent(false, for: [.codex], bridgePath: bridge, defaults: defaults)
        XCTAssertEqual(MCPConfigurationManager.consentDecision(for: .codex, bridgePath: bridge, defaults: defaults), false)
        XCTAssertFalse(MCPConfigurationManager.isConsentGranted(for: .codex, bridgePath: bridge, defaults: defaults))

        MCPConfigurationManager.recordConsent(true, for: [.codex], bridgePath: bridge, defaults: defaults)
        XCTAssertEqual(MCPConfigurationManager.consentDecision(for: .codex, bridgePath: bridge, defaults: defaults), true)
        XCTAssertNotEqual(
            MCPConfigurationManager.consentFingerprint(for: .codex, bridgePath: bridge),
            MCPConfigurationManager.consentFingerprint(for: .codex, bridgePath: "/tmp/other/di-bridge")
        )
    }

    func testConfigurationCannotWriteBeforeConsent() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let suite = "dev.xisland.tests.mcp-write-consent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = home.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("mcp.json")
        let bridge = home.appendingPathComponent(".xisland/bin/di-bridge").path

        XCTAssertThrowsError(try MCPConfigurationManager.configure(
            .cursor, bridgePath: bridge, homeDirectory: home, defaults: defaults
        )) {
            XCTAssertEqual($0 as? MCPConfigurationManager.ConfigurationError, .consentRequired)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        MCPConfigurationManager.recordConsent(true, for: [.cursor], bridgePath: bridge,
                                              homeDirectory: home, defaults: defaults)
        XCTAssertTrue(try MCPConfigurationManager.configure(
            .cursor, bridgePath: bridge, homeDirectory: home, defaults: defaults
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testClientEnvironmentOverridesResolveTheWritableConfiguration() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appendingPathComponent("custom-codex", isDirectory: true)
        let claude = home.appendingPathComponent("custom-claude", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let environment = ["CODEX_HOME": codex.path, "CLAUDE_CONFIG_DIR": claude.path]
        let bridge = home.appendingPathComponent(".xisland/bin/di-bridge").path

        XCTAssertEqual(MCPConfigurationManager.configurationPath(
            for: .codex, homeDirectory: home, environment: environment
        ), codex.appendingPathComponent("config.toml").path)
        XCTAssertEqual(MCPConfigurationManager.configurationPath(
            for: .claudeCode, homeDirectory: home, environment: environment
        ), claude.appendingPathComponent(".claude.json").path)
        XCTAssertTrue(try MCPConfigurationManager.configure(
            .codex, bridgePath: bridge, homeDirectory: home,
            environment: environment, requireConsent: false
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: codex.appendingPathComponent("config.toml").path
        ))
    }

    func testCodexRequiresExactOwnedBlockAndPreservesUnrelatedWhitespace() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.toml")
        let bridge = home.appendingPathComponent(".xisland/bin/di-bridge").path
        let original = """
        notes = \"\"\"line1


        line4\"\"\"

        [mcp_servers.other]
        command = "other"
        """
        try original.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertTrue(try MCPConfigurationManager.configure(.codex, bridgePath: bridge,
                                                             homeDirectory: home, requireConsent: false))
        XCTAssertTrue(try MCPConfigurationManager.remove(.codex, homeDirectory: home))
        let restored = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(restored.contains("notes = \"\"\"line1\n\n\nline4\"\"\""))
        XCTAssertFalse(restored.contains(MCPConfigurationManager.serverName))

        let tampered = """
        # BEGIN X Island approval graph MCP
        [mcp_servers.xisland_approval_graph]
        command = "/tmp/wrong-binary"
        args = ["mcp-server", "--agent", "codex"]
        # END X Island approval graph MCP
        """
        try tampered.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(MCPConfigurationManager.isConfigured(for: .codex, bridgePath: bridge,
                                                             homeDirectory: home))
        XCTAssertThrowsError(try MCPConfigurationManager.configure(
            .codex, bridgePath: bridge, homeDirectory: home, requireConsent: false
        )) {
            XCTAssertEqual($0 as? MCPConfigurationManager.ConfigurationError, .userOwnedEntry)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), tampered)
    }

    func testExtraJSONFieldsRemainOwnedByTheUser() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".config/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("opencode.json")
        let bridge = home.appendingPathComponent(".xisland/bin/di-bridge").path
        try write(["mcp": [MCPConfigurationManager.serverName: [
            "type": "local",
            "command": [bridge, "mcp-server", "--agent", "opencode"],
            "enabled": false,
        ]]], to: url)

        XCTAssertFalse(MCPConfigurationManager.isConfigured(
            for: .openCode, bridgePath: bridge, homeDirectory: home
        ))
        XCTAssertFalse(try MCPConfigurationManager.remove(.openCode, homeDirectory: home))
        let config = try HookConfigurationFile.read(at: url)
        let servers = try XCTUnwrap(config["mcp"] as? [String: Any])
        XCTAssertNotNil(servers[MCPConfigurationManager.serverName])
    }
}
