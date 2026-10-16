import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

final class DevinHookAdapterTests: XCTestCase {
    func testConfigurationDetectionAndRemovalPreserveUnownedSettings() throws {
        let config = try DevinHookConfiguration.merging(into: ["model": "keep"], bridgePath: "/bin/di-bridge")
        XCTAssertTrue(DevinHookConfiguration.isConfigured(in: config, bridgePath: "/bin/di-bridge"))
        XCTAssertFalse(DevinHookConfiguration.isConfigured(in: config, bridgePath: "/new/di-bridge"))
        let removed = try DevinHookConfiguration.removing(from: config)
        XCTAssertEqual(removed["model"] as? String, "keep")
        XCTAssertFalse(DevinHookConfiguration.isConfigured(in: removed, bridgePath: "/bin/di-bridge"))
        XCTAssertTrue((removed["hooks"] as? [String: Any])?.isEmpty == true)
    }

    func testRemovingWithoutExistingHooksDoesNotCreateConfiguration() throws {
        let removed = try DevinHookConfiguration.removing(from: ["model": "keep"])
        XCTAssertNil(removed["hooks"])
        XCTAssertThrowsError(try DevinHookConfiguration.removing(from: ["hooks": "invalid"]))
    }
    func testConfigurationUsesGlobalDevinSchemaAndOnlyNativeEvents() throws {
        XCTAssertEqual(DevinHookConfiguration.relativeConfigPath, ".config/devin/config.json")
        let config = try DevinHookConfiguration.merging(into: [:], bridgePath: "/bin/di-bridge")
        let hooks = try XCTUnwrap(config["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set([
            "SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "PostCompaction",
            "PreToolUse", "PostToolUse", "PermissionRequest",
        ]))
        XCTAssertNil(config["SessionStart"])
        for event in hooks.keys {
            let handler = try firstHandler(config, event: event)
            let command = try XCTUnwrap(handler["command"] as? String)
            XCTAssertTrue(command.contains(" --agent devin --hook \(event)"))
            XCTAssertEqual(command.contains("|| true"), event != "PermissionRequest")
            XCTAssertEqual(handler["timeout"] as? Int, event == "PermissionRequest" ? 300 : 5)
        }
    }

    func testConfigurationPreservesThirdPartyHooksAndOtherSettings() throws {
        let custom: [String: Any] = ["type": "command", "command": "audit di-bridge --agent devin"]
        let prompt: [String: Any] = ["type": "prompt", "prompt": "Review this tool"]
        let original: [String: Any] = [
            "read_config_from": ["claude": false],
            "model": "preserve-model",
            "hooks": [
                "PreToolUse": [["matcher": "^exec$", "hooks": [custom, prompt], "custom": "preserve"]],
                "FutureEvent": [["hooks": [custom]]],
            ],
        ]
        let merged = try DevinHookConfiguration.merging(into: original, bridgePath: "/bin/di-bridge")
        XCTAssertEqual(merged["model"] as? String, "preserve-model")
        XCTAssertEqual((merged["read_config_from"] as? [String: Bool])?["claude"], false)
        let hooks = try XCTUnwrap(merged["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?["matcher"] as? String, "^exec$")
        XCTAssertEqual(groups.first?["custom"] as? String, "preserve")
        XCTAssertEqual((groups.first?["hooks"] as? [[String: Any]])?.count, 2)
        XCTAssertNotNil(hooks["FutureEvent"])
    }

    func testConfigurationIsIdempotentAndReplacesOnlyOwnedHooksAfterPathChanges() throws {
        let first = try DevinHookConfiguration.merging(into: [:], bridgePath: "/old/di-bridge")
        let second = try DevinHookConfiguration.merging(into: first, bridgePath: "/new/di-bridge")
        let third = try DevinHookConfiguration.merging(into: second, bridgePath: "/new/di-bridge")
        XCTAssertEqual(try canonicalJSON(second), try canonicalJSON(third))
        XCTAssertFalse(try canonicalJSON(second).contains("/old/di-bridge"))
    }

    func testShellQuoteTreatsPathsWithQuotesAndSubstitutionsAsLiteral() throws {
        let path = "/tmp/O'Brien $(touch unexpected) `echo bad`/di-bridge"
        let config = try DevinHookConfiguration.merging(into: [:], bridgePath: path)
        let handler = try firstHandler(config, event: "PermissionRequest")
        XCTAssertEqual(handler["command"] as? String,
                       "'/tmp/O'\\''Brien $(touch unexpected) `echo bad`/di-bridge' --agent devin --hook PermissionRequest # XIsland:Devin:PermissionRequest")
        XCTAssertThrowsError(try DevinHookConfiguration.merging(into: [:], bridgePath: "~/bin/di-bridge"))
        XCTAssertThrowsError(try DevinHookConfiguration.merging(into: [:], bridgePath: "/tmp/\0di-bridge"))
    }

    func testMalformedConfigurationsAreRejectedWithoutOverwriting() {
        let malformed: [[String: Any]] = [
            ["hooks": []],
            ["hooks": NSNull()],
            ["hooks": ["Stop": "bad"]],
            ["hooks": ["Stop": [["hooks": "bad"]]]],
            ["hooks": ["Stop": [["hooks": [["type": "command"]]]]]],
            ["hooks": ["Stop": [["matcher": 42, "hooks": []]]]],
            ["hooks": ["Stop": [["hooks": [["type": "prompt", "prompt": 42]]]]]],
            ["hooks": ["Stop": [["hooks": [["type": "command", "command": "audit", "timeout": "5"]]]]]],
            ["hooks": ["Stop": [["hooks": [["type": "command", "command": "audit", "timeout": true]]]]]],
            ["hooks": ["Stop": [["hooks": [["type": "command", "command": "audit", "timeout": -1]]]]]],
        ]
        for config in malformed {
            XCTAssertThrowsError(try DevinHookConfiguration.merging(into: config, bridgePath: "/bin/di-bridge"))
        }
    }

    func testNativeSessionAndPromptUseDevinProjectContext() throws {
        let message = try normalize("UserPromptSubmit", fields: ["prompt": "实现测试", "prompt_id": "turn-2"])
        XCTAssertEqual(message.type, .sessionStart)
        XCTAssertEqual(message.agentType, "devin")
        XCTAssertEqual(message.sessionId, "devin-native-session")
        XCTAssertEqual(message.prompt, "实现测试")
        XCTAssertEqual(message.workingDir, "/tmp/project with spaces")
        XCTAssertEqual(message.terminal, "iTerm.app")
        XCTAssertEqual(message.termSessionId, "terminal-1")
    }

    func testStopDoesNotEndSessionAndPostCompactionUsesSummary() throws {
        let stop = try normalize("Stop", fields: ["stop_hook_active": false])
        XCTAssertEqual(stop.type, .statusUpdate)
        XCTAssertNil(stop.status)
        XCTAssertEqual(try normalize("SessionEnd", fields: ["reason": "exit"]).type, .sessionEnd)
        let compact = try normalize("PostCompaction", fields: ["summary": "压缩摘要"])
        XCTAssertEqual(compact.type, .recap)
        XCTAssertEqual(compact.recapText, "压缩摘要")
        XCTAssertNil(compact.status)
    }

    func testPreToolUseNeverCreatesApprovalOrQuestion() throws {
        for name in ["exec", "AskUserQuestion", "ask_question", "exit_plan_mode"] {
            let message = try normalize("PreToolUse", fields: ["tool_name": name, "tool_input": ["question": "Continue?"]])
            XCTAssertEqual(message.type, .toolStart)
            XCTAssertNil(message.questionText)
            XCTAssertNil(message.planMarkdown)
        }
    }

    func testPermissionKeepsCompleteArgumentsAndRemainsNativePermission() throws {
        let input: [String: Any] = ["command": "echo hello", "cwd": "/tmp/project", "timeout": 10]
        let message = try normalize("PermissionRequest", fields: ["tool_name": "AskUserQuestion", "tool_input": input])
        XCTAssertEqual(message.type, .permissionRequest)
        XCTAssertEqual(message.permDescription, try canonicalJSON(input))
        XCTAssertEqual(message.toolInput, message.permDescription)
        XCTAssertNil(message.questionText)
    }

    func testToolResultsKeepFailureAndOutputFields() throws {
        let response: [String: Any] = ["success": false, "output": "partial output", "error": "permission denied"]
        let message = try normalize("PostToolUse", fields: ["tool_name": "exec", "tool_input": ["command": "pwd"], "tool_response": response])
        XCTAssertEqual(message.type, .toolComplete)
        XCTAssertEqual(message.toolResult, try canonicalJSON(response))
        XCTAssertEqual(message.observedState, "error")
    }

    func testNativeDecisionIsTopLevelAndDenialIsNotAnErrorExit() throws {
        for approved in [false, true] {
            let response = DevinHookAdapter.permissionResponse(approved: approved)
            let json = try XCTUnwrap(response.stdout)
            let data = try XCTUnwrap(json.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["decision"] as? String, approved ? "approve" : "block")
            XCTAssertNil(object["hookSpecificOutput"])
            XCTAssertEqual(response.exitCode, 0)
        }
        let unavailable = DevinHookAdapter.unavailablePermissionResponse()
        XCTAssertEqual(unavailable.exitCode, 2)
        XCTAssertTrue(unavailable.stdout?.contains("\"block\"") == true)
    }

    func testMissingIdentityWrongEventAndMalformedToolsAreRejected() {
        XCTAssertThrowsError(try DevinHookAdapter.normalize(hookType: "Stop", sessionId: "devin-test", stdinData: nil, environment: [:]))
        XCTAssertThrowsError(try normalize("Stop", fields: ["session_id": " "]))
        XCTAssertThrowsError(try normalize("Stop", fields: ["hook_event_name": "PermissionRequest"]))
        XCTAssertThrowsError(try normalize("PermissionRequest", fields: ["tool_name": "exec", "tool_input": "pwd"]))
        XCTAssertThrowsError(try normalize("PreToolUse", fields: ["tool_name": "", "tool_input": [:]]))
        XCTAssertThrowsError(try normalize("PostToolUse", fields: ["tool_name": "exec", "tool_input": [:]]))
        XCTAssertThrowsError(try normalize("UserPromptSubmit", fields: [:]))
        XCTAssertThrowsError(try normalize("Stop", fields: ["prompt_id": 12]))
        XCTAssertThrowsError(try normalize("InventedHook", fields: [:]))
    }

    private func normalize(_ event: String, fields: [String: Any]) throws -> DIMessage {
        var input: [String: Any] = ["hook_event_name": event, "session_id": "native-session"]
        input.merge(fields) { _, replacement in replacement }
        return try DevinHookAdapter.normalize(
            hookType: event, sessionId: "devin-native-session", stdinData: input,
            environment: ["DEVIN_PROJECT_DIR": "/tmp/project with spaces", "TERM_PROGRAM": "iTerm.app", "TERM_SESSION_ID": "terminal-1"]
        )
    }

    private func firstHandler(_ config: [String: Any], event: String) throws -> [String: Any] {
        let hooks = try XCTUnwrap(config["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks[event] as? [[String: Any]])
        let handlers = try XCTUnwrap(groups.first?["hooks"] as? [[String: Any]])
        return try XCTUnwrap(handlers.first)
    }

    private func canonicalJSON(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
