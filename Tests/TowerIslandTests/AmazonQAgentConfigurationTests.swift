import XCTest
@testable import DIBridge

final class AmazonQAgentConfigurationTests: XCTestCase {
    func testPreservesPermissionsAndUserHooksAndIsIdempotent() throws {
        let custom: [String: Any] = ["command": "user-check", "timeout_ms": 4000, "matcher": "fs_*"]
        let original: [String: Any] = ["name": "my-agent", "allowedTools": ["fs_read"], "toolsSettings": ["write": false], "hooks": ["preToolUse": [custom]]]
        let first = try AmazonQAgentConfiguration.addingObservation(to: original, bridgePath: "/tmp/bridge 'quoted'")
        let second = try AmazonQAgentConfiguration.addingObservation(to: first, bridgePath: "/tmp/bridge 'quoted'")
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: first, options: .sortedKeys), try JSONSerialization.data(withJSONObject: second, options: .sortedKeys))
        XCTAssertEqual(first["allowedTools"] as? [String], ["fs_read"])
        XCTAssertEqual(first["toolsSettings"] as? [String: Bool], ["write": false])
        let hooks = try XCTUnwrap(first["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(hooks.count, 5)
        XCTAssertEqual(hooks["preToolUse"]?.count, 2)
        XCTAssertEqual(hooks["preToolUse"]?.first?["command"] as? String, "user-check")
        XCTAssertEqual(hooks["stop"]?.first?["cache_ttl_seconds"] as? Int, 0)
        XCTAssertTrue(hooks["stop"]?.first?["command"] as? String == "'/tmp/bridge '\\''quoted'\\''' amazonq-hook-1-19-7 stop")
    }

    func testRejectsMalformedExistingConfigInsteadOfOverwritingIt() {
        for agent: [String: Any] in [["hooks": [:]], ["name": "agent", "hooks": []], ["name": "agent", "hooks": ["stop": "bad"]]] {
            XCTAssertThrowsError(try AmazonQAgentConfiguration.addingObservation(to: agent, bridgePath: "/tmp/bridge"))
        }
        XCTAssertThrowsError(try AmazonQAgentConfiguration.addingObservation(to: ["name": "agent"], bridgePath: "relative"))
    }
}
