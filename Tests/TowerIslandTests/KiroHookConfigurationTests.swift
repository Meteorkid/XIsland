import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

final class KiroHookConfigurationTests: XCTestCase {
    private let bridge = "/tmp/X Island's App/di-bridge"

    private func merged(_ document: [String: Any] = [:], path: String? = nil) throws -> [String: Any] {
        try KiroHookConfiguration.merging(into: document, bridgePath: path ?? bridge, cliVersion: "2.31.0", engine: "v3")
    }

    func testStandaloneV3DocumentHasSixCanonicalObservationHooks() throws {
        let result = try merged()
        XCTAssertEqual(result["version"] as? String, "v1")
        let hooks = try XCTUnwrap(result["hooks"] as? [[String: Any]])
        XCTAssertEqual(hooks.compactMap { $0["trigger"] as? String }, KiroHookConfiguration.events)
        for hook in hooks {
            XCTAssertNil(hook["timeout"])
            XCTAssertNil(hook["timeout_ms"])
            XCTAssertNil(hook["confirm"])
            XCTAssertNil(hook["matcher"])
            let command = try XCTUnwrap((hook["action"] as? [String: Any])?["command"] as? String)
            XCTAssertTrue(command.contains("'\\''"))
            XCTAssertTrue(command.contains("--adapter kiro_cli"))
            XCTAssertTrue(command.hasSuffix(">/dev/null || true"))
            XCTAssertFalse(command.contains("trust"))
        }
        XCTAssertTrue(KiroHookConfiguration.isConfigured(in: result, bridgePath: bridge))
    }

    func testMergeUpdatesOnlyOwnedHooksAndRemovePreservesThirdParty() throws {
        let original: [String: Any] = ["version": "v1", "note": "preserve", "hooks": [
            ["name": "company-check", "trigger": "PreToolUse", "action": ["type": "command", "command": "./check.sh"], "timeout": 12],
            ["name": "team-summary", "trigger": "Stop", "action": ["type": "agent", "prompt": "Summarize"]],
        ]]
        let first = try merged(original)
        let second = try merged(first)
        XCTAssertTrue(NSDictionary(dictionary: first).isEqual(to: second))
        let changed = try merged(first, path: "/tmp/new/di-bridge")
        XCTAssertTrue(KiroHookConfiguration.isConfigured(in: changed, bridgePath: "/tmp/new/di-bridge"))
        XCTAssertFalse(KiroHookConfiguration.isConfigured(in: changed, bridgePath: bridge))
        XCTAssertTrue(NSDictionary(dictionary: try KiroHookConfiguration.removing(from: changed)).isEqual(to: original))
    }

    func testUnknownVersionAndEngineCannotGenerateConfiguration() {
        for (version, engine) in [("2.31.1", "v3"), ("2.25.0", "v3"), ("3.0.0", "v3"), ("2.31.0", "v2"), ("", "v3")] {
            XCTAssertThrowsError(try KiroHookConfiguration.merging(into: [:], bridgePath: bridge, cliVersion: version, engine: engine))
        }
        for path in ["relative/di-bridge", "/tmp/a\nb", "/tmp/a\0b"] {
            XCTAssertThrowsError(try merged(path: path))
        }
    }

    func testMalformedOrEmbeddedLegacyConfigIsNotOverwritten() {
        for document: [String: Any] in [["version": "v2"], ["hooks": ["preToolUse": []]],
                                        ["version": "v1", "hooks": ["wrong"]],
                                        ["version": "v1", "hooks": [["name": "incomplete"]]]] {
            XCTAssertThrowsError(try merged(document))
            XCTAssertFalse(KiroHookConfiguration.isConfigured(in: document, bridgePath: bridge))
        }
    }

    func testModifiedOwnedHookCannotBeRemovedOrDuplicated() throws {
        var document = try merged()
        var hooks = try XCTUnwrap(document["hooks"] as? [[String: Any]])
        hooks[0]["matcher"] = "user-change"
        document["hooks"] = hooks
        XCTAssertThrowsError(try KiroHookConfiguration.removing(from: document))
        XCTAssertThrowsError(try merged(document))
        XCTAssertFalse(KiroHookConfiguration.isConfigured(in: document, bridgePath: bridge))
        hooks[0].removeValue(forKey: "matcher")
        hooks.append(hooks[0])
        document["hooks"] = hooks
        XCTAssertFalse(KiroHookConfiguration.isConfigured(in: document, bridgePath: bridge))
        XCTAssertTrue(KiroHookConfiguration.isConfigured(in: try merged(document), bridgePath: bridge))
        hooks[0]["enabled"] = 1
        document["hooks"] = hooks
        XCTAssertThrowsError(try merged(document))
        XCTAssertFalse(KiroHookConfiguration.isConfigured(in: document, bridgePath: bridge))
    }

    func testTemporaryFileInstallDetectionAndRemovalAreAtomicAndScoped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xi-kiro-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent(".kiro/hooks/" + KiroHookConfiguration.fileName)
        XCTAssertTrue(try HookConfigurationFile.update(at: target) { try self.merged($0) })
        XCTAssertTrue(KiroHookConfiguration.isConfigured(in: try HookConfigurationFile.read(at: target), bridgePath: bridge))
        XCTAssertFalse(try HookConfigurationFile.update(at: target) { try self.merged($0) })
        try HookConfigurationFile.update(at: target) { try KiroHookConfiguration.removing(from: $0) }
        XCTAssertFalse(KiroHookConfiguration.isConfigured(in: try HookConfigurationFile.read(at: target), bridgePath: bridge))
        let before = try Data(contentsOf: target)
        XCTAssertThrowsError(try HookConfigurationFile.update(at: target) {
            try KiroHookConfiguration.merging(into: $0, bridgePath: self.bridge, cliVersion: "unknown", engine: "v3")
        })
        XCTAssertEqual(try Data(contentsOf: target), before)
    }

    func testCLIRequiresExplicitRuntimeAndRemovesWithoutVersionGuessing() throws {
        let config = try KiroConfigurationCommand.transform([:], arguments: ["--cli-version", "2.31.0", "--engine", "v3"], bridgePath: bridge)
        XCTAssertTrue(KiroHookConfiguration.isConfigured(in: config, bridgePath: bridge))
        for args in [[], ["--cli-version", "2.31.0"], ["--engine", "v3", "--cli-version", "2.31.0"], ["--remove", "extra"]] {
            XCTAssertThrowsError(try KiroConfigurationCommand.transform([:], arguments: args, bridgePath: bridge))
        }
        let removed = try KiroConfigurationCommand.transform(config, arguments: ["--remove"], bridgePath: bridge)
        XCTAssertTrue((removed["hooks"] as? [Any])?.isEmpty == true)
    }
}
