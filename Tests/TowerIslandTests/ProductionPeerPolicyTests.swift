import XCTest
import Darwin
import DIShared
@testable import XIsland

final class ProductionPeerPolicyTests: XCTestCase {
    func testExitedCompiledBridgeIsAcceptedWithKernelUIDAfterAccept() throws {
        let fixture = try PeerFixture()
        defer { withExtendedLifetime(fixture) {} }
        let bridge = try installBuiltBridge(in: fixture)
        let client = try startBridge(bridge, fixture: fixture, hook: "Notification", input: "{}")

        // 必须先退出并回收，再 accept，不能用手工构造的缺失路径身份替代。
        try client.waitForExit()
        XCTAssertEqual(client.process.terminationReason, .exit)
        XCTAssertEqual(client.process.terminationStatus, 0)
        let connection = try fixture.acceptPeer()
        defer { close(connection) }
        let identity = try XCTUnwrap(SocketServer.peerIdentity(of: connection))
        XCTAssertEqual(identity.effectiveUID, geteuid())
        XCTAssertNil(identity.executablePath)
        assertTrusted(identity, bridgePath: bridge.path)
        let message = try DIProtocol.decode(XCTUnwrap(SocketServer.readMessage(from: connection, timeout: 1)))
        XCTAssertEqual(message.sessionId, "production-peer-policy")
    }

    func testLivingCompiledBridgeEnforcesStablePathUIDAndFilePermissions() throws {
        let fixture = try PeerFixture()
        defer { withExtendedLifetime(fixture) {} }
        let bridge = try installBuiltBridge(in: fixture)
        let input = #"{"tool_name":"Bash","tool_input":{"command":"true"}}"#
        let client = try startBridge(bridge, fixture: fixture, hook: "PermissionRequest", input: input)
        let connection = try fixture.acceptPeer()
        defer { close(connection) }
        let request = try DIProtocol.decode(XCTUnwrap(SocketServer.readMessage(from: connection, timeout: 1)))
        XCTAssertEqual(request.type, .permissionRequest)
        XCTAssertTrue(client.process.isRunning, "交互桥接应保活等待测试服务端的响应")

        let identity = try XCTUnwrap(SocketServer.peerIdentity(of: connection))
        XCTAssertEqual(identity.pid, client.process.processIdentifier)
        XCTAssertEqual(identity.effectiveUID, geteuid())
        XCTAssertEqual(identity.executablePath, bridge.path)
        assertTrusted(identity, bridgePath: bridge.path)
        assertUntrusted(identity, ownUID: geteuid() &+ 1, bridgePath: bridge.path, reason: "UID")

        // 只改本次测试复制的二进制，实际文件属性也必须参与生产策略。
        for mode in [0o720, 0o702] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: bridge.path)
            assertUntrusted(identity, bridgePath: bridge.path, reason: "writable")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
        assertTrusted(identity, bridgePath: bridge.path)

