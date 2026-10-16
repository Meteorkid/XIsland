import XCTest
@testable import DIBridge

final class WorkBuddyPluginExportTests: XCTestCase {
    func testExportContainsOnlyVerifiedObservationEventsAndQuotedBridgePath() throws {
        let bridge = "/tmp/O'Brien/bridge $(literal)"
        let files = try WorkBuddyPluginExport.files(bridgePath: bridge)
        let marketplace = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(files[".codebuddy-plugin/marketplace.json"])) as? [String: Any])
        let plugin = try XCTUnwrap((marketplace["plugins"] as? [[String: Any]])?.first)
        XCTAssertEqual(plugin["source"] as? String, "./")
        XCTAssertEqual(plugin["name"] as? String, "xisland-workbuddy-observer")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(files["hooks/hooks.json"])) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(Set(hooks.keys), Set(WorkBuddyPluginExport.events))
        XCTAssertNil(hooks["PermissionRequest"])
        for (event, groups) in hooks {
            let entry = try XCTUnwrap((groups.first?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(entry["command"] as? String, AiderLauncher.shellQuote(bridge) + " --agent workbuddy --adapter workbuddy_5_7_6 --hook " + event)
            XCTAssertEqual(entry["timeout"] as? Int, 3)
        }
    }

    func testExportDoesNotOverwriteExistingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-workbuddy-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("plugin")
        try WorkBuddyPluginExport.write(to: destination, bridgePath: "/tmp/bridge")
        let original = try Data(contentsOf: destination.appendingPathComponent("hooks/hooks.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".codebuddy-plugin/marketplace.json").path))
        XCTAssertThrowsError(try WorkBuddyPluginExport.write(to: destination, bridgePath: "/tmp/other"))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("hooks/hooks.json")), original)
        XCTAssertThrowsError(try WorkBuddyPluginExport.files(bridgePath: "relative"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("absent"))
        XCTAssertThrowsError(try WorkBuddyPluginExport.write(to: link, bridgePath: "/tmp/bridge"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), root.appendingPathComponent("absent").path)
    }
}
