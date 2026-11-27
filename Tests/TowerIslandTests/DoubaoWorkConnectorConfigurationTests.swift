import XCTest
@testable import XIsland

final class DoubaoWorkConnectorConfigurationTests: XCTestCase {
    func testFilesDescribeStdioConnectorWithoutCredentials() throws {
        let files = try DoubaoWorkConnectorConfiguration.files(bridgePath: "/Users/test/.xisland/bin/di-bridge")
        XCTAssertEqual(Set(files.keys), [DoubaoWorkConnectorConfiguration.connectorFileName,
                                        DoubaoWorkConnectorConfiguration.readmeFileName])

        let connectorData = try XCTUnwrap(files[DoubaoWorkConnectorConfiguration.connectorFileName])
        let connector = try XCTUnwrap(JSONSerialization.jsonObject(with: connectorData) as? [String: Any])
        XCTAssertEqual(connector["transport"] as? String, "stdio")
        XCTAssertEqual(connector["command"] as? String, "/Users/test/.xisland/bin/di-bridge")
        XCTAssertEqual(connector["args"] as? [String], ["doubao-work-mcp"])
        XCTAssertNil(connector["token"])
        XCTAssertNil(connector["apiKey"])

        let readme = try XCTUnwrap(files[DoubaoWorkConnectorConfiguration.readmeFileName])
        let text = String(decoding: readme, as: UTF8.self)
        XCTAssertTrue(text.contains("本地电脑"))
        XCTAssertTrue(text.contains("doubao-work-mcp"))
        XCTAssertTrue(text.contains("不推断任务完成"))
    }

    func testRelativeBridgePathIsRejected() {
        XCTAssertThrowsError(try DoubaoWorkConnectorConfiguration.files(bridgePath: "bin/di-bridge"))
        XCTAssertThrowsError(try DoubaoWorkConnectorConfiguration.files(bridgePath: "/bin/di\u{0}-bridge"))
    }

    func testSetupArtifactsPrepareConnectorFiles() throws {
        // Foundation 会把 /private/var 重新简化为 /var；先取 realpath 再建目录，避免被符号链接守卫拒绝。
        let pointer = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(pointer) }
        let directory = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
            .appendingPathComponent("xisland-doubao-artifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prepared = try IntegrationSetupArtifacts.prepare(
            for: .doubaoWork, directory: directory,
            bridgeURL: URL(fileURLWithPath: "/Users/test/.xisland/bin/di-bridge")
        )
        let names = try FileManager.default.contentsOfDirectory(atPath: prepared.path).sorted()
        XCTAssertEqual(names, [DoubaoWorkConnectorConfiguration.readmeFileName,
                               DoubaoWorkConnectorConfiguration.connectorFileName])
    }
}
