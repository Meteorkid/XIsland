import CoreGraphics
import Darwin
import Foundation
import XCTest
@testable import XIsland

@MainActor
final class LinkedIslandPreviewTransportTests: XCTestCase {
    func testAuthenticatedSocketRoundTripUsesMemoryAndRemovesPrivateEndpoint() async throws {
        let finished = expectation(description: "快照回传")
        let snapshot = try makeSnapshot()
        var received: Result<IslandPreviewSnapshot, LinkedIslandPreviewTransport.PreviewError>?
        let pending = try LinkedIslandPreviewTransport.begin(expectedTarget: peer()) { result in
            XCTAssertTrue(Thread.isMainThread)
            received = result
            finished.fulfill()
        }
        let endpoint = URL(fileURLWithPath: pending.request.endpoint)
        let directory = endpoint.deletingLastPathComponent()
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(endpoint), 0o600)
        XCTAssertEqual(LinkedIslandPreviewTransport.Request(userInfo: pending.request.userInfo)?.id, pending.request.id)
        let responder = LinkedIslandPreviewTransport.respond(to: pending.request, expectedSource: try peer()) {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: directory.path), ["s"])
            return snapshot
        }
        defer { pending.cancel(); responder.cancel() }
        await fulfillment(of: [finished], timeout: 2)
        let output = try XCTUnwrap(received).get()
        XCTAssertEqual(output.image.width, snapshot.image.width)
        XCTAssertEqual(output.image.height, snapshot.image.height)
        XCTAssertEqual(output.frame, snapshot.frame)
        XCTAssertEqual(output.scale, snapshot.scale)
        XCTAssertEqual(output.outline, snapshot.outline)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(pending.handle.isFinished)
    }

    func testMissingResponderTimesOutAndCleansUp() async throws {
        let finished = expectation(description: "未连接超时")
        var failure: LinkedIslandPreviewTransport.PreviewError?
        let pending = try LinkedIslandPreviewTransport.begin(expectedTarget: peer(), timeout: 0.06) {
            if case .failure(let error) = $0 { failure = error }
            finished.fulfill()
        }
        defer { pending.cancel() }
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(failure, .timeout)
        assertCleaned(pending.request)
    }

    func testRepeatedCancellationCompletesOnceWithoutClosingUnrelatedDescriptors() async throws {
        let finished = expectation(description: "取消一次完成")
        var count = 0
        var failure: LinkedIslandPreviewTransport.PreviewError?
        let pending = try LinkedIslandPreviewTransport.begin(expectedTarget: peer(), timeout: 0.5) {
            count += 1
            if case .failure(let error) = $0 { failure = error }
            finished.fulfill()
        }
        var descriptors: [Int32] = []
        defer { descriptors.forEach { Darwin.close($0) }; pending.cancel() }
        for _ in 0..<12 {
            pending.cancel()
            let fd = Darwin.open("/dev/null", O_RDONLY)
            XCTAssertGreaterThanOrEqual(fd, 0)
            descriptors.append(fd)
        }
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(failure, .cancelled)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(descriptors.allSatisfy { fcntl($0, F_GETFL) >= 0 })
        assertCleaned(pending.request)
    }

    func testSourceRejectsWrongTargetPIDOrExecutableBeforeCapture() async throws {
        let actual = try peer()
        for bad in [LinkedIslandPreviewPeer(pid: actual.pid + 1, executablePath: actual.executablePath),
                    LinkedIslandPreviewPeer(pid: actual.pid, executablePath: actual.executablePath + ".wrong")] {
            let finished = expectation(description: "来源拒绝错误身份")
            var failure: LinkedIslandPreviewTransport.PreviewError?
            var captured = false
            let pending = try LinkedIslandPreviewTransport.begin(expectedTarget: bad) {
                if case .failure(let error) = $0 { failure = error }
                finished.fulfill()
            }
            let responder = LinkedIslandPreviewTransport.respond(to: pending.request, expectedSource: actual) {
                captured = true
                return nil
            }
            await fulfillment(of: [finished], timeout: 2)
            responder.cancel(); pending.cancel()
            XCTAssertEqual(failure, .peerRejected)
            XCTAssertFalse(captured)
            assertCleaned(pending.request)
        }
    }

    func testTargetRejectsWrongSourceIdentityBeforeCapture() async throws {
        let actual = try peer()
        for bad in [LinkedIslandPreviewPeer(pid: actual.pid + 1, executablePath: actual.executablePath),
                    LinkedIslandPreviewPeer(pid: actual.pid, executablePath: actual.executablePath + ".wrong")] {
            let finished = expectation(description: "目标拒绝错误身份")
            var failed = false
            var captured = false
            let pending = try LinkedIslandPreviewTransport.begin(expectedTarget: actual, timeout: 0.3) {
                if case .failure = $0 { failed = true }
                finished.fulfill()
            }
            let responder = LinkedIslandPreviewTransport.respond(to: pending.request, expectedSource: bad) {
                captured = true
                return nil
            }
            await fulfillment(of: [finished], timeout: 1)
            responder.cancel(); pending.cancel()
            XCTAssertTrue(failed)
            XCTAssertFalse(captured)
            assertCleaned(pending.request)
        }
    }

    func testRefusedCaptureReturnsUnavailable() async throws {
        let result = try await exchange(snapshot: nil)
        guard case .failure(let error) = result else { return XCTFail("拒绝捕获不能返回快照") }
        XCTAssertEqual(error, .unavailable)
    }

    func testCancelledResponderNeverRunsQueuedMainActorCapture() async throws {
        let finished = expectation(description: "取消目标响应")
        let actual = try peer()
        var captured = false
        var failed = false
        let pending = try LinkedIslandPreviewTransport.begin(expectedTarget: actual, timeout: 0.15) {
            if case .failure = $0 { failed = true }
            finished.fulfill()
        }
        let responder = LinkedIslandPreviewTransport.respond(to: pending.request, expectedSource: actual) {
            captured = true
            return nil
        }
        responder.cancel()
        defer { pending.cancel() }
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertTrue(failed)
        XCTAssertFalse(captured)
        assertCleaned(pending.request)
    }

    func testOversizedWireLengthIsRejectedBeforeAllocatingPayload() async throws {
        let finished = expectation(description: "长度上限")
        let rawFinished = expectation(description: "伪响应线程关闭")
        var failure: LinkedIslandPreviewTransport.PreviewError?
        let pending = try LinkedIslandPreviewTransport.begin(expectedTarget: peer(), timeout: 0.5) {
            if case .failure(let error) = $0 { failure = error }
            finished.fulfill()
        }
        defer { pending.cancel() }
        let path = pending.request.endpoint
        DispatchQueue.global(qos: .userInitiated).async {
            defer { rawFinished.fulfill() }
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            defer { Darwin.close(fd) }
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_un()
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { return }
            // 等来源完成对端认证并发出 prepare，避免提前关闭导致 PID 无法核验。
            var request = [UInt8](repeating: 0, count: 1024)
            guard Darwin.read(fd, &request, request.count) > 0 else { return }
            let prefix = [UInt32(1).bigEndian, UInt32(LinkedIslandPreviewTransport.maximumMessageBytes + 1).bigEndian]
            prefix.withUnsafeBytes { bytes in _ = Darwin.write(fd, bytes.baseAddress, bytes.count) }
        }
        await fulfillment(of: [finished, rawFinished], timeout: 2)
        XCTAssertEqual(failure, .tooLarge)
        assertCleaned(pending.request)
    }

    func testInvalidGeometryScaleAndPixelCountDoNotReturnSnapshot() async throws {
        let valid = try makeSnapshot()
        let oversized = try makeSnapshot(width: 2001, height: 2000, scale: 1)
        let invalid = [
            IslandPreviewSnapshot(image: valid.image, frame: CGRect(x: 100, y: 200, width: -16, height: 12),
                                  scale: valid.scale, outline: valid.outline),
            IslandPreviewSnapshot(image: valid.image, frame: valid.frame, scale: .nan, outline: valid.outline),
            IslandPreviewSnapshot(image: valid.image, frame: valid.frame, scale: 0, outline: valid.outline),
            IslandPreviewSnapshot(image: valid.image, frame: CGRect(x: CGFloat.infinity, y: 200, width: 16, height: 12),
                                  scale: valid.scale, outline: valid.outline),
            oversized,
        ]
        for snapshot in invalid {
            if case .success = try await exchange(snapshot: snapshot) { XCTFail("非法快照不能穿过传输层") }
        }
    }

    func testRequestRejectsArbitraryPathsTraversalAndUnsafePermissions() throws {
        let pending = try LinkedIslandPreviewTransport.begin(expectedTarget: peer(), timeout: 0.3) { _ in }
        defer { pending.cancel() }
        let request = pending.request
        XCTAssertNotNil(LinkedIslandPreviewTransport.Request(userInfo: request.userInfo))
        XCTAssertNil(LinkedIslandPreviewTransport.Request(userInfo: ["id": request.id.uuidString, "endpoint": "/tmp/s"]))
        XCTAssertNil(LinkedIslandPreviewTransport.Request(userInfo: ["id": request.id.uuidString, "endpoint": request.endpoint + "/../s"]))
        XCTAssertNil(LinkedIslandPreviewTransport.Request(userInfo: ["id": "bad", "endpoint": request.endpoint]))
        let directory = URL(fileURLWithPath: request.endpoint).deletingLastPathComponent().path
        XCTAssertEqual(chmod(directory, 0o755), 0)
        XCTAssertNil(LinkedIslandPreviewTransport.Request(userInfo: request.userInfo))
        XCTAssertEqual(chmod(directory, 0o700), 0)
        XCTAssertEqual(chmod(request.endpoint, 0o666), 0)
        XCTAssertNil(LinkedIslandPreviewTransport.Request(userInfo: request.userInfo))
        XCTAssertEqual(chmod(request.endpoint, 0o600), 0)
    }

    func testRequestRejectsSymlinkSocketAndSymlinkDirectory() throws {
        let pending = try LinkedIslandPreviewTransport.begin(expectedTarget: peer(), timeout: 0.3) { _ in }
        defer { pending.cancel() }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        var template = Array((root + "/xip-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let alias = String(cString: template)
        defer {
            var info = stat()
            if lstat(alias, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                unlink(alias)
            } else {
                unlink(alias + "/s")
                rmdir(alias)
            }
        }
        XCTAssertEqual(symlink(pending.request.endpoint, alias + "/s"), 0)
        let info = ["id": pending.request.id.uuidString, "endpoint": alias + "/s"]
        XCTAssertNil(LinkedIslandPreviewTransport.Request(userInfo: info))
        XCTAssertEqual(unlink(alias + "/s"), 0)
        XCTAssertEqual(rmdir(alias), 0)
        XCTAssertEqual(symlink(URL(fileURLWithPath: pending.request.endpoint).deletingLastPathComponent().path, alias), 0)
        XCTAssertNil(LinkedIslandPreviewTransport.Request(userInfo: info))
    }

    private func exchange(snapshot: IslandPreviewSnapshot?) async throws -> Result<IslandPreviewSnapshot, LinkedIslandPreviewTransport.PreviewError> {
        let finished = expectation(description: "一次请求响应")
        var result: Result<IslandPreviewSnapshot, LinkedIslandPreviewTransport.PreviewError>?
        let expected = try peer()
        let pending = try LinkedIslandPreviewTransport.begin(expectedTarget: expected, timeout: 1.5) {
            result = $0; finished.fulfill()
        }
        let responder = LinkedIslandPreviewTransport.respond(to: pending.request, expectedSource: expected, timeout: 1.5) { snapshot }
        defer { pending.cancel(); responder.cancel() }
        await fulfillment(of: [finished], timeout: 2)
        assertCleaned(pending.request)
        return try XCTUnwrap(result)
    }

    private func peer() throws -> LinkedIslandPreviewPeer {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return LinkedIslandPreviewPeer(pid: getpid(), executablePath: String(cString: buffer))
    }

    private func makeSnapshot(width: Int = 32, height: Int = 24, scale: CGFloat = 2) throws -> IslandPreviewSnapshot {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let frame = CGRect(x: 100, y: 200, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        let outline = try XCTUnwrap(IslandSwitchGeometry(frame: frame, displayID: 1, topRadius: 0, bottomRadius: 4,
            fill: IslandSwitchColor(red: 1, green: 0, blue: 0, alpha: 1)))
        return IslandPreviewSnapshot(image: try XCTUnwrap(context.makeImage()), frame: frame, scale: scale, outline: outline)
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func assertCleaned(_ request: LinkedIslandPreviewTransport.Request, file: StaticString = #filePath, line: UInt = #line) {
        let directory = URL(fileURLWithPath: request.endpoint).deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), file: file, line: line)
    }
}
