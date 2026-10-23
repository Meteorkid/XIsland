import Darwin
import XCTest
import DIShared
import os
@testable import XIsland

final class SocketResponseChannelTests: XCTestCase {
    private func waitForRelease(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition(), "连接对象必须及时释放")
    }

    func testSendThenDeinitReleasesQuotaOnce() async throws {
        let fds = try pair()
        defer { close(fds[1]) }
        let count = OSAllocatedUnfairLock(initialState: 0)
        var channel: SocketResponseChannel? = SocketResponseChannel(fd: fds[0], idleTimeout: 0) {
            count.withLock { $0 += 1 }
        }
        weak var weakChannel = channel
        let sent = await channel!.send(.permission(false), sessionID: "quota")
        XCTAssertTrue(sent)
        channel = nil
        await waitForRelease { weakChannel == nil }
        XCTAssertEqual(count.withLock { $0 }, 1)
    }

    func testRepeatedCancelThenDeinitReleasesQuotaOnce() async throws {
        let fds = try pair()
        defer { close(fds[1]) }
        let count = OSAllocatedUnfairLock(initialState: 0)
        var channel: SocketResponseChannel? = SocketResponseChannel(fd: fds[0], idleTimeout: 0) {
            count.withLock { $0 += 1 }
        }
        weak var weakChannel = channel
        for _ in 0..<20 { channel?.cancel() }
        channel = nil
        await waitForRelease { weakChannel == nil }
        XCTAssertEqual(count.withLock { $0 }, 1)
    }

    func testIdleTimeoutThenDeinitReleasesQuotaOnce() async throws {
        let fds = try pair()
        defer { close(fds[1]) }
        let count = OSAllocatedUnfairLock(initialState: 0)
        var channel: SocketResponseChannel? = SocketResponseChannel(fd: fds[0], idleTimeout: 0.02) {
            count.withLock { $0 += 1 }
        }
        weak var weakChannel = channel
        await waitForRelease { count.withLock { $0 } > 0 }
        channel = nil
        await waitForRelease { weakChannel == nil }
        XCTAssertEqual(count.withLock { $0 }, 1)
    }

    func testDeinitWithoutSendOrCancelReleasesQuotaOnce() throws {
        let fds = try pair()
        defer { close(fds[1]) }
        let count = OSAllocatedUnfairLock(initialState: 0)
        var channel: SocketResponseChannel? = SocketResponseChannel(fd: fds[0], idleTimeout: 0) {
            count.withLock { $0 += 1 }
        }
        weak var weakChannel = channel
        channel = nil
        XCTAssertNil(weakChannel)
        XCTAssertEqual(count.withLock { $0 }, 1)
        XCTAssertEqual(fcntl(fds[0], F_GETFD), -1)
    }

    func testFailedSendThenDeinitReleasesQuotaOnce() async throws {
        let fds = try pair()
        close(fds[1])
        let count = OSAllocatedUnfairLock(initialState: 0)
        var channel: SocketResponseChannel? = SocketResponseChannel(fd: fds[0], idleTimeout: 0) {
            count.withLock { $0 += 1 }
        }
        weak var weakChannel = channel
        let sent = await channel!.send(.permission(false), sessionID: "closed-peer")
        XCTAssertFalse(sent)
        channel = nil
        await waitForRelease { weakChannel == nil }
        XCTAssertEqual(count.withLock { $0 }, 1)
    }

    func testSendCancelRaceReleasesQuotaOnce() async throws {
        let fds = try pair()
        defer { close(fds[1]) }
        let count = OSAllocatedUnfairLock(initialState: 0)
        var channel: SocketResponseChannel? = SocketResponseChannel(fd: fds[0], idleTimeout: 0.01) {
            count.withLock { $0 += 1 }
        }
        weak var weakChannel = channel
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                let current = channel!
                group.addTask {
                    if index.isMultiple(of: 2) {
                        _ = await current.send(.permission(false), sessionID: "race")
                    } else {
                        current.cancel()
                    }
                }
            }
        }
        channel = nil
        await waitForRelease { weakChannel == nil }
        XCTAssertEqual(count.withLock { $0 }, 1)
    }

    func testClosingOneChannelKeepsOtherConnectionCharged() async throws {
        let first = try pair(), second = try pair()
        defer { close(first[1]); close(second[1]) }
        let active = OSAllocatedUnfairLock(initialState: 2)
        var channel: SocketResponseChannel? = SocketResponseChannel(fd: first[0], idleTimeout: 0) {
            active.withLock { $0 -= 1 }
        }
        var other: SocketResponseChannel? = SocketResponseChannel(fd: second[0], idleTimeout: 0) {
            active.withLock { $0 -= 1 }
        }
        weak var weakChannel = channel
        weak var weakOther = other
        channel?.cancel()
        channel = nil
        await waitForRelease { weakChannel == nil }
        XCTAssertEqual(active.withLock { $0 }, 1, "另一个连接仍占用配额")
        XCTAssertNotEqual(fcntl(second[0], F_GETFD), -1)
        other = nil
        await waitForRelease { weakOther == nil }
        XCTAssertEqual(active.withLock { $0 }, 0)
    }

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
