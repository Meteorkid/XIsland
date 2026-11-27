import AppKit
import SwiftUI
import XCTest
@testable import XIsland

@MainActor
final class ApprovalHistoryPaneRenderTests: XCTestCase {
    func testRendersDecisionsAndChainStatus() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xisland-approval-history-render-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ApprovalAuditStore(url: directory.appendingPathComponent("audit.jsonl"))
        _ = store.append(sessionID: "render-session", agentType: "claudeCode", tool: "Bash",
                         originAgentID: nil, nativeRequestID: "native-1", decision: .approved,
                         latencyMilliseconds: 12, toolInput: "echo render")
        _ = store.append(sessionID: "render-session", agentType: "claudeCode", tool: "Edit",
                         originAgentID: "agent-7", nativeRequestID: "native-2", decision: .denied,
                         latencyMilliseconds: 8, toolInput: "file")
        _ = store.append(sessionID: "render-session", agentType: "claudeCode", tool: "Bash",
                         originAgentID: nil, nativeRequestID: "native-3", decision: .nativeTurnEnded,
                         latencyMilliseconds: 310_000, toolInput: nil)

        let view = ApprovalHistoryPane()
            .environment(SessionManager(approvalAuditStore: store))
            .defaultAppStorage(AppPreferences.defaults)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        host.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 760)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 520)
    }
}
