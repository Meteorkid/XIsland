import XCTest
import DIShared
@testable import XIsland
@testable import DIBridge

final class CopilotCliHookAdapterTests: XCTestCase {
    func testConfigurationUsesDirectoryAndNativeEvents() throws {
        XCTAssertEqual(CopilotCliHookConfiguration.configURL(homeDirectory: "/home/test", environment: [:]).path,
                       "/home/test/.copilot/hooks/xisland.json")
        XCTAssertEqual(CopilotCliHookConfiguration.configURL(homeDirectory: "/home/test", environment: ["COPILOT_HOME": "/custom"]).path,
                       "/custom/hooks/xisland.json")
        let config = try CopilotCliHookConfiguration.merging(into: [:], bridgePath: "/bin/di-bridge")
        XCTAssertEqual(config["version"] as? Int, 1)
        let hooks = try XCTUnwrap(config["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(CopilotCliHookConfiguration.events))
        XCTAssertNil(hooks["PreToolUse"])
        XCTAssertNil(hooks["permissionRequest"])
        XCTAssertTrue(CopilotCliHookConfiguration.isConfigured(in: config, bridgePath: "/bin/di-bridge"))
        let commands = try XCTUnwrap(hooks["preToolUse"] as? [[String: Any]])
        XCTAssertEqual(commands.first?["timeoutSec"] as? Int, 5)
        XCTAssertTrue((commands.first?["bash"] as? String)?.contains(" || true # XIsland:CopilotCLI:") == true)
    }

    func testMergeIsIdempotentAndRemovalPreservesUserEntries() throws {
        let original: [String: Any] = ["version": 1, "disableAllHooks": true, "custom": "keep", "hooks": [
            "preToolUse": [["exec": "/usr/bin/audit", "args": ["di-bridge"], "timeoutSec": 1]],
            "notification": [["type": "http", "url": "https://example.test/hook"]],
        ]]
        let merged = try CopilotCliHookConfiguration.merging(into: original, bridgePath: "/tmp/O'Brien/di-bridge")
        XCTAssertEqual(merged["disableAllHooks"] as? Bool, true)
        XCTAssertEqual(try json(merged), try json(CopilotCliHookConfiguration.merging(into: merged, bridgePath: "/tmp/O'Brien/di-bridge")))
        XCTAssertEqual(try json(original), try json(CopilotCliHookConfiguration.removing(from: merged)))
    }

    func testPartialAndMalformedConfigurationsAreNotHealthy() throws {
        var config = try CopilotCliHookConfiguration.merging(into: [:], bridgePath: "/bin/di-bridge")
        var hooks = try XCTUnwrap(config["hooks"] as? [String: Any])
        hooks.removeValue(forKey: "agentStop")
        config["hooks"] = hooks
        XCTAssertFalse(CopilotCliHookConfiguration.isConfigured(in: config, bridgePath: "/bin/di-bridge"))
        let malformed: [[String: Any]] = [["version": true], ["version": 2], ["hooks": []],
            ["hooks": ["preToolUse": [["type": "command", "bash": "audit", "timeoutSec": false]]]]]
        for value in malformed {
            XCTAssertThrowsError(try CopilotCliHookConfiguration.merging(into: value, bridgePath: "/bin/di-bridge"))
            XCTAssertFalse(CopilotCliHookConfiguration.isConfigured(in: value, bridgePath: "/bin/di-bridge"))
        }
    }

    func testNativeIdentityMillisecondsAndToolResultArePreserved() throws {
        let result = try normalize("postToolUse", extra: ["toolName": "bash", "toolArgs": ["command": "echo fixture"],
            "toolResult": ["resultType": "success", "textResultForLlm": "fixture"]])
        XCTAssertEqual(result.sessionId, "copilot_cli-fixture-session")
        XCTAssertEqual(result.timestamp.timeIntervalSince1970, 1789550400, accuracy: 0.001)
        XCTAssertEqual(result.workingDir, "/tmp/project")
        XCTAssertEqual(result.type, .toolComplete)
        XCTAssertEqual(result.toolInput, try json(["command": "echo fixture"]))
        XCTAssertTrue(result.toolResult?.contains("textResultForLlm") == true)
        XCTAssertNil(result.toolCallId)
    }

    func testTurnStopAndSessionEndHaveDifferentMeaning() throws {
        let stop = try normalize("agentStop", extra: ["stopReason": "end_turn", "transcriptPath": "/tmp/unused"])
        XCTAssertEqual(stop.type, .statusUpdate)
        XCTAssertEqual(stop.observedState, "completionUnconfirmed")
        XCTAssertNil(stop.status)
        XCTAssertEqual(stop.statusIsAssistantReply, false)
        XCTAssertEqual(try normalize("sessionEnd").observedState, "completed")
        XCTAssertEqual(try normalize("sessionEnd").type, .sessionEnd)
    }

    func testNativeFailureAndNotificationRemainOperational() throws {
        let failure = try normalize("postToolUseFailure", extra: ["toolName": "bash", "toolArgs": "{\"command\":\"false\"}", "error": "fixture failure"])
        XCTAssertEqual(failure.observedState, "error")
        XCTAssertEqual(failure.toolResult, "fixture failure")
        let notice = try normalize("notification", extra: ["notification_type": "permission_prompt", "message": "Native permission required"])
        XCTAssertEqual(notice.type, .statusUpdate)
        XCTAssertEqual(notice.observedState, "waitingPermission")
        XCTAssertEqual(notice.statusIsAssistantReply, false)
        XCTAssertNil(notice.approved)
    }

    func testPascalCaseOrIncompleteIdentityIsRejected() {
        XCTAssertThrowsError(try normalize("PermissionRequest"))
        XCTAssertThrowsError(try normalize("permissionRequest"))
        XCTAssertThrowsError(try normalize("sessionStart", extra: ["sessionId": " "]))
        XCTAssertThrowsError(try normalize("sessionStart", extra: ["timestamp": "2026-09-18T00:00:00Z"]))
        XCTAssertThrowsError(try normalize("sessionStart", extra: ["timestamp": true]))
    }

    func testPermissionCodecIsNotThePreToolCodec() throws {
        for approved in [true, false] {
            let response = CopilotCliHookAdapter.permissionResponse(approved: approved)
            let text = try XCTUnwrap(response.stdout)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(root["behavior"] as? String, approved ? "allow" : "deny")
            XCTAssertNil(root["permissionDecision"])
            XCTAssertEqual(response.exitCode, 0)
        }
    }

    private func normalize(_ event: String, extra: [String: Any] = [:]) throws -> DIMessage {
        var data: [String: Any] = ["sessionId": "fixture-session", "timestamp": 1_789_550_400_000, "cwd": "/tmp/project"]
        data.merge(extra) { _, replacement in replacement }
        return try DIBridge.makeMessage(agentType: "copilot_cli", hookType: event, sessionId: "fallback", stdinData: data)
    }

    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}
