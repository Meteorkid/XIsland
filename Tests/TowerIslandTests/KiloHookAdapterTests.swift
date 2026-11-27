import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

final class KiloHookAdapterTests: XCTestCase {
    private func normalize(_ event: String, _ data: [String: Any]) throws -> DIMessage {
        try DIBridge.makeMessage(agentType: "kilo_code", hookType: event, sessionId: "fallback",
                                 stdinData: data, adapter: "kilo_plugin")
    }

    func testToolEventsUseKiloAgentAndSessionNamespace() throws {
        let started = try normalize("tool.started", [
            "native_event": "tool.started", "session_id": "session", "tool_name": "bash",
            "tool_use_id": "call-1", "tool_input": ["command": "swift test"],
        ])
        XCTAssertEqual(started.agentType, "kilo_code")
        XCTAssertEqual(started.sessionId, "kilo-session")
        XCTAssertEqual(started.type, .toolStart)
        XCTAssertEqual(started.tool, "bash")
        XCTAssertEqual(started.toolCallId, "call-1")
        XCTAssertEqual(started.toolInput, "{\"command\":\"swift test\"}")

        let completed = try normalize("tool.completed", [
            "native_event": "tool.completed", "session_id": "session", "tool_name": "bash",
            "tool_use_id": "call-1", "tool_input": ["command": "swift test"], "tool_response": "ok",
        ])
        XCTAssertEqual(completed.type, .toolComplete)
        XCTAssertEqual(completed.toolResult, "ok")
    }

    func testPromptAndStatusMappingKeepApprovalsInsideKilo() throws {
        let start = try normalize("prompt.submitted", [
            "native_event": "prompt.submitted", "session_id": "session", "prompt": "修复测试", "model": "kilo/model",
        ])
        XCTAssertEqual(start.type, .sessionStart)
        XCTAssertEqual(start.prompt, "修复测试")
        XCTAssertEqual(start.model, "kilo/model")

        let waiting = try normalize("status.update", [
            "native_event": "status.update", "session_id": "session",
            "state": "waitingPermission", "status": "请在 Kilo 处理权限请求",
        ])
        XCTAssertEqual(waiting.type, .statusUpdate)
        XCTAssertEqual(waiting.observedState, "waitingPermission")
        XCTAssertEqual(waiting.status, "请在 Kilo 处理权限请求")
        XCTAssertNil(waiting.nativeRequestId)

        XCTAssertThrowsError(try normalize("status.update", [
            "native_event": "status.update", "session_id": "session", "state": "approved",
        ]))
    }

    func testTerminalIdentityFromTheHostMakesCLISessionsPrecise() throws {
        let start = try normalize("prompt.submitted", [
            "native_event": "prompt.submitted", "session_id": "session", "prompt": "修复测试",
            "terminal": "iTerm.app", "term_session_id": "iterm:w0t0p0:11111111-2222-4333-8444-555555555555",
            "cwd": "/tmp/kilo-work",
        ])
        XCTAssertEqual(start.terminal, "iTerm.app")
        XCTAssertEqual(start.termSessionId, "iterm:w0t0p0:11111111-2222-4333-8444-555555555555")
        let snapshot = TerminalJumpManager.SessionSnapshot(id: start.sessionId, agentType: .kiloCode,
            terminal: start.terminal ?? "", workingDirectory: start.workingDir ?? "",
            termSessionId: start.termSessionId, windowNumber: nil, title: "")
        XCTAssertEqual(TerminalJumpManager.plan(for: snapshot),
                       .terminal(.iTerm(id: "iterm:w0t0p0:11111111-2222-4333-8444-555555555555")))
    }

    func testExtensionSessionsOpenTheProjectWhenNoSessionLinkExists() throws {
        let start = try normalize("prompt.submitted", [
            "native_event": "prompt.submitted", "session_id": "session", "prompt": "修复测试",
            "terminal": "vscode", "cwd": "/tmp/kilo-work",
        ])
        XCTAssertNil(start.termSessionId)
        let snapshot = TerminalJumpManager.SessionSnapshot(id: start.sessionId, agentType: .kiloCode,
            terminal: start.terminal ?? "", workingDirectory: start.workingDir ?? "",
            termSessionId: start.termSessionId, windowNumber: nil, title: "")
        XCTAssertEqual(TerminalJumpManager.plan(for: snapshot),
                       .project(.vscode, URL(fileURLWithPath: "/tmp/kilo-work"), ""))
    }

    func testDeletedSessionEndsWithoutClaimingCompletion() throws {
        let end = try normalize("session.deleted", ["native_event": "session.deleted", "session_id": "session"])
        XCTAssertEqual(end.type, .sessionEnd)
        XCTAssertEqual(end.observedState, "completed")
        XCTAssertEqual(end.sessionId, "kilo-session")
    }
}
