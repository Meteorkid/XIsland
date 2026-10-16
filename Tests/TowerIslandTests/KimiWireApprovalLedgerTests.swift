import XCTest
@testable import DIBridge

final class KimiWireApprovalLedgerTests: XCTestCase {
    private func packet(rpc: String = "rpc", native: String = "native", description: String = "fixture") -> [String: Any] {
        ["jsonrpc": "2.0", "method": "request", "id": rpc, "params": ["type": "ApprovalRequest",
            "payload": ["id": native, "tool_call_id": "tool", "sender": "Shell", "action": "run", "description": description]]]
    }

    func testDuplicatesCannotRespondTwiceOrReopenConsumedIdentity() throws {
        let ledger = try KimiWireApprovalLedger(protocolVersion: "1.10", ownsApprovalResponses: true)
        XCTAssertNotNil(try ledger.register(packet(), isReplay: false))
        XCTAssertNil(try ledger.register(packet(), isReplay: false))
        XCTAssertThrowsError(try ledger.register(packet(description: "changed"), isReplay: false))
        XCTAssertThrowsError(try ledger.respond(rpcID: "rpc", requestID: "other", approved: true))
        XCTAssertEqual(ledger.pendingCount, 1)
        _ = try ledger.respond(rpcID: "rpc", requestID: "native", approved: false)
        XCTAssertThrowsError(try ledger.respond(rpcID: "rpc", requestID: "native", approved: true))
        XCTAssertThrowsError(try ledger.register(packet(), isReplay: false))
    }

    func testExternalResolutionAndCloseInvalidatePendingResponses() throws {
        let ledger = try KimiWireApprovalLedger(protocolVersion: "1.10", ownsApprovalResponses: true)
        _ = try ledger.register(packet(), isReplay: false)
        XCTAssertFalse(ledger.resolveExternally(requestID: "unknown"))
        XCTAssertTrue(ledger.resolveExternally(requestID: "native"))
        XCTAssertThrowsError(try ledger.respond(rpcID: "rpc", requestID: "native", approved: true))
        _ = try ledger.register(packet(rpc: "next", native: "next"), isReplay: false)
        ledger.close()
        XCTAssertEqual(ledger.pendingCount, 0)
        XCTAssertThrowsError(try ledger.respond(rpcID: "next", requestID: "next", approved: true))
    }

    func testOwnershipReplayAndInvalidFeedbackDoNotCreateOrConsumeRequests() throws {
        XCTAssertThrowsError(try KimiWireApprovalLedger(protocolVersion: "1.10", ownsApprovalResponses: false))
        let ledger = try KimiWireApprovalLedger(protocolVersion: "1.10", ownsApprovalResponses: true)
        XCTAssertThrowsError(try ledger.register(packet(), isReplay: true))
        XCTAssertEqual(ledger.pendingCount, 0)
        _ = try ledger.register(packet(), isReplay: false)
        XCTAssertThrowsError(try ledger.respond(rpcID: "rpc", requestID: "native", approved: true, feedback: "invalid"))
        XCTAssertEqual(ledger.pendingCount, 1)
        XCTAssertNoThrow(try ledger.respond(rpcID: "rpc", requestID: "native", approved: false))
    }
}
