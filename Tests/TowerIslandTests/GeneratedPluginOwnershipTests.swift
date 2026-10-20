import XCTest
@testable import XIsland

final class GeneratedPluginOwnershipTests: XCTestCase {
    private let configurations: [(name: String, source: (String) throws -> String, isOwned: (String) -> Bool)] = [
        ("OpenCode", OpenCodePluginConfiguration.source, OpenCodePluginConfiguration.isOwnedSource),
        ("Amp", AmpPluginConfiguration.source, AmpPluginConfiguration.isOwnedSource),
        ("Pi", PiPluginConfiguration.source, PiPluginConfiguration.isOwnedSource),
    ]

    func testCompleteGeneratedSourcesRemainOwnedAfterBridgeRelocationAndCRLFConversion() throws {
        let paths = ["/old installation/.xisland/bin/di-bridge",
                     "/tmp/O'Brien/\"quoted\"/$(no-exec)`no-exec`\\line\n/di-bridge"]
        for configuration in configurations {
            for path in paths {
                let source = try configuration.source(path)
                XCTAssertTrue(configuration.isOwned(source), "\(configuration.name): \(path)")
                XCTAssertTrue(configuration.isOwned(" \n" + source.replacingOccurrences(of: "\n", with: "\r\n") + "\n\t"),
                              "\(configuration.name): CRLF and outer whitespace")
            }
        }
    }

    func testInstallRepairAndRemovalOwnershipRejectsModifiedMarkedSources() throws {
        for configuration in configurations {
            let source = try configuration.source("/old installation/di-bridge")
            let marker = try XCTUnwrap(source.components(separatedBy: "\n").first)
            let modifiedSources = [
                source.replacingOccurrences(of: "shell: false", with: "shell: true"),
                source + "\nconsole.log(\"user extension\");",
                source + "\n// User customization",
                source.replacingOccurrences(of: "const children =", with: "const userState = 1;\n  const children ="),
                String(source.dropLast()),
                marker + "\nexport default () => {};",
            ]
            // 安装、修复及卸载共用这个认领入口；用户保留标记不代表仍是完整托管文件。
            for modified in modifiedSources {
                XCTAssertNotEqual(modified, source)
                XCTAssertFalse(configuration.isOwned(modified), "\(configuration.name): modified source must be preserved")
                XCTAssertFalse(configuration.isOwned(modified.replacingOccurrences(of: "\n", with: "\r\n")),
                               "\(configuration.name): modified CRLF source must be preserved")
            }
        }
    }

    func testOwnershipRejectsInvalidBridgeDeclarationsWithoutExecutingThem() throws {
        for configuration in configurations {
            let source = try configuration.source("/bin/di-bridge")
            let declaration = try XCTUnwrap(source.components(separatedBy: "\n").first { $0.hasPrefix("const BRIDGE = ") })
            for value in ["null", "42", "\"relative/di-bridge\"", "\"/tmp/di\\u0000bridge\"",
                          "\"/bin/di-bridge\"; console.log(\"custom\")", "getUserBridge()"] {
                let modified = source.replacingOccurrences(of: declaration, with: "const BRIDGE = \(value);")
                XCTAssertFalse(configuration.isOwned(modified), "\(configuration.name): \(value)")
            }
            XCTAssertFalse(configuration.isOwned(source.replacingOccurrences(of: declaration, with: "")), configuration.name)
            XCTAssertFalse(configuration.isOwned(source + "\n" + declaration), configuration.name)
        }
    }
}
