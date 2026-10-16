import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

final class CursorHookAdapterTests: XCTestCase {
    func testNativeConfigurationMigratesExactLegacyCommandsAndKeepsUserHooks() throws {
        let original: [String: Any] = ["version": 1, "custom": true, "hooks": [
            "beforeShellExecution": [["command": "/old/di-bridge --agent cursor --hook PreToolUse --tool Shell"],
                                     ["command": "audit di-bridge --agent cursor", "matcher": "curl"]],
            "stop": [["command": "/old/di-bridge --agent cursor --hook session_end"]],
        ]]
        let merged = try CursorHookConfiguration.merging(into: original, bridgePath: "/bin/di-bridge")
        let hooks = try XCTUnwrap(merged["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["beforeShellExecution"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(merged["custom"] as? Bool, true)
        XCTAssertTrue(CursorHookConfiguration.isConfigured(in: merged, bridgePath: "/bin/di-bridge"))
        XCTAssertEqual(try json(merged), try json(CursorHookConfiguration.merging(into: merged, bridgePath: "/bin/di-bridge")))
        let removed = try CursorHookConfiguration.removing(from: merged)
        let remaining = try XCTUnwrap(removed["hooks"] as? [String: Any])
        XCTAssertEqual((remaining["beforeShellExecution"] as? [[String: String]])?.first?["command"], "audit di-bridge --agent cursor")
        XCTAssertNil(remaining["stop"])
    }

    func testObservationCommandsReturnValidNativeJSONEvenIfBridgeFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = root.appendingPathComponent("di-bridge 'quoted' $(no-exec)")
        try "#!/bin/sh\nprintf 'not JSON'\nexit 2\n".write(to: bridge, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
        let config = try CursorHookConfiguration.merging(into: [:], bridgePath: bridge.path)
        let hooks = try XCTUnwrap(config["hooks"] as? [String: [[String: Any]]])
        for (event, expected) in ["preToolUse": "{\"permission\":\"allow\"}", "beforeSubmitPrompt": "{\"continue\":true}", "stop": "{}"] {
            let command = try XCTUnwrap(hooks[event]?.first?["command"] as? String)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), expected)
        }
    }

    func testMalformedConfigurationIsRejected() {
        let configurations: [[String: Any]] = [["version": true], ["version": 2], ["hooks": []], ["hooks": ["stop": [["command": 1]]]]]
        for configuration in configurations {
            XCTAssertThrowsError(try CursorHookConfiguration.merging(into: configuration, bridgePath: "/bin/di-bridge"))
            XCTAssertFalse(CursorHookConfiguration.isConfigured(in: configuration, bridgePath: "/bin/di-bridge"))
        }
        XCTAssertThrowsError(try CursorHookConfiguration.merging(into: [:], bridgePath: "relative"))
    }

    func testConversationAndToolIdentitySurviveDifferentGenerations() throws {
        let first = try normalize("preToolUse", fields: ["tool_name": "Shell", "tool_use_id": "first", "tool_input": ["command": "one"]])
        let second = try normalize("postToolUse", fields: ["generation_id": "turn-2", "tool_name": "Shell", "tool_use_id": "second",
            "tool_input": ["command": "two"], "tool_output": "{\"exitCode\":0}"])
        XCTAssertEqual(first.sessionId, "cursor-conversation")
        XCTAssertEqual(first.sessionId, second.sessionId)
        XCTAssertEqual(first.toolCallId, "first")
        XCTAssertEqual(second.toolCallId, "second")
        XCTAssertEqual(second.toolResult, "{\"exitCode\":0}")
    }

    func testQuestionNamedToolStaysObservationAndMultirootDoesNotInventDirectory() throws {
        let message = try normalize("preToolUse", fields: ["tool_name": "AskUserQuestion", "tool_use_id": "question", "tool_input": [:],
            "workspace_roots": ["/tmp/first", "/tmp/second"]])
        XCTAssertEqual(message.type, .toolStart)
        XCTAssertNil(message.questionText)
        XCTAssertNil(message.workingDir)
    }

    func testResponseIsNotIdleUntilLoopStopsAndSessionEndIsExplicit() throws {
        let reply = try normalize("afterAgentResponse", fields: ["text": "No errors found"])
        XCTAssertEqual(reply.statusIsAssistantReply, true)
        XCTAssertNil(reply.observedState)
        for state in ["completed", "aborted", "error"] {
            let stop = try normalize("stop", fields: ["status": state])
            XCTAssertEqual(stop.type, .statusUpdate)
            XCTAssertEqual(stop.observedState, state == "error" ? "error" : "idle")
            XCTAssertEqual(stop.statusIsAssistantReply, false)
        }
        XCTAssertEqual(try normalize("sessionEnd", fields: ["session_id": "conversation"]).observedState, "completed")
    }

    func testNativeFailureAndUserCancellationRemainDistinct() throws {
        let payload: [String: Any] = ["tool_name": "Shell", "tool_use_id": "call", "tool_input": [:], "error_message": "Stopped"]
        XCTAssertEqual(try normalize("postToolUseFailure", fields: payload).observedState, "error")
        XCTAssertNil(try normalize("postToolUseFailure", fields: payload.merging(["is_interrupt": true]) { _, new in new }).observedState)
    }

    func testMissingIdentityAndMismatchedEventsAreRejected() {
        XCTAssertThrowsError(try normalize("stop", fields: ["conversation_id": " ", "status": "completed"]))
        XCTAssertThrowsError(try normalize("stop", fields: ["hook_event_name": "sessionEnd", "status": "completed"]))
        XCTAssertThrowsError(try normalize("sessionEnd", fields: ["session_id": "another-conversation"]))
        XCTAssertThrowsError(try normalize("workspaceOpen"))
    }

    private func normalize(_ event: String, fields: [String: Any] = [:]) throws -> DIMessage {
        var data: [String: Any] = ["hook_event_name": event, "conversation_id": "conversation", "generation_id": "turn",
                                   "workspace_roots": ["/tmp/project"], "model": "fixture"]
        data.merge(fields) { _, new in new }
        return try DIBridge.makeMessage(agentType: "cursor", hookType: event, sessionId: "fallback", stdinData: data)
    }

    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}

@MainActor
final class NativeAssistantStateTests: XCTestCase {
    func testStructuredAssistantTextDoesNotInferAnErrorOrPrematureIdle() {
        let manager = SessionManager()
        var reply = DIMessage(type: .statusUpdate, sessionId: "cursor-fixture")
        reply.agentType = "cursor"
        reply.status = "No errors found"
        reply.statusIsAssistantReply = true
        manager.handleMessage(reply)
        XCTAssertEqual(manager.sessions.first?.status, .active)
        XCTAssertEqual(manager.sessions.first?.chatHistory.last?.content, "No errors found")
    }
}
