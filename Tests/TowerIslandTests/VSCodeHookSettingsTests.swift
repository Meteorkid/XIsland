import XCTest
@testable import XIsland

final class VSCodeHookSettingsTests: XCTestCase {
    private let path = "~/.xisland/hooks/vscode-local.json"

    func testRegistersMissingSettingWithoutChangingOriginalText() throws {
        let source = "// 中文说明\r\n{\r\n\t\"editor.fontSize\": 14, // ] }\r\n\t\"nested\": {\"array\": [1, true, null,],},\r\n}\r\n"
        let expected = "// 中文说明\r\n{\r\n\t\"chat.hookFilesLocations\": {\"\(path)\": true}," + String(source.dropFirst("// 中文说明\r\n{".count))
        let registered = try VSCodeHookSettings.registering(in: source, hookPath: path)
        XCTAssertEqual(registered, expected)
        XCTAssertTrue(VSCodeHookSettings.isRegistered(in: registered, hookPath: path))
        XCTAssertEqual(try VSCodeHookSettings.registering(in: registered, hookPath: path), registered)
        XCTAssertFalse(registered.contains("chat.useHooks"))
    }

    func testRegistersInsideExistingMapAndPreservesOtherPaths() throws {
        let source = "{\"chat.hookFilesLocations\": { /* keep { } */ \"~/其他.json\": false,}, \"keep\": true}"
        let expected = "{\"chat.hookFilesLocations\": {\"\(path)\": true, /* keep { } */ \"~/其他.json\": false,}, \"keep\": true}"
        XCTAssertEqual(try VSCodeHookSettings.registering(in: source, hookPath: path), expected)
    }

    func testEmptyMapsAndMultilineCommentsRemainValid() throws {
        for source in ["{}", "{\"chat.hookFilesLocations\": {}}", "{\r\n// 注释\r\n}", "{\"chat.hookFilesLocations\": {\n/* ] } */\n}}"] {
            let result = try VSCodeHookSettings.registering(in: source, hookPath: path)
            XCTAssertTrue(VSCodeHookSettings.isRegistered(in: result, hookPath: path), source)
        }
    }

    func testAlreadyEnabledIsByteForByteIdempotent() throws {
        let source = "/* } */ {\"chat.hookFilesLocations\": { \"\(path)\" /* a */ : /* b */ true, },}\r\n"
        XCTAssertEqual(try VSCodeHookSettings.registering(in: source, hookPath: path), source)
    }

    func testExplicitDisableIsAConflict() {
        let source = "{\"chat.hookFilesLocations\": {\"\(path)\": false}}"
        XCTAssertThrowsError(try VSCodeHookSettings.registering(in: source, hookPath: path)) {
            XCTAssertEqual($0 as? VSCodeHookSettings.ConfigurationError, .userDisabled(self.path))
        }
        XCTAssertFalse(VSCodeHookSettings.isRegistered(in: source, hookPath: path))
    }

