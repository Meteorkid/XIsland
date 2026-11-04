import XCTest
@testable import XIsland

/// JSONC 最小编辑：只替换顶层 hooks，其余字节（含注释）原样保留。
final class JSONTextSurgeryTests: XCTestCase {

    // MARK: 注释检测

    func testDetectsLineAndBlockComments() {
        XCTAssertTrue(JSONTextSurgery.containsComments("{\n  // note\n  \"a\": 1\n}"))
        XCTAssertTrue(JSONTextSurgery.containsComments("{ /* note */ \"a\": 1 }"))
    }

    func testCommentMarkersInsideStringsAreNotComments() {
        XCTAssertFalse(JSONTextSurgery.containsComments("{\"url\": \"https://example.com/a/b\"}"))
        XCTAssertFalse(JSONTextSurgery.containsComments("{\"note\": \"/* not a comment */\"}"))
    }

    func testStrippingKeepsStringContentsIntact() {
        let source = "{\n  // drop me\n  \"url\": \"https://x/y\", /* and me */\n  \"v\": 1\n}"
        let stripped = JSONTextSurgery.strippingComments(source)
        XCTAssertFalse(stripped.contains("drop me"))
        XCTAssertFalse(stripped.contains("and me"))
        XCTAssertTrue(stripped.contains("\"https://x/y\""))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(stripped.utf8)))
    }

    // MARK: 顶层替换

    func testReplacesValueAndKeepsSurroundingBytes() {
        let source = "{\n  // keep this line\n  \"hooks\": {\"A\": 1},\n  \"model\": \"opus\"\n}"
        let out = JSONTextSurgery.replaceTopLevelValue(in: source, key: "hooks", with: "{\"B\":2}")
        let unwrapped = try? XCTUnwrap(out)
        XCTAssertNotNil(unwrapped)
        XCTAssertTrue(unwrapped!.contains("// keep this line"))
        XCTAssertTrue(unwrapped!.contains("\"hooks\": {\"B\":2}"))
        XCTAssertTrue(unwrapped!.contains("\"model\": \"opus\""))
    }

    func testDoesNotTouchNestedKeyWithSameName() {
        // 嵌套对象里的 hooks 不能被当成顶层键。
        let source = "{\"outer\": {\"hooks\": 1}, \"hooks\": 2}"
        let out = JSONTextSurgery.replaceTopLevelValue(in: source, key: "hooks", with: "3")
        let unwrapped = try? XCTUnwrap(out)
        XCTAssertEqual(unwrapped, "{\"outer\": {\"hooks\": 1}, \"hooks\": 3}")
    }

    func testHandlesBracesInsideStringValues() {
        let source = "{\"a\": \"}}}{\", \"hooks\": 0}"
        let out = JSONTextSurgery.replaceTopLevelValue(in: source, key: "hooks", with: "1")
        XCTAssertEqual(out, "{\"a\": \"}}}{\", \"hooks\": 1}")
    }

    func testReturnsNilWhenKeyMissing() {
        XCTAssertNil(JSONTextSurgery.replaceTopLevelValue(in: "{\"a\": 1}", key: "hooks", with: "2"))
    }

    func testReturnsNilOnMalformedInput() {
        XCTAssertNil(JSONTextSurgery.replaceTopLevelValue(in: "[1,2,3]", key: "hooks", with: "2"))
        XCTAssertNil(JSONTextSurgery.replaceTopLevelValue(in: "not json", key: "hooks", with: "2"))
    }
}
