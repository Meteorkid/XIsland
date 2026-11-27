import Foundation
import XCTest
@testable import XIsland

final class KiloPluginConfigurationTests: XCTestCase {
    private let bridge = "/Users/test/.xisland/bin/di-bridge"

    func testPluginURLFollowsKiloConfigRoot() {
        XCTAssertEqual(
            KiloPluginConfiguration.pluginURL(homeDirectory: "/Users/test", environment: [:]).path,
            "/Users/test/.config/kilo/plugin/xisland.js"
        )
        XCTAssertEqual(
            KiloPluginConfiguration.pluginURL(homeDirectory: "/Users/test",
                                              environment: ["XDG_CONFIG_HOME": "/tmp/custom"]).path,
            "/tmp/custom/kilo/plugin/xisland.js"
        )
        // 相对路径的 XDG_CONFIG_HOME 不能把插件写到进程工作目录。
        XCTAssertEqual(
            KiloPluginConfiguration.pluginURL(homeDirectory: "/Users/test",
                                              environment: ["XDG_CONFIG_HOME": "relative"]).path,
            "/Users/test/.config/kilo/plugin/xisland.js"
        )
    }

    func testSourceIsObservationOnlyAndUsesTheNativePluginShape() throws {
        let source = try KiloPluginConfiguration.source(bridgePath: bridge)
        let bridgeLine = try XCTUnwrap(source.components(separatedBy: "\n").first { $0.hasPrefix("const BRIDGE = ") })
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(bridgeLine.dropFirst("const BRIDGE = ".count).dropLast().utf8)), bridge)
        XCTAssertTrue(source.contains("export default"))
        XCTAssertTrue(source.contains("id: \"xisland\""))
        XCTAssertTrue(source.contains("server:"))
        XCTAssertTrue(source.contains("--agent"))
        XCTAssertTrue(source.contains("kilo_code"))
        XCTAssertTrue(source.contains("kilo_plugin"))
        XCTAssertTrue(source.contains("tool.execute.before"))
        XCTAssertTrue(source.contains("tool.execute.after"))
        XCTAssertTrue(source.contains("chat.message"))
        XCTAssertTrue(source.contains("permission.asked"))
        XCTAssertTrue(source.contains("status.update"))
        // 只观察：不声明权限决定 hook，也不代替用户回复。
        XCTAssertFalse(source.contains("\"permission.ask\":"))
        XCTAssertFalse(source.contains("client.permission.reply"))
        XCTAssertFalse(source.contains("\"question.answered\""))
    }

    func testOwnedSourceRequiresExactTemplateForTheSameBridge() throws {
        let source = try KiloPluginConfiguration.source(bridgePath: bridge)
        XCTAssertTrue(KiloPluginConfiguration.isOwnedSource(source))
        XCTAssertFalse(KiloPluginConfiguration.isOwnedSource(source + "\n// user edit"))
        XCTAssertFalse(KiloPluginConfiguration.isOwnedSource(source.replacingOccurrences(of: "kilo_plugin", with: "other")))
    }

    func testGeneratedPluginParsesAsAnESModule() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-kilo-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("xisland.mjs")
        try KiloPluginConfiguration.source(bridgePath: bridge).write(to: file, atomically: true, encoding: .utf8)
        let node = Process()
        node.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        node.arguments = ["node", "--check", file.path]
        let error = Pipe()
        node.standardError = error
        node.standardOutput = Pipe()
        do { try node.run() } catch { throw XCTSkip("node is unavailable") }
        node.waitUntilExit()
        let message = String(decoding: (try? error.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
        XCTAssertEqual(node.terminationStatus, 0, message)
    }

    func testRejectsRelativeAndControlCharacterBridgePaths() {
        XCTAssertThrowsError(try KiloPluginConfiguration.source(bridgePath: "relative/di-bridge"))
        XCTAssertThrowsError(try KiloPluginConfiguration.source(bridgePath: "/tmp/di\u{0}-bridge"))
    }
}
