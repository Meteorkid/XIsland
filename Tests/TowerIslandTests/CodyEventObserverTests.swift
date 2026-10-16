import XCTest
@testable import DIBridge

final class CodyEventObserverTests: XCTestCase {
    func testObserverEndIsReportedOnceWithoutInventingNativeSessionEnd() throws {
        let observer = try CodyEventObserver(source: "fixture")
        _ = try observer.consumeAgentFrame(frame(processing: true))
        let ended = observer.finish(interrupted: true)
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended.first?.type, .statusUpdate)
        XCTAssertNil(ended.first?.observedState)
        XCTAssertEqual(ended.first?.statusIsAssistantReply, false)
        XCTAssertTrue(ended.first?.status?.contains("可能已过期") == true)
        XCTAssertTrue(observer.finish(interrupted: false).isEmpty)
        XCTAssertTrue(try observer.consumeAgentFrame(frame()).isEmpty)
    }

    private func frame(chat: String = "chat", panel: String = "panel", processing: Any = false, encoded: Bool = false, messages: [[String: Any]] = []) throws -> Data {
        let transcript: [String: Any] = ["type": "transcript", "chatID": chat, "isMessageInProgress": processing, "messages": messages]
        var params: [String: Any] = ["id": panel]
        if encoded { params["stringEncodedMessage"] = String(decoding: try JSONSerialization.data(withJSONObject: transcript), as: UTF8.self) }
        else { params["message"] = transcript }
        return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": encoded ? "webview/postMessageStringEncoded" : "webview/postMessage", "params": params])
    }

    func testBothEncodingsDeduplicateByChatNotPanel() throws {
        let observer = try CodyEventObserver(source: "fixture")
        let first = try observer.consumeAgentFrame(frame())
        XCTAssertEqual(first.first?.observedState, "idle")
        XCTAssertTrue(try observer.consumeAgentFrame(frame(panel: "other", encoded: true)).isEmpty)
        let active = try observer.consumeAgentFrame(frame(processing: true))
        XCTAssertEqual(active.first?.sessionId, first.first?.sessionId)
        XCTAssertEqual(active.first?.observedState, "active")
        XCTAssertNotEqual(try observer.consumeAgentFrame(frame(chat: "other")).first?.sessionId, first.first?.sessionId)
        XCTAssertNotEqual(try CodyEventObserver(source: "another").consumeAgentFrame(frame()).first?.sessionId, first.first?.sessionId)
    }

    func testPreviewExcludesContextAndDoesNotInventMessageID() throws {
        let result = try CodyEventObserver(source: "fixture").consumeAgentFrame(frame(messages: [["speaker": "assistant", "text": "reply", "contextFiles": ["secret"], "processes": ["private"], "error": ["message": "sensitive"]]]))
        XCTAssertEqual(result.first?.observedState, "error")
        XCTAssertEqual(result.first?.status, "Cody 本轮报告错误\n回复预览：reply")
        XCTAssertEqual(result.first?.statusIsAssistantReply, false)
        XCTAssertNil(result.first?.nativeMessageId)
        XCTAssertNil(result.first?.tokensIn)
    }

    func testRejectsMalformedStateAndBoundsSessions() throws {
        let observer = try CodyEventObserver(source: "fixture")
        XCTAssertThrowsError(try observer.consumeAgentFrame(frame(processing: 1)))
        XCTAssertThrowsError(try observer.consumeAgentFrame(frame(chat: "")))
        for index in 0..<64 { _ = try observer.consumeAgentFrame(frame(chat: String(index))) }
        XCTAssertThrowsError(try observer.consumeAgentFrame(frame(chat: "overflow")))
        XCTAssertTrue(try observer.consumeAgentFrame(frame(chat: "0")).isEmpty)
    }
}
