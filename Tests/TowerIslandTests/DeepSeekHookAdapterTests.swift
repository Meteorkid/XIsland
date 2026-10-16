import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

final class DeepSeekHookAdapterTests: XCTestCase {
    func testConfigurationPinsCodewhaleContractAndMakesAllHooksObservers() throws {
        XCTAssertEqual(DeepSeekHookConfiguration.supportedVersion, "0.10.0")
        XCTAssertEqual(DeepSeekHookConfiguration.relativeConfigPath, ".codewhale/config.toml")
        let config = try DeepSeekHookConfiguration.merging(into: "", bridgePath: "/bin/di-bridge")
        XCTAssertEqual(config.components(separatedBy: "[[hooks.hooks]]").count - 1, 14)
        for field in ["continue_on_error = true", "timeout_secs = 5", "condition = { type = \"always\" }"] {
            XCTAssertEqual(config.components(separatedBy: field).count - 1, 14)
        }
        XCTAssertEqual(config.components(separatedBy: "background = true").count - 1, 2)
        XCTAssertEqual(config.components(separatedBy: "background = false").count - 1, 12)
        XCTAssertFalse(config.contains("|| true"))
        XCTAssertFalse(config.contains("shell_env"))
        XCTAssertFalse(config.contains("[hooks]\n"))
        XCTAssertTrue(DeepSeekHookConfiguration.isConfigured(in: config, bridgePath: "/bin/di-bridge"))
        XCTAssertEqual(try DeepSeekHookConfiguration.removing(from: config), "")
    }

    func testRoundTripPreservesThirdPartyTOMLAndCommentsExactly() throws {
        let original = """
        # preserve formatting
        model = 'user-model'
        description = '''
        # BEGIN XIsland:Codewhale:hooks v1
        [hooks]
        # END XIsland:Codewhale:hooks v1
        '''
        [hooks] # user's timeout applies to every hook
        enabled = true
        default_timeout_secs = 18
        [[hooks.hooks]]
        name = 'user-audit'
        event = 'session_end'
        command = 'audit di-bridge --agent deepseek'
        condition = { type = 'always' }
        [models.custom]
        hooks = [
          '[hooks]',
          'other',
        ]
        """
        for source in [original, original + "\n", original.replacingOccurrences(of: "\n", with: "\r\n")] {
            let config = try DeepSeekHookConfiguration.merging(into: source, bridgePath: "/bin/di-bridge")
            XCTAssertTrue(config.hasPrefix(source))
            XCTAssertEqual(try DeepSeekHookConfiguration.removing(from: config), source)
            XCTAssertEqual(try DeepSeekHookConfiguration.removing(from: source), source)
        }
    }

    func testIdempotencyAndBridgeReplacementOnlyTouchOwnedBlock() throws {
        let original = "[hooks]\nenabled=true\n[[hooks.hooks]]\nevent='session_start'\ncommand='/old/di-bridge --agent deepseek --hook session_start'\n"
        let first = try DeepSeekHookConfiguration.merging(into: original, bridgePath: "/old/di-bridge")
        let second = try DeepSeekHookConfiguration.merging(into: first, bridgePath: "/new/di-bridge")
        XCTAssertEqual(try DeepSeekHookConfiguration.merging(into: second, bridgePath: "/new/di-bridge"), second)
        XCTAssertEqual(try DeepSeekHookConfiguration.removing(from: second), original)
        XCTAssertFalse(DeepSeekHookConfiguration.isConfigured(in: second, bridgePath: "/old/di-bridge"))
    }

