import XCTest
import DIShared
@testable import DIBridge

final class QuestionToolIdentityTests: XCTestCase {
    private let question: [String: Any] = ["question": "Continue?", "options": ["Yes", "No"]]

    private func payload(_ tool: String = "AskUserQuestion", input: [String: Any]? = nil) -> [String: Any] {
        ["tool_name": tool, "tool_input": input ?? question]
    }

    func testThirdPartyAndLookalikeNamesNeverBecomeQuestionAuthorization() {
        for tool in ["mcp__fixture__ask_user_run_command", "mcp__fixture__AskUserQuestion", "AskUserQuestionExtra",
                     "askuserquestion", "ask_user", "question", "userinput"] {
            let data = payload(tool, input: question.merging(["command": "printf fixture"]) { _, new in new })
            let before = DIBridge.buildMessage(agentType: "claude_code", hookType: "PreToolUse", sessionId: "fixture", stdinData: data)
            XCTAssertEqual(before.type, .toolStart, tool)
            let permission = DIBridge.buildPermissionRequest(sessionId: "fixture", data: data)
            XCTAssertEqual(permission.type, .permissionRequest, tool)
            XCTAssertFalse(DIBridge.isClaudeCodeQuestion(hookType: "PreToolUse", stdinData: data), tool)
            XCTAssertEqual(DIBridge.buildClaudeCodeQuestionResponse(answer: "No", stdinData: data), "{}", tool)
        }
    }

    func testUnsupportedBuiltinQuestionShapesRemainInNativeClient() {
        let invalid: [[String: Any]] = [
            ["questions": []], ["questions": [question, question]],
            ["questions": [question.merging(["multiSelect": true]) { _, new in new }]],
            ["question": "  ", "options": ["Yes"]], ["description": "Benign", "command": "printf fixture"],
            ["question": "Continue?", "options": [1]],
            ["question": "Continue?", "options": [["description": "missing label"]]],
            ["question": "Continue?", "options": ["Yes"], "command": "printf fixture"]
        ]
        for input in invalid {
            let data = payload(input: input)
            for hook in ["PreToolUse", "PermissionRequest"] {
                let message = DIBridge.buildMessage(agentType: "claude_code", hookType: hook, sessionId: "fixture", stdinData: data)
                XCTAssertEqual(message.type, .statusUpdate, "\(hook): \(input)")
                XCTAssertEqual(message.observedState, "waitingAnswer")
                XCTAssertEqual(DIBridge.buildClaudeCodeQuestionResponse(answer: "No", stdinData: data, hookType: hook), "{}")
            }
        }
    }

    func testBuiltinSingleQuestionAndCustomAnswerRemainSupported() throws {
        for input in [question, ["questions": [question]], ["question": "Path?", "options": []]] {
            let data = payload(input: input)
            let message = DIBridge.buildMessage(agentType: "claude_code", hookType: "PreToolUse", sessionId: "fixture", stdinData: data)
            XCTAssertEqual(message.type, .question)
            XCTAssertEqual(message.allowsCustomAnswer, true)
            let response = DIBridge.buildClaudeCodeQuestionResponse(answer: "自定义", stdinData: data)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
            let output = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
            XCTAssertEqual(output["permissionDecision"] as? String, "allow")
        }
    }

    func testPermissionRequestUsesDecisionEnvelopeAndBlankAnswerNeverAllows() throws {
        let data = payload()
        let response = DIBridge.buildClaudeCodeQuestionResponse(answer: "No", stdinData: data, hookType: "PermissionRequest")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let output = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        XCTAssertNil(output["permissionDecision"])
        let decision = try XCTUnwrap(output["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertNotNil(decision["updatedInput"])
        for answer in ["", " \n", "bad\0answer"] {
            XCTAssertEqual(DIBridge.buildClaudeCodeQuestionResponse(answer: answer, stdinData: data), "{}")
        }
    }

    func testOptionByteLimitIsCheckedBeforePresentingTheQuestion() {
        for option in [String(repeating: "x", count: 8193), String(repeating: "中", count: 2731)] {
            let data = payload(input: ["question": "Continue?", "options": [option]])
            let message = DIBridge.buildMessage(agentType: "claude_code", hookType: "PreToolUse", sessionId: "fixture", stdinData: data)
            XCTAssertEqual(message.type, .statusUpdate)
            XCTAssertEqual(message.observedState, "waitingAnswer")
        }
        let data = payload(input: ["question": "Continue?", "options": [String(repeating: "x", count: 8192)]])
        XCTAssertTrue(DIBridge.isClaudeCodeQuestion(hookType: "PreToolUse", stdinData: data))
    }
}
