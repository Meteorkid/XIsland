import XCTest
@testable import XIsland

final class PermissionInputEditingTests: XCTestCase {
    func testOnlyBashExposesCommandEditor() {
        XCTAssertEqual(PermissionInputEditing.command(
            tool: "Bash", toolInput: #"{"command":"npm test","description":"run tests"}"#),
                       "npm test")
        XCTAssertNil(PermissionInputEditing.command(
            tool: "Write", toolInput: #"{"file_path":"/tmp/a"}"#))
    }

    func testReplacingCommandPreservesSiblingFields() throws {
        let edited = try XCTUnwrap(PermissionInputEditing.replacingCommand(
            toolInput: #"{"command":"rm -rf build","description":"clean up","timeout":120}"#,
            command: "npm run lint"))
        let object = try XCTUnwrap(PermissionInputEditing.parsedObject(edited))
        XCTAssertEqual(object["command"] as? String, "npm run lint")
        XCTAssertEqual(object["description"] as? String, "clean up")
        XCTAssertEqual(object["timeout"] as? Int, 120)
    }

    func testMalformedInputNeverPretendsToBeEditable() {
        XCTAssertNil(PermissionInputEditing.parsedObject(#"["not","an","object"]"#))
        XCTAssertNil(PermissionInputEditing.parsedObject(#"{"command":"#))
        XCTAssertNil(PermissionInputEditing.replacingCommand(toolInput: "not-json", command: "ls"))
    }

    func testPrettyJSONDoesNotChangeSemantics() throws {
        let pretty = PermissionInputEditing.prettyJSON(
            toolInput: #"{"command":"npm test","timeout":30}"#)
        let object = try XCTUnwrap(PermissionInputEditing.parsedObject(pretty))
        XCTAssertEqual(object["command"] as? String, "npm test")
        XCTAssertEqual(object["timeout"] as? Int, 30)
    }

    func testSessionCommandRejectsWildcardAndNewline() {
        XCTAssertEqual(PermissionInputEditing.exactBashCommand(
            toolInput: #"{"command":"npm test"}"#), "npm test")
        XCTAssertNil(PermissionInputEditing.exactBashCommand(
            toolInput: #"{"command":"rm -rf *"}"#))
        XCTAssertNil(PermissionInputEditing.exactBashCommand(
            toolInput: #"{"command":"echo hi\nrm -rf build"}"#))
        XCTAssertNil(PermissionInputEditing.exactBashCommand(toolInput: nil))
    }
}
