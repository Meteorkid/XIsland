import XCTest
import Darwin
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
}
