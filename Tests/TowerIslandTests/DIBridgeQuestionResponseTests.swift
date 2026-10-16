import XCTest
import Darwin
import DIShared
@testable import DIBridge

final class DIBridgeQuestionResponseTests: XCTestCase {
    func testInteractiveReadReturnsBeforeConfiguredDeadlineWithoutResponse() throws {
        let sockets = try makeSocketPair()
        defer { close(sockets.0); close(sockets.1) }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(DIBridge.readFramedMessage(sockets.1, timeoutSeconds: 0.02))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    func testInteractiveReadDoesNotDecodeIncompleteFrameOnTimeout() throws {
        let sockets = try makeSocketPair()
        defer { close(sockets.0); close(sockets.1) }
        XCTAssertTrue(DIBridge.sendAll(fd: sockets.0, data: Data("{\"type\":".utf8)))
        XCTAssertNil(DIBridge.readFramedMessage(sockets.1, timeoutSeconds: 0.02))
    }

    func testQuestionsArrayResponseIncludesAllAnswerFields() throws {
        let stdin: [String: Any] = [
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": [
                    [
                        "question": "How to proceed?",
                        "options": [
                            ["label": "Refactor"],
                            ["label": "Test"]
                        ]
                    ]
                ]
            ]
        ]

        let json = DIBridge.buildClaudeCodeQuestionResponse(answer: "Refactor", stdinData: stdin)
        let decoded = try decodeJSON(json)
        let output = try hookOutput(from: decoded)
        let updated = try updatedInput(from: output)

        XCTAssertEqual(output["permissionDecision"] as? String, "allow")
        XCTAssertEqual(updated["answer"] as? String, "Refactor")

        let answers = try XCTUnwrap(updated["answers"] as? [String: String])
        XCTAssertEqual(answers["How to proceed?"], "Refactor")

