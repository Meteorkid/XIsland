import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

final class WindsurfHookAdapterTests: XCTestCase {
    func testConfigurationUsesNativePathAndFlatObservationCommands() throws {
        XCTAssertEqual(WindsurfHookConfiguration.relativeConfigPath, ".codeium/windsurf/hooks.json")
        let config = try WindsurfHookConfiguration.merging(into: [:], bridgePath: "/bin/di-bridge")
        let hooks = try XCTUnwrap(config["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(WindsurfHookConfiguration.events))
        XCTAssertEqual(hooks.count, 10)
        for event in hooks.keys {
            let commands = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertEqual(commands.count, 1)
            XCTAssertEqual(commands[0]["show_output"] as? Bool, false)
            XCTAssertNil(commands[0]["hooks"])
            XCTAssertNil(commands[0]["timeout"])
            XCTAssertTrue((commands[0]["command"] as? String)?.contains(" || true # XIsland:Windsurf:") == true)
        }
        XCTAssertNil(hooks["onIdle"])
        XCTAssertNil(hooks["post_cascade_response_with_transcript"])
        XCTAssertTrue(WindsurfHookConfiguration.isConfigured(in: config, bridgePath: "/bin/di-bridge"))
    }

    func testMergeAndRemovalPreserveThirdPartyCommandsAndSettings() throws {
        let thirdParty: [String: Any] = [
            "command": "audit di-bridge --agent windsurf", "working_directory": "/tmp/my project", "show_output": true,
        ]
        let original: [String: Any] = ["custom": 12, "hooks": [
            "pre_run_command": [thirdParty], "FutureEvent": [["powershell": "Write-Output 'hello'"]],
        ]]
        let merged = try WindsurfHookConfiguration.merging(into: original, bridgePath: "/bin/di-bridge")
        let removed = try WindsurfHookConfiguration.removing(from: merged)
        XCTAssertEqual(try canonicalJSON(original), try canonicalJSON(removed))
        XCTAssertEqual(try canonicalJSON(original), try canonicalJSON(WindsurfHookConfiguration.removing(from: original)))
        XCTAssertFalse(WindsurfHookConfiguration.isConfigured(in: removed, bridgePath: "/bin/di-bridge"))
    }

    func testMergeIsIdempotentAndUpdatesOnlyOwnedBridgePath() throws {
        let first = try WindsurfHookConfiguration.merging(into: [:], bridgePath: "/old/di-bridge")
        let second = try WindsurfHookConfiguration.merging(into: first, bridgePath: "/new/di-bridge")
        let third = try WindsurfHookConfiguration.merging(into: second, bridgePath: "/new/di-bridge")
        XCTAssertEqual(try canonicalJSON(second), try canonicalJSON(third))
        XCTAssertFalse(try canonicalJSON(second).contains("/old/di-bridge"))
        XCTAssertFalse(WindsurfHookConfiguration.isConfigured(in: second, bridgePath: "/old/di-bridge"))
    }

    func testShellQuotedPathIsLiteralAndWrapperCommandIsNotOwned() throws {
        let path = "/tmp/O'Brien $(touch unexpected) `echo bad`/di-bridge"
        let merged = try WindsurfHookConfiguration.merging(into: [:], bridgePath: path)
        var hooks = try XCTUnwrap(merged["hooks"] as? [String: Any])
        let commands = try XCTUnwrap(hooks["pre_user_prompt"] as? [[String: Any]])
        let command = try XCTUnwrap(commands[0]["command"] as? String)
        XCTAssertTrue(command.hasPrefix("'/tmp/O'\\''Brien $(touch unexpected) `echo bad`/di-bridge' --agent"))
        hooks["pre_user_prompt"] = [["command": "echo " + command]]
        let wrapped: [String: Any] = ["hooks": hooks]
        let removed = try WindsurfHookConfiguration.removing(from: wrapped)
        let retained = try XCTUnwrap(removed["hooks"] as? [String: Any])
        XCTAssertEqual((retained["pre_user_prompt"] as? [[String: String]])?.first?["command"], "echo " + command)
        XCTAssertTrue(WindsurfHookConfiguration.isConfigured(in: merged, bridgePath: path))
    }

    func testMalformedConfigurationsAndInvalidPathsDoNotProduceReplacement() {
        let malformed: [[String: Any]] = [
            ["hooks": NSNull()], ["hooks": []], ["hooks": ["pre_user_prompt": "wrong"]],
            ["hooks": ["pre_user_prompt": [["hooks": []]]]],
            ["hooks": ["pre_user_prompt": [["command": 1]]]],
            ["hooks": ["pre_user_prompt": [["command": "audit", "show_output": 1]]]],
            ["hooks": ["pre_user_prompt": [["command": "audit", "working_directory": []]]]],
        ]
        for config in malformed {
            XCTAssertThrowsError(try WindsurfHookConfiguration.merging(into: config, bridgePath: "/bin/di-bridge"))
            XCTAssertThrowsError(try WindsurfHookConfiguration.removing(from: config))
            XCTAssertFalse(WindsurfHookConfiguration.isConfigured(in: config, bridgePath: "/bin/di-bridge"))
        }
        for path in ["~/bin/di-bridge", "/bin/di\0bridge"] {
            XCTAssertThrowsError(try WindsurfHookConfiguration.merging(into: [:], bridgePath: path))
        }
    }

    func testIdentityUsesConversationAndKeepsMultipleTurnsTogether() throws {
        let first = try normalize("pre_user_prompt", info: ["user_prompt": "实现搜索"])
        let next = try normalize("pre_user_prompt", info: ["user_prompt": "加测试"], fields: ["execution_id": "turn-2"])
        let other = try normalize("pre_user_prompt", info: ["user_prompt": "另一个会话"], fields: ["trajectory_id": "conversation-2"])
        XCTAssertEqual(first.sessionId, "windsurf-conversation-1")
        XCTAssertEqual(first.sessionId, next.sessionId)
        XCTAssertNotEqual(first.sessionId, other.sessionId)
        XCTAssertEqual(first.type, .sessionStart)
        XCTAssertEqual(first.prompt, "实现搜索")
        XCTAssertEqual(first.agentType, "windsurf")
        XCTAssertEqual(first.model, "Example model")
        XCTAssertNil(first.workingDir)
    }

    func testTimestampsAreISO8601NotEpochOrDuration() throws {
        let first = try normalize("post_cascade_response", info: ["response": "done"])
        let fractional = try normalize("post_cascade_response", info: ["response": "done"], fields: ["timestamp": "2026-09-16T05:25:43.250Z"])
        XCTAssertEqual(fractional.timestamp.timeIntervalSince(first.timestamp), 0.25, accuracy: 0.001)
        XCTAssertThrowsError(try normalize("post_cascade_response", info: ["response": "done"], fields: ["timestamp": 123456]))
        XCTAssertThrowsError(try normalize("post_cascade_response", info: ["response": "done"], fields: ["timestamp": "123456"]))
    }

    func testToolsPreserveNativeInputsWithoutInventingResultsOrApprovals() throws {
        let command: [String: Any] = ["command_line": "echo hello", "cwd": "/tmp/project"]
        for event in ["pre_run_command", "post_run_command"] {
            let message = try normalize(event, info: command)
            XCTAssertEqual(message.type, event.hasPrefix("pre_") ? .toolStart : .toolComplete)
            XCTAssertEqual(message.toolInput, try canonicalJSON(command))
            XCTAssertEqual(message.workingDir, "/tmp/project")
            XCTAssertNil(message.toolResult)
            XCTAssertNil(message.permDescription)
            XCTAssertNil(message.questionText)
        }
        let write: [String: Any] = ["file_path": "/tmp/project/a.swift", "edits": [["old_string": "a", "new_string": "b"]]]
        for event in ["pre_write_code", "post_write_code"] {
            XCTAssertEqual(try normalize(event, info: write).filePath, "/tmp/project/a.swift")
        }
        for event in ["pre_read_code", "post_read_code"] {
            XCTAssertEqual(try normalize(event, info: ["file_path": "/tmp/project"]).tool, "Read")
        }
    }

    func testMCPQuestionNamedToolRemainsAnObservation() throws {
        let info: [String: Any] = ["mcp_server_name": "sample", "mcp_tool_name": "AskUserQuestion", "mcp_tool_arguments": ["question": "继续？"]]
        let start = try normalize("pre_mcp_tool_use", info: info)
        XCTAssertEqual(start.type, .toolStart)
        XCTAssertNil(start.questionText)
        let complete = try normalize("post_mcp_tool_use", info: info.merging(["mcp_result": "用户尚未回答"]) { _, new in new })
        XCTAssertEqual(complete.toolResult, "用户尚未回答")
    }

    func testResponseEndsTurnWithoutClosingConversation() throws {
        let message = try normalize("post_cascade_response", info: ["response": "### 完成\n任务已经完成"])
        XCTAssertEqual(message.type, .statusUpdate)
        XCTAssertEqual(message.observedState, "idle")
        XCTAssertEqual(message.statusIsAssistantReply, true)
        XCTAssertEqual(message.status, "### 完成\n任务已经完成")
    }

    func testMissingIdentityWrongEventAndMalformedPayloadAreRejected() {
        XCTAssertThrowsError(try WindsurfHookAdapter.normalize(hookType: "pre_user_prompt", stdinData: nil, environment: [:]))
        for field in ["trajectory_id", "execution_id", "model_name"] {
            XCTAssertThrowsError(try normalize("pre_user_prompt", info: ["user_prompt": "test"], fields: [field: " "]))
        }
        XCTAssertThrowsError(try normalize("pre_user_prompt", info: [:]))
        XCTAssertThrowsError(try normalize("pre_user_prompt", info: ["user_prompt": "test"], fields: ["agent_action_name": "post_cascade_response"]))
        XCTAssertThrowsError(try normalize("pre_run_command", info: ["command_line": "pwd"]))
        XCTAssertThrowsError(try normalize("pre_read_code", info: ["file_path": 12]))
        XCTAssertThrowsError(try normalize("pre_write_code", info: ["file_path": "/tmp/test", "edits": [["old_string": "test"]]]))
        XCTAssertThrowsError(try normalize("pre_mcp_tool_use", info: ["mcp_server_name": "server", "mcp_tool_name": "tool", "mcp_tool_arguments": "{}"]))
        XCTAssertThrowsError(try normalize("onIdle", info: [:]))
        XCTAssertThrowsError(try normalize("post_cascade_response_with_transcript", info: ["transcript_path": "/tmp/transcript"]))
    }

    private func normalize(_ event: String, info: [String: Any], fields: [String: Any] = [:]) throws -> DIMessage {
        var data: [String: Any] = [
            "agent_action_name": event, "trajectory_id": "conversation-1", "execution_id": "turn-1",
            "timestamp": "2026-09-16T05:25:43Z", "model_name": "Example model", "tool_info": info,
        ]
        data.merge(fields) { _, replacement in replacement }
        return try WindsurfHookAdapter.normalize(hookType: event, stdinData: data, environment: [:])
    }

    private func canonicalJSON(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
