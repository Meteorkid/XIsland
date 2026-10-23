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
    /// 整条消息的读取时限（秒），分片到达不能重新获得完整等待时间。
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
    ///
    /// `pid` 可能为 `nil`：非交互 hook 的桥接程序在写入后立即 `shutdown`/`close` 并退出，
    /// 此时 `LOCAL_PEERPID` 会以 `ENOTCONN` 失败（实测 errno 57），而对端 UID 仍可读出。
    /// 因此 PID 缺失只意味着拿不到可执行路径，**不构成认证失败**。
    struct PeerIdentity {
        let pid: pid_t?
        let effectiveUID: uid_t
        let executablePath: String?
    }

    enum PeerTrust {
        case trusted
        case untrusted(reason: String)
    }

    /// 读取对端进程的有效 UID 与（尽可能的）PID。
    ///
    /// 有效 UID 由内核在连接建立时快照，无法被对端伪造，是认证的基准。
    ///
    /// UID 必须用 `getpeereid(3)` 读取：macOS 的 `sys/un.h` 只定义了
    /// `LOCAL_PEERCRED` / `LOCAL_PEERPID` / `LOCAL_PEEREPID` / `LOCAL_PEERUUID` /
    /// `LOCAL_PEEREUUID` / `LOCAL_PEERTOKEN`，**没有** `LOCAL_PEEREUID`。
    /// 若把 `0x005`（实为 `LOCAL_PEEREUUID`）当 UID 读，取到的是 16 字节对端 UUID 的
    /// 前 4 字节，与真实 UID 永不相等，会导致所有连接被判为不可信而全部关闭。
    static func peerIdentity(of fd: Int32) -> PeerIdentity? {
        var effectiveUID: uid_t = 0
        var effectiveGID: gid_t = 0
        guard getpeereid(fd, &effectiveUID, &effectiveGID) == 0 else { return nil }

        // PID 仅在能取到时用于解析可执行路径；对端已退出时取不到属正常情况。
        var pid: pid_t = 0
        var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        let hasPID = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLength) == 0

        return PeerIdentity(
            pid: hasPID ? pid : nil,
            effectiveUID: effectiveUID,
            executablePath: hasPID ? processPath(of: pid) : nil
        )
    }

    /// 取指定进程的可执行文件路径。
    static func processPath(of pid: pid_t) -> String? {
        let capacity = Int(MAXPATHLEN) * 4
        var buffer = [CChar](repeating: 0, count: capacity)
        let length = proc_pidpath(pid, &buffer, UInt32(capacity))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// 隔离测试默认放宽进程路径检查；兼容性验收可显式启用完整生产策略。
    ///
    /// 强制认证只收紧检查，不改变测试的 socket、数据库和偏好隔离。
    static var isTestMode: Bool {
        guard ProcessInfo.processInfo.environment["X_ISLAND_TEST_ENFORCE_PEER_AUTH"] != "1" else {
            return false
        }
        return ProcessInfo.processInfo.arguments.contains("--ui-test-mode")
            || ProcessInfo.processInfo.environment["X_ISLAND_TEST_MODE"] == "1"
    }

    /// 判定对端是否可信。
    ///
    /// 判定顺序：有效 UID 一致 → 测试模式放行 → 可执行路径白名单 → 拒绝。
    ///
    /// 有效 UID 是唯一始终可用的判据，也是认证基准。可执行路径是**尽力而为**的加强项：
    /// 非交互 hook 的桥接程序写入后立即退出，服务端 `accept` 到时对端往往已消失，
    /// `LOCAL_PEERPID` 返回 `ENOTCONN`，此时拿不到路径。若把这种情况判为不可信，
    /// 会导致所有非交互 hook 全部无法送达，因此路径不可得时回退为「仅按 UID 判定」。
    ///
    /// 白名单内的 `di-bridge` 在路径可得时额外要求属主为当前用户且非组/其他可写，
    /// 因为该文件已被注入所有 agent 的全局 hook 配置，一旦被篡改即为常驻执行点。
    ///
    /// 效力边界：同 UID 下无法做真正的强认证 —— 攻击者可以直接运行合法客户端，
    /// 也可以抢先退出以跳过路径校验。这里的实际收益是拦截跨用户连接，
    /// 并在路径可得时拦截未走既定调用链的进程、检测 di-bridge 被篡改。
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
        // 对端已退出（短命 hook 客户端）：路径不可得，按 UID 放行。
        guard let path = identity.executablePath, !path.isEmpty else {
            return .trusted
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

    static func readMessage(from fd: Int32, timeout: TimeInterval = TimeInterval(receiveTimeoutSeconds)) -> Data? {
        guard timeout > 0, timeout.isFinite else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        let bufSize = 65536
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0, ProcessInfo.processInfo.systemUptime < deadline else { return nil }

            // 仅此读操作非阻塞，保留半关闭请求的写端供后续审批响应使用。
            let n = recv(fd, buf, bufSize, MSG_DONTWAIT)
            if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            if n > 0 {
                data.append(buf, count: n)
                if data.count > maxMessageBytes { return nil }
                if let newline = data.firstIndex(of: 0x0A) {
                    return Data(data.prefix(through: newline))
                }
            } else if n == 0 {
                // 兼容以 EOF 结束的旧客户端；超时与错误不能当作完整帧。
                return data.isEmpty ? nil : data
            } else {
                return nil
            }
        }
    }
}
