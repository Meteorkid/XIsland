import XCTest
import DIShared
@testable import XIsland
@testable import DIBridge

final class TraeHookAdapterTests: XCTestCase {
    func testCNConfigurationUsesSixDocumentedEventsAndExplicitDialect() throws {
        XCTAssertEqual(TraeHookConfiguration.relativeConfigPath, ".trae-cn/hooks.json")
        let config = try TraeHookConfiguration.merging(into: [:], bridgePath: "/bin/di-bridge")
        XCTAssertEqual(config["version"] as? Int, 1)
        let hooks = try XCTUnwrap(config["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(TraeHookConfiguration.events))
        XCTAssertNil(hooks["PermissionRequest"])
        XCTAssertNil(hooks["SessionEnd"])
        let pre = try XCTUnwrap((hooks["PreToolUse"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(pre.first?["timeout"] as? Int, 5)
        XCTAssertTrue((pre.first?["command"] as? String)?.hasSuffix(" --adapter trae_cn || true") == true)
        XCTAssertTrue(TraeHookConfiguration.isConfigured(in: config, bridgePath: "/bin/di-bridge"))
    }

    func testMergePreservesValidOptionalTypeAndRemovesOnlyLegacyAppCommands() throws {
        let original: [String: Any] = ["version": 1, "custom": true, "hooks": [
            "beforeSubmitPrompt": [["command": "/old/di-bridge --agent trae --hook session_start"]],
            "PreToolUse": [["matcher": "RunCommand", "hooks": [["command": "audit", "timeout": 10]]]],
        ]]
        let merged = try TraeHookConfiguration.merging(into: original, bridgePath: "/bin/di-bridge")
        XCTAssertEqual(merged["custom"] as? Bool, true)
        XCTAssertEqual(try json(merged), try json(TraeHookConfiguration.merging(into: merged, bridgePath: "/bin/di-bridge")))
        let removed = try TraeHookConfiguration.removing(from: merged)
        let hooks = try XCTUnwrap(removed["hooks"] as? [String: Any])
        XCTAssertNil(hooks["beforeSubmitPrompt"])
        let retained = try XCTUnwrap((hooks["PreToolUse"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(retained.first?["command"] as? String, "audit")
    }

    func testUnknownLegacyFlatCommandsAndVersionsAreNotOverwritten() {
        let configurations: [[String: Any]] = [["version": true], ["version": 2],
            ["hooks": ["beforeSubmitPrompt": [["command": "my-custom-hook"]]]],
            ["hooks": ["beforeSubmitPrompt": [["command": "echo /old/di-bridge --agent trae --hook session_start"]]]]]
        for config in configurations {
            XCTAssertThrowsError(try TraeHookConfiguration.merging(into: config, bridgePath: "/bin/di-bridge"))
            XCTAssertFalse(TraeHookConfiguration.isConfigured(in: config, bridgePath: "/bin/di-bridge"))
        }
    }

    func testToolIdentityAndStructuredResultArePreservedWithoutQuestions() throws {
        let fields: [String: Any] = ["tool_name": "AskUserQuestion", "tool_use_id": "call-1", "tool_input": ["question": "Continue?"],
                                      "tool_response": ["content": "fixture"]]
        let start = try normalize("PreToolUse", fields: fields)
        XCTAssertEqual(start.type, .toolStart)
        XCTAssertEqual(start.toolCallId, "call-1")
        XCTAssertEqual(start.sessionId, "trae-fixture")
        XCTAssertNil(start.questionText)
        let end = try normalize("PostToolUse", fields: fields)
        XCTAssertEqual(end.type, .toolComplete)
        XCTAssertEqual(end.toolCallId, "call-1")
        XCTAssertTrue(end.toolResult?.contains("fixture") == true)
    }

    func testNotificationsHaveNoInteractiveRequestOrAssistantReply() throws {
        for (notice, status) in ["idle_prompt": "idle", "permission_prompt": "waitingPermission", "document_review": "waitingPlanReview", "ask_user_question": "waitingAnswer"] {
            let message = try normalize("Notification", fields: ["notification_type": notice, "message": "Native action required"])
            XCTAssertEqual(message.type, .statusUpdate)
            XCTAssertEqual(message.observedState, status)
            XCTAssertEqual(message.statusIsAssistantReply, false)
            XCTAssertNil(message.questionText)
            XCTAssertNil(message.planMarkdown)
        }
    }

    func testStopPreservesReplyWithoutAssumingOtherHooksAllowTermination() throws {
        for alreadyBlocked in [false, true] {
            let message = try normalize("Stop", fields: ["last_assistant_message": "No errors found",
                "stop_hook_active": alreadyBlocked, "loop_count": alreadyBlocked ? 1 : 0])
            XCTAssertEqual(message.type, .statusUpdate)
            XCTAssertEqual(message.status, "No errors found")
            XCTAssertEqual(message.statusIsAssistantReply, true)
            XCTAssertEqual(message.observedState, "completionUnconfirmed")
        }
    }

    func testNativeProtocolRejectsUnsupportedEventsAndMismatchedIdentity() {
        XCTAssertThrowsError(try normalize("PermissionRequest"))
        XCTAssertThrowsError(try normalize("SessionEnd"))
        XCTAssertThrowsError(try normalize("Stop", fields: ["hook_event_name": "Notification"]))
        XCTAssertThrowsError(try normalize("SessionStart", fields: ["session_id": ""]))
        XCTAssertThrowsError(try normalize("PreToolUse", fields: ["tool_name": "RunCommand", "tool_input": [:]]))
    }

    func testGateCodecUsesPreToolDecisionAndDoesNotRewriteArguments() throws {
        let response = TraeHookAdapter.permissionResponse(approved: false)
        let output = try XCTUnwrap(response.stdout)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let specific = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(specific["permissionDecision"] as? String, "deny")
        XCTAssertNil(specific["updatedInput"])
        XCTAssertEqual(response.exitCode, 0)
    }

    private func normalize(_ event: String, fields: [String: Any] = [:]) throws -> DIMessage {
        var data: [String: Any] = ["hook_event_name": event, "session_id": "fixture", "cwd": "/tmp/project"]
        data.merge(fields) { _, new in new }
        return try DIBridge.makeMessage(agentType: "trae", hookType: event, sessionId: "fallback", stdinData: data, adapter: "trae_cn")
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
