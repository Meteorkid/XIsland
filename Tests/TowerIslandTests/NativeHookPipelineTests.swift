import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

final class NativeHookPipelineTests: XCTestCase {
    func testTabnineUsesNativeSettingsAndPreservesDisabledHooks() throws {
        let profile = try XCTUnwrap(NativeHookProfile.profile(for: .tabnine))
        XCTAssertEqual(profile.relativeConfigPath, ".tabnine/agent/settings.json")
        XCTAssertEqual(profile.timeoutUnit, .milliseconds)
        XCTAssertFalse(profile.bindings.contains { $0.event == "PermissionRequest" })
        let config = try profile.merging(into: ["hooksConfig": ["enabled": false, "disabled": ["audit"]]], bridgePath: "/bin/di-bridge")
        XCTAssertEqual((config["hooksConfig"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertEqual(profile.bindings.first { $0.event == "BeforeTool" }?.bridgeHook, "toolstart")
        XCTAssertEqual(profile.bindings.first { $0.event == "BeforeTool" }?.timeout, 5000)
    }

    func testTabnineReplyAndNativeToolFailureAreParsedWithoutPermissionInterception() throws {
        let reply = try DIBridge.makeMessage(agentType: "tabnine", hookType: "notification", sessionId: "fixture",
            stdinData: ["session_id": "fixture", "hook_event_name": "AfterAgent", "prompt_response": "Done"])
        XCTAssertEqual(reply.status, "Done")
        XCTAssertEqual(reply.observedState, "completionUnconfirmed")
        let failure = try DIBridge.makeMessage(agentType: "tabnine", hookType: "PostToolUse", sessionId: "fixture",
            stdinData: ["session_id": "fixture", "hook_event_name": "AfterTool", "tool_name": "run_shell_command",
                        "tool_input": ["command": "false"], "tool_response": ["error": ["message": "fixture failure"]]])
        XCTAssertEqual(failure.type, .toolComplete)
        XCTAssertEqual(failure.observedState, "error")
        XCTAssertTrue(DIBridge.needsJsonOutput("BeforeTool", agentType: "tabnine"))
    }

    func testInheritedClaudeHooksSkipOnlyDevinPayloadWithoutClaudeContext() {
        let devin: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "session", "prompt_id": "turn"]
        let environment = ["DEVIN_PROJECT_DIR": "/tmp/project"]
        XCTAssertTrue(DIBridge.shouldSkipImportedClaudeHook(agentType: "claude_code", stdinData: devin, environment: environment))
        XCTAssertFalse(DIBridge.shouldSkipImportedClaudeHook(agentType: "devin", stdinData: devin, environment: environment))
        XCTAssertFalse(DIBridge.shouldSkipImportedClaudeHook(agentType: "claude_code", stdinData: devin, environment: [:]))
        var nestedClaude = devin
        nestedClaude["cwd"] = "/tmp/project"
        XCTAssertFalse(DIBridge.shouldSkipImportedClaudeHook(agentType: "claude_code", stdinData: nestedClaude, environment: environment))
    }

    func testRepairDetectsMissingNativeEventWithoutTouchingUserHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try XCTUnwrap(NativeHookProfile.profile(for: .codex))
        let url = root.appendingPathComponent(profile.relativeConfigPath)
        XCTAssertFalse(ZeroConfigManager.shouldRepairNativeHooks(for: .codex, homeDirectory: root.path))
        var config = try profile.merging(into: [:], bridgePath: root.path + "/.xisland/bin/di-bridge")
        try HookConfigurationFile.update(at: url) { _ in config }
        XCTAssertFalse(ZeroConfigManager.shouldRepairNativeHooks(for: .codex, homeDirectory: root.path))
        var hooks = try XCTUnwrap(config["hooks"] as? [String: Any])
        hooks.removeValue(forKey: "PermissionRequest")
        config["hooks"] = hooks
        try HookConfigurationFile.update(at: url) { _ in config }
        XCTAssertTrue(ZeroConfigManager.shouldRepairNativeHooks(for: .codex, homeDirectory: root.path))
        try Data("broken JSON".utf8).write(to: url)
        XCTAssertFalse(ZeroConfigManager.shouldRepairNativeHooks(for: .codex, homeDirectory: root.path))
        XCTAssertEqual(try String(contentsOf: url), "broken JSON")
    }

    func testNativeProfileRejectsInvalidTimeoutsAndBridgePaths() throws {
        let profile = try XCTUnwrap(NativeHookProfile.profile(for: .codex))
        let invalidTimeouts: [Any] = [true, -1, 0, "300"]
        for timeout in invalidTimeouts {
            let config: [String: Any] = ["hooks": ["Stop": [["hooks": [[
                "type": "command", "command": "audit", "timeout": timeout,
            ]]]]]]
            XCTAssertThrowsError(try profile.merging(into: config, bridgePath: "/bin/di-bridge"))
        }
        for path in ["~/di-bridge", "/bin/di\0bridge"] {
            XCTAssertThrowsError(try profile.merging(into: [:], bridgePath: path))
            XCTAssertFalse(profile.isConfigured(in: [:], bridgePath: path))
        }
    }

    func testWindsurfPipelineUsesTrajectoryIdentityInsteadOfGenericFallback() throws {
        let message = try DIBridge.makeMessage(agentType: "windsurf", hookType: "post_cascade_response", sessionId: "fallback",
            stdinData: ["agent_action_name": "post_cascade_response", "trajectory_id": "conversation",
                        "execution_id": "turn", "timestamp": "2026-09-16T05:25:43Z", "model_name": "Unknown",
                        "tool_info": ["response": "Done"]])
        XCTAssertEqual(message.sessionId, "windsurf-conversation")
        XCTAssertEqual(message.observedState, "idle")
        XCTAssertEqual(message.status, "Done")
    }

    func testObservationToolStartDoesNotInterceptQuestions() throws {
        for agent in ["gemini_cli", "droid", "qwen", "qoder"] {
            let message = try DIBridge.makeMessage(agentType: agent, hookType: "toolstart", sessionId: "test",
                                                   stdinData: ["tool_name": "AskUserQuestion", "tool_input": ["question": "Choose"]])
            XCTAssertEqual(message.type, .toolStart)
            XCTAssertNil(message.questionText)
        }
    }

    func testGeminiAfterAgentExtractsReplyWithoutClaimingFinality() throws {
        let message = try DIBridge.makeMessage(agentType: "gemini_cli", hookType: "notification", sessionId: "test",
                                               stdinData: ["session_id": "native-test", "hook_event_name": "AfterAgent", "prompt_response": "No errors found"])
        XCTAssertEqual(message.type, .statusUpdate)
        XCTAssertEqual(message.status, "No errors found")
        XCTAssertEqual(message.observedState, "completionUnconfirmed")
        XCTAssertEqual(message.statusIsAssistantReply, true)
    }

    func testNativePermissionNotificationDoesNotBecomeApprovalRequest() throws {
        let message = try DIBridge.makeMessage(agentType: "gemini_cli", hookType: "Notification", sessionId: "test",
                                               stdinData: ["session_id": "native-test", "hook_event_name": "Notification", "notification_type": "ToolPermission", "message": "Approve in Gemini"])
        XCTAssertEqual(message.type, .statusUpdate)
        XCTAssertEqual(message.observedState, "waitingPermission")
        XCTAssertEqual(message.statusIsAssistantReply, false)
        XCTAssertNil(message.approved)
    }

    func testObjectToolResultIsPreserved() throws {
        let message = try DIBridge.makeMessage(agentType: "codex", hookType: "PostToolUse", sessionId: "test",
                                               stdinData: ["tool_name": "Bash", "tool_response": ["stdout": "fixture", "exit_code": 0]])
        let data = try XCTUnwrap(message.toolResult?.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["stdout"] as? String, "fixture")
        XCTAssertEqual(object["exit_code"] as? Int, 0)
    }

    func testNativePayloadWithoutSessionIDIsRejectedInsteadOfMergingByDirectory() {
        XCTAssertThrowsError(try DIBridge.makeMessage(agentType: "codex", hookType: "Stop", sessionId: "fallback",
                                                     stdinData: ["hook_event_name": "Stop", "cwd": "/tmp/shared-project"]))
    }

    func testObservationHooksReturnNeutralJSONWithoutGrantingPermission() {
        XCTAssertTrue(DIBridge.needsJsonOutput("BeforeTool", agentType: "gemini_cli"))
        XCTAssertTrue(DIBridge.needsJsonOutput("PostToolUse", agentType: "codex"))
        XCTAssertFalse(DIBridge.needsJsonOutput("post_run_command", agentType: "windsurf"))
    }

    func testFactoryKeepsExistingLegacyConfigurationLocationUntilNativeFileExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let factory = root.appendingPathComponent(".factory")
        try FileManager.default.createDirectory(at: factory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"hooks\":{}}".utf8).write(to: factory.appendingPathComponent("settings.json"))
        let legacy = try XCTUnwrap(ZeroConfigManager.effectiveNativeProfile(for: .droid, homeDirectory: root.path))
        XCTAssertEqual(legacy.relativeConfigPath, ".factory/settings.json")
        XCTAssertFalse(legacy.hooksAreAtRoot)
        try Data("{}".utf8).write(to: factory.appendingPathComponent("hooks.json"))
        let native = try XCTUnwrap(ZeroConfigManager.effectiveNativeProfile(for: .droid, homeDirectory: root.path))
        XCTAssertEqual(native.relativeConfigPath, ".factory/hooks.json")
        XCTAssertTrue(native.hooksAreAtRoot)
    }
}

