import Foundation

/// 由单个 Wire 连接串行调用；只用于明确拥有审批响应权的连接。
final class KimiWireApprovalLedger {
    enum LedgerError: Error { case unsupportedContext, closed, conflict, unknownRequest, limitReached }
    private let protocolVersion: String
    private var pending: [String: KimiWireApproval] = [:]
    private var nativeToRPC: [String: String] = [:]
    private var usedRPC: Set<String> = []
    private var usedNative: Set<String> = []
    private(set) var isClosed = false
    var pendingCount: Int { pending.count }

    init(protocolVersion: String, ownsApprovalResponses: Bool) throws {
        guard protocolVersion == "1.10", ownsApprovalResponses else { throw LedgerError.unsupportedContext }
        self.protocolVersion = protocolVersion
    }

    /// 相同在途请求重发不重复展示；已完成身份绝不重新打开。
    func register(_ packet: [String: Any], isReplay: Bool) throws -> KimiWireApproval? {
        guard !isClosed else { throw LedgerError.closed }
        let request = try KimiWireApproval(packet: packet, protocolVersion: protocolVersion, isReplay: isReplay)
        if let existing = pending[request.rpcID] {
            guard existing == request else { throw LedgerError.conflict }
            return nil
        }
        guard nativeToRPC[request.requestID] == nil, !usedRPC.contains(request.rpcID), !usedNative.contains(request.requestID) else {
            throw LedgerError.conflict
        }
        guard pending.count < 256, usedRPC.count < 4096 else { throw LedgerError.limitReached }
        pending[request.rpcID] = request
        nativeToRPC[request.requestID] = request.rpcID
        usedRPC.insert(request.rpcID)
        usedNative.insert(request.requestID)
        return request
    }

    func respond(rpcID: String, requestID: String, approved: Bool, feedback: String = "") throws -> Data {
        guard !isClosed else { throw LedgerError.closed }
        guard let request = pending[rpcID], request.requestID == requestID else { throw LedgerError.unknownRequest }
        let bytes = try request.response(approved: approved, feedback: feedback)
        // 生成合法响应后即消耗，写入失败由连接报告，不自动重发审批。
        pending.removeValue(forKey: rpcID)
        nativeToRPC.removeValue(forKey: requestID)
        return bytes
    }

    @discardableResult
    func resolveExternally(requestID: String) -> Bool {
        guard !isClosed, let rpc = nativeToRPC.removeValue(forKey: requestID) else { return false }
        pending.removeValue(forKey: rpc)
        return true
    }

    func close() {
        isClosed = true
        pending.removeAll()
        nativeToRPC.removeAll()
    }
}
