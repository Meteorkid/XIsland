import Foundation
import XCTest
@testable import XIsland

final class IntegrationSetupToolSyncTests: XCTestCase {
    func testSuccessfulToolSyncAtomicallyReplacesOlderExecutableAndCleansStaging() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundled")
        let stable = root.appendingPathComponent("bin/bridge")
        try FileManager.default.createDirectory(at: stable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: stable)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: stable.path)
        try Data("new-bundle".utf8).write(to: bundled)

        try await IntegrationSetupIO.run {
            ZeroConfigManager.syncBundledFileIfNeeded(bundled: bundled.path, stable: stable.path)
        }

        XCTAssertEqual(try Data(contentsOf: stable), Data("new-bundle".utf8))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: stable.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stable.deletingLastPathComponent().path), ["bridge"])
    }

    @MainActor
    func testCancelledToolSyncKeepsExistingExecutable() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundled")
        let stable = root.appendingPathComponent("bridge")
        try Data("existing".utf8).write(to: stable)
        try Data("replacement".utf8).write(to: bundled)
        let pending = Task {
            try await IntegrationSetupIO.run {
                ZeroConfigManager.syncBundledFileIfNeeded(bundled: bundled.path, stable: stable.path)
            }
        }
        pending.cancel()
        do { try await pending.value; XCTFail("取消应传递到文件 worker") }
        catch is CancellationError {}

        XCTAssertEqual(try Data(contentsOf: stable), Data("existing".utf8))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["bundled", "bridge"])
    }

    func testMissingBundleKeepsExistingExecutable() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stable = root.appendingPathComponent("bridge")
        try Data("existing".utf8).write(to: stable)
        ZeroConfigManager.syncBundledFileIfNeeded(bundled: root.appendingPathComponent("missing").path, stable: stable.path)
        XCTAssertEqual(try Data(contentsOf: stable), Data("existing".utf8))
    }

    private func fixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("integration-tool-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
