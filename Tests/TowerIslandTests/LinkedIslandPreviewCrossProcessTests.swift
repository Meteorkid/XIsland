import CoreGraphics
import Darwin
import Foundation
import XCTest
@testable import XIsland

@MainActor
final class LinkedIslandPreviewCrossProcessTests: XCTestCase {
    func testDifferentProcessRoundTripAndBidirectionalIdentityRejection() async throws {
        let artifact = try await compileResponder()
        defer { try? FileManager.default.removeItem(at: artifact.directory) }
        for scenario in Scenario.allCases {
            try await exchange(with: artifact, scenario: scenario)
        }
    }

    private enum Scenario: String, CaseIterable {
        case authenticated, wrongTargetPID, wrongTargetExecutable, wrongSourcePID, wrongSourceExecutable
    }

    private struct Artifact {
        let directory: URL
        let executable: URL
    }

    private struct Handshake: Encodable {
        let request: LinkedIslandPreviewTransport.Request
        let sourcePID: Int32
        let sourceExecutable: String
    }

    private struct Report: Decodable {
        let pid: Int32
        let uid: UInt32
        let captures: Int
        let finished: Bool
        let endpointValidated: Bool
    }

    private enum FixtureError: Error {
        case compilerFailed(String)
        case processTimedOut(String)
        case processPathUnavailable(Int32)
    }

