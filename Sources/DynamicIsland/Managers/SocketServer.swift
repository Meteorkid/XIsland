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
        case .permissionRequest:
            Task { @MainActor in
                self.sessionManager.handlePermissionRequest(message) { [weak self] approved in
                    self?.sendResponse(fd: fd, approved: approved, sessionId: message.sessionId)
                }
                logger.debug("Sessions count: \(self.sessionManager.sessions.count)")
            }

        case .question:
            Task { @MainActor in
                self.sessionManager.handleQuestionRequest(
                    message,
                    respond: { [weak self] answer in
                        self?.sendQuestionResponse(fd: fd, answer: answer, sessionId: message.sessionId)
                    },
                    cancel: { close(fd) }
                )
                logger.debug("Sessions count: \(self.sessionManager.sessions.count)")
            }

        case .planReview:
            Task { @MainActor in
                self.sessionManager.handlePlanReview(message) { [weak self] approved, feedback in
                    self?.sendPlanResponse(fd: fd, approved: approved, feedback: feedback, sessionId: message.sessionId)
                }
                logger.debug("Sessions count: \(self.sessionManager.sessions.count)")
            }

        default:
            Task { @MainActor in
                self.sessionManager.handleMessage(message)
                logger.debug("Sessions count: \(self.sessionManager.sessions.count)")
            }
            close(fd)
        }
    }

    private func sendResponse(fd: Int32, approved: Bool, sessionId: String) {
        var msg = DIMessage(type: .permissionResponse, sessionId: sessionId)
        msg.approved = approved
        writeAndClose(fd: fd, message: msg)
    }

    private func sendQuestionResponse(fd: Int32, answer: String, sessionId: String) {
        var msg = DIMessage(type: .questionResponse, sessionId: sessionId)
        msg.answer = answer
        writeAndClose(fd: fd, message: msg)
    }

    private func sendPlanResponse(fd: Int32, approved: Bool, feedback: String?, sessionId: String) {
        var msg = DIMessage(type: .planResponse, sessionId: sessionId)
        msg.planApproved = approved
        msg.feedback = feedback
        writeAndClose(fd: fd, message: msg)
    }

    private func writeAndClose(fd: Int32, message: DIMessage) {
        guard let data = try? DIProtocol.encode(message) else {
            close(fd)
            return
        }
        _ = Self.sendAll(fd: fd, data: data)
        close(fd)
    }

    static func sendAll(fd: Int32, data: Data) -> Bool {
        var noSigPipe: Int32 = 1
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            return false
        }

        return data.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return true }
            var sent = 0
            while sent < ptr.count {
                let n = send(fd, base.advanced(by: sent), ptr.count - sent, 0)
                guard n > 0 else { return false }
                sent += n
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
