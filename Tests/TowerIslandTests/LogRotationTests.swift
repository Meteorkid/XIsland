import XCTest
@testable import DIBridge

final class LogRotationTests: XCTestCase {
    func testOversizedLogIsRotatedAndLargeHistoryDiscarded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("bridge-stdin.log")

        try Data(repeating: 0, count: 20).write(to: path)
        DIBridge.rotateDebugLogIfNeeded(at: path.path, maxBytes: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path + ".1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))

        try Data(repeating: 0, count: 100).write(to: path)
        DIBridge.rotateDebugLogIfNeeded(at: path.path, maxBytes: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path + ".1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testSmallLogIsNotRotated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("bridge-stdin.log")
        try Data(repeating: 0, count: 5).write(to: path)

        DIBridge.rotateDebugLogIfNeeded(at: path.path, maxBytes: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path + ".1"))
    }
}