    func testShellAndTOMLPathEscapingIsLiteral() throws {
        let path = "/tmp/O'Brien $(touch forbidden) `false` \\ \"a\"/di-bridge"
        let config = try DeepSeekHookConfiguration.merging(into: "", bridgePath: path)
        XCTAssertTrue(DeepSeekHookConfiguration.isConfigured(in: config, bridgePath: path))
        let line = try XCTUnwrap(config.components(separatedBy: "\n").first { $0.hasPrefix("command = ") })
        let command = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst(10).utf8), options: [.fragmentsAllowed]) as? String)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s\\n' " + command]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), path + "\n--agent\ndeepseek\n--hook\nsession_start\n")
    }

    func testDisabledGlobalHooksAreNotEnabledAsASideEffect() throws {
        let original = "[hooks]\nenabled = false\n"
        XCTAssertThrowsError(try DeepSeekHookConfiguration.merging(into: original, bridgePath: "/bin/di-bridge")) { error in
            XCTAssertEqual(error as? DeepSeekHookConfiguration.ConfigurationError, .hooksDisabled)
        }
        XCTAssertEqual(try DeepSeekHookConfiguration.removing(from: original), original)
        let config = try DeepSeekHookConfiguration.merging(into: "[hooks]\nenabled = true\n", bridgePath: "/bin/di-bridge")
        let disabled = config.replacingOccurrences(of: "enabled = true", with: "enabled = false")
        XCTAssertFalse(DeepSeekHookConfiguration.isConfigured(in: disabled, bridgePath: "/bin/di-bridge"))
        XCTAssertEqual(try DeepSeekHookConfiguration.removing(from: disabled), original)
    }

    func testAmbiguousTOMLAndModifiedOwnedBlocksAreRejected() throws {
        let owned = try DeepSeekHookConfiguration.merging(into: "", bridgePath: "/bin/di-bridge")
        let invalid = [
            "hooks = {}", "hooks.enabled=true", "[hooks]\nhooks=[]", "[[hooks]]", "[hooks.hooks]",
            "[hooks]\nenabled=true\nenabled=false", "[hooks]\nenabled=1", "[hooks]\n[hooks]\n",
            "[hooks.extra]", "[\"\\u0068ooks\"]", "text='unfinished", "items=[1, 2", "items={x=1]", "x='a'\rx='b'",
            "[[hooks.hooks]]\ncondition='*'", owned + "[user]\nkeep=true\n",
            owned.replacingOccurrences(of: "timeout_secs = 5", with: "timeout_secs = 8"),
            owned.replacingOccurrences(of: "# END XIsland:Codewhale:hooks v1", with: "# removed"), owned + owned,
        ]
        for source in invalid {
            XCTAssertThrowsError(try DeepSeekHookConfiguration.merging(into: source, bridgePath: "/new/di-bridge"), source)
            XCTAssertThrowsError(try DeepSeekHookConfiguration.removing(from: source), source)
            XCTAssertFalse(DeepSeekHookConfiguration.isConfigured(in: source, bridgePath: "/bin/di-bridge"), source)
        }
        for path in ["relative", "~/bin/bridge", "/tmp/line\nbridge", "/tmp/nul\0bridge"] {
            XCTAssertThrowsError(try DeepSeekHookConfiguration.merging(into: "", bridgePath: path))
        }
    }

    func testExactLegacyTemplatesAreRemovedIncludingMarkerlessDuplicates() throws {
        let legacy = "[[hooks.hooks]]\nname = \"xisland_tool_call_before\"\nevent = \"tool_call_before\"\ncommand = \"/old/di-bridge --agent deepseek --hook PreToolUse || true\"\ncondition = \"*\"\n"
        let original = "[hooks]\nenabled = true\n# X Island hooks\n"
        let merged = try DeepSeekHookConfiguration.merging(into: original + legacy + legacy, bridgePath: "/new/di-bridge")
        XCTAssertEqual(try DeepSeekHookConfiguration.removing(from: merged), original)
        XCTAssertFalse(merged.contains("condition = \"*\""))
        XCTAssertFalse(merged.contains("PreToolUse"))
        // 手改旧模板不再能证明所有权，尤其不能默默留下无效 condition 然后报告安装成功。
        XCTAssertThrowsError(try DeepSeekHookConfiguration.merging(into: legacy + "custom = true\n", bridgePath: "/bin/di-bridge"))
        let modified = legacy.replacingOccurrences(of: "condition = \"*\"", with: "condition = { type = 'always' }")
        XCTAssertEqual(try DeepSeekHookConfiguration.removing(from: modified), modified)
    }

    func testDefaultPathUsesExistingLegacyWithoutCreatingAnOverridingNewConfig() throws {
        XCTAssertEqual(try path(existing: []), "/users/test/.codewhale/config.toml")
        XCTAssertEqual(try path(existing: ["/users/test/.deepseek/config.toml"]), "/users/test/.deepseek/config.toml")
        XCTAssertEqual(try path(existing: ["/users/test/.deepseek/config.toml", "/users/test/.codewhale/config.toml"]), "/users/test/.codewhale/config.toml")
    }

    func testConfigPathOverridesMatchUpstreamPriorityAndIsolation() throws {
        let env = ["CODEWHALE_CONFIG_PATH": "~/new.toml", "DEEPSEEK_CONFIG_PATH": "/old.toml", "CODEWHALE_HOME": "/isolated"]
        XCTAssertEqual(try path(environment: env), "/users/test/new.toml")
        XCTAssertEqual(try path(environment: ["CODEWHALE_CONFIG_PATH": "  ~/new.toml \n"]), "/users/test/new.toml")
        XCTAssertEqual(try path(environment: env, explicit: "local.toml"), "/workspace/local.toml")
        XCTAssertEqual(try path(environment: ["DEEPSEEK_CONFIG_PATH": "/old.toml", "CODEWHALE_HOME": "/isolated"]), "/old.toml")
        XCTAssertEqual(try path(environment: ["CODEWHALE_HOME": "~/isolated"], existing: ["/users/test/.deepseek/config.toml"]), "/users/test/isolated/config.toml")
        XCTAssertEqual(try path(environment: ["CODEWHALE_CONFIG_PATH": "  ", "CODEWHALE_HOME": ""]), "/users/test/.codewhale/config.toml")
        for env in [["CODEWHALE_CONFIG_PATH": "relative"], ["DEEPSEEK_CONFIG_PATH": "relative"], ["CODEWHALE_HOME": "relative"], ["CODEWHALE_CONFIG_PATH": "/a/../b.toml"]] {
            XCTAssertThrowsError(try path(environment: env))
        }
        XCTAssertThrowsError(try path(explicit: "../other.toml"))
        XCTAssertThrowsError(try path(explicit: ""))
    }

    func testEnvironmentOnlyLifecycleAndNativeIdentityAcrossWorkspaceChanges() throws {
        let start = try normalize("session_start")
        let end = try normalize("session_end")
        let moved = try normalize("session_start", environment: ["DEEPSEEK_WORKSPACE": "/other"])
        XCTAssertEqual(start.type, .sessionStart)
        XCTAssertEqual(start.sessionId, "deepseek-sess_native1")
        XCTAssertEqual(start.sessionId, end.sessionId)
        XCTAssertEqual(start.sessionId, moved.sessionId)
        XCTAssertEqual(start.agentType, "deepseek")
        XCTAssertEqual(start.nativeEvent, "session_start")
        XCTAssertEqual(end.nativeEvent, "session_end")
        XCTAssertEqual(start.usageIsCumulative, true)
        XCTAssertEqual(start.workingDir, "/workspace")
        XCTAssertEqual(start.model, "deepseek-v4-flash")
        XCTAssertEqual(start.terminal, "iTerm.app")
        XCTAssertEqual(start.termSessionId, "term-1")
        XCTAssertEqual(end.type, .sessionEnd)
        XCTAssertEqual(end.observedState, "completed")
        XCTAssertNil(start.prompt)
    }

    func testMessageSubmitUsesBoundedNativeTextNotEnvironmentPreview() throws {
        let first = try normalize("message_submit", payload: ["event": "message_submit", "text": "原生提示", "text_truncated": false], environment: ["DEEPSEEK_MESSAGE": "old preview"])
        let next = try normalize("message_submit", payload: ["event": "message_submit", "text": "下一轮", "text_truncated": true])
        XCTAssertEqual(first.prompt, "原生提示")
        XCTAssertEqual(first.sessionId, next.sessionId)
        XCTAssertEqual(next.prompt, "下一轮\n[Codewhale preview truncated]")
        XCTAssertEqual(first.observedState, "active")
        XCTAssertEqual(first.nativeEvent, "message_submit")
        XCTAssertNil(first.approved)
    }

    func testToolsKeepNativeIDsAndTruncatedInputWithoutInventingInteractions() throws {
        for tool in ["exec_shell", "request_user_input", "ExitPlanMode"] {
            let message = try normalize("tool_call_before", environment: ["DEEPSEEK_TOOL_NAME": tool, "DEEPSEEK_TOOL_ARGS": "{\"large\":\"...[truncated]", "DEEPSEEK_TOOL_CALL_ID": "call-native"])
            XCTAssertEqual(message.type, .toolStart)
            XCTAssertEqual(message.tool, tool)
            XCTAssertEqual(message.toolCallId, "call-native")
            XCTAssertEqual(message.toolInput, "{\"large\":\"...[truncated]")
            XCTAssertNil(message.filePath)
            XCTAssertNil(message.permDescription)
            XCTAssertNil(message.questionText)
            XCTAssertNil(message.planMarkdown)
            XCTAssertNil(message.approved)
        }
        let output = try normalize("tool_call_after", environment: ["DEEPSEEK_TOOL_NAME": "exec_shell", "DEEPSEEK_TOOL_CALL_ID": "call-native", "DEEPSEEK_TOOL_RESULT": "", "DEEPSEEK_TOOL_SUCCESS": "false", "DEEPSEEK_TOOL_EXIT_CODE": "3221225477"])
        XCTAssertEqual(output.type, .toolComplete)
        XCTAssertEqual(output.toolResult, "")
        XCTAssertEqual(output.observedState, "error")
    }

    func testModernIdentityAliasesAgreeWithLegacyAndMissingIdentityFails() throws {
        let modern = try DeepSeekHookAdapter.normalize(hookType: "session_start", stdinData: nil, environment: ["CODEWHALE_SESSION_ID": "sess_native1"])
        XCTAssertEqual(modern.sessionId, "deepseek-sess_native1")
        for env in [[:], ["CODEWHALE_SESSION_ID": ""], ["DEEPSEEK_SESSION_ID": " \n"], ["DEEPSEEK_SESSION_ID": "native\0id"], ["CODEWHALE_SESSION_ID": "one", "DEEPSEEK_SESSION_ID": "two"]] {
            XCTAssertThrowsError(try DeepSeekHookAdapter.normalize(hookType: "session_start", stdinData: nil, environment: env))
        }
        XCTAssertThrowsError(try normalize("message_submit", payload: ["event": "message_submit", "session_id": "other", "text": "prompt"]))
        XCTAssertThrowsError(try normalize("session_start", payload: ["session_id": "json-is-not-the-contract"]))
        XCTAssertThrowsError(try normalize("tool_call_before", environment: ["DEEPSEEK_TOOL_NAME": "exec_shell", "DEEPSEEK_TOOL_ARGS": "{}", "CODEWHALE_TOOL_CALL_ID": "a", "DEEPSEEK_TOOL_CALL_ID": "b"]))
    }

    func testWaitingStatesRemainObservationsWithoutQuestionOrPermissionPayload() throws {
        for (reason, expected) in [("approval", "waitingPermission"), ("user_input", "waitingAnswer"), ("goal_continuation", "waitingAnswer")] {
            let message = try normalize("waiting_for_user", payload: ["from": "in_progress", "to": "waiting", "reason": reason])
            XCTAssertEqual(message.type, .statusUpdate)
            XCTAssertEqual(message.observedState, expected)
            XCTAssertNil(message.nativeRequestId)
            XCTAssertNil(message.permDescription)
            XCTAssertNil(message.questionText)
            XCTAssertNil(message.options)
            XCTAssertNil(message.answer)
        }
        let unknown = try normalize("waiting_for_user", payload: ["from": "idle", "to": "waiting"])
        XCTAssertNil(unknown.observedState)
        XCTAssertEqual(try normalize("session_busy", payload: ["from": "waiting", "to": "in_progress"]).observedState, "active")
        XCTAssertEqual(try normalize("session_idle", payload: ["from": "in_progress", "to": "idle", "last_turn_status": "completed"]).observedState, "idle")
    }

    func testTurnEndUsesCumulativeTotalsAndDoesNotInventFinalReplyOrIdle() throws {
        let payload: [String: Any] = ["event": "turn_end", "status": "completed", "error": NSNull(), "queued_message_count": 1, "usage": ["input_tokens": 4, "output_tokens": 2], "totals": ["session_tokens": 150, "input_tokens": 100, "output_tokens": 50]]
        let message = try normalize("turn_end", payload: payload, environment: ["DEEPSEEK_TOTAL_TOKENS": "150", "DEEPSEEK_SESSION_COST": "0.001234"])
        XCTAssertEqual(message.totalTokens, 150)
        XCTAssertEqual(message.tokensIn, 100)
        XCTAssertEqual(message.tokensOut, 50)
        XCTAssertEqual(message.costUSD, 0.001234)
        XCTAssertEqual(message.usageIsCumulative, true)
        XCTAssertNil(message.observedState)
        XCTAssertNil(message.status)
        XCTAssertNil(message.recapText)
        XCTAssertEqual(message.statusIsAssistantReply, false)
    }

    func testTransientErrorAndTerminalFailureHaveDifferentStateSemantics() throws {
        let transient = try normalize("on_error", environment: ["DEEPSEEK_ERROR": "tool failed; may retry"])
        XCTAssertEqual(transient.status, "tool failed; may retry")
        XCTAssertNil(transient.observedState)
        let terminal = try normalize("session_error", payload: ["status": "failed", "error": "transport offline"])
        XCTAssertEqual(terminal.observedState, "error")
        XCTAssertEqual(terminal.status, "transport offline")
        let mode = try normalize("mode_change", environment: ["DEEPSEEK_PREVIOUS_MODE": "PLAN", "DEEPSEEK_MODE": "ACT"])
        XCTAssertEqual(mode.status, "Codewhale: PLAN → ACT")
        XCTAssertNil(mode.planMarkdown)
    }

    func testSubagentLifecycleUsesNativeAgentIDAndPreviewFields() throws {
        let spawn = try normalize("subagent_spawn", payload: ["event": "subagent_spawn", "agent_id": "agent-real", "prompt_preview": "inspect", "prompt_truncated": false])
        let done = try normalize("subagent_complete", payload: ["event": "subagent_complete", "agent_id": "agent-real", "result_preview": "result", "result_truncated": true, "status": "cancelled"])
        XCTAssertEqual(spawn.type, .subagentStart)
        XCTAssertEqual(done.type, .subagentEnd)
        XCTAssertEqual(spawn.parentSessionId, spawn.sessionId)
        XCTAssertEqual(spawn.subagentId, "deepseek-sess_native1-subagent-agent-real")
        XCTAssertEqual(spawn.subagentId, done.subagentId)
        XCTAssertEqual(done.status, "cancelled")
        XCTAssertEqual(done.toolResult, "result\n[Codewhale preview truncated]")
    }

    func testMalformedNativePayloadsAndUnsupportedShellEnvironmentAreRejected() {
        XCTAssertThrowsError(try normalize("shell_env"))
        XCTAssertThrowsError(try normalize("PermissionRequest"))
        XCTAssertThrowsError(try normalize("message_submit"))
        XCTAssertThrowsError(try normalize("message_submit", payload: ["event": "turn_end", "text": "text"]))
        XCTAssertThrowsError(try normalize("message_submit", payload: ["event": "message_submit", "text": 5]))
        XCTAssertThrowsError(try normalize("message_submit", payload: ["event": "message_submit", "text": "text", "text_truncated": 1]))
        XCTAssertThrowsError(try normalize("session_busy", payload: ["from": "idle", "to": "waiting"]))
        XCTAssertThrowsError(try normalize("session_idle", payload: ["from": "idle", "to": "idle"]))
        XCTAssertThrowsError(try normalize("waiting_for_user", payload: ["from": "idle", "to": "waiting", "reason": "invented"]))
        XCTAssertThrowsError(try normalize("session_error", payload: ["status": "completed", "error": "error"]))
        XCTAssertThrowsError(try normalize("subagent_spawn", payload: ["event": "subagent_spawn", "prompt_preview": "missing ID"]))
        for value: Any in [true, -1, 1.5, "10"] {
            XCTAssertThrowsError(try normalize("turn_end", payload: ["event": "turn_end", "status": "completed", "totals": ["session_tokens": value, "input_tokens": 1, "output_tokens": 1]]))
        }
        for cost in ["nan", "inf", "-0.1", "bad"] { XCTAssertThrowsError(try normalize("session_start", environment: ["DEEPSEEK_SESSION_COST": cost])) }
    }

    private func path(environment: [String: String] = [:], existing: Set<String> = [], explicit: String? = nil) throws -> String {
        try DeepSeekHookConfiguration.resolvedConfigPath(homeDirectory: "/users/test", environment: environment, explicitPath: explicit, currentDirectory: "/workspace", fileExists: existing.contains)
    }

    private func normalize(_ event: String, payload: [String: Any]? = nil, environment: [String: String] = [:]) throws -> DIMessage {
        let base = ["CODEWHALE_SESSION_ID": "sess_native1", "DEEPSEEK_SESSION_ID": "sess_native1", "DEEPSEEK_WORKSPACE": "/workspace", "DEEPSEEK_MODEL": "deepseek-v4-flash", "TERM_PROGRAM": "iTerm.app", "TERM_SESSION_ID": "term-1"]
        return try DeepSeekHookAdapter.normalize(hookType: event, stdinData: payload, environment: base.merging(environment) { _, new in new })
    }
}
