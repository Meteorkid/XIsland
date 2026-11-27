import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

final class AntigravityHookConfigurationTests: XCTestCase {
    func testConfigurationUsesNamedGlobalHookWithOfficialEvents() throws {
        XCTAssertEqual(AntigravityHookConfiguration.relativeConfigPath, ".gemini/config/hooks.json")
        let config = try AntigravityHookConfiguration.hooksFile(bridgePath: "/bin/di-bridge")
        let entry = try XCTUnwrap(config[AntigravityHookConfiguration.hookName] as? [String: Any])
        XCTAssertEqual(Set(entry.keys), Set(["SessionStart", "PreInvocation", "PreToolUse", "PostToolUse", "Stop"]))
        XCTAssertNil(config["hooks"], "Antigravity 不是 Gemini CLI 的 hooks 字典结构")

        let start = try XCTUnwrap(entry["SessionStart"] as? [[String: Any]])
        let handler = try XCTUnwrap(start.first)
        XCTAssertEqual(handler["type"] as? String, "command")
        XCTAssertEqual(handler["timeout"] as? Int, 5, "Antigravity 的 timeout 单位是秒")
        let command = try XCTUnwrap(handler["command"] as? String)
        XCTAssertEqual(command, "'/bin/di-bridge' --agent antigravity --hook SessionStart || true")

        for event in ["PreToolUse", "PostToolUse"] {
            let group = try XCTUnwrap((entry[event] as? [[String: Any]])?.first)
            XCTAssertEqual(group["matcher"] as? String, "*", "工具事件必须带 matcher")
            let nested = try XCTUnwrap((group["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(nested["type"] as? String, "command")
        }
    }

    func testMergingPreservesThirdPartyHooksAndRemovalOnlyDropsOurs() throws {
        let thirdParty: [String: Any] = ["SessionStart": [["type": "command", "command": "audit"]]]
        let original: [String: Any] = ["audit-hooks": thirdParty, "model": "keep"]
        let merged = try AntigravityHookConfiguration.merging(into: original, bridgePath: "/bin/di-bridge")
        XCTAssertEqual(merged["model"] as? String, "keep")
        XCTAssertEqual((merged["audit-hooks"] as? [String: Any])?.count, 1)
        XCTAssertTrue(AntigravityHookConfiguration.isConfigured(in: merged, bridgePath: "/bin/di-bridge"))
        XCTAssertFalse(AntigravityHookConfiguration.isConfigured(in: merged, bridgePath: "/other/di-bridge"))

        let removed = try AntigravityHookConfiguration.removing(from: merged)
        XCTAssertNil(removed[AntigravityHookConfiguration.hookName])
        XCTAssertNotNil(removed["audit-hooks"])
        XCTAssertFalse(AntigravityHookConfiguration.isConfigured(in: removed, bridgePath: "/bin/di-bridge"))
    }

    func testBareConfigurationIsNotInventedAndInvalidBridgeIsRejected() throws {
        let removed = try AntigravityHookConfiguration.removing(from: [:])
        XCTAssertTrue(removed.isEmpty)
        XCTAssertThrowsError(try AntigravityHookConfiguration.hooksFile(bridgePath: "relative/di-bridge"))
    }
}

final class AntigravityHookAdapterTests: XCTestCase {
    private let base: [String: Any] = [
        "conversationId": "conv-1",
        "workspacePaths": ["/tmp/project"],
        "modelName": "gemini-3-pro",
        "lastUserInput": "修复登录页",
        "stepIdx": 3,
    ]

    func testSessionEventsMapToSessionStart() throws {
        for event in ["SessionStart", "PreInvocation"] {
            let data = base.merging(["lastUserInput": "修一下登录页"]) { _, new in new }
            let message = try AntigravityHookAdapter.normalize(hookType: event, stdinData: data)
            XCTAssertEqual(message.type, .sessionStart)
            XCTAssertEqual(message.sessionId, "antigravity-conv-1")
            XCTAssertEqual(message.agentType, "antigravity")
            XCTAssertEqual(message.nativeEvent, event)
            XCTAssertEqual(message.prompt, "修一下登录页")
            XCTAssertEqual(message.workingDir, "/tmp/project")
            XCTAssertEqual(message.model, "gemini-3-pro")
        }
    }

    func testToolEventsCarryStableCallIdAndError() throws {
        var data = base
        data["toolCall"] = ["name": "run_command", "args": ["command": "npm test"]]
        let start = try AntigravityHookAdapter.normalize(hookType: "PreToolUse", stdinData: data)
        XCTAssertEqual(start.type, .toolStart)
        XCTAssertEqual(start.tool, "run_command")
        XCTAssertEqual(start.toolCallId, "antigravity-step-3")
        XCTAssertTrue(start.toolInput?.contains("npm test") ?? false)

        data["error"] = "exit code 1"
        let complete = try AntigravityHookAdapter.normalize(hookType: "PostToolUse", stdinData: data)
        XCTAssertEqual(complete.type, .toolComplete)
        XCTAssertEqual(complete.toolCallId, "antigravity-step-3")
        XCTAssertEqual(complete.toolResult, "exit code 1")
    }

    func testStopNeverClaimsCompletion() throws {
        let data: [String: Any] = base.merging(["terminationReason": "model_stop", "fullyIdle": true]) { _, new in new }
        let message = try AntigravityHookAdapter.normalize(hookType: "Stop", stdinData: data)
        XCTAssertEqual(message.type, .statusUpdate)
        XCTAssertEqual(message.status, "model_stop")
        XCTAssertEqual(message.observedState, "completionUnconfirmed")
    }

    func testMissingConversationOrUnknownEventIsRejected() {
        XCTAssertThrowsError(try AntigravityHookAdapter.normalize(
            hookType: "SessionStart", stdinData: ["lastUserInput": "x"]
        ))
        XCTAssertThrowsError(try AntigravityHookAdapter.normalize(
            hookType: "Notification", stdinData: base
        ))
    }
}
