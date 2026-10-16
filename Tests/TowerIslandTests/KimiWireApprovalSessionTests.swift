import XCTest
@testable import DIBridge

final class KimiWireApprovalSessionTests: XCTestCase {
    func testConcurrentApprovalsStayFIFOAndExternalResolutionAdvancesQueue() throws {
        let session = KimiWireApprovalSession(ownsApprovalResponses: true)
        try initialize(session)
        let first = try XCTUnwrap(session.observeAgent(request))
        var secondPacket = request
        secondPacket["id"] = "rpc-2"
        var params = try XCTUnwrap(secondPacket["params"] as? [String: Any])
        var payload = try XCTUnwrap(params["payload"] as? [String: Any])
        payload["id"] = "native-2"
        params["payload"] = payload; secondPacket["params"] = params
        let second = try XCTUnwrap(session.observeAgent(secondPacket))
        XCTAssertEqual(session.queuedCount, 2)
        XCTAssertEqual(session.nextApproval, first)
        XCTAssertThrowsError(try session.respond(to: second, approved: true))
        XCTAssertEqual(session.queuedCount, 2)
        _ = try session.observeAgent(["jsonrpc": "2.0", "method": "event", "params": ["type": "ApprovalResponse",
            "payload": ["request_id": "native", "response": "reject"]]])
        XCTAssertEqual(session.nextApproval, second)
        XCTAssertThrowsError(try session.respond(to: first, approved: true))
        _ = try session.respond(to: second, approved: false)
        XCTAssertNil(session.nextApproval)
        XCTAssertEqual(session.queuedCount, 0)
    }

    func testResolutionDuringReplayCannotBeAnsweredAfterReplayEnds() throws {
        let session = KimiWireApprovalSession(ownsApprovalResponses: true)
        try initialize(session)
        let live = try XCTUnwrap(session.observeAgent(request))
        session.observeClient(["jsonrpc": "2.0", "id": "replay", "method": "replay"])
        _ = try session.observeAgent(["jsonrpc": "2.0", "method": "event", "params": ["type": "ApprovalResponse",
            "payload": ["request_id": "native", "response": "reject"]]])
        _ = try session.observeAgent(["jsonrpc": "2.0", "id": "replay", "result": ["status": "finished"]])
        XCTAssertThrowsError(try session.respond(to: live, approved: true))
        XCTAssertThrowsError(try session.observeAgent(request))
    }

    func testReinitializationNeverReclaimsReusedRequestIDs() throws {
        let session = KimiWireApprovalSession(ownsApprovalResponses: true)
        try initialize(session)
        let old = try XCTUnwrap(session.observeAgent(request))
        try initialize(session)
        XCTAssertNil(try session.observeAgent(request))
        XCTAssertThrowsError(try session.respond(to: old, approved: true))
    }

    private let request: [String: Any] = ["jsonrpc": "2.0", "method": "request", "id": "rpc", "params": ["type": "ApprovalRequest",
        "payload": ["id": "native", "tool_call_id": "tool", "sender": "Shell", "action": "run", "description": "fixture"]]]
    private func initialize(_ session: KimiWireApprovalSession) throws {
        session.observeClient(["jsonrpc": "2.0", "id": "init", "method": "initialize", "params": ["protocol_version": "1.10"]])
        _ = try session.observeAgent(["jsonrpc": "2.0", "id": "init", "result": ["protocol_version": "1.10"]])
    }

    func testObserverWithoutOwnershipNeverClaimsApproval() throws {
        let session = KimiWireApprovalSession(ownsApprovalResponses: false)
        try initialize(session)
        XCTAssertNil(try session.observeAgent(request))
        let parsed = try KimiWireApproval(packet: request, protocolVersion: "1.10", isReplay: false)
        XCTAssertThrowsError(try session.respond(to: parsed, approved: true))
    }

    func testReplayBlocksLiveResponseAndDoesNotClaimHistoricalRequests() throws {
        let session = KimiWireApprovalSession(ownsApprovalResponses: true)
        XCTAssertNil(try session.observeAgent(request))
        try initialize(session)
        let live = try XCTUnwrap(session.observeAgent(request))
        session.observeClient(["jsonrpc": "2.0", "id": "replay", "method": "replay"])
        XCTAssertNil(try session.observeAgent(request))
        XCTAssertThrowsError(try session.respond(to: live, approved: true))
        _ = try session.observeAgent(["jsonrpc": "2.0", "id": "replay", "error": ["code": -32000]])
        XCTAssertNoThrow(try session.respond(to: live, approved: false))
        XCTAssertThrowsError(try session.respond(to: live, approved: true))
    }

    func testExternalResolutionReinitializationAndCloseInvalidateCallbacks() throws {
        for mode in ["external", "initialize", "close"] {
            let session = KimiWireApprovalSession(ownsApprovalResponses: true)
            try initialize(session)
            let live = try XCTUnwrap(session.observeAgent(request))
            if mode == "external" {
                _ = try session.observeAgent(["jsonrpc": "2.0", "method": "event", "params": ["type": "ApprovalResponse", "payload": ["request_id": "native", "response": "reject"]]])
            } else if mode == "initialize" { try initialize(session) }
            else { session.close() }
            XCTAssertThrowsError(try session.respond(to: live, approved: true), mode)
        }
    }
}
