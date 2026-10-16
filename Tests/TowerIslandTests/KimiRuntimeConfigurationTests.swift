import CryptoKit
import XCTest
@testable import XIsland

final class KimiRuntimeConfigurationTests: XCTestCase {
    func testLegacyDefaultKeepsCanonicalV1Bytes() throws {
        let configuration = try KimiHookConfiguration.merging(into: "", bridgePath: "/bin/di-bridge")
        // 改动前固定路径的完整 v1 输出，涵盖空行、命令、事件顺序和标记。
        let digest = SHA256.hash(data: Data(configuration.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "579662192c909e34d621e96c055f8aa7ec6093bf897f1042648d2ab396582a8a")
        XCTAssertEqual(KimiHookConfiguration.relativeConfigPath, ".kimi/config.toml")
        XCTAssertEqual(KimiHookConfiguration.Runtime.legacyPython.events.count, 13)
        XCTAssertEqual(configuration, try KimiHookConfiguration.merging(into: "", bridgePath: "/bin/di-bridge", runtime: .legacyPython))
        XCTAssertFalse(configuration.contains("kimi_code"))
    }

    func testNodeUsesTwentyNativeEventsAndObservationOnlyCommands() throws {
        let expectedEvents: Set<String> = [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
            "Stop", "StopFailure", "SessionEnd", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "Notification",
            "UserPromptQueued", "TurnStarted", "PermissionRequest", "PermissionResult", "SessionHeartbeat", "TaskStarted", "Interrupt",
        ]
        let configuration = try KimiHookConfiguration.merging(into: "", bridgePath: "/bin/di-bridge", runtime: .node)
        XCTAssertEqual(Set(KimiHookConfiguration.Runtime.node.events), expectedEvents)
        XCTAssertEqual(configuration.components(separatedBy: "[[hooks]]").count - 1, 20)
        XCTAssertEqual(configuration.components(separatedBy: "timeout = 5").count - 1, 20)
        XCTAssertEqual(configuration.components(separatedBy: " || true").count - 1, 20)
        XCTAssertTrue(configuration.hasPrefix("\n# BEGIN XIsland:KimiCode:hooks v1\n"))
        XCTAssertTrue(configuration.hasSuffix("# END XIsland:KimiCode:hooks v1\n"))
        for event in expectedEvents {
            XCTAssertTrue(configuration.contains("command = \"'/bin/di-bridge' --agent kimi --adapter kimi_code --hook \(event) || true\""))
        }
        XCTAssertFalse(configuration.contains("matcher"))
        XCTAssertTrue(KimiHookConfiguration.isConfigured(in: configuration, bridgePath: "/bin/di-bridge", runtime: .node))
        XCTAssertFalse(KimiHookConfiguration.isConfigured(in: configuration, bridgePath: "/bin/di-bridge"))
        XCTAssertEqual(try KimiHookConfiguration.removing(from: configuration, runtime: .node), "")
    }

    func testNodePreservesThirdPartyTablesAndEmbeddedMarkersByteForByte() throws {
        let source = """
        # Keep third-party permission processing.
        note = '''
        # BEGIN XIsland:KimiCode:hooks v1
        [[hooks]]
        # END XIsland:KimiCode:hooks v1
        '''
        [[hooks]] # independently maintained
        event = 'PermissionRequest'
        command = 'audit di-bridge --agent kimi'
        timeout = 19
        [[hooks]]
        event = 'SessionHeartbeat'
        command = 'observe'
        [models.'sample']
        hooks = ['leave alone']
        """
        for original in [source, source + "\n", source.replacingOccurrences(of: "\n", with: "\r\n")] {
            let merged = try KimiHookConfiguration.merging(into: original, bridgePath: "/bin/di-bridge", runtime: .node)
            XCTAssertTrue(merged.hasPrefix(original))
            XCTAssertEqual(try KimiHookConfiguration.removing(from: merged, runtime: .node), original)
            XCTAssertEqual(try KimiHookConfiguration.merging(into: merged, bridgePath: "/bin/di-bridge", runtime: .node), merged)
        }
    }

    func testNodeUpgradesOnlyCompleteLegacyOwnedBlock() throws {
        let original = "model = 'keep'\n"
        let legacy = try KimiHookConfiguration.merging(into: original, bridgePath: "/old/di-bridge")
        let upgraded = try KimiHookConfiguration.merging(into: legacy, bridgePath: "/new/di-bridge", runtime: .node)
        XCTAssertEqual(upgraded, try KimiHookConfiguration.merging(into: original, bridgePath: "/new/di-bridge", runtime: .node))
        XCTAssertEqual(try KimiHookConfiguration.removing(from: upgraded, runtime: .node), original)
        XCTAssertFalse(KimiHookConfiguration.isConfigured(in: legacy, bridgePath: "/old/di-bridge", runtime: .node))
        XCTAssertThrowsError(try KimiHookConfiguration.merging(into: upgraded, bridgePath: "/new/di-bridge"))
        for runtime in KimiHookConfiguration.Runtime.allCases {
            let owned = try KimiHookConfiguration.merging(into: original, bridgePath: "/bin/di-bridge", runtime: runtime)
            for modified in [
                owned.replacingOccurrences(of: "timeout = 5", with: "timeout = 6"),
                owned.replacingOccurrences(of: "hooks v1", with: "hooks v2"),
                owned + "# user addition\n",
                owned + owned,
            ] {
                XCTAssertThrowsError(try KimiHookConfiguration.merging(into: modified, bridgePath: "/new/di-bridge", runtime: .node))
                XCTAssertThrowsError(try KimiHookConfiguration.removing(from: modified, runtime: .node))
            }
        }
    }

    func testNodeDoesNotClaimUnmarkedLegacyCommands() throws {
        let original = "[[hooks]]\nevent = \"PermissionRequest\"\ncommand = \"/old/di-bridge --agent kimi --hook PermissionRequest\"\nmatcher = \"*\"\ntimeout = 300\n"
        let merged = try KimiHookConfiguration.merging(into: original, bridgePath: "/bin/di-bridge", runtime: .node)
        XCTAssertEqual(try KimiHookConfiguration.removing(from: merged, runtime: .node), original)
    }

    func testNodeRejectsUnsupportedOrDamagedTOMLAndHooksEvents() {
        for original in [
            "hooks = []\n", "[hooks]\n", "[[hooks.child]]\nevent = 'Stop'\n",
            "text = '''unfinished", "tags = [1, 2", "name='a'\rname='b'", "name='\0'",
            "[[hooks]]\nevent = 'UnknownEvent'\n", "[[hooks]]\nevent = 'Stop'\nevent = 'Interrupt'\n",
        ] {
            XCTAssertThrowsError(try KimiHookConfiguration.merging(into: original, bridgePath: "/bin/di-bridge", runtime: .node), original)
            XCTAssertThrowsError(try KimiHookConfiguration.removing(from: original, runtime: .node), original)
        }
    }

    func testNoConfigurationFilesMeansNoCreatedClientDirectories() throws {
        try withDirectory { root in
            let override = root.appendingPathComponent("custom-kimi-home")
            for environment in [[:], ["KIMI_CODE_HOME": override.path]] {
                XCTAssertFalse(try KimiHookInstallation.install(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: environment))
                XCTAssertFalse(KimiHookInstallation.isConfigured(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: environment))
                XCTAssertFalse(KimiHookInstallation.shouldRepair(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: environment))
                try KimiHookInstallation.remove(homeDirectory: root.path, environment: environment)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testOnlyExistingRuntimeIsInstalledAndRemoved() throws {
        for runtime in KimiHookConfiguration.Runtime.allCases {
            try withDirectory { root in
                let url = try write("model = 'fixture'\n", at: runtime.relativeConfigPath, in: root)
                XCTAssertEqual(try KimiHookInstallation.existingConfigurations(homeDirectory: root.path, environment: [:]).map(\.runtime), [runtime])
                XCTAssertTrue(try KimiHookInstallation.install(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: [:]))
                XCTAssertTrue(KimiHookConfiguration.isConfigured(in: try String(contentsOf: url, encoding: .utf8), bridgePath: "/bin/di-bridge", runtime: runtime))
                XCTAssertTrue(KimiHookInstallation.isConfigured(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: [:]))
                XCTAssertFalse(KimiHookInstallation.shouldRepair(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: [:]))
                try KimiHookInstallation.remove(homeDirectory: root.path, environment: [:])
                XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "model = 'fixture'\n")
                let other: KimiHookConfiguration.Runtime = runtime == .node ? .legacyPython : .node
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(other.relativeConfigPath).deletingLastPathComponent().path))
            }
        }
    }

    func testExistingClientDirectoriesWithoutConfigAreNotPopulated() throws {
        try withDirectory { root in
            for directory in [".kimi", ".kimi-code", "custom"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
            }
            for environment in [[:], ["KIMI_CODE_HOME": root.appendingPathComponent("custom").path]] {
                XCTAssertFalse(try KimiHookInstallation.install(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: environment))
                try KimiHookInstallation.remove(homeDirectory: root.path, environment: environment)
            }
            for directory in [".kimi", ".kimi-code", "custom"] {
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(directory).path), [])
            }
        }
    }

    func testCoexistingRuntimesRepairIndependentlyAndPreserveOriginals() throws {
        try withDirectory { root in
            let originalLegacy = "model = 'python'\n"
            let originalNode = "model = 'node'\n"
            let legacy = try write(KimiHookConfiguration.merging(into: originalLegacy, bridgePath: "/bin/di-bridge"), at: ".kimi/config.toml", in: root)
            let node = try write(originalNode, at: ".kimi-code/config.toml", in: root)
            let installedLegacy = try Data(contentsOf: legacy)
            XCTAssertFalse(KimiHookInstallation.isConfigured(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: [:]))
            XCTAssertTrue(KimiHookInstallation.shouldRepair(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: [:]))
            try KimiHookInstallation.install(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: [:])
            XCTAssertEqual(try Data(contentsOf: legacy), installedLegacy)
            XCTAssertTrue(KimiHookInstallation.isConfigured(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: [:]))
            XCTAssertTrue(KimiHookConfiguration.isConfigured(in: try String(contentsOf: node, encoding: .utf8), bridgePath: "/bin/di-bridge", runtime: .node))
            XCTAssertTrue(KimiHookInstallation.shouldRepair(homeDirectory: root.path, bridgePath: "/new/di-bridge", environment: [:]))
            try KimiHookInstallation.remove(homeDirectory: root.path, environment: [:])
            XCTAssertEqual(try String(contentsOf: legacy, encoding: .utf8), originalLegacy)
            XCTAssertEqual(try String(contentsOf: node, encoding: .utf8), originalNode)
        }
    }

    func testEnvironmentOverrideOnlySelectsExistingNodeHome() throws {
        try withDirectory { root in
            let defaultNode = try write("model = 'default'\n", at: ".kimi-code/config.toml", in: root)
            let customNode = try write("model = 'override'\n", at: "custom/config.toml", in: root)
            let environment = ["KIMI_CODE_HOME": customNode.deletingLastPathComponent().path]
            try KimiHookInstallation.install(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: environment)
            XCTAssertEqual(try String(contentsOf: defaultNode, encoding: .utf8), "model = 'default'\n")
            XCTAssertTrue(KimiHookConfiguration.isConfigured(in: try String(contentsOf: customNode, encoding: .utf8), bridgePath: "/bin/di-bridge", runtime: .node))
            try KimiHookInstallation.remove(homeDirectory: root.path, environment: environment)
            XCTAssertEqual(try String(contentsOf: customNode, encoding: .utf8), "model = 'override'\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".kimi").path))
        }
    }

    func testRejectsRelativeEmptyAndLegacyOverlappingOverridesWithoutWriting() throws {
        try withDirectory { root in
            let legacy = try write("model = 'keep'\n", at: ".kimi/config.toml", in: root)
            for override in ["", "relative", "~/.kimi-code", "/tmp/invalid\npath", legacy.deletingLastPathComponent().path,
                             root.appendingPathComponent(".kimi/../.kimi").path] {
                let environment = ["KIMI_CODE_HOME": override]
                XCTAssertThrowsError(try KimiHookInstallation.install(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: environment))
                XCTAssertThrowsError(try KimiHookInstallation.remove(homeDirectory: root.path, environment: environment))
                XCTAssertFalse(KimiHookInstallation.shouldRepair(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: environment))
                XCTAssertEqual(try String(contentsOf: legacy, encoding: .utf8), "model = 'keep'\n")
            }
        }
    }

    func testRejectsSymlinkAndHardLinkAliasingLegacyConfiguration() throws {
        for useHardLink in [false, true] {
            try withDirectory { root in
                let legacy = try write("model = 'keep'\n", at: ".kimi/config.toml", in: root)
                let node = root.appendingPathComponent(".kimi-code/config.toml")
                try FileManager.default.createDirectory(at: node.deletingLastPathComponent(), withIntermediateDirectories: true)
                if useHardLink { try FileManager.default.linkItem(at: legacy, to: node) }
                else { try FileManager.default.createSymbolicLink(at: node, withDestinationURL: legacy) }
                XCTAssertThrowsError(try KimiHookInstallation.install(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: [:]))
                XCTAssertThrowsError(try KimiHookInstallation.remove(homeDirectory: root.path, environment: [:]))
                XCTAssertEqual(try String(contentsOf: legacy, encoding: .utf8), "model = 'keep'\n")
                XCTAssertEqual(try String(contentsOf: node, encoding: .utf8), "model = 'keep'\n")
            }
        }
    }

    func testNodeFileLegacyUpgradeLeavesExistingLegacyFileUntouched() throws {
        try withDirectory { root in
            let legacyText = try KimiHookConfiguration.merging(into: "model = 'python'\n", bridgePath: "/bin/di-bridge")
            let legacy = try write(legacyText, at: ".kimi/config.toml", in: root)
            let nodeText = try KimiHookConfiguration.merging(into: "model = 'node'\n", bridgePath: "/old/di-bridge")
            let node = try write(nodeText, at: ".kimi-code/config.toml", in: root)
            try KimiHookInstallation.install(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: [:])
            XCTAssertEqual(try String(contentsOf: legacy, encoding: .utf8), legacyText)
            XCTAssertTrue(KimiHookConfiguration.isConfigured(in: try String(contentsOf: node, encoding: .utf8), bridgePath: "/bin/di-bridge", runtime: .node))
        }
    }

    func testInvalidOrModifiedNodeConfigPreventsPartialInstallationAndRemoval() throws {
        let modifiedOwned = try KimiHookConfiguration.merging(into: "", bridgePath: "/bin/di-bridge", runtime: .node)
            .replacingOccurrences(of: "timeout = 5", with: "timeout = 6")
        for invalid in ["text = '''unfinished", "hooks = []\n", modifiedOwned] {
            try withDirectory { root in
                let legacy = try write("model = 'keep'\n", at: ".kimi/config.toml", in: root)
                let node = try write(invalid, at: ".kimi-code/config.toml", in: root)
                XCTAssertThrowsError(try KimiHookInstallation.install(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: [:]))
                XCTAssertThrowsError(try KimiHookInstallation.remove(homeDirectory: root.path, environment: [:]))
                XCTAssertFalse(KimiHookInstallation.shouldRepair(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: [:]))
                XCTAssertEqual(try String(contentsOf: legacy, encoding: .utf8), "model = 'keep'\n")
                XCTAssertEqual(try String(contentsOf: node, encoding: .utf8), invalid)
            }
        }
    }

    private func write(_ text: String, at path: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xi-kimi-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