        var response = DIMessage(type: .permissionResponse, sessionId: request.sessionId)
        response.approved = false
        XCTAssertTrue(SocketServer.sendAll(fd: connection, data: try DIProtocol.encode(response)))
        try client.waitForExit()
        XCTAssertEqual(client.process.terminationStatus, 0)
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: client.standardOutput()) as? [String: Any])
        let hookOutput = try XCTUnwrap(output["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookOutput["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "deny")
    }

    func testLivingUnapprovedRuntimeIsRejectedUsingRealPeerIdentity() throws {
        let fixture = try PeerFixture()
        defer { withExtendedLifetime(fixture) {} }
        let runtime = try unapprovedRuntime(socketPath: fixture.socketPath)
        let client = try PeerProcess(executable: runtime.executable, arguments: runtime.arguments)
        let connection = try fixture.acceptPeer()
        defer { close(connection) }
        XCTAssertEqual(SocketServer.readMessage(from: connection, timeout: 1), Data("unapproved\n".utf8))
        XCTAssertTrue(client.process.isRunning)

        let identity = try XCTUnwrap(SocketServer.peerIdentity(of: connection))
        XCTAssertEqual(identity.pid, client.process.processIdentifier)
        XCTAssertEqual(identity.effectiveUID, geteuid())
        let executablePath = try XCTUnwrap(identity.executablePath)
        XCTAssertFalse(executablePath.isEmpty)
        XCTAssertNotEqual(executablePath, "/usr/bin/ssh")
        XCTAssertFalse(SocketServer.systemShellPaths.contains(executablePath))
        assertUntrusted(identity, bridgePath: fixture.bridgePath.path, reason: "not an approved client")
        shutdown(connection, SHUT_RDWR)
        try client.waitForExit()
    }

    /// 仅验证真实 ssh 进程的白名单策略；本地 mux 探针不代表反向隧道验收。
    func testSystemSSHLocalMuxPeerIsAcceptedByProductionPolicy() throws {
        let fixture = try PeerFixture()
        defer { withExtendedLifetime(fixture) {} }
        let client = try PeerProcess(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: [
            "-F", "/dev/null", "-o", "ControlPath=\(fixture.socketPath)",
            "-o", "ControlMaster=no", "-o", "ProxyCommand=/usr/bin/false",
            "-o", "BatchMode=yes", "-O", "check", "peer-policy.invalid"
        ])
        let connection = try fixture.acceptPeer()
        defer { close(connection) }
        XCTAssertTrue(client.process.isRunning)
        let identity = try XCTUnwrap(SocketServer.peerIdentity(of: connection))
        XCTAssertEqual(identity.pid, client.process.processIdentifier)
        XCTAssertEqual(identity.effectiveUID, geteuid())
        XCTAssertEqual(identity.executablePath, "/usr/bin/ssh")
        assertTrusted(identity, bridgePath: fixture.bridgePath.path)

        // 不实现 mux 握手；关闭本地测试连接即可结束 ssh，不触发远端连接。
        shutdown(connection, SHUT_RDWR)
        try client.waitForExit()
        XCTAssertEqual(client.process.terminationReason, .exit)
        XCTAssertNotEqual(client.process.terminationStatus, 0)
    }

    private func assertTrusted(_ identity: SocketServer.PeerIdentity, bridgePath: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let result = SocketServer.evaluatePeer(identity, ownUID: geteuid(), bridgePath: bridgePath, isTestMode: false)
        guard case .trusted = result else {
            XCTFail("生产策略应允许真实对端，实际：\(result)", file: file, line: line)
            return
        }
    }

    private func assertUntrusted(_ identity: SocketServer.PeerIdentity, ownUID: uid_t = geteuid(),
                                 bridgePath: String, reason: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let result = SocketServer.evaluatePeer(identity, ownUID: ownUID, bridgePath: bridgePath, isTestMode: false)
        guard case .untrusted(let actualReason) = result else {
            XCTFail("生产策略应拒绝真实对端，实际：\(result)", file: file, line: line)
            return
        }
        XCTAssertTrue(actualReason.contains(reason), actualReason, file: file, line: line)
    }

    private func installBuiltBridge(in fixture: PeerFixture) throws -> URL {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var directory = Bundle(for: Self.self).bundleURL
        var candidates: [URL] = []
        for _ in 0..<5 {
            directory.deleteLastPathComponent()
            candidates.append(directory.appendingPathComponent("DIBridge"))
        }
        candidates += [".build/debug/DIBridge", ".build/arm64-apple-macosx/debug/DIBridge",
                       ".build/x86_64-apple-macosx/debug/DIBridge"].map { repository.appendingPathComponent($0) }
        let source = try XCTUnwrap(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) },
                                  "测试依赖应先构建真实 DIBridge 可执行目标")
        try FileManager.default.createDirectory(at: fixture.bridgePath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: source, to: fixture.bridgePath)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.bridgePath.path)
        return fixture.bridgePath
    }

    private func startBridge(_ executable: URL, fixture: PeerFixture, hook: String, input: String) throws -> PeerProcess {
        try PeerProcess(executable: executable,
                        arguments: ["--agent", "claude_code", "--hook", hook,
                                    "--session", "production-peer-policy"],
                        environment: ["DI_SOCKET_PATH": fixture.socketPath], input: Data(input.utf8))
    }

    private func unapprovedRuntime(socketPath: String) throws -> (executable: URL, arguments: [String]) {
        let nodePaths = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        if let node = nodePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let script = #"""
            const socket = require('node:net').createConnection(process.argv[1]);
            const deadline = setTimeout(() => process.exit(2), 10000);
            socket.on('connect', () => socket.write('unapproved\n'));
            socket.on('error', () => process.exit(1));
            socket.on('end', () => { clearTimeout(deadline); socket.end(); });
            """#
            return (URL(fileURLWithPath: node), ["-e", script, socketPath])
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") {
            let script = """
            import socket, sys
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(10)
                client.connect(sys.argv[1])
                client.sendall(b'unapproved\\n')
                client.recv(1)
            """
            return (URL(fileURLWithPath: "/usr/bin/python3"), ["-c", script, socketPath])
        }
        throw XCTSkip("未找到 Node 或系统 Python，无法启动非白名单真实对端；不为测试安装依赖。")
    }
}

private final class PeerFixture {
    let directory: URL
    let socketPath: String
    var bridgePath: URL { directory.appendingPathComponent("runtime/bin/di-bridge") }
    private let listener: Int32

    init() throws {
        // macOS 的默认临时目录可能超过 sockaddr_un 的 104 字节路径上限。
        directory = URL(fileURLWithPath: "/private/tmp/xip-\(UUID().uuidString)")
        socketPath = directory.appendingPathComponent("peer.sock").path
        guard socketPath.utf8.count < 104 else { throw PeerTestError.failure("测试 socket 路径过长") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        do {
            guard listener >= 0 else { throw PeerTestError.failure("socket 失败：\(errno)") }
            guard fcntl(listener, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else {
                throw PeerTestError.failure("设置 listener 标志失败：\(errno)")
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            socketPath.withCString { path in
                withUnsafeMutablePointer(to: &address.sun_path) {
                    UnsafeMutableRawPointer($0).copyMemory(from: path, byteCount: socketPath.utf8.count + 1)
                }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(listener, 1) == 0 else {
                throw PeerTestError.failure("绑定或监听测试 socket 失败：\(errno)")
            }
        } catch {
            if listener >= 0 { close(listener) }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func acceptPeer(timeout: TimeInterval = 10) throws -> Int32 {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            let result = poll(&descriptor, 1, Int32(max(1, remaining * 1000)))
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw PeerTestError.failure("等待测试对端超时或失败：\(errno)") }
            let connection = accept(listener, nil, nil)
            if connection < 0, errno == EINTR || errno == EAGAIN { continue }
            guard connection >= 0 else { throw PeerTestError.failure("accept 失败：\(errno)") }
            guard fcntl(connection, F_SETFD, FD_CLOEXEC) == 0 else {
                close(connection)
                throw PeerTestError.failure("设置连接标志失败：\(errno)")
            }
            return connection
        }
        throw PeerTestError.failure("测试对端未在截止时间内连接")
    }

    deinit {
        close(listener)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class PeerProcess {
    let process = Process()
    private let completed = DispatchGroup()
    private let output = Pipe()
    private let errors = Pipe()

    init(executable: URL, arguments: [String], environment: [String: String] = [:], input: Data? = nil) throws {
        process.executableURL = executable
        process.arguments = arguments
        // 不继承 Node 注入参数、SSH agent、调试日志或生产 socket 环境。
        process.environment = environment.merging(["PATH": "/usr/bin:/bin"]) { current, _ in current }
        process.standardOutput = output
        process.standardError = errors
        let stdin = input.map { _ in Pipe() }
        if let stdin {
            process.standardInput = stdin
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        completed.enter()
        let completion = completed
        process.terminationHandler = { _ in completion.leave() }
        do {
            try process.run()
        } catch {
            completed.leave()
            throw error
        }
        if let stdin, let input {
            defer {
                stdin.fileHandleForReading.closeFile()
                stdin.fileHandleForWriting.closeFile()
            }
            try stdin.fileHandleForWriting.write(contentsOf: input)
        }
    }

    func waitForExit(timeout: TimeInterval = 10) throws {
        guard completed.wait(timeout: .now() + timeout) == .success else {
            throw PeerTestError.failure("测试子进程 \(process.processIdentifier) 未按时退出")
        }
    }

    func standardOutput() -> Data {
        output.fileHandleForReading.readDataToEndOfFile()
    }

    deinit {
        if process.isRunning {
            process.terminate()
            if completed.wait(timeout: .now() + 0.5) != .success, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 1)
            }
        }
        output.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        errors.fileHandleForReading.closeFile()
        errors.fileHandleForWriting.closeFile()
    }
}

private enum PeerTestError: Error {
    case failure(String)
}
