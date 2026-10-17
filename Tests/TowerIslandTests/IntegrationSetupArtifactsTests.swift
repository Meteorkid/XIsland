import DIShared
import Darwin
import XCTest
@testable import DIBridge
@testable import XIsland

@MainActor
final class IntegrationSetupArtifactsTests: XCTestCase {
    private func root() throws -> URL {
        // Foundation 会将 /private/var 重新简化为 /var，需保留 realpath 的无符号链接路径。
        let pointer = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(pointer) }
        let directory = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
            .appendingPathComponent("xisland-preparation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private let bridge = URL(fileURLWithPath: "/Applications/X Island's $(literal).app/Contents/MacOS/di-bridge")

    func testWorkBuddyUsesTheExistingExporterContractWithoutInstallingIt() throws {
        let directory = try root()
        let prepared = try IntegrationSetupArtifacts.prepare(for: .workBuddy, directory: directory, bridgeURL: bridge)
        let expected = try WorkBuddyPluginExport.files(bridgePath: bridge.path)
        XCTAssertEqual(prepared.deletingLastPathComponent(), directory)
        XCTAssertTrue(prepared.lastPathComponent.hasPrefix("workbuddy-"))
        for (path, data) in expected {
            XCTAssertEqual(try Data(contentsOf: prepared.appendingPathComponent(path)), data)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [prepared.lastPathComponent])
    }

    func testKiroPreparesTheDocumentedV3TemplateWithoutRuntimeDetection() throws {
        let directory = try root()
        let file = try IntegrationSetupArtifacts.prepare(for: .kiro, directory: directory, bridgeURL: bridge)
        XCTAssertEqual(file.lastPathComponent, KiroHookConfiguration.fileName)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertTrue(KiroHookConfiguration.isConfigured(in: document, bridgePath: bridge.path))
        XCTAssertEqual((document["hooks"] as? [[String: Any]])?.count, 6)
        XCTAssertEqual(document["version"] as? String, "v1")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testIdenticalContentReusesTheSameFilesWithoutRewriting() throws {
        let directory = try root()
        for agent in [AgentType.workBuddy, .kiro] {
            let result = try IntegrationSetupArtifacts.prepare(for: agent, directory: directory, bridgeURL: bridge)
            let file = agent == .workBuddy ? result.appendingPathComponent("hooks/hooks.json") : result
            let savedDate = Date(timeIntervalSince1970: 1_500_000_000)
            try FileManager.default.setAttributes([.modificationDate: savedDate], ofItemAtPath: file.path)
            XCTAssertEqual(try IntegrationSetupArtifacts.prepare(for: agent, directory: directory, bridgeURL: bridge), result)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, savedDate)
        }
    }

    func testChangedBridgePathCreatesANewArtifactAndPreservesThePreviousOne() throws {
        let directory = try root()
        let first = try IntegrationSetupArtifacts.prepare(for: .workBuddy, directory: directory, bridgeURL: bridge)
        let original = try Data(contentsOf: first.appendingPathComponent("hooks/hooks.json"))
        let second = try IntegrationSetupArtifacts.prepare(for: .workBuddy, directory: directory,
                                                           bridgeURL: URL(fileURLWithPath: "/Applications/New.app/di-bridge"))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent("hooks/hooks.json")), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testModifiedExistingArtifactsArePreservedAndRejected() throws {
        let directory = try root()
        for agent in [AgentType.workBuddy, .kiro] {
            let result = try IntegrationSetupArtifacts.prepare(for: agent, directory: directory, bridgeURL: bridge)
            let file = agent == .workBuddy ? result.appendingPathComponent("hooks/hooks.json") : result
            let changed = Data("user edited content".utf8)
            try changed.write(to: file)
            XCTAssertThrowsError(try IntegrationSetupArtifacts.prepare(for: agent, directory: directory, bridgeURL: bridge)) {
                XCTAssertEqual($0 as? IntegrationSetupArtifacts.PreparationError, .modifiedArtifact)
            }
            XCTAssertEqual(try Data(contentsOf: file), changed)
        }
    }

    func testUnexpectedFilesAlsoPreventReuse() throws {
        let directory = try root()
        let prepared = try IntegrationSetupArtifacts.prepare(for: .workBuddy, directory: directory, bridgeURL: bridge)
        let extra = prepared.appendingPathComponent("user-note.txt")
        try Data("keep me".utf8).write(to: extra)
        XCTAssertThrowsError(try IntegrationSetupArtifacts.prepare(for: .workBuddy, directory: directory, bridgeURL: bridge)) {
            XCTAssertEqual($0 as? IntegrationSetupArtifacts.PreparationError, .modifiedArtifact)
        }
        XCTAssertEqual(try String(contentsOf: extra), "keep me")
    }

    func testSymlinkInPreparationDirectoryIsRejectedWithoutWritingThroughIt() throws {
        let directory = try root()
        let target = directory.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = directory.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try IntegrationSetupArtifacts.prepare(for: .workBuddy,
            directory: link.appendingPathComponent("nested"), bridgeURL: bridge)) {
            XCTAssertEqual($0 as? IntegrationSetupArtifacts.PreparationError, .unsafePath)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testSymlinkReplacingAnArtifactFileIsRejectedWithoutTouchingItsTarget() throws {
        let directory = try root()
        let prepared = try IntegrationSetupArtifacts.prepare(for: .workBuddy, directory: directory, bridgeURL: bridge)
        let file = prepared.appendingPathComponent("hooks/hooks.json")
        let target = directory.appendingPathComponent("private-file")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try IntegrationSetupArtifacts.prepare(for: .workBuddy, directory: directory, bridgeURL: bridge)) {
            XCTAssertEqual($0 as? IntegrationSetupArtifacts.PreparationError, .unsafePath)
        }
        XCTAssertEqual(try String(contentsOf: target), "untouched")
    }

    func testUnsupportedSourceDoesNotCreatePreparationDirectories() throws {
        let directory = try root().appendingPathComponent("absent")
        XCTAssertThrowsError(try IntegrationSetupArtifacts.prepare(for: .codex, directory: directory, bridgeURL: bridge)) {
            XCTAssertEqual($0 as? IntegrationSetupArtifacts.PreparationError, .unsupportedAgent)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
