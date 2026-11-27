import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

@MainActor
final class NativeToolResolutionTests: XCTestCase {
    private func makeAuditManager() -> (SessionManager, ApprovalAuditStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xisland-native-tool-\(UUID().uuidString)", isDirectory: true)
        let store = ApprovalAuditStore(url: directory.appendingPathComponent("audit.jsonl"))
        return (SessionManager(approvalAuditStore: store), store, directory)
    }

    private func permission(_ sessionID: String, hash: String?, nativeID: String? = nil) -> DIMessage {
        var message = DIMessage(type: .permissionRequest, sessionId: sessionID)
        message.agentType = AgentType.claudeCode.rawValue
        message.tool = "Bash"
        message.toolInput = #"{"command":"echo hi"}"#
        message.toolInputHash = hash
        message.nativeRequestId = nativeID
        return message
    }

    private func toolStart(_ sessionID: String, callID: String, agentID: String? = nil,
                           tool: String = "Bash") -> DIMessage {
        let hash = DIBridge.toolInputHash(["command": "echo hi"])
        var message = DIMessage(type: .toolStart, sessionId: sessionID)
        message.agentType = AgentType.claudeCode.rawValue
        message.tool = tool
        message.toolCallId = callID
        message.toolInputHash = hash
        message.nativeAgentId = agentID
        return message
    }

    private func toolComplete(_ sessionID: String, callID: String, tool: String = "Bash") -> DIMessage {
        var message = DIMessage(type: .toolComplete, sessionId: sessionID)
        message.agentType = AgentType.claudeCode.rawValue
        message.tool = tool
        message.toolCallId = callID
        message.toolResult = "hi"
        return message
    }

    func testPreToolUseToolIDIsAttachedToPermissionAndCompletedToolClearsIt() throws {
        let (manager, store, directory) = makeAuditManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hash = DIBridge.toolInputHash(["command": "echo hi"])
        manager.handleMessage(toolStart("correlated", callID: "tool-1"))
        manager.handlePermissionRequest(permission("correlated", hash: hash),
                                        cancel: {}, respond: { _ in })
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.pendingPermission?.nativeToolCallID, "tool-1")
        XCTAssertEqual(session.pendingPermission?.toolInputHash, hash)
        XCTAssertEqual(session.status, .waitingPermission)

        manager.handleMessage(toolComplete("correlated", callID: "tool-1"))
        XCTAssertNil(session.pendingPermission)
        XCTAssertEqual(session.status, .active)
        XCTAssertEqual(store.records(sessionID: "correlated").first?.decision, .nativeResolved)
    }

    func testUnrelatedCompletionCannotClearPendingPermission() throws {
        let manager = SessionManager()
        let hash = DIBridge.toolInputHash(["command": "echo hi"])
        manager.handleMessage(toolStart("unrelated", callID: "read-1", tool: "Read"))
        manager.handlePermissionRequest(permission("unrelated", hash: hash),
                                        cancel: {}, respond: { _ in })
        let session = try XCTUnwrap(manager.sessions.first)
        let pendingID = session.pendingPermission?.id

        manager.handleMessage(toolComplete("unrelated", callID: "read-1", tool: "Read"))
        XCTAssertEqual(session.pendingPermission?.id, pendingID)
        XCTAssertEqual(session.status, .waitingPermission)
    }

    func testAmbiguousIdenticalPreToolCallsAreNotGuessed() throws {
        let manager = SessionManager()
        let hash = DIBridge.toolInputHash(["command": "echo hi"])
        manager.handleMessage(toolStart("ambiguous", callID: "tool-a"))
        manager.handleMessage(toolStart("ambiguous", callID: "tool-b"))
        manager.handlePermissionRequest(permission("ambiguous", hash: hash),
                                        cancel: {}, respond: { _ in })
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertNil(session.pendingPermission?.nativeToolCallID)
        XCTAssertEqual(session.status, .waitingPermission)

        manager.handleMessage(toolComplete("ambiguous", callID: "tool-a"))
        XCTAssertNotNil(session.pendingPermission, "ambiguous ownership must not be guessed")
    }

    func testPreToolUseArrivingAfterPermissionCanStillAttach() throws {
        let (manager, store, directory) = makeAuditManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hash = DIBridge.toolInputHash(["command": "echo hi"])
        manager.handlePermissionRequest(permission("reverse", hash: hash),
                                        cancel: {}, respond: { _ in })
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertNil(session.pendingPermission?.nativeToolCallID)

        manager.handleMessage(toolStart("reverse", callID: "tool-late"))
        XCTAssertEqual(session.pendingPermission?.nativeToolCallID, "tool-late")

        manager.handleMessage(toolComplete("reverse", callID: "tool-late"))
        XCTAssertNil(session.pendingPermission)
        XCTAssertEqual(store.records(sessionID: "reverse").first?.decision, .nativeResolved)
    }

    func testClaudePreToolUseAndPermissionRequestProduceSameCanonicalHash() throws {
        let pre = try DIBridge.makeMessage(
            agentType: "claude_code", hookType: "PreToolUse", sessionId: "bridge",
            stdinData: [
                "session_id": "bridge", "hook_event_name": "PreToolUse",
                "tool_name": "Bash", "tool_input": ["command": "echo hi", "timeout": 30],
                "tool_use_id": "tool-bridge"
            ] as [String: Any]
        )
        let permission = try DIBridge.makeMessage(
            agentType: "claude_code", hookType: "PermissionRequest", sessionId: "bridge",
            stdinData: [
                "session_id": "bridge", "hook_event_name": "PermissionRequest",
                "tool_name": "Bash", "tool_input": ["timeout": 30, "command": "echo hi"]
            ] as [String: Any]
        )
        XCTAssertEqual(pre.toolInputHash, permission.toolInputHash)
        XCTAssertEqual(pre.toolCallId, "tool-bridge")
        XCTAssertNil(permission.toolCallId, "PermissionRequest has no tool_use_id by contract")
    }
}
