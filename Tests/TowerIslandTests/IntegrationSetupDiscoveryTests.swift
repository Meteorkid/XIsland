import XCTest
import os
@testable import XIsland

@MainActor
final class IntegrationSetupDiscoveryTests: XCTestCase {
    func testScansEverySupportedAgentButDoesNotInventInstallations() {
        let configurationReads = OSAllocatedUnfairLock(initialState: 0)
        let entries = IntegrationSetupDiscovery.scan(environment: environment(configured: { _ in
            configurationReads.withLock { $0 += 1 }
            return true
        }))
        XCTAssertEqual(Set(entries.map(\.agent)), Set(AgentType.allCases.filter(\.isSupported)))
        XCTAssertFalse(entries.contains { $0.agent == .hermes })
        XCTAssertFalse(entries.contains { $0.installed || $0.configured || $0.canAutoConfigure })
        XCTAssertEqual(configurationReads.withLock { $0 }, 0)
    }

    func testOldConfigurationDirectoriesDoNotProveInstallation() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for directory in [".codex", ".claude", ".kimi", ".qwen", ".trae-cn", ".kiro", ".codebuddy"] {
            let url = home.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url.appendingPathComponent("settings.json"))
        }
        XCTAssertFalse(IntegrationSetupDiscovery.scan(environment: environment(home: home)).contains(where: \.installed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".xisland").path))
    }

    func testDiscoversStandardLocalBinaryWithoutExecutingIt() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sentinel = home.appendingPathComponent("executed")
        try "#!/bin/sh\ntouch '\(sentinel.path)'\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let entry = try find(.claudeCode, in: environment(home: home, executablePaths: [binary.path]))
        XCTAssertTrue(entry.installed)
        XCTAssertTrue(entry.canAutoConfigure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".xisland").path))
    }

    func testIgnoresRelativePathDirectories() throws {
        let entry = try find(.claudeCode, in: environment(path: ".:bin", executablePaths: ["bin/claude", "./claude"]))
        XCTAssertFalse(entry.installed)
    }

    func testCodexPrefersDesktopCoreOverPathBinary() throws {
        let app = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let embedded = app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        let entry = try find(.codex, in: environment(applications: ["com.openai.codex": app],
            executablePaths: [embedded.path, "/opt/homebrew/bin/codex"]))
        XCTAssertTrue(entry.installed)
        XCTAssertEqual(entry.appURL, app)
        XCTAssertEqual(entry.codexBinary, embedded)
    }

    func testCodexCanUseStandaloneBinary() throws {
        let entry = try find(.codex, in: environment(executablePaths: ["/fixture/bin/codex"]))
        XCTAssertTrue(entry.installed)
        XCTAssertNil(entry.appURL)
        XCTAssertEqual(entry.codexBinary?.path, "/fixture/bin/codex")
    }

    func testOnlyTraeCNIsAutomaticallyConfigured() throws {
        for id in ["com.trae.app", "cn.trae.solo.app", "cn.trae.work.app", "cn.trae.app"] {
            let entry = try find(.trae, in: environment(applications: [id: URL(fileURLWithPath: "/Applications/Trae.app")]))
            XCTAssertTrue(entry.installed)
            XCTAssertEqual(entry.canAutoConfigure, id == "cn.trae.app")
        }
    }

    func testManualIntegrationsNeedRealInstallationEvidence() throws {
        let environment = environment(applications: ["com.tencent.workbuddy.mac": URL(fileURLWithPath: "/Applications/WorkBuddy.app")],
                                      executablePaths: ["/fixture/bin/kiro-cli"])
        for agent in [AgentType.workBuddy, .kiro] {
            let entry = try find(agent, in: environment)
            XCTAssertTrue(entry.installed)
            XCTAssertFalse(entry.canAutoConfigure)
        }
        XCTAssertFalse(try find(.glm, in: environment).installed)
    }

    func testChangingTraeEditionInvalidatesPreviouslyObservedConfiguration() throws {
        let cn = try find(.trae, in: environment(applications: ["cn.trae.app": URL(fileURLWithPath: "/Applications/Trae CN.app")], configured: { _ in true }))
        let international = try find(.trae, in: environment(applications: ["com.trae.app": URL(fileURLWithPath: "/Applications/Trae.app")], configured: { _ in true }))
        XCTAssertNotEqual(cn.fingerprint, international.fingerprint)
        XCTAssertFalse(international.canAutoConfigure)
    }

    func testContinueServeAndQchatAreDetectedAsManualRoutes() throws {
        let environment = environment(executablePaths: ["/fixture/bin/cn", "/fixture/bin/qchat"])
        for agent in [AgentType.continue, .amazonQ] {
            let entry = try find(agent, in: environment)
            XCTAssertTrue(entry.installed)
            XCTAssertFalse(entry.canAutoConfigure)
        }
        let legacy = try find(.amazonQ, in: self.environment(executablePaths: ["/fixture/bin/q"]))
        XCTAssertTrue(legacy.detail?.contains("qchat 1.19.7") ?? false)
    }

    func testVSCodeNeedsCopilotExtensionAndProvidesHostForExtensions() throws {
        let app = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        XCTAssertFalse(try find(.copilot, in: environment(applications: ["com.microsoft.VSCode": app])).installed)
        let environment = environment(applications: ["com.microsoft.VSCode": app],
                                      extensions: ["GitHub.copilot-chat", "saoudrizwan.claude-dev"])
        for agent in [AgentType.copilot, .cline] {
            let entry = try find(agent, in: environment)
            XCTAssertTrue(entry.installed)
            XCTAssertTrue(entry.canAutoConfigure)
            XCTAssertEqual(entry.appURL, app)
        }
    }

    func testTabnineExtensionAndOldDeepseekAreNotAutomaticallyConfigured() throws {
        let entries = IntegrationSetupDiscovery.scan(environment: environment(executablePaths: ["/fixture/bin/deepseek"],
                                                                             extensions: ["tabnine.tabnine-vscode"]))
        for agent in [AgentType.tabnine, .deepseek] {
            let entry = try XCTUnwrap(entries.first { $0.agent == agent })
            XCTAssertTrue(entry.installed)
            XCTAssertFalse(entry.canAutoConfigure)
        }
        XCTAssertTrue(try find(.deepseek, in: environment(executablePaths: ["/fixture/bin/codewhale"])).canAutoConfigure)
    }

    func testExtensionDiscoveryRequiresARealManifest() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = home.appendingPathComponent(".vscode/extensions/saoudrizwan.claude-dev-99")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        XCTAssertTrue(IntegrationSetupDiscovery.installedExtensionIDs(home: home).isEmpty)
        try Data("{\"publisher\":\"saoudrizwan\",\"name\":\"claude-dev\"}".utf8)
            .write(to: fake.appendingPathComponent("package.json"))
        XCTAssertEqual(IntegrationSetupDiscovery.installedExtensionIDs(home: home), ["saoudrizwan.claude-dev"])
    }

    func testFingerprintOnlyTracksOwnedDefinitionAndConfiguredState() throws {
        let unconfigured = try find(.codex, in: environment(executablePaths: ["/fixture/bin/codex"]))
        let configured = try find(.codex, in: environment(executablePaths: ["/fixture/bin/codex"], configured: { _ in true }))
        XCTAssertNotEqual(unconfigured.fingerprint, configured.fingerprint)
        let movedBinary = try find(.codex, in: environment(executablePaths: ["/opt/homebrew/bin/codex"]))
        XCTAssertEqual(unconfigured.fingerprint, movedBinary.fingerprint)
        let movedHome = try find(.codex, in: environment(home: URL(fileURLWithPath: "/different-home"),
                                                       executablePaths: ["/fixture/bin/codex"]))
        XCTAssertNotEqual(unconfigured.fingerprint, movedHome.fingerprint)
        XCTAssertEqual(unconfigured.fingerprint.count, 64)
        let manual = try find(.kiro, in: environment(executablePaths: ["/fixture/bin/kiro-cli"]))
        let manualMoved = try find(.kiro, in: environment(home: URL(fileURLWithPath: "/different-home"),
                                                        executablePaths: ["/fixture/bin/kiro-cli"]))
        XCTAssertNotEqual(manual.fingerprint, manualMoved.fingerprint, "Kiro 模板包含桥接路径，迁移目录后需要重新核对")
    }

    func testCodexExpectedCommandsUseExactCurrentGeneratedProfile() throws {
        let home = URL(fileURLWithPath: "/Users/O'Brien")
        let commands = IntegrationSetupDiscovery.codexExpectedCommands(homeDirectory: home)
        XCTAssertEqual(commands.count, 12)
        XCTAssertTrue(commands.allSatisfy { $0.hasPrefix("'/Users/O'\\''Brien/.xisland/bin/di-bridge' --agent codex --hook ") })
        XCTAssertTrue(commands.contains("'/Users/O'\\''Brien/.xisland/bin/di-bridge' --agent codex --hook PermissionRequest"))
    }

    func testFactoryFallbackDefinitionChangesFingerprintButUserContentDoesNot() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = environment(home: home, executablePaths: ["/fixture/bin/droid"])
        let initial = try find(.droid, in: environment)
        let settings = home.appendingPathComponent(".factory/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"unrelated\":\"first-private-value\"}".utf8).write(to: settings)
        let fallback = try find(.droid, in: environment)
        XCTAssertNotEqual(initial.fingerprint, fallback.fingerprint)
        try Data("{\"unrelated\":\"second-private-value\"}".utf8).write(to: settings)
        XCTAssertEqual(fallback.fingerprint, try find(.droid, in: environment).fingerprint)
    }

    func testAutomaticSelectionIntersectsInstalledRoutesAndRequestedSet() {
        let entries = IntegrationSetupDiscovery.scan(environment: environment(
            applications: ["com.trae.app": URL(fileURLWithPath: "/Applications/Trae.app")],
            executablePaths: ["/fixture/bin/claude", "/fixture/bin/codex", "/fixture/bin/kiro-cli"]))
        XCTAssertEqual(IntegrationSetupDiscovery.automaticAgents(in: entries), [.claudeCode, .codex])
        XCTAssertEqual(IntegrationSetupDiscovery.automaticAgents(in: entries, requested: [.codex, .kiro, .trae, .hermes]), [.codex])
        XCTAssertTrue(IntegrationSetupDiscovery.automaticAgents(in: entries, requested: []).isEmpty)
    }

    private func environment(home: URL = URL(fileURLWithPath: "/fixture/home"), path: String = "/fixture/bin",
                             applications: [String: URL] = [:], executablePaths: Set<String> = [],
                             extensions: Set<String> = [], configured: @escaping @Sendable (AgentType) -> Bool = { _ in false }) -> IntegrationSetupDiscovery.Environment {
        .init(homeDirectory: home, path: path, applicationURL: { applications[$0] },
              isExecutable: { executablePaths.contains($0.path) }, extensionIDs: extensions, hasConfiguration: configured)
    }

    private func find(_ agent: AgentType, in environment: IntegrationSetupDiscovery.Environment) throws -> IntegrationSetupDiscoveryEntry {
        try XCTUnwrap(IntegrationSetupDiscovery.scan(environment: environment).first { $0.agent == agent })
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-discovery-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
