import XCTest
@testable import DIBridge

final class AmazonQHookAdapterTests: XCTestCase {
    private let identity = "b9268c52-0714-4f16-a6b8-2637437d920c"
    private func payload(_ event: String) -> [String: Any] {
        ["hook_event_name": event, "cwd": "/tmp/project", "prompt": "hello", "tool_name": "read",
         "tool_input": ["path": "fixture"], "tool_response": ["success": false, "error": ["fixture"]]]
    }

    func testNativePayloadCannotSupplyWrapperIdentity() {
        var data = payload("agentSpawn")
        data["session_id"] = identity
        XCTAssertThrowsError(try AmazonQHookAdapter.normalize(hookType: "agentSpawn", stdinData: data, wrapperSessionID: nil))
        XCTAssertThrowsError(try AmazonQHookAdapter.normalize(hookType: "agentSpawn", stdinData: data, wrapperSessionID: "/tmp/project"))
    }

    func testSameDirectoryDifferentWrappersStaySeparate() throws {
        let data = payload("userPromptSubmit")
        let first = try AmazonQHookAdapter.normalize(hookType: "userPromptSubmit", stdinData: data, wrapperSessionID: identity)
        let second = try AmazonQHookAdapter.normalize(hookType: "userPromptSubmit", stdinData: data, wrapperSessionID: UUID().uuidString)
        XCTAssertNotEqual(first.sessionId, second.sessionId)
        XCTAssertTrue(first.sessionId.hasPrefix("amazonq-wrapper-"))
        XCTAssertEqual(first.prompt, "hello")
        XCTAssertEqual(first.type, .sessionStart)
    }

    func testToolAndStopDoNotInventPermissionCallIDOrReply() throws {
        let before = try AmazonQHookAdapter.normalize(hookType: "preToolUse", stdinData: payload("preToolUse"), wrapperSessionID: identity)
        XCTAssertEqual(before.type, .statusUpdate)
        XCTAssertNil(before.nativeRequestId)
        let after = try AmazonQHookAdapter.normalize(hookType: "postToolUse", stdinData: payload("postToolUse"), wrapperSessionID: identity)
        XCTAssertEqual(after.type, .toolComplete)
        XCTAssertEqual(after.observedState, "error")
        XCTAssertNil(after.toolCallId)
        let stop = try AmazonQHookAdapter.normalize(hookType: "stop", stdinData: payload("stop"), wrapperSessionID: identity)
        XCTAssertEqual(stop.type, .statusUpdate)
        XCTAssertEqual(stop.statusIsAssistantReply, false)
        XCTAssertEqual(stop.observedState, "idle")
        XCTAssertThrowsError(try AmazonQHookAdapter.normalize(hookType: "PermissionRequest", stdinData: payload("PermissionRequest"), wrapperSessionID: identity))
    }
}
