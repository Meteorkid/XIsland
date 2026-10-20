import XCTest
@testable import XIsland

final class HookConfigurationFileTests: XCTestCase {
    func testJSONUpdateRejectsConcurrentContentChange() throws {
        try withDirectory { directory in
            let path = directory.appendingPathComponent("settings.json")
            try Data("{\"custom\":true}".utf8).write(to: path)
            let concurrent = Data("{\"custom\":false,\"parallel\":true}".utf8)

            XCTAssertThrowsError(try HookConfigurationFile.update(at: path) { original in
                try concurrent.write(to: path)
                var updated = original
                updated["hooks"] = [:] as [String: Any]
                return updated
            }) { self.assertConflict($0, at: path) }

            XCTAssertEqual(try Data(contentsOf: path), concurrent)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["settings.json"])
        }
    }

    func testTextUpdateRejectsConcurrentContentChange() throws {
        try withDirectory { directory in
            let path = directory.appendingPathComponent("config.toml")
            try Data("model = 'original'\n".utf8).write(to: path)
            let concurrent = Data("model = 'parallel'\n".utf8)

            XCTAssertThrowsError(try HookConfigurationFile.updateText(at: path) { original in
                try concurrent.write(to: path)
                return original + "# hook\n"
            }) { self.assertConflict($0, at: path) }

            XCTAssertEqual(try Data(contentsOf: path), concurrent)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["config.toml"])
        }
    }

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
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["config.toml", "managed.toml"])
        XCTAssertTrue(try HookConfigurationFile.updateText(at: link) { $0 + "# appended\n" })
        XCTAssertFalse(try HookConfigurationFile.updateText(at: link) { $0 })
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), source + "# appended\n")
        let backups = try backupFiles(in: root)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), Data(source.utf8))
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
        let backups = try backupFiles(in: directory)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), Data("{\"custom\":true}".utf8))
        XCTAssertTrue(try XCTUnwrap(backups.first).lastPathComponent.hasPrefix(".managed-settings.json.xisland-"))
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
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["settings.json"])
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
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["settings.json"])
    }

    func testBothFormatsRejectFileCreatedDuringTransform() throws {
        for format in Format.allCases {
            try withDirectory { directory in
                let path = directory.appendingPathComponent("settings")
                let concurrent = Data("{\"parallel\":true}".utf8)

                XCTAssertThrowsError(try update(at: path, format: format) {
                    try concurrent.write(to: path)
                }) { self.assertConflict($0, at: path) }

                XCTAssertEqual(try Data(contentsOf: path), concurrent)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["settings"])
            }
        }
    }

    func testBothFormatsRejectReplacementWithIdenticalBytes() throws {
        for format in Format.allCases {
            try withDirectory { directory in
                let path = directory.appendingPathComponent("settings")
                let replacement = directory.appendingPathComponent("replacement")
                let bytes = Data("{}".utf8)
                try bytes.write(to: path)
                try bytes.write(to: replacement)
                let replacementIdentity = try FileManager.default.attributesOfItem(atPath: replacement.path)[.systemFileNumber] as? NSNumber

                XCTAssertThrowsError(try update(at: path, format: format) {
                    try FileManager.default.removeItem(at: path)
                    try FileManager.default.moveItem(at: replacement, to: path)
                }) { self.assertConflict($0, at: path) }

                XCTAssertEqual(try Data(contentsOf: path), bytes)
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber] as? NSNumber, replacementIdentity)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["settings"])
            }
        }
    }

    func testBothFormatsRejectSymlinkRedirection() throws {
        for format in Format.allCases {
            try withDirectory { directory in
                let first = directory.appendingPathComponent("first")
                let second = directory.appendingPathComponent("second")
                let link = directory.appendingPathComponent("settings")
                let bytes = Data("{}".utf8)
                try bytes.write(to: first)
                try bytes.write(to: second)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)

                XCTAssertThrowsError(try update(at: link, format: format) {
                    try FileManager.default.removeItem(at: link)
                    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
                }) { self.assertConflict($0, at: link) }

                XCTAssertEqual(try Data(contentsOf: first), bytes)
                XCTAssertEqual(try Data(contentsOf: second), bytes)
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), second.path)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["first", "second", "settings"])
            }
        }
    }

    func testBothFormatsRejectDeletionDuringTransform() throws {
        for format in Format.allCases {
            try withDirectory { directory in
                let path = directory.appendingPathComponent("settings")
                try Data("{}".utf8).write(to: path)
                XCTAssertThrowsError(try update(at: path, format: format) {
                    try FileManager.default.removeItem(at: path)
                }) { self.assertConflict($0, at: path) }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
            }
        }
    }

    func testBothFormatsRejectReplacedSymlinkEvenWithSameTarget() throws {
        for format in Format.allCases {
            try withDirectory { directory in
                let target = directory.appendingPathComponent("target")
                let link = directory.appendingPathComponent("settings")
                let replacement = directory.appendingPathComponent("replacement-link")
                let bytes = Data("{}".utf8)
                try bytes.write(to: target)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
                try FileManager.default.createSymbolicLink(at: replacement, withDestinationURL: target)

                XCTAssertThrowsError(try update(at: link, format: format) {
                    try FileManager.default.removeItem(at: link)
                    try FileManager.default.moveItem(at: replacement, to: link)
                }) { self.assertConflict($0, at: link) }

                XCTAssertEqual(try Data(contentsOf: target), bytes)
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["settings", "target"])
            }
        }
    }

    func testBothFormatsRejectFailedTransformWithoutCreatingDirectory() throws {
        for format in Format.allCases {
            try withDirectory { directory in
                let path = directory.appendingPathComponent("missing/settings")
                XCTAssertThrowsError(try update(at: path, format: format) {
                    throw HookConfigurationFile.ConfigurationError.rootMustBeObject
                })
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
            }
        }
    }

    func testInvalidUTF8AndNonObjectJSONAreNotOverwritten() throws {
        try withDirectory { directory in
            let path = directory.appendingPathComponent("settings")
            for invalidJSON in [Data("[]".utf8), Data()] {
                try invalidJSON.write(to: path)
                XCTAssertThrowsError(try HookConfigurationFile.update(at: path) { _ in ["hooks": true] })
                XCTAssertEqual(try Data(contentsOf: path), invalidJSON)
            }
            let invalidText = Data([0xff, 0xfe, 0xff])
            try invalidText.write(to: path)
            XCTAssertThrowsError(try HookConfigurationFile.updateText(at: path) { _ in "replacement" })
            XCTAssertEqual(try Data(contentsOf: path), invalidText)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["settings"])
        }
    }

    func testSuccessfulUpdatesKeepSeparatePrivateBackupsAndPreservePermissions() throws {
        try withDirectory { directory in
            let path = directory.appendingPathComponent("settings")
            let original = Data("{ \"custom\": true }\n".utf8)
            try original.write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)
            try HookConfigurationFile.update(at: path) { original in
                var updated = original
                updated["hooks"] = true
                return updated
            }
            let firstUpdate = try Data(contentsOf: path)
            try HookConfigurationFile.updateText(at: path) { $0 + "\n" }

            let backups = try backupFiles(in: directory)
            XCTAssertEqual(backups.count, 2)
            XCTAssertEqual(Set(try backups.map { try Data(contentsOf: $0) }), Set([original, firstUpdate]))
            for backup in backups {
                let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
                XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            }
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".tmp") })
        }
    }

    func testUpdatesDoNotReuseExistingBackupOrTemporarySymlinks() throws {
        try withDirectory { directory in
            let path = directory.appendingPathComponent("settings")
            let sentinel = directory.appendingPathComponent("unrelated")
            let previousBackup = directory.appendingPathComponent(".settings.xisland-existing.bak")
            let previousTemporary = directory.appendingPathComponent(".xisland-existing.tmp")
            let original = Data("{}".utf8)
            let unrelated = Data("private unrelated content".utf8)
            try original.write(to: path)
            try unrelated.write(to: sentinel)
            try FileManager.default.createSymbolicLink(at: previousBackup, withDestinationURL: sentinel)
            try FileManager.default.createSymbolicLink(at: previousTemporary, withDestinationURL: sentinel)

            XCTAssertTrue(try HookConfigurationFile.update(at: path) { _ in ["hooks": true] })

            XCTAssertEqual(try Data(contentsOf: sentinel), unrelated)
            for symlink in [previousBackup, previousTemporary] {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path), sentinel.path)
            }
            let createdBackups = try backupFiles(in: directory).filter { $0.lastPathComponent != previousBackup.lastPathComponent }
            XCTAssertEqual(createdBackups.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(createdBackups.first)), original)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: XCTUnwrap(createdBackups.first).path)[.type] as? FileAttributeType, .typeRegular)
        }
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

    private func withDirectory(_ test: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try test(directory)
    }

    private enum Format: CaseIterable { case json, text }

    private func update(at url: URL, format: Format, duringTransform: () throws -> Void) throws {
        switch format {
        case .json:
            try HookConfigurationFile.update(at: url) { original in
                try duringTransform()
                var updated = original
                updated["hooks"] = true
                return updated
            }
        case .text:
            try HookConfigurationFile.updateText(at: url) { original in
                try duringTransform()
                return original + "\n# hook\n"
            }
        }
    }

    private func assertConflict(_ error: Error, at url: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(error as? HookConfigurationFile.ConfigurationError, .configurationChanged(url.path), file: file, line: line)
    }

    private func backupFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".xisland-") && $0.pathExtension == "bak" }
    }
}