@MainActor
final class NativeObservedStateTests: XCTestCase {
    func testTurnCompletionWithErrorWordInReplyStaysIdle() {
        let manager = SessionManager()
        var message = DIMessage(type: .statusUpdate, sessionId: "native-codex")
        message.agentType = "codex"
        message.status = "No errors found"
        message.observedState = "idle"
        message.statusIsAssistantReply = true
        manager.handleMessage(message)
        XCTAssertEqual(manager.sessions.first?.status, .idle)
        XCTAssertEqual(manager.sessions.first?.chatHistory.last?.content, "No errors found")
    }

    func testOperationalNotificationDoesNotPolluteAssistantHistory() {
        let manager = SessionManager()
        var message = DIMessage(type: .statusUpdate, sessionId: "native-gemini")
        message.agentType = "gemini_cli"
        message.status = "Native approval required"
        message.observedState = "waitingPermission"
        message.statusIsAssistantReply = false
        manager.handleMessage(message)
        XCTAssertEqual(manager.sessions.first?.status, .waitingPermission)
        XCTAssertTrue(manager.sessions.first?.chatHistory.isEmpty == true)
        XCTAssertFalse(manager.hasInteraction)
    }

    func testExplicitNativeSessionEndCompletesEvenWhenAgentApplicationKeepsRunning() {
        let manager = SessionManager()
        var start = DIMessage(type: .sessionStart, sessionId: "native-codex")
        start.agentType = "codex"
        manager.handleMessage(start)
        var end = DIMessage(type: .sessionEnd, sessionId: start.sessionId)
        end.agentType = "codex"
        end.observedState = "completed"
        manager.handleMessage(end)
        XCTAssertEqual(manager.sessions.first?.status, .completed)
    }
}
