import Darwin
import Foundation
import os
import DIShared

/// 一个响应连接只发送/关闭一次，取消和写入在同一队列上执行，避免复用fd后误关闭其他连接。
///
/// 交互式连接会一直持有 fd 直到用户做出决策。若请求被静默丢弃或用户长期不响应，
/// fd 将无限期占用，因此这里加了 idle 超时：超时后自动取消并关闭连接。
final class SocketResponseChannel: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.xisland.response", qos: .userInitiated)
    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var fd: Int32 = -1
        var isClosed = false
        var idleWorkItem: DispatchWorkItem?
    }

    /// fd 释放后回调，用于服务端归还并发连接配额。
    private let onRelease: (() -> Void)?
    private let idleTimeout: TimeInterval

    init(fd: Int32, idleTimeout: TimeInterval = 600, onRelease: (() -> Void)? = nil) {
        self.onRelease = onRelease
        self.idleTimeout = idleTimeout
        self.lock.withLock { $0.fd = fd }
        scheduleIdleTimeout()
    }

    /// 空闲超过阈值则取消连接，避免请求无人处理时长期占用 fd。
    private func scheduleIdleTimeout() {
        guard idleTimeout > 0, idleTimeout.isFinite else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.cancel()
        }
        lock.withLock { $0.idleWorkItem = workItem }
        queue.asyncAfter(deadline: .now() + idleTimeout, execute: workItem)
    }

    func send(_ decision: InteractionDecision, sessionID: String) async -> Bool {
        var response: DIMessage
        switch decision {
        case .permission(let approved):
            response = DIMessage(type: .permissionResponse, sessionId: sessionID)
            response.approved = approved
        case .question(let answer):
            response = DIMessage(type: .questionResponse, sessionId: sessionID)
            response.answer = answer
        case .questionSelections(let answers):
            response = DIMessage(type: .questionResponse, sessionId: sessionID)
            response.selectedAnswers = answers
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
                let fd = lock.withLock { $0.fd }
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
        let fd: Int32 = lock.withLock { state in
            guard !state.isClosed else { return -1 }
            state.isClosed = true
            state.idleWorkItem?.cancel()
            state.idleWorkItem = nil
            let fd = state.fd
            state.fd = -1
            return fd
        }
        guard fd >= 0 else { return }
        close(fd)
        onRelease?()
    }

    deinit {
        closeConnection()
    }
}
