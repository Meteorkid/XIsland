import AppKit
import SwiftUI
import XCTest
@testable import XIsland

@MainActor
final class PermissionDiffPreviewRenderTests: XCTestCase {
    func testRendersEditPreview() throws {
        let raw = #"{"file_path":"/tmp/Example.swift","old_string":"let a = 1\nlet b = 2","new_string":"let a = 3\nlet b = 2"}"#
        let preview = try XCTUnwrap(PermissionDiffPreview.make(
            tool: "Edit", filePath: nil, toolInput: raw))
        let view = PermissionDiffPreviewView(preview: preview, expanded: true,
                                            scheme: .dark, requestID: UUID())
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 220)
        host.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 420)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 220)
    }
}
