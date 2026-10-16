import XCTest
@testable import XIsland

final class DeepSeekHookInstallationTests: XCTestCase {
    func testVersionGateAcceptsOnlyAuditedReleaseOutput() {
        for version in ["codewhale 0.10.0", "codewhale 0.10.0 (1be1a703b975)\n"] {
            XCTAssertTrue(DeepSeekHookInstallation.isSupportedVersionOutput(version))
        }
        for version in ["deepseek 0.10.0", "codewhale 0.10.1", "codewhale 0.10.0 (dev)",
                        "codewhale 0.10.0 (abcdef123456)", "codewhale 0.10.0\nextra", ""] {
            XCTAssertFalse(DeepSeekHookInstallation.isSupportedVersionOutput(version))
        }
    }

    func testAuditedClientUsesExistingLegacyConfigWithoutShadowingIt() throws {
        try withDirectory { root in
            let binary = try fixtureCLI(at: root, body: "printf '%s\\n' 'codewhale 0.10.0 (1be1a703b975)'")
            let config = root.appendingPathComponent(".deepseek/config.toml")
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = "# keep\nmodel = 'fixture'\n[hooks]\nenabled = true\n"
            try original.write(to: config, atomically: true, encoding: .utf8)
            let environment = ["PATH": binary.deletingLastPathComponent().path]
            XCTAssertTrue(try DeepSeekHookInstallation.install(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: environment))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".codewhale").path))
            XCTAssertTrue(DeepSeekHookInstallation.isConfigured(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: environment))
            try DeepSeekHookInstallation.remove(homeDirectory: root.path, environment: environment)
            XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
        }
    }

    func testUnverifiedVersionAndDisabledHooksNeverWriteConfiguration() throws {
        try withDirectory { root in
            let binary = try fixtureCLI(at: root, body: "printf '%s\\n' 'codewhale 0.9.0'")
            let environment = ["PATH": binary.deletingLastPathComponent().path]
            XCTAssertFalse(try DeepSeekHookInstallation.install(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: environment))
            let config = root.appendingPathComponent(".codewhale/config.toml")
            XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
            _ = try fixtureCLI(at: root, body: "printf '%s\\n' 'codewhale 0.10.0'")
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = "[hooks]\nenabled = false\n"
            try original.write(to: config, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try DeepSeekHookInstallation.install(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: environment))
            XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
            XCTAssertFalse(DeepSeekHookInstallation.shouldRepair(homeDirectory: root.path, bridgePath: "/bin/di-bridge", environment: environment))
        }
    }

    func testProbeIsBoundedAndRequiresSuccessfulVersionCommand() throws {
        try withDirectory { root in
            let binary = try fixtureCLI(at: root, body: "exit 7")
            XCTAssertNil(DeepSeekHookInstallation.versionOutput(at: binary, environment: [:]))
            _ = try fixtureCLI(at: root, body: "exec /bin/sleep 5")
            let start = Date()
            XCTAssertNil(DeepSeekHookInstallation.versionOutput(at: binary, environment: [:], timeout: 0.03))
            XCTAssertLessThan(Date().timeIntervalSince(start), 1)
            _ = try fixtureCLI(at: root, body: "[ \"$#\" = 1 ] && [ \"$1\" = --version ] || exit 9\nprintf '%s\\n' 'codewhale 0.10.0'")
            XCTAssertEqual(DeepSeekHookInstallation.versionOutput(at: binary, environment: [:]), "codewhale 0.10.0\n")
        }
    }

    private func fixtureCLI(at root: URL, body: String) throws -> URL {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let path = bin.appendingPathComponent("codewhale")
        try ("#!/bin/sh\n[ \"$1\" = --fixture-ready ] && exit 0\n" + body + "\n").write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        // 新建脚本的首次 exec 本机实测约400ms，不属于版本协议的处理耗时。
        // 先确认离线替身可执行，产品本身的500ms上限及超时用例均保持。
        let readiness = Process()
        readiness.executableURL = path
        readiness.arguments = ["--fixture-ready"]
        readiness.standardInput = FileHandle.nullDevice
        readiness.standardOutput = FileHandle.nullDevice
        readiness.standardError = FileHandle.nullDevice
        try readiness.run()
        readiness.waitUntilExit()
        XCTAssertEqual(readiness.terminationStatus, 0)
        return path
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xi-codewhale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
