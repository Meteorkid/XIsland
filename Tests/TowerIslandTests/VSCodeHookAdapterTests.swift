import XCTest
import DIShared
@testable import XIsland
@testable import DIBridge

final class VSCodeHookAdapterTests: XCTestCase {
    func testLocalConfigurationUsesIsolatedFileAndEightObservationEvents() throws {
        XCTAssertEqual(VSCodeHookConfiguration.relativeConfigPath, ".xisland/hooks/vscode-local.json")
        let config = try VSCodeHookConfiguration.merging(into: [:], bridgePath: "/tmp/O'Brien/di-bridge")
        XCTAssertNil(config["version"])
        let hooks = try XCTUnwrap(config["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(VSCodeHookConfiguration.events))
        XCTAssertNil(hooks["SessionEnd"])
        XCTAssertNil(hooks["PermissionRequest"])
        for value in hooks.values {
            let entry = try XCTUnwrap((value as? [[String: Any]])?.first)
            XCTAssertEqual(entry["type"] as? String, "command")
            let command = try XCTUnwrap(entry["command"] as? String)
            XCTAssertTrue(command.contains("'/tmp/O'\\''Brien/di-bridge' --agent copilot --adapter vscode_local"))
            XCTAssertTrue(command.contains(">/dev/null || true"))
            XCTAssertEqual(entry["timeout"] as? Int, 5)
        }
        XCTAssertTrue(VSCodeHookConfiguration.isConfigured(in: config, bridgePath: "/tmp/O'Brien/di-bridge"))
    }

    func testMergeAndRemovalPreserveNativePlatformOverridesAndThirdPartyHooks() throws {
        let original: [String: Any] = ["custom": "keep", "hooks": ["PreToolUse": [
            ["type": "command", "osx": "my-audit", "windows": "my-audit.ps1", "env": ["LABEL": "keep"], "timeout": 20],
        ]]]
        let installed = try VSCodeHookConfiguration.merging(into: original, bridgePath: "/old/di-bridge")
        let updated = try VSCodeHookConfiguration.merging(into: installed, bridgePath: "/new/di-bridge")
        XCTAssertEqual(try json(updated), try json(VSCodeHookConfiguration.merging(into: updated, bridgePath: "/new/di-bridge")))
        XCTAssertEqual(try json(original), try json(VSCodeHookConfiguration.removing(from: updated)))
        XCTAssertFalse(VSCodeHookConfiguration.isConfigured(in: updated, bridgePath: "/old/di-bridge"))
    }

    func testMalformedConfigurationIsNotRewrittenOrDetected() {
        for config: [String: Any] in [["version": 1], ["hooks": []], ["hooks": ["Stop": ["bad"]]],
                                     ["hooks": ["Stop": [["command": "foo"]]]],
                                     ["hooks": ["Stop": [["type": "command", "command": "foo", "timeout": true]]]]] {
            XCTAssertThrowsError(try VSCodeHookConfiguration.merging(into: config, bridgePath: "/bin/di-bridge"))
            XCTAssertFalse(VSCodeHookConfiguration.isConfigured(in: config, bridgePath: "/bin/di-bridge"))
        }
    }

    func testNativeIdentityTimestampAndPromptAreUsed() throws {
        let message = try normalize("UserPromptSubmit", fields: ["prompt": "你好"])
        XCTAssertEqual(message.sessionId, "copilot-local-fixture")
        XCTAssertEqual(message.type, .sessionStart)
        XCTAssertEqual(message.agentType, "copilot")
        XCTAssertEqual(message.workingDir, "/tmp/project")
        XCTAssertEqual(message.timestamp.timeIntervalSince1970, 1_790_208_000.125, accuracy: 0.001)
        XCTAssertEqual(message.prompt, "你好")
        XCTAssertEqual(message.statusIsAssistantReply, false)
    }

    func testToolQuestionNameDoesNotTriggerInteractiveWaitAndResultPreservesIdentity() throws {
        let fields: [String: Any] = ["tool_name": "AskUserQuestion", "tool_use_id": "call-1", "tool_input": ["question": "Choose"]]
        let start = try normalize("PreToolUse", fields: fields)
        XCTAssertEqual(start.type, .toolStart)
        XCTAssertNil(start.questionText)
        XCTAssertNil(start.nativeRequestId)
        var completed = fields
        completed["tool_response"] = ["content": "No errors found"]
        let result = try normalize("PostToolUse", fields: completed)
        XCTAssertEqual(result.type, .toolComplete)
        XCTAssertEqual(result.toolCallId, start.toolCallId)
        XCTAssertTrue(result.toolResult?.contains("No errors found") == true)
        XCTAssertNil(result.observedState)
    }

    func testStopDoesNotClaimIdleSessionEndOrAssistantReply() throws {
        for active in [false, true] {
            let message = try normalize("Stop", fields: ["stop_hook_active": active, "last_assistant_message": "unverified"])
            XCTAssertEqual(message.type, .statusUpdate)
            XCTAssertEqual(message.observedState, "completionUnconfirmed")
            XCTAssertNil(message.status)
            XCTAssertEqual(message.statusIsAssistantReply, false)
        }
    }

    func testParallelSubagentsUseNativeIDsScopedToParentSession() throws {
        let first = try normalize("SubagentStart", fields: ["agent_id": "one", "agent_type": "Plan"])
        let second = try normalize("SubagentStart", fields: ["agent_id": "two", "agent_type": "Plan"])
        let end = try normalize("SubagentStop", fields: ["agent_id": "one", "agent_type": "Plan"])
        XCTAssertEqual(first.type, .subagentStart)
        XCTAssertEqual(end.type, .subagentEnd)
        XCTAssertEqual(end.subagentEndIsProvisional, true)
        XCTAssertNil(first.subagentEndIsProvisional)
        XCTAssertEqual(first.subagentId, end.subagentId)
        XCTAssertNotEqual(first.subagentId, second.subagentId)
        XCTAssertEqual(first.parentSessionId, first.sessionId)
    }

    func testMissingIdentityAndDifferentHarnessPayloadAreRejected() {
        for fields: [String: Any] in [["session_id": NSNull()], ["session_id": ""], ["timestamp": 100],
                                     ["timestamp": "invalid"], ["hook_event_name": "Other"]] {
            XCTAssertThrowsError(try normalize("SessionStart", fields: fields))
        }
        XCTAssertThrowsError(try normalize("PermissionRequest"))
        XCTAssertThrowsError(try normalize("SessionEnd"))
        XCTAssertThrowsError(try DIBridge.makeMessage(agentType: "copilot", hookType: "SessionStart", sessionId: "fallback",
                                                     stdinData: ["sessionId": "cli-id", "timestamp": 100, "cwd": "/tmp"], adapter: "vscode_local"))
        XCTAssertThrowsError(try DIBridge.makeMessage(agentType: "copilot_cli", hookType: "sessionStart", sessionId: "fallback",
                                                     stdinData: payload("SessionStart")))
    }

    private func payload(_ event: String) -> [String: Any] {
        ["hook_event_name": event, "session_id": "fixture", "timestamp": "2026-09-24T00:00:00.125Z", "cwd": "/tmp/project"]
    }

    private func normalize(_ event: String, fields: [String: Any] = [:]) throws -> DIMessage {
        var data = payload(event)
        data.merge(fields) { _, new in new }
        return try DIBridge.makeMessage(agentType: "copilot", hookType: event, sessionId: "ignored-fallback", stdinData: data, adapter: "vscode_local")
    }

    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}
