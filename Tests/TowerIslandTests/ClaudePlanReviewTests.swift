import XCTest
import DIShared
@testable import DIBridge

final class ClaudePlanReviewTests: XCTestCase {
    private let plan = "# Plan\n1. Read the existing bridge.\n2. Add the missing decision route."

    func testPermissionRequestKeepsSubagentAgentIDWithoutLeavingTheParentSession() {
        let message = DIBridge.buildPermissionRequest(sessionId: "parent", data: [
            "session_id": "parent",
            "agent_id": "agent-7",
            "tool_name": "Bash",
            "tool_input": ["command": "echo hi"]
        ] as [String: Any])

        XCTAssertEqual(message.sessionId, "parent")
        XCTAssertEqual(message.nativeAgentId, "agent-7")
        XCTAssertNil(message.parentSessionId)
        XCTAssertEqual(message.tool, "Bash")
    }

    func testPermissionRequestIgnoresInvalidSubagentAgentID() {
        let message = DIBridge.buildPermissionRequest(sessionId: "parent", data: [
            "agent_id": "  ",
            "tool_name": "Bash"
        ] as [String: Any])
        XCTAssertNil(message.nativeAgentId)
    }

    func testExitPlanModePermissionBecomesPlanReview() throws {
        let data: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "claude-session",
            "tool_name": "ExitPlanMode",
            "tool_input": ["plan": plan, "planFilePath": "/tmp/plan.md"],
        ]
        let message = try DIBridge.makeMessage(
            agentType: "claude_code",
            hookType: "PermissionRequest",
            sessionId: "claude-session",
            stdinData: data
        )
        XCTAssertEqual(message.type, .planReview)
        XCTAssertEqual(message.planMarkdown, plan)
        XCTAssertNotNil(message.toolInput)
        XCTAssertNil(message.nativeRequestId)
    }

    func testNonClaudeCompatiblePermissionKeepsPermissionSemantics() throws {
        let data: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "devin-session",
            "tool_name": "ExitPlanMode",
            "tool_input": ["plan": plan],
        ]
        let message = try DIBridge.makeMessage(
            agentType: "devin",
            hookType: "PermissionRequest",
            sessionId: "devin-session",
            stdinData: data
        )
        XCTAssertEqual(message.type, .permissionRequest)
        XCTAssertNil(message.planMarkdown)
    }

    func testPlanApprovalCarriesUpdatedInputAndDenialCarriesFeedback() throws {
        let data: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "claude-session",
            "tool_name": "ExitPlanMode",
            "tool_input": ["plan": plan, "planFilePath": "/tmp/plan.md"],
        ]
        let allow = try XCTUnwrap(DIBridge.buildClaudeCodePlanResponse(approved: true, feedback: nil, stdinData: data))
        let allowRoot = try decode(allow)
        let allowOutput = try XCTUnwrap(allowRoot["hookSpecificOutput"] as? [String: Any])
        let allowDecision = try XCTUnwrap(allowOutput["decision"] as? [String: Any])
        XCTAssertEqual(allowOutput["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual(allowDecision["behavior"] as? String, "allow")
        XCTAssertEqual(allowDecision["updatedInput"] as? [String: String], ["plan": plan, "planFilePath": "/tmp/plan.md"])

        let deny = try XCTUnwrap(DIBridge.buildClaudeCodePlanResponse(approved: false, feedback: "Please add tests.", stdinData: data))
        let denyRoot = try decode(deny)
        let denyOutput = try XCTUnwrap(denyRoot["hookSpecificOutput"] as? [String: Any])
        let denyDecision = try XCTUnwrap(denyOutput["decision"] as? [String: Any])
        XCTAssertEqual(denyDecision["behavior"] as? String, "deny")
        XCTAssertEqual(denyDecision["message"] as? String, "Please add tests.")
        XCTAssertNil(denyDecision["updatedInput"])
    }

    func testExitPlanModeWithoutInlinePlanFallsBackToPermissionButStillCanApprove() throws {
        let data: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "claude-session",
            "tool_name": "ExitPlanMode",
            "tool_input": ["allowedPrompts": [["tool": "Bash", "prompt": "run tests"]]],
        ]
        let message = try DIBridge.makeMessage(
            agentType: "claude_code",
            hookType: "PermissionRequest",
            sessionId: "claude-session",
            stdinData: data
        )
        XCTAssertEqual(message.type, .permissionRequest)
        XCTAssertNil(message.planMarkdown)

        let response = DIBridge.permissionHookResponse(agentType: "claude_code", approved: true,
                                                       hookType: "PermissionRequest", stdinData: data)
        let root = try decode(try XCTUnwrap(response.stdout))
        let output = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(output["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertNotNil(decision["updatedInput"])
    }

    func testPlanApprovalWithoutNativeInputDoesNotClaimSuccess() throws {
        XCTAssertNil(DIBridge.buildClaudeCodePlanResponse(approved: true, feedback: nil, stdinData: [:]))
        XCTAssertNil(DIBridge.buildClaudeCodePlanResponse(approved: true, feedback: nil, stdinData: nil))
    }

    func testPlanTextWithoutNativeToolInputDoesNotCreateUnapprovablePlanReview() {
        let data: [String: Any] = ["tool_name": "ExitPlanMode", "plan": self.plan]
        let message = DIBridge.buildPermissionRequest(sessionId: "fixture", data: data, allowsPlanRedirect: true)
        XCTAssertEqual(message.type, .permissionRequest)
        XCTAssertNil(message.planMarkdown)
    }

    func testNonPlanPermissionCannotBeRedirectedAsPlanReview() {
        let data: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": "npm test"],
        ]
        let message = DIBridge.buildPermissionRequest(sessionId: "fixture", data: data, allowsPlanRedirect: true)
        XCTAssertEqual(message.type, .permissionRequest)
        XCTAssertNil(message.planMarkdown)
    }

    func testOnlyVerifiedPermissionSourcesGetStructuredDecisionRoutes() {
        let supported: [(String, String?, String?)] = [
            ("claude_code", nil, "PermissionRequest"),
            ("codex", nil, "PermissionRequest"),
            ("qwen", nil, "PermissionRequest"),
            ("qoder", nil, "PermissionRequest"),
            ("trae", nil, "PermissionRequest"),
            ("devin", nil, "PermissionRequest"),
            ("opencode", "opencode_plugin", "PermissionRequest"),
            ("cursor", nil, "beforeShellExecution"),
        ]
        for (agent, adapter, hook) in supported {
            for approved in [true, false] {
                let response = DIBridge.permissionHookResponse(agentType: agent, approved: approved,
                                                               adapter: adapter, hookType: hook)
                XCTAssertNotNil(response.stdout, "\(agent) approved=\(approved)")
                XCTAssertEqual(response.exitCode, 0, "\(agent) approved=\(approved)")
            }
        }

        let observeOnly = ["kimi", "workbuddy", "kilo_code", "aider", "copilot_cli",
                           "antigravity", "amp", "pi", "kiro", "code_buddy", "deepseek"]
        for agent in observeOnly {
            let response = DIBridge.permissionHookResponse(agentType: agent, approved: false)
            XCTAssertNil(response.stdout, agent)
            XCTAssertEqual(response.exitCode, 1, agent)
        }
    }

    private func decode(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
