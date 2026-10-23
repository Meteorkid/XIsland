import XCTest
import Darwin
import DIShared
@testable import XIsland

@_silgen_name("fork")
private func systemFork() -> pid_t

final class SocketServerAcceptTests: XCTestCase {
    func testAcceptFailureBackoffIsNonZero() {
        XCTAssertEqual(SocketServer.acceptFailureBackoffMicroseconds, 50_000)
    }

    func testReadMessageKeepsLargePayloadUntilFrameNewline() throws {
        let fds = try makeSocketPair()
        defer {
            close(fds.0)
            close(fds.1)
        }

        var payload = Data(repeating: 120, count: 80_000)
        payload.append(0x0A)

        let sent = expectation(description: "payload sent")
        DispatchQueue.global().async {
            XCTAssertTrue(SocketServer.sendAll(fd: fds.0, data: payload))
            shutdown(fds.0, SHUT_WR)
            sent.fulfill()
        }

        XCTAssertEqual(SocketServer.readMessage(from: fds.1), payload)
        wait(for: [sent], timeout: 1)
    }

    func testSendAllReturnsFalseWhenPeerDisconnectsWithoutTerminatingProcess() {
        let childPID = systemFork()
        guard childPID >= 0 else {
            XCTFail("无法创建 SIGPIPE 回归测试子进程")
            return
        }

        if childPID == 0 {
            var fds = [Int32](repeating: -1, count: 2)
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { _exit(2) }
            close(fds[1])
            let sent = SocketServer.sendAll(fd: fds[0], data: Data([0x01]))
            close(fds[0])
            _exit(sent ? 3 : 0)
        }

        var childStatus: Int32 = 0
        XCTAssertEqual(waitpid(childPID, &childStatus, 0), childPID)
        XCTAssertEqual(childStatus, 0, "写入已断开的审批连接不应以 SIGPIPE 终止进程")
    }

    private func makeSocketPair() throws -> (Int32, Int32) {
        var fds = [Int32](repeating: -1, count: 2)
        let result = fds.withUnsafeMutableBufferPointer { buffer in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress!)
        }
        XCTAssertEqual(result, 0)
        return (fds[0], fds[1])
    }

    // MARK: - 对端身份读取回归

    /// 回归：UID 必须来自 `getpeereid(3)`，不能把 `0x005` 当 UID 读。
    ///
    /// macOS 的 `sys/un.h` 中 `0x005` 是 `LOCAL_PEEREUUID`（16 字节对端 UUID），
    /// 不存在 `LOCAL_PEEREUID`。误用它取到的是 UUID 前 4 字节，与真实 UID 永不相等，
    /// 会让所有连接被判为不可信而全部关闭 —— 应用表现为完全收不到任何 agent 消息。
    func testPeerIdentityReadsRealUIDNotPeerUUIDPrefix() throws {
        let fds = try makeSocketPair()
        defer {
            close(fds.0)
            close(fds.1)
        }

        let identity = try XCTUnwrap(SocketServer.peerIdentity(of: fds.1))
        XCTAssertEqual(identity.effectiveUID, getuid(),
                       "对端 UID 必须等于本进程真实 UID，否则所有连接都会被拒绝")
        XCTAssertEqual(identity.pid, getpid(),
                       "socketpair 对端即本进程，PID 应一致")
    }

    /// 回归：对端已退出（路径不可得）时，仍必须按 UID 放行。
    ///
    /// 非交互 hook 的桥接程序写入后立即 `shutdown`/`close` 并退出，服务端 `accept` 到时
    /// 对端往往已消失，`LOCAL_PEERPID` 返回 `ENOTCONN`（实测 errno 57），拿不到可执行路径。
    /// 若把「路径不可得」判为不可信，所有非交互 hook 都会无法送达 ——
    /// 应用表现为顶部面板完全不响应任何 agent 事件。
    func testExitedPeerWithoutPathIsStillTrusted() throws {
        let fds = try makeSocketPair()
        defer {
            close(fds.0)
            close(fds.1)
        }

        // 模拟对端已退出：UID 正确但 PID/路径均不可得。
        let exitedPeer = SocketServer.PeerIdentity(
            pid: nil,
            effectiveUID: getuid(),
            executablePath: nil
        )
        let trust = SocketServer.evaluatePeer(
            exitedPeer,
            ownUID: getuid(),
            bridgePath: DISocketConfig.socketDir + "/bin/di-bridge",
            isTestMode: false
        )
        guard case .trusted = trust else {
            XCTFail("对端已退出、路径不可得时不应拒绝，实际：\(trust)")
            return
        }
    }

    /// 对照：路径可得且不在白名单内时，仍必须拒绝。
    ///
    /// 保证上一条的放宽没有把路径校验整体废掉。
    func testResolvableUnapprovedPathIsStillUntrusted() throws {
        let fds = try makeSocketPair()
        defer {
            close(fds.0)
            close(fds.1)
        }

        let stranger = SocketServer.PeerIdentity(
            pid: getpid(),
            effectiveUID: getuid(),
            executablePath: "/usr/bin/curl"
        )
        let trust = SocketServer.evaluatePeer(
            stranger,
            ownUID: getuid(),
            bridgePath: DISocketConfig.socketDir + "/bin/di-bridge",
            isTestMode: false
        )
        guard case .untrusted = trust else {
            XCTFail("非白名单可执行路径应被拒绝，实际：\(trust)")
            return
        }
    }

    /// 回归：UID 不一致必须被拒绝。
    ///
    /// 与上一条互为对照 —— 上一条保证真实 UID 被正确读出，这一条保证读出的
    /// UID 真的参与了判定。两者同时成立，跨用户连接才会被拦住。
    func testMismatchedUIDIsUntrusted() throws {
        let fds = try makeSocketPair()
        defer {
            close(fds.0)
            close(fds.1)
        }

        let identity = try XCTUnwrap(SocketServer.peerIdentity(of: fds.1))
        let foreignUID = identity.effectiveUID &+ 1
        let trust = SocketServer.evaluatePeer(
            identity,
            ownUID: foreignUID,
            bridgePath: DISocketConfig.socketDir + "/bin/di-bridge",
            isTestMode: false
        )
        guard case .untrusted(let reason) = trust else {
            XCTFail("UID 不一致时不应判为可信，实际：\(trust)")
            return
        }
        XCTAssertTrue(reason.contains("UID"), "拒绝原因应指明 UID 不一致，实际：\(reason)")
    }
}
