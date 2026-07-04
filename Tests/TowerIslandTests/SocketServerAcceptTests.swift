import XCTest
import Darwin
@testable import XIsland

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

        XCTAssertTrue(SocketServer.sendAll(fd: fds.0, data: payload))
        shutdown(fds.0, SHUT_WR)

        XCTAssertEqual(SocketServer.readMessage(from: fds.1), payload)
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
