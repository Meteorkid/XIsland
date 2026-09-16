import Darwin
import Foundation
import DIShared

/// 一个响应连接只发送/关闭一次，取消和写入在同一队列上执行，避免复用fd后误关闭其他连接。
final class SocketResponseChannel: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.xisland.response", qos: .userInitiated)
    private var fd: Int32

    init(fd: Int32) { self.fd = fd }

    func send(_ decision: InteractionDecision, sessionID: String) async -> Bool {
        var response: DIMessage
        switch decision {
        case .permission(let approved):
            response = DIMessage(type: .permissionResponse, sessionId: sessionID)
            response.approved = approved
        case .question(let answer):
            response = DIMessage(type: .questionResponse, sessionId: sessionID)
            response.answer = answer
        case .plan(let approved, let feedback):
            response = DIMessage(type: .planResponse, sessionId: sessionID)
            response.planApproved = approved
            response.feedback = feedback
        }
        guard let data = try? DIProtocol.encode(response) else {
            cancel()
            return false
        }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard fd >= 0 else { continuation.resume(returning: false); return }
                let success = SocketServer.sendAll(fd: fd, data: data)
                closeConnection()
                continuation.resume(returning: success)
            }
        }
    }

    func cancel() {
        queue.async { [self] in closeConnection() }
    }

    private func closeConnection() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    deinit { if fd >= 0 { close(fd) } }
}
