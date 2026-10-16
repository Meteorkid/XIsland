import XCTest
import DIShared
@testable import DIBridge

final class ACPCustomAgentConfigurationTests: XCTestCase {
    func testWrappingPreservesEnvironmentAndArgumentsWithoutShellInterpolation() throws {
        let original: [String: Any] = ["type": "custom", "command": "/tmp/Agent 'name'", "args": ["--acp", "中文 $()\n"],
                                       "env": ["TOKEN": "fixture-only"], "custom": ["keep": true]]
        let wrapped = try ACPCustomAgentConfiguration.wrapping(original, host: "zed", source: "Profile", bridgePath: "/tmp/di-bridge")
        XCTAssertEqual(wrapped["command"] as? String, "/tmp/di-bridge")
        XCTAssertEqual(wrapped["args"] as? [String], ["acp", "--host", "zed", "--source", "Profile", "--", "/tmp/Agent 'name'", "--acp", "中文 $()\n"])
        XCTAssertEqual(try json(original), try json(ACPCustomAgentConfiguration.unwrapping(wrapped, host: "zed", source: "Profile")))
        XCTAssertEqual(try json(wrapped), try json(ACPCustomAgentConfiguration.wrapping(wrapped, host: "zed", source: "Profile", bridgePath: "/tmp/di-bridge")))
    }

    func testJetBrainsEntryDoesNotGainZedSpecificTypeAndBridgePathCanUpgrade() throws {
        let original: [String: Any] = ["command": "agent", "args": ["acp"], "env": [:]]
        let old = try ACPCustomAgentConfiguration.wrapping(original, host: "jetbrains_ai", source: "Profile", bridgePath: "/old/di-bridge")
        let new = try ACPCustomAgentConfiguration.wrapping(old, host: "jetbrains_ai", source: "Profile", bridgePath: "/new/di-bridge")
        XCTAssertNil(new["type"])
        XCTAssertEqual(new["command"] as? String, "/new/di-bridge")
        XCTAssertEqual(try json(ACPCustomAgentConfiguration.unwrapping(new, host: "jetbrains_ai", source: "Profile")), try json(original))
    }

    func testRegistryAndInvalidEntriesAreRejectedAndUnrelatedWrappersNotRemoved() throws {
        for entry: [String: Any] in [["type": "registry", "command": "agent"], ["command": "agent"],
                                      ["type": "custom", "command": "~/agent"], ["type": "custom", "command": "agent", "args": "bad"]] {
            XCTAssertThrowsError(try ACPCustomAgentConfiguration.wrapping(entry, host: "zed", source: "p", bridgePath: "/tmp/di-bridge"))
        }
        let original: [String: Any] = ["command": "/tmp/di-bridge", "args": ["acp", "--host", "zed", "--source", "other", "--", "agent"]]
        XCTAssertEqual(try json(original), try json(ACPCustomAgentConfiguration.unwrapping(original, host: "zed", source: "p")))
    }

    func testCLIOptionsRequireAnExplicitHostRegistrationAndExecutableBoundary() throws {
        let arguments = ["--host", "zed", "--source", "Profile", "--", "agent", "--flag", "value with spaces"]
        let options = try ACPRunner.options(arguments)
        XCTAssertEqual(options.host, "zed")
        XCTAssertEqual(options.command, "agent")
        XCTAssertEqual(options.arguments, ["--flag", "value with spaces"])
        for invalid in [[], ["--host", "zed"], ["--host", "zed", "--source", "p", "--"],
                        ["--host", "zed", "--host", "zed", "--source", "p", "--", "agent"]] {
            XCTAssertThrowsError(try ACPRunner.options(invalid))
        }
    }
    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
}
