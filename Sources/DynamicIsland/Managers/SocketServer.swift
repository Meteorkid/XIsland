import Darwin
import Foundation
import os
import DIShared

final class SocketServer: @unchecked Sendable {
    /// Pause after a failed `accept(2)` while still running (avoid tight spin).
    static let acceptFailureBackoffMicroseconds: UInt32 = 50_000
    static let maxMessageBytes = 16 * 1024 * 1024
    /// 同时处理的连接上限；超出后立即关闭新连接，避免文件描述符与 GCD 线程被耗尽。
    static let maxConcurrentConnections = 32
    /// 单条消息的读取超时（秒）。防止只连接不发送数据的对端永久占用线程。
    static let receiveTimeoutSeconds: Int = 10
    /// 交互式请求（权限 / 问答 / 计划评审）等待用户决策的最长时间（秒）。
    /// 超时后关闭连接释放 fd，避免无人处理的请求无限期占用资源。
    static let interactionIdleTimeoutSeconds: Double = 600
    /// SSH 反向隧道的对端可执行路径。
    ///
    /// `SSHRemoteManager` 用 `ssh -R remote:local` 把远端 di-bridge 的连接转发到本 socket，
    /// 因此本地看到的对端进程是 ssh 自身，而不是 di-bridge。
    static let sshPeerPath = "/usr/bin/ssh"

    /// 系统 shell 解释器。
    ///
    /// 除 `PermissionRequest` 外的 hook 命令都带有 `|| true`（见 `ZeroConfigManager` 的
    /// `guardedCommand`），属于复合命令，shell 不会做 exec 优化，因此对端进程是 shell 自身。
    /// 放行它们会削弱认证强度，但这是保持集成可用的必要条件 ——
    /// 代价是同 UID 下任何进程都可以通过 `/bin/sh -c` 通过路径校验。
    static let systemShellPaths: Set<String> = [
        "/bin/sh",
        "/bin/bash",
        "/bin/zsh",
        "/usr/bin/env"
    ]

    /// `LOCAL_PEEREUID`（sys/socket.h）在 Swift 的 Darwin 模块中未导出，按内核取值显式定义。
    /// 与 `LOCAL_PEERPID` 一样由内核在 accept 时快照，对端无法伪造。
    private static let localPeerEffectiveUID: Int32 = 0x005

    private let logger = Logger(subsystem: "dev.xisland", category: "socket")
    private let sessionManager: SessionManager
    private let queue = DispatchQueue(label: "dev.towerisland.socket", qos: .userInitiated)

    /// Shared mutable state protected by `stateLock`.
    private let stateLock = OSAllocatedUnfairLock(initialState: ServerState())

    private struct ServerState {
        var serverFD: Int32 = -1
        var isRunning = false
        var activeConnections = 0
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

            let admitted = stateLock.withLock { state -> Bool in
                guard state.activeConnections < Self.maxConcurrentConnections else { return false }
                state.activeConnections += 1
                return true
            }
            guard admitted else {
                logger.error("Connection limit \(Self.maxConcurrentConnections, privacy: .public) reached; rejecting client")
                close(clientFD)
                continue
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private func releaseConnection() {
        stateLock.withLock { state in
            state.activeConnections = max(0, state.activeConnections - 1)
        }
    }

    // MARK: - 对端认证

    /// 连接对端的进程身份。
    struct PeerIdentity {
        let pid: pid_t
        let effectiveUID: uid_t
        let executablePath: String?
    }

    enum PeerTrust {
        case trusted
        case untrusted(reason: String)
    }

    /// 读取对端进程的 PID 与有效 UID。
    ///
    /// 这两个值由内核在 `accept` 时快照，无法被对端伪造。
    static func peerIdentity(of fd: Int32) -> PeerIdentity? {
        var pid: pid_t = 0
        var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLength) == 0 else { return nil }

        var effectiveUID: uid_t = 0
        var uidLength = socklen_t(MemoryLayout<uid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, localPeerEffectiveUID, &effectiveUID, &uidLength) == 0 else { return nil }

        return PeerIdentity(pid: pid, effectiveUID: effectiveUID, executablePath: processPath(of: pid))
    }

