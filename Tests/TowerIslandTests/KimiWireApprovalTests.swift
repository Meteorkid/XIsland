import XCTest
@testable import DIBridge

final class KimiWireApprovalTests: XCTestCase {
    func testPermissionProjectionUsesConnectionIdentityAndExactResolutionKey() throws {
        let request = try KimiWireApproval(packet: packet, protocolVersion: "1.10", isReplay: false)
        let connection = UUID()
        let message = request.permissionMessage(connectionID: connection)
        XCTAssertEqual(message.type, .permissionRequest)
        XCTAssertEqual(message.nativeRequestId, "native-request")
        XCTAssertEqual(message.toolCallId, "tool-1")
        XCTAssertEqual(message.nativeRequestKind, "permission")
        XCTAssertTrue(message.sessionId.hasPrefix("kimi-wire-connection-"))
        XCTAssertNotEqual(message.sessionId, request.permissionMessage(connectionID: UUID()).sessionId)
        let resolved = request.resolvedMessage(connectionID: connection)
        XCTAssertEqual(resolved.type, .interactionResolved)
        XCTAssertEqual(resolved.sessionId, message.sessionId)
        XCTAssertEqual(resolved.nativeRequestId, message.nativeRequestId)
        XCTAssertNil(message.workingDir)
    }

    func testBackgroundSourceAndNativeDisplayArePreservedWithoutExecutingThem() throws {
        var value = packet
        var params = try XCTUnwrap(value["params"] as? [String: Any])
        var payload = try XCTUnwrap(params["payload"] as? [String: Any])
        payload["source_kind"] = "background_agent"
        payload["source_id"] = "background-task"
        payload["agent_id"] = "agent-1"
        payload["source_description"] = "Background fixture"
        payload["display"] = [["type": "shell", "language": "bash", "command": "echo 'fixture'"],
                              ["type": "diff", "path": "/tmp/file", "old_text": "old", "new_text": "new"]]
        params["payload"] = payload; value["params"] = params
        let parsed = try KimiWireApproval(packet: value, protocolVersion: "1.10", isReplay: false)
        XCTAssertEqual(parsed.sourceKind, "background_agent")
        XCTAssertEqual(parsed.sourceID, "background-task")
        XCTAssertEqual(parsed.agentID, "agent-1")
        let blocks = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(parsed.displayJSON.utf8)) as? [[String: Any]])
        XCTAssertEqual(blocks.first?["command"] as? String, "echo 'fixture'")
        XCTAssertEqual(blocks.last?["old_text"] as? String, "old")
        payload["display"] = "invalid"
        params["payload"] = payload; value["params"] = params
        XCTAssertThrowsError(try KimiWireApproval(packet: value, protocolVersion: "1.10", isReplay: false))
    }

    func testEmptyDisplayStringsAreValidButMissingIdentityIsNot() throws {
        var value = packet
        var params = try XCTUnwrap(value["params"] as? [String: Any])
        var payload = try XCTUnwrap(params["payload"] as? [String: Any])
        for field in ["sender", "action", "description"] { payload[field] = "" }
        params["payload"] = payload; value["params"] = params
        XCTAssertNoThrow(try KimiWireApproval(packet: value, protocolVersion: "1.10", isReplay: false))
        payload["id"] = ""
        params["payload"] = payload; value["params"] = params
        XCTAssertThrowsError(try KimiWireApproval(packet: value, protocolVersion: "1.10", isReplay: false))
    }

    private var packet: [String: Any] {
        ["jsonrpc": "2.0", "method": "request", "id": "outer-rpc",
         "params": ["type": "ApprovalRequest", "payload": ["id": "native-request", "tool_call_id": "tool-1",
             "sender": "Shell", "action": "run command", "description": "fixture only"]]]
    }

    func testBothIdentitiesArePreservedAndAllowIsOnlyOnce() throws {
        let approval = try KimiWireApproval(packet: packet, protocolVersion: "1.10", isReplay: false)
        for approved in [true, false] {
            let data = try approval.response(approved: approved, feedback: approved ? "" : "不要执行\n改用只读命令")
            XCTAssertEqual(data.last, 10)
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(response["id"] as? String, "outer-rpc")
            let result = try XCTUnwrap(response["result"] as? [String: String])
            XCTAssertEqual(result["request_id"], "native-request")
            XCTAssertEqual(result["response"], approved ? "approve" : "reject")
        }
    }

    func testReplayUnsupportedVersionAndOtherRequestKindsCannotBeApproved() {
        XCTAssertThrowsError(try KimiWireApproval(packet: packet, protocolVersion: "1.10", isReplay: true))
        XCTAssertThrowsError(try KimiWireApproval(packet: packet, protocolVersion: "1.1", isReplay: false))
        var other = packet
        other["params"] = ["type": "HookRequest", "payload": [:]]
        XCTAssertThrowsError(try KimiWireApproval(packet: other, protocolVersion: "1.10", isReplay: false))
        other = packet; other["id"] = 1
        XCTAssertThrowsError(try KimiWireApproval(packet: other, protocolVersion: "1.10", isReplay: false))
    }

    func testFeedbackIsBoundedAndOnlyAttachedToDenial() throws {
        let approval = try KimiWireApproval(packet: packet, protocolVersion: "1.10", isReplay: false)
        XCTAssertThrowsError(try approval.response(approved: true, feedback: "change intent"))
        XCTAssertThrowsError(try approval.response(approved: false, feedback: "a\0b"))
        XCTAssertThrowsError(try approval.response(approved: false, feedback: String(repeating: "x", count: 8193)))
    }
}
