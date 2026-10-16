import XCTest
@testable import XIsland

final class VSCodeHookInstallationTests: XCTestCase {
    func testInstallRegistersExistingProfilesAndLeavesOtherSettingsAndCLIAlone() throws {
        try withHome { home in
            let files = FileManager.default
            let root = home.appendingPathComponent("Library/Application Support/Code/User")
            let profile = root.appendingPathComponent("profiles/work/settings.json")
            try files.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = "{\r\n // 保留注释\r\n \"chat.useHooks\": false,\r\n \"editor.fontSize\": 15,\r\n}\r\n"
            try original.write(to: root.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
            try "{\"profile\":true}".write(to: profile, atomically: true, encoding: .utf8)
            let bridge = home.appendingPathComponent(".xisland/bin/di-bridge").path
            try VSCodeHookInstallation.install(homeDirectory: home.path, bridgePath: bridge)
            XCTAssertTrue(VSCodeHookInstallation.isConfigured(homeDirectory: home.path, bridgePath: bridge))
            XCTAssertFalse(VSCodeHookInstallation.shouldRepair(homeDirectory: home.path, bridgePath: bridge))
            XCTAssertFalse(files.fileExists(atPath: home.appendingPathComponent(".copilot").path))
            let text = try String(contentsOf: root.appendingPathComponent("settings.json"), encoding: .utf8)
            XCTAssertTrue(text.contains("// 保留注释\r\n \"chat.useHooks\": false"))
            XCTAssertTrue(text.contains("\"editor.fontSize\": 15,"))
            try VSCodeHookInstallation.install(homeDirectory: home.path, bridgePath: bridge)
            XCTAssertEqual(text, try String(contentsOf: root.appendingPathComponent("settings.json"), encoding: .utf8))
            try VSCodeHookInstallation.remove(homeDirectory: home.path)
            XCTAssertFalse(VSCodeHookInstallation.isConfigured(homeDirectory: home.path, bridgePath: bridge))
            XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("settings.json"), encoding: .utf8).contains("\"chat.useHooks\": false"))
        }
    }

    func testPreflightRejectsDisabledOrBrokenProfileWithoutCreatingHooks() throws {
        for content in ["", "broken", "{\"chat.hookFilesLocations\":{\"~/.xisland/hooks/vscode-local.json\":false}}"] {
            try withHome { home in
                let root = home.appendingPathComponent("Library/Application Support/Code/User")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let settings = root.appendingPathComponent("settings.json")
                try content.write(to: settings, atomically: true, encoding: .utf8)
                XCTAssertThrowsError(try VSCodeHookInstallation.install(homeDirectory: home.path, bridgePath: "/bin/di-bridge"))
                XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), content)
                XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(VSCodeHookConfiguration.relativeConfigPath).path))
            }
        }
    }

    func testAbsentUserDirectoryIsNotCreatedAndExistingDirectoryCanGetNewSettings() throws {
        try withHome { home in
            try VSCodeHookInstallation.install(homeDirectory: home.path, bridgePath: "/bin/di-bridge")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
            let root = home.appendingPathComponent("Library/Application Support/Code - Insiders/User")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try VSCodeHookInstallation.install(homeDirectory: home.path, bridgePath: "/bin/di-bridge")
            XCTAssertTrue(VSCodeHookInstallation.isConfigured(homeDirectory: home.path, bridgePath: "/bin/di-bridge"))
        }
    }

    private func withHome(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("xi-vscode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }
}
