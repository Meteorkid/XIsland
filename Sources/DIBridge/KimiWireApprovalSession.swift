import Foundation

/// 显式拥有审批响应权的连接逻辑；不负责启动进程或转发原始报文。
final class KimiWireApprovalSession {
    enum SessionError: Error { case interactionUnavailable }
    private let ownsApprovalResponses: Bool
    private let connection = KimiWireConnectionState()
    private var ledger: KimiWireApprovalLedger?
    private var queue: [KimiWireApproval] = []
    var nextApproval: KimiWireApproval? { connection.canHandleLiveApproval ? queue.first : nil }
    var queuedCount: Int { queue.count }

    init(ownsApprovalResponses: Bool) { self.ownsApprovalResponses = ownsApprovalResponses }

    func observeClient(_ packet: [String: Any]) {
        if packet["method"] as? String == "initialize" {
            // 新握手不能沿用前一轮 UI 的响应句柄。
            if connection.negotiatedVersion != nil { close(); return }
            ledger?.close()
            ledger = nil
            queue.removeAll()
        }
        connection.observeClient(packet)
        if connection.closed { close() }
    }

    func observeAgent(_ packet: [String: Any]) throws -> KimiWireApproval? {
        connection.observeAgent(packet)
        if connection.closed { close(); return nil }
        guard ownsApprovalResponses else { return nil }
        guard packet["jsonrpc"] as? String == "2.0", let params = packet["params"] as? [String: Any] else { return nil }
        if packet["method"] as? String == "event", params["type"] as? String == "ApprovalResponse",
           let payload = params["payload"] as? [String: Any], let requestID = payload["request_id"] as? String {
            ledger?.resolveExternally(requestID: requestID)
            queue.removeAll { $0.requestID == requestID }
            return nil
        }
        guard connection.canHandleLiveApproval else { return nil }
        if ledger == nil { ledger = try KimiWireApprovalLedger(protocolVersion: "1.10", ownsApprovalResponses: true) }
        guard packet["method"] as? String == "request", params["type"] as? String == "ApprovalRequest" else { return nil }
        let request = try ledger?.register(packet, isReplay: false)
        if let request { queue.append(request) }
        return request
    }

    func respond(to request: KimiWireApproval, approved: Bool, feedback: String = "") throws -> Data {
        guard ownsApprovalResponses, connection.canHandleLiveApproval, let ledger,
              queue.first == request else { throw SessionError.interactionUnavailable }
        let bytes = try ledger.respond(rpcID: request.rpcID, requestID: request.requestID, approved: approved, feedback: feedback)
        queue.removeFirst()
        return bytes
    }

    func close() {
        connection.close()
        ledger?.close()
        ledger = nil
        queue.removeAll()
    }
}
