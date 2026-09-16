import Darwin
import Foundation
import os
import DIShared

final class SocketServer: @unchecked Sendable {
    /// Pause after a failed `accept(2)` while still running (avoid tight spin).
    static let acceptFailureBackoffMicroseconds: UInt32 = 50_000
    static let maxMessageBytes = 16 * 1024 * 1024

    private let logger = Logger(subsystem: "dev.xisland", category: "socket")
    private let sessionManager: SessionManager
    private let queue = DispatchQueue(label: "dev.towerisland.socket", qos: .userInitiated)

    /// Shared mutable state protected by `stateLock`.
    private let stateLock = OSAllocatedUnfairLock(initialState: ServerState())

    private struct ServerState {
        var serverFD: Int32 = -1
        var isRunning = false
    }

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    func start() {
        let dir = DISocketConfig.socketDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Restrict directory to owner-only access
        chmod(dir, 0o700)
        unlink(DISocketConfig.socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = DISocketConfig.socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            pathBytes.withUnsafeBufferPointer { src in
                let raw = UnsafeMutableRawPointer(sunPath)
                raw.copyMemory(from: src.baseAddress!, byteCount: min(src.count, 104))
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            close(fd)
            return
        }

        // Restrict socket to owner-only access
        fchmod(fd, 0o600)

        guard listen(fd, 16) == 0 else {
            close(fd)
            return
        }

        stateLock.withLock { state in
            state.serverFD = fd
            state.isRunning = true
        }

        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        let fd = stateLock.withLock { state -> Int32 in
            state.isRunning = false
            let fd = state.serverFD
            state.serverFD = -1
            return fd
        }
        if fd >= 0 {
            close(fd)
        }
        unlink(DISocketConfig.socketPath)
    }

    private func acceptLoop() {
        while true {
            let (running, fd) = stateLock.withLock { state in
                (state.isRunning, state.serverFD)
            }
            guard running else { break }

            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else {
                if running {
                    usleep(Self.acceptFailureBackoffMicroseconds)
                }
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        guard let data = Self.readMessage(from: fd), !data.isEmpty else {
            logger.debug("No data from client")
            close(fd)
            return
        }

        logger.debug("Received \(data.count) bytes")

        guard let message = try? DIProtocol.decode(data) else {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "?"
            logger.error("Failed to decode: \(preview)")
            close(fd)
            return
        }

        let statusPreview = String((message.status ?? "nil").prefix(100))
        logger.debug("Message: type=\(message.type.rawValue) session=\(message.sessionId) agent=\(message.agentType ?? "nil") tool=\(message.tool ?? "nil") desc=\(message.permDescription ?? "nil") question=\(message.questionText ?? "nil") options=\(message.options?.joined(separator: ",") ?? "nil") status=\(statusPreview)")

        switch message.type {
        case .permissionRequest, .question, .planReview:
            let channel = SocketResponseChannel(fd: fd)
            let delivery: InteractionDelivery = { decision in
                await channel.send(decision, sessionID: message.sessionId)
            }
            Task { @MainActor in
                switch message.type {
                case .permissionRequest:
                    self.sessionManager.handlePermissionRequest(
                        message, delivery: delivery, cancel: { channel.cancel() },
                        respond: { approved in Task { _ = await delivery(.permission(approved)) } })
                case .question:
                    self.sessionManager.handleQuestionRequest(
                        message, delivery: delivery,
                        respond: { answer in Task { _ = await delivery(.question(answer)) } },
                        cancel: { channel.cancel() })
                case .planReview:
                    self.sessionManager.handlePlanReview(
                        message, delivery: delivery, cancel: { channel.cancel() },
                        respond: { approved, feedback in Task { _ = await delivery(.plan(approved, feedback)) } })
                default: break
                }
            }
        default:
            Task { @MainActor in self.sessionManager.handleMessage(message) }
            close(fd)
        }
    }

    /// 整个响应共用一个截止时间，避免部分写入把单次超时无限延长。
    static func sendAll(fd: Int32, data: Data, timeout: TimeInterval = 3) -> Bool {
        guard timeout > 0, timeout.isFinite else { return false }
        var noSigPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else { return false }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        return data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            var sent = 0
            while sent < buffer.count {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return false }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0 else { return false }
                let count = send(fd, base.advanced(by: sent), buffer.count - sent, 0)
                if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    static func readMessage(from fd: Int32) -> Data? {
        var data = Data()
        let bufSize = 65536
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while true {
            let n = recv(fd, buf, bufSize, 0)
            if n > 0 {
                data.append(buf, count: n)
                if data.count > maxMessageBytes { return nil }
                if let newline = data.firstIndex(of: 0x0A) {
                    return Data(data.prefix(through: newline))
                }
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }
}
