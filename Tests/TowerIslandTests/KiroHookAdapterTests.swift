import XCTest
import DIShared
@testable import DIBridge

final class KiroHookAdapterTests: XCTestCase {
    func testLegacyGenericEntryCannotFabricateSessionOrApproval() {
        for hook in ["SessionStart", "PermissionRequest", "Stop", "session_end"] {
            XCTAssertThrowsError(try DIBridge.makeMessage(agentType: "kiro", hookType: hook,
                sessionId: "guessed-from-cwd", stdinData: ["cwd": "/tmp/project"]))
        }
    }

    private func payload(_ event: String) -> [String: Any] {
        ["hook_event_name": event, "session_id": "native", "cwd": "/tmp/project"]
    }

    func testRequiresNativeIdentityAndExplicitEvent() throws {
        var data = payload("agentSpawn")
        let result = try KiroHookAdapter.normalize(hookType: "agentSpawn", stdinData: data)
        XCTAssertEqual(result.agentType, "kiro")
        XCTAssertNil(result.observedState)
        data.removeValue(forKey: "session_id")
        XCTAssertThrowsError(try KiroHookAdapter.normalize(hookType: "agentSpawn", stdinData: data))
        XCTAssertThrowsError(try KiroHookAdapter.normalize(hookType: "SessionStart", stdinData: payload("agentSpawn")))
    }

    func testPreToolDoesNotFabricateExecutionOrPermission() throws {
        var data = payload("preToolUse")
        data["tool_name"] = "execute_bash"
        data["tool_input"] = ["command": "pwd"]
        let result = try KiroHookAdapter.normalize(hookType: "preToolUse", stdinData: data)
        XCTAssertEqual(result.type, .statusUpdate)
        XCTAssertNil(result.toolCallId)
        XCTAssertNil(result.nativeRequestId)
        XCTAssertEqual(result.statusIsAssistantReply, false)
    }

    func testOnlyBooleanFailureMarksErrorAndStopDoesNotEndSession() throws {
        var data = payload("postToolUse")
        data["tool_name"] = "read"
        data["tool_input"] = [:] as [String: String]
        data["tool_response"] = ["success": 0]
        XCTAssertNil(try KiroHookAdapter.normalize(hookType: "postToolUse", stdinData: data).observedState)
        data["tool_response"] = ["success": false]
        XCTAssertEqual(try KiroHookAdapter.normalize(hookType: "postToolUse", stdinData: data).observedState, "error")
        var stop = payload("stop")
        stop["assistant_response"] = "Done"
        let result = try KiroHookAdapter.normalize(hookType: "stop", stdinData: stop)
        XCTAssertEqual(result.type, .statusUpdate)
        XCTAssertEqual(result.observedState, "completionUnconfirmed")
    }

    func testV3StopWithoutAnswerKeepsCompletionUnconfirmedWithoutInventingReply() throws {
        let result = try KiroHookAdapter.normalize(hookType: "Stop", stdinData: payload("Stop"))
        XCTAssertEqual(result.type, .statusUpdate)
        XCTAssertEqual(result.observedState, "completionUnconfirmed")
        XCTAssertEqual(result.statusIsAssistantReply, false)
        XCTAssertEqual(result.nativeEvent, "kiro_cli_Stop")
        var wrongType = payload("Stop")
        wrongType["assistant_response"] = 7
        XCTAssertThrowsError(try KiroHookAdapter.normalize(hookType: "Stop", stdinData: wrongType))
    }

    func testV3AndLegacyEventsKeepNativeSessionIdentityAndObservationSemantics() throws {
        for (canonical, legacy) in [("AgentSpawn", "agentSpawn"), ("UserPromptSubmit", "userPromptSubmit"),
                                     ("PreToolUse", "preToolUse"), ("PostToolUse", "postToolUse"), ("Stop", "stop")] {
            func message(_ event: String) throws -> DIMessage {
                var data = payload(event)
                data["prompt"] = "read a file"
                data["tool_name"] = "read_file"
                data["tool_input"] = ["path": "/tmp/a"]
                data["tool_response"] = ["success": false]
                return try KiroHookAdapter.normalize(hookType: event, stdinData: data)
            }
            let newer = try message(canonical)
            let older = try message(legacy)
            XCTAssertEqual(newer.sessionId, older.sessionId)
            XCTAssertEqual(newer.type, older.type)
            XCTAssertEqual(newer.observedState, older.observedState)
            XCTAssertNil(newer.toolCallId)
            XCTAssertNil(newer.nativeRequestId)
        }
    }

    func testOnlySessionEndClosesSessionAndDoesNotBecomeAssistantAnswer() throws {
        let result = try KiroHookAdapter.normalize(hookType: "SessionEnd", stdinData: payload("SessionEnd"))
        XCTAssertEqual(result.type, .sessionEnd)
        XCTAssertEqual(result.observedState, "completed")
        XCTAssertEqual(result.statusIsAssistantReply, false)
        XCTAssertThrowsError(try KiroHookAdapter.normalize(hookType: "SessionEnd", stdinData: payload("Stop")))
        XCTAssertThrowsError(try KiroHookAdapter.normalize(hookType: "PermissionRequest", stdinData: payload("PermissionRequest")))
    }
}
