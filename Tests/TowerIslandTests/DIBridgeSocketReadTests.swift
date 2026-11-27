import Darwin
import XCTest
@testable import DIBridge

/// 桥接读取短连接帧的回归：客户端写完即关闭时，EOF 不能覆盖已到达的数据。
final class DIBridgeSocketReadTests: XCTestCase {
    func testWaitForPeerCloseSeesEofAfterShortConnection() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { Darwin.close(pair[0]) }
        Darwin.close(pair[1]); pair[1] = -1
        XCTAssertTrue(VSCodeObservationCommand.waitForPeerClose(pair[0],
            deadline: ProcessInfo.processInfo.systemUptime + 1))
    }

    func testReadFramedMessageReturnsFrameAfterPeerClose() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
        let payload = Data("{\"type\":\"statusUpdate\"}\n".utf8)
        XCTAssertEqual(payload.withUnsafeBytes { write(pair[1], $0.baseAddress, payload.count) }, payload.count)
        Darwin.close(pair[1]); pair[1] = -1
        let frame = DIBridge.readFramedMessage(pair[0], timeoutSeconds: 1)
        XCTAssertEqual(frame, payload)
    }
}