    private func exchange(with artifact: Artifact, scenario: Scenario) async throws {
        let process = Process()
        let input = Pipe()
        let reportURL = artifact.directory.appendingPathComponent("\(scenario.rawValue).json")
        let errorsURL = artifact.directory.appendingPathComponent("\(scenario.rawValue).stderr")
        let output = try outputHandle(at: reportURL)
        let errors = try outputHandle(at: errorsURL)
        defer { try? output.close(); try? errors.close(); try? input.fileHandleForWriting.close() }
        process.executableURL = artifact.executable
        process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        do {
            let parent = try peer(pid: getpid())
            let child = try peer(pid: process.processIdentifier)
            XCTAssertNotEqual(child.pid, parent.pid)
            XCTAssertEqual(child.executablePath, artifact.executable.resolvingSymlinksInPath().path)
            XCTAssertNotEqual(child.executablePath, parent.executablePath)
            var expectedTarget = child
            if scenario == .wrongTargetPID {
                expectedTarget = LinkedIslandPreviewPeer(pid: parent.pid, executablePath: child.executablePath)
            } else if scenario == .wrongTargetExecutable {
                expectedTarget = LinkedIslandPreviewPeer(pid: child.pid, executablePath: parent.executablePath)
            }
            let completed = expectation(description: "独立进程响应 \(scenario.rawValue)")
            var received: Result<IslandPreviewSnapshot, LinkedIslandPreviewTransport.PreviewError>?
            let pending = try LinkedIslandPreviewTransport.begin(expectedTarget: expectedTarget, timeout: 2.5) {
                received = $0
                completed.fulfill()
            }
            defer { pending.cancel() }
            let handshake = Handshake(request: pending.request,
                sourcePID: scenario == .wrongSourcePID ? child.pid : parent.pid,
                sourceExecutable: scenario == .wrongSourceExecutable ? child.executablePath : parent.executablePath)
            var command = try JSONEncoder().encode(handshake)
            command.append(0x0a)
            try input.fileHandleForWriting.write(contentsOf: command)
            await fulfillment(of: [completed], timeout: 4)
            // 保持目标存活直至父端完成本轮传输，不能因目标先退出而误得 peerRejected。
            try input.fileHandleForWriting.write(contentsOf: Data("exit\n".utf8))
            try input.fileHandleForWriting.close()
            try await waitForExit(process, timeout: 4, label: scenario.rawValue)
            let errorText = String(data: try Data(contentsOf: errorsURL), encoding: .utf8) ?? ""
            XCTAssertEqual(process.terminationStatus, 0, errorText)
            XCTAssertFalse(process.isRunning)
            let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: reportURL))
            XCTAssertEqual(report.pid, child.pid)
            XCTAssertEqual(report.uid, geteuid())
            XCTAssertTrue(report.finished)
            XCTAssertTrue(report.endpointValidated, "helper 必须先确认私有端点可用再响应")
            let result = try XCTUnwrap(received)
            var outcome = "snapshot"
            if scenario == .authenticated {
                let snapshot = try result.get()
                XCTAssertEqual(report.captures, 1)
                XCTAssertEqual(snapshot.image.width, 16)
                XCTAssertEqual(snapshot.image.height, 12)
                XCTAssertEqual(snapshot.frame, CGRect(x: 100, y: 200, width: 16, height: 12))
                XCTAssertEqual(snapshot.scale, 1)
                XCTAssertEqual(snapshot.outline.displayID, 1)
                XCTAssertEqual(snapshot.outline.topRadius, 2)
                XCTAssertEqual(snapshot.outline.bottomRadius, 3)
                XCTAssertEqual(snapshot.outline.fill, IslandSwitchColor(red: 1, green: 0, blue: 0, alpha: 1))
                try assertRedPayload(snapshot.image)
            } else {
                XCTAssertEqual(report.captures, 0, "身份拒绝必须发生在捕获之前")
                guard case .failure(let failure) = result else { return XCTFail("错误身份不能收到快照") }
                outcome = String(describing: failure)
                if scenario == .wrongTargetPID || scenario == .wrongTargetExecutable {
                    XCTAssertEqual(failure, .peerRejected)
                } else {
                    XCTAssertNotEqual(failure, .timeout, "无连接或无响应不能算作身份拒绝")
                    XCTAssertNotEqual(failure, .cancelled)
                    // 目标保持存活；来源必须观察到连接早断开或真实 I/O 失败。
                    switch failure {
                    case .unavailable:
                        break
                    case .io(let code):
                        XCTAssertNotEqual(code, 0, "保留实际系统 I/O 错误，不把它改写成身份错误")
                    default:
                        XCTFail("应收到目标关闭连接的结果，实际为 \(failure)")
                    }
                }
            }
            XCTAssertTrue(pending.handle.isFinished)
            let endpoint = URL(fileURLWithPath: pending.request.endpoint)
            XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.deletingLastPathComponent().path))
            print("Cross-process preview \(scenario.rawValue): parent=\(parent.pid), child=\(child.pid), captures=\(report.captures), outcome=\(outcome), endpointValidated=\(report.endpointValidated), exited=true, endpointRemoved=true")
        } catch {
            await stopOwnedProcess(process)
            throw error
        }
    }

    private func compileResponder() async throws -> Artifact {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = package.appendingPathComponent(".build/linked-preview-cross-process/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let helper = directory.appendingPathComponent("Responder.swift")
        let stub = directory.appendingPathComponent("SwipeDirection.swift")
        let executable = directory.appendingPathComponent("preview-responder")
        try Self.helperSource.write(to: helper, atomically: true, encoding: .utf8)
        try "import CoreGraphics\nenum SwipeDirection: String, Equatable, Sendable { case left, right; var sign: CGFloat { self == .left ? -1 : 1 } }\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        let logURL = directory.appendingPathComponent("compile.log")
        let log = try outputHandle(at: logURL)
        defer { try? log.close() }
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-parse-as-library", "-swift-version", "5",
            "-module-cache-path", directory.appendingPathComponent("ModuleCache").path,
            package.appendingPathComponent("Sources/DynamicIsland/LinkedIslandPreviewTransport.swift").path,
            package.appendingPathComponent("Sources/DynamicIsland/IslandSwitchMotion.swift").path,
            stub.path, helper.path, "-o", executable.path]
        compiler.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()]
        compiler.standardOutput = log
        compiler.standardError = log
        do {
            try compiler.run()
            try await waitForExit(compiler, timeout: 45, label: "swiftc helper")
            guard compiler.terminationStatus == 0 else {
                let output = String(data: try Data(contentsOf: logURL), encoding: .utf8) ?? ""
                throw FixtureError.compilerFailed(output)
            }
            return Artifact(directory: directory, executable: executable)
        } catch {
            await stopOwnedProcess(compiler)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func outputHandle(at url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try FileHandle(forWritingTo: url)
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval, label: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning {
            await stopOwnedProcess(process)
            throw FixtureError.processTimedOut(label)
        }
    }

    private func stopOwnedProcess(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        let killDeadline = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(process.isRunning, "只能终止本测试创建的进程，并等待退出")
    }

    private func peer(pid: Int32) throws -> LinkedIslandPreviewPeer {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            throw FixtureError.processPathUnavailable(pid)
        }
        return LinkedIslandPreviewPeer(pid: pid, executablePath: String(cString: buffer))
    }

    private func assertRedPayload(_ image: CGImage) throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(pixels[0], 240)
        XCTAssertLessThan(pixels[1], 15)
        XCTAssertLessThan(pixels[2], 15)
        XCTAssertEqual(pixels[3], 255)
    }

    private static let helperSource = #"""
    import CoreGraphics
    import Darwin
    import Foundation

    private struct Handshake: Decodable {
        let request: LinkedIslandPreviewTransport.Request
        let sourcePID: Int32
        let sourceExecutable: String
    }

    private struct Report: Encodable {
        let pid: Int32
        let uid: UInt32
        let captures: Int
        let finished: Bool
        let endpointValidated: Bool
    }

    @main
    private struct PreviewResponder {
        @MainActor
        static func main() async {
            do {
                guard let line = readLine(), let data = line.data(using: .utf8) else { exit(2) }
                let handshake = try JSONDecoder().decode(Handshake.self, from: data)
                let endpointValidated = LinkedIslandPreviewTransport.Request(userInfo: handshake.request.userInfo) != nil
                guard endpointValidated else { exit(5) }
                var captures = 0
                let response = LinkedIslandPreviewTransport.respond(to: handshake.request,
                    expectedSource: LinkedIslandPreviewPeer(pid: handshake.sourcePID,
                                                          executablePath: handshake.sourceExecutable),
                    timeout: 2.5) {
                    captures += 1
                    return snapshot()
                }
                let deadline = ProcessInfo.processInfo.systemUptime + 4
                while !response.isFinished && ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                let finished = response.isFinished
                if !finished { response.cancel() }
                let report = Report(pid: getpid(), uid: geteuid(), captures: captures,
                                    finished: finished, endpointValidated: endpointValidated)
                try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(report))
                // 等父端结束本轮传输，再退出，避免执行路径查询与进程退出竞争。
                guard readLine() == "exit" else { exit(4) }
                exit(finished ? 0 : 3)
            } catch {
                try? FileHandle.standardError.write(contentsOf: Data("fixture failed\n".utf8))
                exit(2)
            }
        }

        private static func snapshot() -> IslandPreviewSnapshot? {
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8,
                    bytesPerRow: 64, space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
            let frame = CGRect(x: 100, y: 200, width: 16, height: 12)
            guard let image = context.makeImage(),
                  let outline = IslandSwitchGeometry(frame: frame, displayID: 1, topRadius: 2, bottomRadius: 3,
                    fill: IslandSwitchColor(red: 1, green: 0, blue: 0, alpha: 1)) else { return nil }
            return IslandPreviewSnapshot(image: image, frame: frame, scale: 1, outline: outline)
        }
    }
    """#
}
