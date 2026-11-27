import Foundation
import XCTest
@testable import XIsland

final class PermissionDiffPreviewTests: XCTestCase {
    func testEditPreviewShowsRemovedAndAddedLines() throws {
        let raw = #"{"file_path":"/tmp/Example.swift","old_string":"let a = 1\nlet b = 2","new_string":"let a = 3\nlet b = 2","replace_all":true}"#
        let preview = try XCTUnwrap(PermissionDiffPreview.make(
            tool: "Edit", filePath: nil, toolInput: raw))

        XCTAssertEqual(preview.kind, .edit)
        XCTAssertEqual(preview.filePath, "/tmp/Example.swift")
        XCTAssertEqual(preview.hunks.count, 1)
        XCTAssertEqual(preview.hunks[0].oldLines, ["let a = 1", "let b = 2"])
        XCTAssertEqual(preview.hunks[0].newLines, ["let a = 3", "let b = 2"])
        XCTAssertTrue(preview.hunks[0].replaceAll)
        XCTAssertEqual(preview.removedLineCount, 2)
        XCTAssertEqual(preview.addedLineCount, 2)
        XCTAssertFalse(preview.isTruncated)
    }

    func testWritePreviewLimitsDisplayedLines() throws {
        let content = (1...50).map { "line \($0)" }.joined(separator: "\n")
        let raw = try json(["file_path": "/tmp/Large.txt", "content": content])
        let preview = try XCTUnwrap(PermissionDiffPreview.make(
            tool: "Write", filePath: nil, toolInput: raw))

        XCTAssertEqual(preview.kind, .write)
        XCTAssertEqual(preview.addedLineCount, 50)
        XCTAssertEqual(preview.hunks[0].newLineCount, 50)
        XCTAssertEqual(preview.hunks[0].newLines.count, PermissionDiffPreview.maxLinesPerSide)
        XCTAssertTrue(preview.isTruncated)
    }

    func testMultiEditKeepsOrderAndPerEditReplaceAll() throws {
        let raw = try json([
            "file_path": "/tmp/Multi.swift",
            "edits": [
                ["old_string": "first", "new_string": "FIRST"],
                ["old_string": "second", "new_string": "SECOND", "replace_all": true]
            ]
        ])
        let preview = try XCTUnwrap(PermissionDiffPreview.make(
            tool: "MultiEdit", filePath: nil, toolInput: raw))

        XCTAssertEqual(preview.kind, .multiEdit)
        XCTAssertEqual(preview.hunks.count, 2)
        XCTAssertEqual(preview.hunks[0].oldLines, ["first"])
        XCTAssertEqual(preview.hunks[1].newLines, ["SECOND"])
        XCTAssertFalse(preview.hunks[0].replaceAll)
        XCTAssertTrue(preview.hunks[1].replaceAll)
    }

    func testNotebookEditShowsNewSource() throws {
        let raw = try json([
            "notebook_path": "/tmp/Notebook.ipynb",
            "new_source": "print(1)\nprint(2)",
            "edit_mode": "replace"
        ])
        let preview = try XCTUnwrap(PermissionDiffPreview.make(
            tool: "NotebookEdit", filePath: nil, toolInput: raw))

        XCTAssertEqual(preview.kind, .notebook)
        XCTAssertEqual(preview.filePath, "/tmp/Notebook.ipynb")
        XCTAssertEqual(preview.notebookMode, "replace")
        XCTAssertEqual(preview.hunks[0].newLines, ["print(1)", "print(2)"])
        XCTAssertEqual(preview.addedLineCount, 2)
    }

    func testLongLineAndOversizedInputAreBounded() throws {
        let longLine = String(repeating: "a", count: PermissionDiffPreview.maxLineCharacters + 10)
        let raw = try json(["file_path": "/tmp/Long.txt", "content": longLine])
        let preview = try XCTUnwrap(PermissionDiffPreview.make(
            tool: "Write", filePath: nil, toolInput: raw))
        XCTAssertEqual(preview.truncatedLineCount, 1)
        XCTAssertTrue(preview.isTruncated)
        let first = try XCTUnwrap(preview.hunks.first?.newLines.first)
        XCTAssertTrue(first.hasSuffix("…"))

        let oversized = try json([
            "file_path": "/tmp/Huge.txt",
            "content": String(repeating: "x", count: PermissionDiffPreview.maxInputBytes + 1)
        ])
        XCTAssertNil(PermissionDiffPreview.make(
            tool: "Write", filePath: nil, toolInput: oversized))
    }

    func testInvalidInputsAndUnsupportedToolsReturnNil() throws {
        XCTAssertNil(PermissionDiffPreview.make(
            tool: "Bash", filePath: "/tmp/a", toolInput: #"{"command":"npm test"}"#))
        XCTAssertNil(PermissionDiffPreview.make(
            tool: "Edit", filePath: nil,
            toolInput: #"{"file_path":"/tmp/a","old_string":"a"}"#))
        XCTAssertNil(PermissionDiffPreview.make(
            tool: "Edit", filePath: nil,
            toolInput: #"{"file_path":"/tmp/a","old_string":"a\u0000","new_string":"b"}"#))
        XCTAssertNil(PermissionDiffPreview.make(
            tool: "Write", filePath: "/tmp/a\nb", toolInput: #"{"content":"x"}"#))
        XCTAssertNil(PermissionDiffPreview.make(
            tool: "Write", filePath: nil, toolInput: "not-json"))
    }

    private func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
