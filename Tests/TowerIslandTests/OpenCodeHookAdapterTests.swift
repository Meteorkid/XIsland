import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

final class OpenCodeHookAdapterTests: XCTestCase {
    func testPermissionKeepsUpstreamIdentityAndDoesNotInferQuestionTool() throws {
        let message = try normalize("permission.asked", fields: ["native_request_id": "request-1", "native_request_kind": "permission",
            "permission": "external_directory", "patterns": ["/tmp/outside"], "metadata": [:]])
        XCTAssertEqual(message.type, .permissionRequest)
        XCTAssertEqual(message.sessionId, "opencode-session")
        XCTAssertEqual(message.nativeRequestId, "request-1")
        XCTAssertEqual(message.nativeRequestKind, "permission")
        XCTAssertEqual(message.filePath, "/tmp/outside")
    }

    func testQuestionAndExternalResolutionCarrySameScopedID() throws {
        let fields: [String: Any] = ["native_request_id": "question-1", "native_request_kind": "question", "question": "Choose", "options": ["A", "B"]]
        let question = try normalize("question.asked", fields: fields)
        XCTAssertEqual(question.type, .question)
        let resolved = try normalize("interaction.resolved", fields: fields)
        XCTAssertEqual(resolved.type, .interactionResolved)
        XCTAssertEqual(resolved.nativeRequestId, question.nativeRequestId)
        XCTAssertEqual(resolved.nativeRequestKind, "question")
        XCTAssertNil(resolved.status)
    }

    func testToolAndLifecycleStatesAreExplicit() throws {
        let failed = try normalize("tool.failed", fields: ["tool_name": "bash", "tool_use_id": "call", "tool_response": "failed"])
        XCTAssertEqual(failed.type, .toolComplete)
        XCTAssertEqual(failed.toolCallId, "call")
        XCTAssertEqual(failed.toolResult, "failed")
        XCTAssertEqual(failed.observedState, "error")
        XCTAssertEqual(try normalize("session.deleted").observedState, "completed")
        XCTAssertEqual(try normalize("session.idle").observedState, "idle")
        let reply = try normalize("assistant.message", fields: ["message": "No errors found"])
        XCTAssertTrue(reply.statusIsAssistantReply == true)
        XCTAssertNil(reply.observedState)
    }

    func testTransportFailureIsOnlyAnOperationalNotification() throws {
        let message = try normalize("interaction.unavailable", fields: ["native_request_id": "request", "native_request_kind": "permission"])
        XCTAssertEqual(message.type, .statusUpdate)
        XCTAssertEqual(message.observedState, "waitingPermission")
        XCTAssertFalse(message.statusIsAssistantReply ?? true)
        XCTAssertNil(message.approved)
    }

    func testMissingOrConflictingRequestIdentityIsRejected() {
        XCTAssertThrowsError(try normalize("permission.asked", fields: ["permission": "bash", "patterns": []]))
        XCTAssertThrowsError(try normalize("permission.asked", fields: ["native_request_id": "id", "native_request_kind": "question", "permission": "bash", "patterns": []]))
        XCTAssertThrowsError(try normalize("question.asked", fields: ["native_request_id": "id", "native_request_kind": "question", "question": "Choose", "options": ["same", "same"]]))
        XCTAssertThrowsError(try normalize("interaction.resolved", fields: ["native_request_id": "", "native_request_kind": "permission"]))
    }

    func testInteractiveStdoutDistinguishesDecisionsFromProcessFailure() throws {
        for approved in [true, false] {
            let output = DIBridge.permissionHookResponse(agentType: "opencode", approved: approved, adapter: "opencode_plugin")
            XCTAssertEqual(output.exitCode, 0)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(output.stdout).utf8)) as? [String: String])
            XCTAssertEqual(root["decision"], approved ? "allow" : "deny")
        }
        let answer = "中文\n\"quoted\""
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try OpenCodeHookAdapter.questionResponse(answer: answer).utf8)) as? [String: String])
        XCTAssertEqual(root["answer"], answer)
    }

    func testReferenceCleanupKeepsOtherPluginsAndSettings() throws {
        let url = URL(fileURLWithPath: "/tmp/space path/xisland.js")
        let config: [String: Any] = ["model": "fixture", "plugin": [url.absoluteString, ["file://" + url.path, ["custom": true]],
            "another-xisland-plugin", ["other-plugin", ["enabled": true]]]]
        let cleaned = OpenCodePluginConfiguration.removingLegacyReferences(from: config, pluginURLs: [url])
        let plugins = try XCTUnwrap(cleaned["plugin"] as? [Any])
        XCTAssertEqual(plugins.count, 2)
        XCTAssertEqual(plugins.first as? String, "another-xisland-plugin")
        XCTAssertEqual(cleaned["model"] as? String, "fixture")
    }

    func testMultipleAnswerEncodingPreservesLabelsAndRejectsAmbiguousArrays() throws {
        let labels = ["带,逗号", "包含\n换行", "\"quoted\""]
        let encoded = try OpenCodeHookAdapter.questionResponse(answers: labels)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: [String]])
        XCTAssertEqual(object["answers"], labels)
        let exact = ["选", String(repeating: "中", count: 2729) + "ab"]
        XCTAssertNoThrow(try OpenCodeHookAdapter.questionResponse(answers: exact))
        XCTAssertThrowsError(try OpenCodeHookAdapter.questionResponse(answers: [exact[0], exact[1] + "c"]))
        for invalid in [[], ["same", "same"], [" "], ["a\0b"], [String(repeating: "x", count: 8193)]] {
            XCTAssertThrowsError(try OpenCodeHookAdapter.questionResponse(answers: invalid))
        }
    }

    private func normalize(_ event: String, fields: [String: Any] = [:]) throws -> DIMessage {
        var data: [String: Any] = ["session_id": "session", "native_event": event, "cwd": "/tmp/project"]
        data.merge(fields) { _, new in new }
        return try DIBridge.makeMessage(agentType: "opencode", hookType: event, sessionId: "fallback", stdinData: data, adapter: "opencode_plugin")
    }
}