    /// 取指定进程的可执行文件路径。
    static func processPath(of pid: pid_t) -> String? {
        let capacity = Int(MAXPATHLEN) * 4
        var buffer = [CChar](repeating: 0, count: capacity)
        let length = proc_pidpath(pid, &buffer, UInt32(capacity))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// 判断是否处于隔离的测试运行模式。
    ///
    /// 测试模式下 socket 位于临时目录、进程由测试脚本直接启动，此时不做生产级身份校验。
    static var isTestMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-mode")
            || ProcessInfo.processInfo.environment["X_ISLAND_TEST_MODE"] == "1"
    }

    /// 判定对端是否可信。
    ///
    /// 判定顺序：有效 UID 一致 → 测试模式放行 → 白名单路径 → 拒绝。
    /// 白名单内的 `di-bridge` 额外要求属主为当前用户且非组/其他可写，
    /// 因为该文件已被注入所有 agent 的全局 hook 配置，一旦被篡改即为常驻执行点。
    ///
    /// 效力边界：同 UID 下无法做真正的强认证 —— 攻击者可以直接运行合法客户端。
    /// 这里的实际收益是拦截跨用户连接、拦截未走既定调用链的进程，以及检测 di-bridge 被篡改。
    static func evaluatePeer(
        _ identity: PeerIdentity?,
        ownUID: uid_t,
        bridgePath: String,
        isTestMode: Bool,
        fileAttributes: (String) -> [FileAttributeKey: Any]? = { try? FileManager.default.attributesOfItem(atPath: $0) }
    ) -> PeerTrust {
        guard let identity else {
            return .untrusted(reason: "unable to read peer credentials")
        }
        guard identity.effectiveUID == ownUID else {
            return .untrusted(reason: "peer effective UID \(identity.effectiveUID) differs from \(ownUID)")
        }
        if isTestMode {
            return .trusted
        }
        guard let path = identity.executablePath, !path.isEmpty else {
            return .untrusted(reason: "peer pid \(identity.pid) has no resolvable executable path")
        }
        if path == sshPeerPath {
            return .trusted
        }
        if systemShellPaths.contains(path) {
            return .trusted
        }
        if path == bridgePath {
            guard let attributes = fileAttributes(path),
                  let owner = attributes[.ownerAccountID] as? NSNumber,
                  owner.uint32Value == ownUID,
                  let mode = attributes[.posixPermissions] as? NSNumber else {
                return .untrusted(reason: "di-bridge at \(path) has unverifiable ownership")
            }
            guard mode.uint16Value & 0o022 == 0 else {
                return .untrusted(reason: "di-bridge at \(path) is group- or world-writable")
            }
            return .trusted
        }
        return .untrusted(reason: "peer executable \(path) is not an approved client")
    }

    // MARK: - 连接处理

    private func handleClient(_ fd: Int32) {
        let ownUID = geteuid()
        let bridgePath = DISocketConfig.socketDir + "/bin/di-bridge"
        switch Self.evaluatePeer(
            Self.peerIdentity(of: fd),
            ownUID: ownUID,
            bridgePath: bridgePath,
            isTestMode: Self.isTestMode
        ) {
        case .trusted:
            break
        case .untrusted(let reason):
            logger.error("Rejected connection: \(reason, privacy: .public)")
            close(fd)
            releaseConnection()
            return
        }

        var receiveTimeout = timeval(tv_sec: Self.receiveTimeoutSeconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout,
                       socklen_t(MemoryLayout<timeval>.size))

        guard let data = Self.readMessage(from: fd), !data.isEmpty else {
            logger.debug("No data from client")
            close(fd)
            releaseConnection()
            return
        }

        logger.debug("Received \(data.count) bytes")

        guard let message = try? DIProtocol.decode(data) else {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "?"
            logger.error("Failed to decode: \(preview)")
            close(fd)
            releaseConnection()
            return
        }

        let statusPreview = String((message.status ?? "nil").prefix(100))
        logger.debug("Message: type=\(message.type.rawValue) session=\(message.sessionId) agent=\(message.agentType ?? "nil") tool=\(message.tool ?? "nil") desc=\(message.permDescription ?? "nil") question=\(message.questionText ?? "nil") options=\(message.options?.joined(separator: ",") ?? "nil") status=\(statusPreview)")

        switch message.type {
        case .permissionRequest, .question, .planReview:
            // 交互式连接的 fd 由 channel 持有，连接计数在其关闭时释放。
            let channel = SocketResponseChannel(
                fd: fd,
                idleTimeout: Self.interactionIdleTimeoutSeconds,
                onRelease: { [weak self] in self?.releaseConnection() }
            )
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
            releaseConnection()
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
