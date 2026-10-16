import XCTest
@testable import XIsland

final class HookConfigurationFileTests: XCTestCase {
    func testTextUpdatePreservesBytesOnFailureAndUpdatesSymlinkTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("managed.toml")
        let link = root.appendingPathComponent("config.toml")
        let source = "# formatting matters\r\nmodel = 'fixture'\r\n"
        try source.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try HookConfigurationFile.updateText(at: link) { _ in throw HookConfigurationFile.ConfigurationError.rootMustBeObject })
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), source)
        XCTAssertTrue(try HookConfigurationFile.updateText(at: link) { $0 + "# appended\n" })
        XCTAssertFalse(try HookConfigurationFile.updateText(at: link) { $0 })
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), source + "# appended\n")
    }

    func testUpdatePreservesConfigurationSymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("managed-settings.json")
        let link = directory.appendingPathComponent("settings.json")
        try Data("{\"custom\":true}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try HookConfigurationFile.update(at: link) { original in
            var changed = original
            changed["hooks"] = [:] as [String: Any]
            return changed
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try HookConfigurationFile.read(at: target)["custom"] as? Bool, true)
        XCTAssertNotNil(try HookConfigurationFile.read(at: target)["hooks"])
    }

    func testInvalidExistingJSONIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("settings.json")
        let original = Data("{invalid json".utf8)
        try original.write(to: path)
        XCTAssertThrowsError(try HookConfigurationFile.update(at: path) { _ in ["hooks": [:]] })
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testFailedTransformPreservesOriginalBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("settings.json")
        let original = Data("{ \"custom\": true }".utf8)
        try original.write(to: path)
        XCTAssertThrowsError(try HookConfigurationFile.update(at: path) { _ in
            throw HookConfigurationFile.ConfigurationError.rootMustBeObject
        })
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testUpdateIsAtomicAndIdempotentWithoutTemporaryFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("settings.json")
        XCTAssertTrue(try HookConfigurationFile.update(at: path) { _ in ["custom": true, "hooks": [:]] })
        let original = try Data(contentsOf: path)
        XCTAssertFalse(try HookConfigurationFile.update(at: path) { $0 })
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["settings.json"])
        XCTAssertEqual(try HookConfigurationFile.read(at: path)["custom"] as? Bool, true)
    }
}