        let questions = try XCTUnwrap(updated["questions"] as? [[String: Any]])
        XCTAssertEqual(questions.first?["answer"] as? String, "Refactor")
        let perQuestionAnswers = try XCTUnwrap(questions.first?["answers"] as? [String])
        XCTAssertEqual(perQuestionAnswers.first, "Refactor")
    }

    func testSingleQuestionResponseIncludesAnswerAndAnswerMap() throws {
        let stdin: [String: Any] = [
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "question": "Continue?",
                "options": ["yes", "no"]
            ]
        ]

        let json = DIBridge.buildClaudeCodeQuestionResponse(answer: "yes", stdinData: stdin)
        let decoded = try decodeJSON(json)
        let output = try hookOutput(from: decoded)
        let updated = try updatedInput(from: output)

        XCTAssertEqual(updated["answer"] as? String, "yes")
        let answers = try XCTUnwrap(updated["answers"] as? [String: String])
        XCTAssertEqual(answers["Continue?"], "yes")
    }

    func testClaudePermissionResponseStdoutUsesDecisionBehavior() throws {
        let allowJson = DIBridge.buildClaudeCodePermissionResponse(approved: true)
        let denyJson = DIBridge.buildClaudeCodePermissionResponse(approved: false)

        let allowRoot = try decodeJSON(allowJson)
        let denyRoot = try decodeJSON(denyJson)
        let allowOut = try hookOutput(from: allowRoot)
        let denyOut = try hookOutput(from: denyRoot)

        XCTAssertEqual(allowOut["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual(denyOut["hookEventName"] as? String, "PermissionRequest")

        let allowDecision = try XCTUnwrap(allowOut["decision"] as? [String: Any])
        let denyDecision = try XCTUnwrap(denyOut["decision"] as? [String: Any])
        XCTAssertEqual(allowDecision["behavior"] as? String, "allow")
        XCTAssertEqual(denyDecision["behavior"] as? String, "deny")
    }

    func testTraePermissionRequestsUseClaudeCompatibleStdout() {
        XCTAssertTrue(DIBridge.usesClaudeCodePermissionStdout(agentType: "claude_code"))
        XCTAssertTrue(DIBridge.usesClaudeCodePermissionStdout(agentType: "trae"))
        XCTAssertFalse(DIBridge.usesClaudeCodePermissionStdout(agentType: "cursor"))
    }

    func testCodexPermissionDecisionsUseStructuredOutputAndSuccessfulHookExit() throws {
        for approved in [true, false] {
            let response = DIBridge.permissionHookResponse(agentType: "codex", approved: approved)
            XCTAssertEqual(response.exitCode, 0)
            let root = try decodeJSON(try XCTUnwrap(response.stdout))
            let output = try hookOutput(from: root)
            XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
            let decision = try XCTUnwrap(output["decision"] as? [String: Any])
            XCTAssertEqual(decision["behavior"] as? String, approved ? "allow" : "deny")
            XCTAssertNil(output["updatedInput"])
            XCTAssertNil(output["updatedPermissions"])
        }
    }

    func testNativeExitCodePermissionAdapterKeepsItsExistingContract() {
        let response = DIBridge.permissionHookResponse(agentType: "cursor", approved: false)
        XCTAssertNil(response.stdout)
        XCTAssertEqual(response.exitCode, 1)
    }

    func testOutputUsesNativeEventNameForLegacyCodexStopMapping() {
        let event = DIBridge.outputEvent(hookType: "notification", stdinData: ["hook_event_name": "Stop"])
        XCTAssertEqual(event, "Stop")
        XCTAssertTrue(DIBridge.needsJsonOutput(event))
        XCTAssertEqual(DIBridge.outputEvent(hookType: "session_start", stdinData: [:]), "session_start")
        XCTAssertEqual(DIBridge.outputEvent(hookType: "Stop", stdinData: ["hook_event_name": " "]), "Stop")
    }

    func testCodexStopUpdatesReplyWithoutEndingTheSession() {
        let message = DIBridge.buildMessage(agentType: "codex", hookType: "Stop", sessionId: "codex-stop",
                                           stdinData: ["last_assistant_message": "Completed this turn"])
        XCTAssertEqual(message.type, .statusUpdate)
        XCTAssertEqual(message.status, "Completed this turn")
    }

    func testPermissionHookUsesPermissionRequestEventName() throws {
        let stdin: [String: Any] = [
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "question": "Continue?",
                "options": ["yes", "no"]
            ]
        ]

        let json = DIBridge.buildClaudeCodeQuestionResponse(
            answer: "yes",
            stdinData: stdin,
            hookType: "PermissionRequest"
        )
        let decoded = try decodeJSON(json)
        let output = try hookOutput(from: decoded)

        XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
    }

    func testBridgeDebugLogIsDisabledByDefault() {
        XCTAssertFalse(DIBridge.shouldWriteDebugLog(environment: [:]))
        XCTAssertTrue(DIBridge.shouldWriteDebugLog(environment: ["DI_BRIDGE_DEBUG_LOG": "1"]))
    }

    func testSocketPathCanBeOverriddenForRemoteTunnels() {
        XCTAssertEqual(
            DIBridge.socketPath(environment: ["DI_SOCKET_PATH": "/tmp/xisland-remote.sock"]),
            "/tmp/xisland-remote.sock"
        )
        XCTAssertTrue(
            DIBridge.socketPath(environment: ["DI_SOCKET_PATH": "~/.xisland/remote.sock"])
                .hasSuffix("/.xisland/remote.sock")
        )
    }

    func testBridgeDebugLogRedactsSensitiveValues() {
        let line = DIBridge.logLine(
            hook: "PreToolUse",
            data: [
                "api_key": "sk-secret",
                "nested": ["authorization": "Bearer token"],
                "safe": "visible"
            ]
        )

        XCTAssertFalse(line.contains("sk-secret"))
        XCTAssertFalse(line.contains("Bearer token"))
        XCTAssertTrue(line.contains("[redacted]"))
        XCTAssertTrue(line.contains("visible"))
    }

    func testReceiveResponseReadsLargeFramedMessage() throws {
        let fds = try makeSocketPair()
        defer {
            close(fds.0)
            close(fds.1)
        }

        var response = DIMessage(type: .questionResponse, sessionId: "large-response")
        response.answer = String(repeating: "x", count: 80_000)
        let data = try DIProtocol.encode(response)

        let sent = expectation(description: "response sent")
        DispatchQueue.global().async {
            XCTAssertTrue(DIBridge.sendAll(fd: fds.0, data: data))
            shutdown(fds.0, SHUT_WR)
            sent.fulfill()
        }

        let decoded = DIBridge.receiveResponse(fds.1)
        wait(for: [sent], timeout: 1)
        XCTAssertEqual(decoded?.answer?.count, 80_000)
    }

    private func decodeJSON(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hookOutput(from root: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
    }

    private func updatedInput(from hookOutput: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(hookOutput["updatedInput"] as? [String: Any])
    }

    private func makeSocketPair() throws -> (Int32, Int32) {
        var fds = [Int32](repeating: -1, count: 2)
        let result = fds.withUnsafeMutableBufferPointer { buffer in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress!)
        }
        XCTAssertEqual(result, 0)
        return (fds[0], fds[1])
    }
}