    func testDecodedEscapedKeysAreMatched() throws {
        let source = #"{"chat\u002ehookFilesLocations":{"~\/.xisland\/hooks\/vscode-local.json":true},"text":"quote: \" slash: \\ /* } ] */"}"#
        XCTAssertTrue(VSCodeHookSettings.isRegistered(in: source, hookPath: path))
        XCTAssertEqual(try VSCodeHookSettings.registering(in: source, hookPath: path), source)
        let removed = try VSCodeHookSettings.removing(from: source, hookPath: path)
        XCTAssertEqual(removed, #"{"chat\u002ehookFilesLocations":{},"text":"quote: \" slash: \\ /* } ] */"}"#)
    }

    func testInsertedPathIsCorrectlyEscaped() throws {
        let unusualPath = "~/中文/quote\"\\tab\t.json"
        let result = try VSCodeHookSettings.registering(in: "{}", hookPath: unusualPath)
        XCTAssertTrue(VSCodeHookSettings.isRegistered(in: result, hookPath: unusualPath))
        XCTAssertEqual(try VSCodeHookSettings.removing(from: result, hookPath: unusualPath), "{\"chat.hookFilesLocations\": { }}")
    }

    func testOnlyRootSettingIsModified() throws {
        let source = "{\"nested\":{\"chat.hookFilesLocations\":{\"\(path)\":false}}}"
        let result = try VSCodeHookSettings.registering(in: source, hookPath: path)
        XCTAssertEqual(result, "{\"chat.hookFilesLocations\": {\"\(path)\": true}," + source.dropFirst())
        XCTAssertTrue(VSCodeHookSettings.isRegistered(in: result, hookPath: path))
    }

    func testRemovalPreservesAllCommentsAndWhitespaceAroundTokens() throws {
        let source = "{\"chat.hookFilesLocations\": {\r\n  /* before */ \"\(path)\" /* key */ : /* value */ true /* after */,\r\n  \"~/other.json\": false,\r\n}, \"中文\": [1, 2,]}"
        let expected = "{\"chat.hookFilesLocations\": {\r\n  /* before */  /* key */  /* value */  /* after */\r\n  \"~/other.json\": false,\r\n}, \"中文\": [1, 2,]}"
        XCTAssertEqual(try VSCodeHookSettings.removing(from: source, hookPath: path), expected)
        XCTAssertEqual(try VSCodeHookSettings.removing(from: expected, hookPath: path), expected)
    }

    func testRemovesFirstMiddleAndLastEntriesWithOrWithoutTrailingComma() throws {
        let target = "\"\(path)\":true"
        let cases = [
            (target, ""),
            (target + ",", ""),
            (target + ",\"a\":false", "\"a\":false"),
            ("\"a\":true," + target + ",\"b\":false", "\"a\":true,\"b\":false"),
            ("\"a\":true," + target, "\"a\":true"),
            ("\"a\":true," + target + ",", "\"a\":true,"),
        ]
        for (contents, expected) in cases {
            let source = "{\"chat.hookFilesLocations\":{\(contents)}}"
            let result = try VSCodeHookSettings.removing(from: source, hookPath: path)
            XCTAssertEqual(result, "{\"chat.hookFilesLocations\":{\(expected)}}")
            XCTAssertFalse(VSCodeHookSettings.isRegistered(in: result, hookPath: path))
            XCTAssertTrue(VSCodeHookSettings.isRegistered(in: try VSCodeHookSettings.registering(in: result, hookPath: path), hookPath: path))
        }
    }

    func testRemovalOfAbsentPathPreservesOriginal() throws {
        for source in ["{ }", "{\"chat.hookFilesLocations\":{\"~/other\":false,}}"] {
            XCTAssertEqual(try VSCodeHookSettings.removing(from: source, hookPath: path), source)
        }
    }

    func testRejectsDuplicateKeysIncludingDecodedAndNestedKeys() {
        let sources = [
            #"{"chat.hookFilesLocations":{},"chat.hookFilesLocations":{}}"#,
            #"{"chat.hookFilesLocations":{"same":true,"\u0073ame":false}}"#,
            #"{"nested":[{"same":1,"same":2}]}"#,
        ]
        for source in sources {
            XCTAssertThrowsError(try VSCodeHookSettings.registering(in: source, hookPath: path)) {
                guard case .duplicateKey = $0 as? VSCodeHookSettings.ConfigurationError else { return XCTFail("\($0)") }
            }
            XCTAssertThrowsError(try VSCodeHookSettings.removing(from: source, hookPath: path))
            XCTAssertFalse(VSCodeHookSettings.isRegistered(in: source, hookPath: path))
        }
    }

    func testRejectsIncorrectSettingAndPathValueTypes() {
        for value in ["[]", "null", "true", "1", "\"text\"", "{\"\(path)\": 1}", "{\"other\": {}}"] {
            let source = "{\"chat.hookFilesLocations\":\(value)}"
            XCTAssertThrowsError(try VSCodeHookSettings.registering(in: source, hookPath: path)) {
                XCTAssertEqual($0 as? VSCodeHookSettings.ConfigurationError, .invalidLocations)
            }
            XCTAssertThrowsError(try VSCodeHookSettings.removing(from: source, hookPath: path))
            XCTAssertFalse(VSCodeHookSettings.isRegistered(in: source, hookPath: path))
        }
    }

    func testRejectsMissingRootObject() {
        for source in ["", "  // comment\n", "[]", "null", "true", "42", "\"text\""] {
            XCTAssertThrowsError(try VSCodeHookSettings.registering(in: source, hookPath: path)) {
                XCTAssertEqual($0 as? VSCodeHookSettings.ConfigurationError, .rootMustBeObject)
            }
            XCTAssertThrowsError(try VSCodeHookSettings.removing(from: source, hookPath: path))
        }
    }

    func testRejectsMalformedJSONCAnywhereInDocument() {
        let sources = ["{", "{,}", "{\"a\":}", "{\"a\":1 \"b\":2}", "{\"a\":[1,,2]}", "{} trailing", "{} {}", "{/* unfinished", "{\"a\":01}", "{\"a\":1.}", "{\"a\":1e+}", "{\"a\":tru}", #"{"a":"\q"}"#, #"{"a":"\uZZZZ"}"#, "{\"a\":\"line\nfeed\"}"]
        for source in sources {
            XCTAssertThrowsError(try VSCodeHookSettings.registering(in: source, hookPath: path), source)
            XCTAssertThrowsError(try VSCodeHookSettings.removing(from: source, hookPath: path), source)
            XCTAssertFalse(VSCodeHookSettings.isRegistered(in: source, hookPath: path), source)
        }
    }
}
