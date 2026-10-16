import XCTest
@testable import DIBridge

final class KimiWireConnectionStateTests: XCTestCase {
    func testMalformedReplayCompletionNeverReenablesApproval() {
        let state = ready()
        state.observeClient(["jsonrpc": "2.0", "method": "replay", "id": "replay"])
        state.observeAgent(["jsonrpc": "2.0", "id": "replay", "result": ["status": "unknown"]])
        XCTAssertTrue(state.closed)
        XCTAssertFalse(state.canHandleLiveApproval)
    }

    private func ready() -> KimiWireConnectionState {
        let state = KimiWireConnectionState()
        state.observeClient(["jsonrpc": "2.0", "method": "initialize", "id": "init", "params": ["protocol_version": "1.10"]])
        state.observeAgent(["jsonrpc": "2.0", "id": "init", "result": ["protocol_version": "1.10"]])
        return state
    }

    func testHandshakeAndReplayAreCorrelatedByExactID() {
        let state = ready()
        XCTAssertTrue(state.canHandleLiveApproval)
        state.observeClient(["jsonrpc": "2.0", "method": "replay", "id": "r1"])
        state.observeClient(["jsonrpc": "2.0", "method": "replay", "id": "r2"])
        XCTAssertFalse(state.canHandleLiveApproval)
        state.observeAgent(["jsonrpc": "2.0", "id": "other", "result": [:]])
        XCTAssertFalse(state.canHandleLiveApproval)
        state.observeAgent(["jsonrpc": "2.0", "id": "r2", "error": ["code": -32000]])
        XCTAssertFalse(state.canHandleLiveApproval)
        state.observeAgent(["jsonrpc": "2.0", "id": "r1", "result": ["status": "finished"]])
        XCTAssertTrue(state.canHandleLiveApproval)
        state.close()
        XCTAssertFalse(state.canHandleLiveApproval)
    }

    func testMissingOrUnsupportedHandshakeNeverEnablesApproval() {
        let state = KimiWireConnectionState()
        XCTAssertFalse(state.canHandleLiveApproval)
        state.observeAgent(["jsonrpc": "2.0", "id": "unknown", "result": ["protocol_version": "1.10"]])
        XCTAssertFalse(state.canHandleLiveApproval)
        state.observeClient(["jsonrpc": "2.0", "method": "initialize", "id": "init", "params": ["protocol_version": "1.10"]])
        state.observeAgent(["jsonrpc": "2.0", "id": "init", "result": ["protocol_version": "1.11"]])
        XCTAssertTrue(state.closed)
        XCTAssertFalse(state.canHandleLiveApproval)
    }

    func testReusedInFlightIDsFailClosed() {
        let state = ready()
        let replay: [String: Any] = ["jsonrpc": "2.0", "method": "replay", "id": "same"]
        state.observeClient(replay); state.observeClient(replay)
        XCTAssertTrue(state.closed)
        XCTAssertFalse(state.canHandleLiveApproval)
    }
}
