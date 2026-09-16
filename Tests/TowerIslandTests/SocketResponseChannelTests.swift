import Darwin
import XCTest
import DIShared
@testable import XIsland

final class SocketResponseChannelTests: XCTestCase {
    private func pair() throws -> [Int32] {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return descriptors
    }

    func testPlanResponseIncludesFeedbackAndCanOnlyBeSentOnce() async throws {
        let fds = try pair()
        defer { close(fds[1]) }
        let channel = SocketResponseChannel(fd: fds[0])
        let sent = await channel.send(.plan(false, "Add tests\n保留接口"), sessionID: "plan")
        XCTAssertTrue(sent)
        let data = try XCTUnwrap(SocketServer.readMessage(from: fds[1]))
        let response = try DIProtocol.decode(data)
        XCTAssertEqual(response.type, .planResponse)
        XCTAssertEqual(response.planApproved, false)
        XCTAssertEqual(response.feedback, "Add tests\n保留接口")
        let sentAgain = await channel.send(.permission(true), sessionID: "other")
        XCTAssertFalse(sentAgain)
    }

    func testClosedPeerReportsFailureWithoutSIGPIPE() async throws {
        let fds = try pair()
        close(fds[1])
        let channel = SocketResponseChannel(fd: fds[0])
        let sent = await channel.send(.permission(true), sessionID: "closed")
        XCTAssertFalse(sent)
    }

    func testUnresponsivePeerHasBoundedTotalWriteTime() throws {
        let fds = try pair()
        defer { close(fds[0]); close(fds[1]) }
        let started = ProcessInfo.processInfo.systemUptime
        let sent = SocketServer.sendAll(fd: fds[0], data: Data(repeating: 65, count: 8 * 1024 * 1024), timeout: 0.05)
        XCTAssertFalse(sent)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
    }
}
