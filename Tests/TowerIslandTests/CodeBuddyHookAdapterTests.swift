import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

final class CodeBuddyHookAdapterTests: XCTestCase {
    func testConfigurationUsesCLIPathAndOnlyVerifiedObservationEvents() throws {
        XCTAssertEqual(CodeBuddyHookConfiguration.relativeConfigPath, ".codebuddy/settings.json")
        let config = try CodeBuddyHookConfiguration.merging(into: [:], bridgePath: "/bin/di-bridge")
        let hooks = try XCTUnwrap(config["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set([
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification",
            "Stop", "SubagentStop", "PreCompact", "PostCompact", "SessionEnd",
        ]))
        XCTAssertNil(hooks["PermissionRequest"])
        XCTAssertNil(hooks["PostToolUseFailure"])
        for event in hooks.keys {
            let group = try firstGroup(config, event: event)
            XCTAssertNil(group["matcher"])
            let handler = try XCTUnwrap((group["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(handler["type"] as? String, "command")
            XCTAssertEqual(handler["command"] as? String, "'/bin/di-bridge' --agent code_buddy --hook \(event) || true")
            XCTAssertEqual(handler["timeout"] as? Int, event == "SessionEnd" ? 1 : 5)
        }
    }

    func testConfigurationIsIdempotentAndDetectsPathChanges() throws {
        let original = try CodeBuddyHookConfiguration.merging(into: ["model": "keep"], bridgePath: "/old/di-bridge")
        let updated = try CodeBuddyHookConfiguration.merging(into: original, bridgePath: "/new/di-bridge")
        let repeated = try CodeBuddyHookConfiguration.merging(into: updated, bridgePath: "/new/di-bridge")
        XCTAssertEqual(try canonicalJSON(updated), try canonicalJSON(repeated))
        XCTAssertFalse(try canonicalJSON(updated).contains("/old/di-bridge"))
        XCTAssertTrue(CodeBuddyHookConfiguration.isConfigured(in: updated, bridgePath: "/new/di-bridge"))
        XCTAssertFalse(CodeBuddyHookConfiguration.isConfigured(in: updated, bridgePath: "/old/di-bridge"))
        XCTAssertEqual(updated["model"] as? String, "keep")
    }

    func testMixedGroupsAndThirdPartySettingsSurviveRemoval() throws {
        let custom: [String: Any] = ["type": "command", "command": "audit di-bridge --agent code_buddy"]
        let prompt: [String: Any] = ["type": "prompt", "prompt": "Check this command"]
        let thirdParty: [String: Any] = [
            "model": "keep", "permissions": ["defaultMode": "plan"],
            "hooks": [
                "PreToolUse": [["matcher": "^Bash$", "hooks": [custom, prompt], "custom": "keep"]],
                "FutureEvent": [["hooks": [custom]]],
            ],
        ]
        var merged = try CodeBuddyHookConfiguration.merging(into: thirdParty, bridgePath: "/bin/di-bridge")
        var hooks = try XCTUnwrap(merged["hooks"] as? [String: Any])
        var groups = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let owned = try XCTUnwrap(groups.last?["hooks"] as? [[String: Any]])
        var mixed = groups[0]
        mixed["hooks"] = [custom, prompt] + owned
        groups = [mixed]
        hooks["PreToolUse"] = groups
        merged["hooks"] = hooks

        // matcher 被改动后不再是覆盖所有工具的完整配置。
        XCTAssertFalse(CodeBuddyHookConfiguration.isConfigured(in: merged, bridgePath: "/bin/di-bridge"))
        let removed = try CodeBuddyHookConfiguration.removing(from: merged)
        XCTAssertEqual(try canonicalJSON(removed), try canonicalJSON(thirdParty))
    }

    func testLegacyOwnedEventsAndDuplicateHandlersCannotPassDetection() throws {
        var config = try CodeBuddyHookConfiguration.merging(into: [:], bridgePath: "/bin/di-bridge")
        var hooks = try XCTUnwrap(config["hooks"] as? [String: Any])
        let oldPermission: [String: Any] = ["type": "command", "command": "'/old/di-bridge' --agent code_buddy --hook PermissionRequest"]
        let thirdParty: [String: Any] = ["type": "command", "command": "permission-audit"]
        hooks["PermissionRequest"] = [["hooks": [oldPermission, thirdParty]]]
        let stop = try firstGroup(config, event: "Stop")
        hooks["Stop"] = [stop, stop]
        config["hooks"] = hooks
        XCTAssertFalse(CodeBuddyHookConfiguration.isConfigured(in: config, bridgePath: "/bin/di-bridge"))

        let repaired = try CodeBuddyHookConfiguration.merging(into: config, bridgePath: "/bin/di-bridge")
        XCTAssertTrue(CodeBuddyHookConfiguration.isConfigured(in: repaired, bridgePath: "/bin/di-bridge"))
        let permission = try firstGroup(repaired, event: "PermissionRequest")
        XCTAssertEqual(try canonicalJSON(permission), try canonicalJSON(["hooks": [thirdParty]]))
    }

    func testOnlyExactOwnedCommandsAreRemoved() throws {
        let commands = [
            "'/bin/di-bridge' --agent claude_code --hook Stop || true",
            "wrapper '/bin/di-bridge' --agent code_buddy --hook Stop",
            "'/bin/di-bridge' --agent code_buddy --hook Stop; audit",
            "echo '/bin/di-bridge --agent code_buddy --hook Stop'",
            "'/bin/custom-bridge' --agent code_buddy --hook Stop",
        ]
        let handlers = commands.map { ["type": "command", "command": $0] }
        let original: [String: Any] = ["hooks": ["Stop": [["hooks": handlers]]]]
        let merged = try CodeBuddyHookConfiguration.merging(into: original, bridgePath: "/bin/di-bridge")
        XCTAssertEqual(try canonicalJSON(CodeBuddyHookConfiguration.removing(from: merged)), try canonicalJSON(original))
    }

    func testShellQuoteKeepsSpecialCharactersLiteralAndRejectsInvalidPaths() throws {
        let path = "/tmp/O'Brien $(touch unexpected) `echo bad`/di-bridge"
        let config = try CodeBuddyHookConfiguration.merging(into: [:], bridgePath: path)
        let group = try firstGroup(config, event: "PreToolUse")
        let handler = try XCTUnwrap((group["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(handler["command"] as? String,
                       "'/tmp/O'\\''Brien $(touch unexpected) `echo bad`/di-bridge' --agent code_buddy --hook PreToolUse || true")
        XCTAssertTrue(CodeBuddyHookConfiguration.isConfigured(in: config, bridgePath: path))
        for invalid in ["~/bin/di-bridge", "relative/di-bridge", "/tmp/\0di-bridge"] {
            XCTAssertThrowsError(try CodeBuddyHookConfiguration.merging(into: [:], bridgePath: invalid))
            XCTAssertFalse(CodeBuddyHookConfiguration.isConfigured(in: config, bridgePath: invalid))
        }
    }

    func testMalformedStructuresRejectMergeRemovalAndDetection() {
        let malformed: [[String: Any]] = [
            ["hooks": []], ["hooks": NSNull()], ["hooks": ["Stop": "invalid"]],
            ["hooks": ["Stop": [["hooks": "invalid"]]]],
            ["hooks": ["Stop": [["matcher": 42, "hooks": []]]]],
            ["hooks": ["Stop": [["hooks": [["type": "command"]]]]]],
            ["hooks": ["Stop": [["hooks": [["type": "command", "command": " "]]]]]],
            ["hooks": ["Stop": [["hooks": [["type": "prompt", "prompt": 42]]]]]],
            ["hooks": ["Stop": [["hooks": [["type": " ", "command": "audit"]]]]]],
            ["hooks": ["Stop": [["hooks": [["type": "command", "command": "audit", "timeout": true]]]]]],
            ["hooks": ["Stop": [["hooks": [["type": "command", "command": "audit", "timeout": "5"]]]]]],
            ["hooks": ["Stop": [["hooks": [["type": "command", "command": "audit", "timeout": 0]]]]]],
            ["nonJSON": Date()],
        ]
        for config in malformed {
            XCTAssertThrowsError(try CodeBuddyHookConfiguration.merging(into: config, bridgePath: "/bin/di-bridge"))
            XCTAssertThrowsError(try CodeBuddyHookConfiguration.removing(from: config))
            XCTAssertFalse(CodeBuddyHookConfiguration.isConfigured(in: config, bridgePath: "/bin/di-bridge"))
        }
    }

    func testRemovingWithoutHooksDoesNotCreateThem() throws {
        let config: [String: Any] = ["model": "keep"]
        XCTAssertEqual(try canonicalJSON(CodeBuddyHookConfiguration.removing(from: config)), try canonicalJSON(config))
    }

    func testPromptUsesActualCwdAndPreservesTerminalContext() throws {
        let message = try normalize("UserPromptSubmit", fields: ["prompt": "实现测试", "generation_id": "turn-1"])
        XCTAssertEqual(message.type, .sessionStart)
        XCTAssertEqual(message.agentType, "code_buddy")
        XCTAssertEqual(message.sessionId, "code_buddy-native-session")
        XCTAssertEqual(message.prompt, "实现测试")
        XCTAssertEqual(message.workingDir, "/project/subdirectory")
        XCTAssertEqual(message.terminal, "iTerm.app")
        XCTAssertEqual(message.termSessionId, "terminal-1")
        XCTAssertEqual(message.statusIsAssistantReply, false)
        XCTAssertNil(message.nativeRequestId)
    }

    func testDocumentedSessionStartWithoutCwdCanUseProjectEnvironment() throws {
        let message = try CodeBuddyHookAdapter.normalize(
            hookType: "SessionStart", sessionId: "code_buddy-native-session",
            stdinData: ["hook_event_name": "SessionStart", "session_id": "native-session", "source": "startup"],
            environment: ["CODEBUDDY_PROJECT_DIR": "/project root"]
        )
        XCTAssertEqual(message.workingDir, "/project root")
        XCTAssertNil(message.status)
    }

    func testPreToolUseNeverRequestsPermissionQuestionOrPlan() throws {
        for name in ["Bash", "AskUserQuestion", "ExitPlanMode", "ask_question", "exit_plan_mode"] {
            let input: [String: Any] = ["command": "pwd", "questions": [["question": "Continue?"]], "timeout": 10]
            let message = try normalize("PreToolUse", fields: ["tool_name": name, "tool_input": input])
            XCTAssertEqual(message.type, .toolStart)
            XCTAssertEqual(message.tool, name)
            XCTAssertEqual(message.toolInput, try canonicalJSON(input))
            XCTAssertNil(message.approved)
            XCTAssertNil(message.questionText)
            XCTAssertNil(message.planMarkdown)
            XCTAssertNil(message.nativeRequestId)
        }
    }

    func testToolResultPreservesTheNativeResponseObject() throws {
        let response: [String: Any] = ["filePath": "/tmp/a.txt", "success": true, "details": ["lines": 3]]
        let message = try normalize("PostToolUse", fields: [
            "tool_name": "Write", "tool_input": ["file_path": "/tmp/a.txt", "content": "你好"],
            "tool_response": response,
        ])
        XCTAssertEqual(message.type, .toolComplete)
        XCTAssertEqual(message.filePath, "/tmp/a.txt")
        XCTAssertEqual(message.toolResult, try canonicalJSON(response))
        XCTAssertNil(message.toolCallId)
    }

    func testPermissionNotificationOnlyObservesNativeWaitingState() throws {
        let message = try normalize("Notification", fields: ["notification_type": "permission_prompt", "message": "Needs permission"])
        XCTAssertEqual(message.type, .statusUpdate)
        XCTAssertEqual(message.observedState, "waitingPermission")
        XCTAssertEqual(message.status, "Needs permission")
        XCTAssertEqual(message.statusIsAssistantReply, false)
        XCTAssertNil(message.permDescription)
        XCTAssertNil(message.approved)
        XCTAssertNil(message.questionText)
        XCTAssertEqual(try normalize("Notification", fields: ["notification_type": "idle_prompt", "message": "Waiting"]).observedState, "idle")
        XCTAssertNil(try normalize("Notification", fields: ["notification_type": "auth_success", "message": "Signed in"]).observedState)
    }

    func testStopAndSubagentStopDoNotInventAssistantRepliesOrCloseSession() throws {
        let stop = try normalize("Stop", fields: ["stop_hook_active": false, "last_assistant_message": "Unverified field"])
        XCTAssertEqual(stop.type, .statusUpdate)
        XCTAssertEqual(stop.observedState, "completionUnconfirmed")
        XCTAssertEqual(stop.statusIsAssistantReply, false)
        XCTAssertNil(stop.status)
        let subagent = try normalize("SubagentStop", fields: ["stop_hook_active": true])
        XCTAssertEqual(subagent.type, .statusUpdate)
        XCTAssertNil(subagent.observedState)
        XCTAssertNil(subagent.subagentId)
        XCTAssertEqual(subagent.statusIsAssistantReply, false)
        let end = try normalize("SessionEnd", fields: ["reason": "other"])
        XCTAssertEqual(end.type, .sessionEnd)
        XCTAssertEqual(end.observedState, "completed")
    }

    func testCompactionUsesDocumentedCompactSummary() throws {
        XCTAssertEqual(try normalize("PreCompact", fields: ["trigger": "manual", "custom_instructions": ""]).type, .contextCompact)
        let compact = try normalize("PostCompact", fields: ["trigger": "auto", "compact_summary": "压缩摘要", "summary": "Wrong field"])
        XCTAssertEqual(compact.type, .recap)
        XCTAssertEqual(compact.recapText, "压缩摘要")
        XCTAssertNil(compact.status)
        XCTAssertEqual(compact.statusIsAssistantReply, false)
    }

    func testUnverifiedInteractiveAndFailureEventsAreRejected() {
        for event in ["PermissionRequest", "PermissionDenied", "PostToolUseFailure", "SubagentStart", "Elicitation", "InventedHook"] {
            XCTAssertThrowsError(try normalize(event, fields: ["tool_name": "Bash", "tool_input": [:]])) { error in
                XCTAssertEqual(error as? CodeBuddyHookAdapter.PayloadError, .unsupportedEvent(event))
            }
        }
    }

    func testMalformedNativePayloadsAreRejected() {
        XCTAssertThrowsError(try CodeBuddyHookAdapter.normalize(hookType: "Stop", sessionId: "code_buddy-test", stdinData: nil, environment: [:]))
        for fields: [String: Any] in [
            ["session_id": " "], ["session_id": 42], ["session_id": "bad\0id"],
            ["hook_event_name": "PermissionRequest"], ["cwd": 12], ["generation_id": 12],
            ["permission_mode": NSNull()], ["stop_hook_active": "false"], ["stop_hook_active": 1],
        ] {
            XCTAssertThrowsError(try normalize("Stop", fields: fields))
        }
        XCTAssertThrowsError(try normalize("UserPromptSubmit", fields: [:]))
        XCTAssertThrowsError(try normalize("PreToolUse", fields: ["tool_name": " ", "tool_input": [:]]))
        XCTAssertThrowsError(try normalize("PreToolUse", fields: ["tool_name": "Bash", "tool_input": "pwd"]))
        XCTAssertThrowsError(try normalize("PostToolUse", fields: ["tool_name": "Bash", "tool_input": [:], "tool_response": "unverified shape"]))
        XCTAssertThrowsError(try normalize("Notification", fields: ["message": "Waiting"]))
        XCTAssertThrowsError(try normalize("PostCompact", fields: ["summary": "Wrong field"]))
    }

    private func normalize(_ event: String, fields: [String: Any]) throws -> DIMessage {
        var input: [String: Any] = ["hook_event_name": event, "session_id": "native-session", "cwd": "/project/subdirectory"]
        input.merge(fields) { _, replacement in replacement }
        return try CodeBuddyHookAdapter.normalize(
            hookType: event, sessionId: "code_buddy-native-session", stdinData: input,
            environment: ["CODEBUDDY_PROJECT_DIR": "/project", "TERM_PROGRAM": "iTerm.app", "TERM_SESSION_ID": "terminal-1"]
        )
    }

    private func firstGroup(_ config: [String: Any], event: String) throws -> [String: Any] {
        let hooks = try XCTUnwrap(config["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks[event] as? [[String: Any]])
        return try XCTUnwrap(groups.first)
    }

    private func canonicalJSON(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
