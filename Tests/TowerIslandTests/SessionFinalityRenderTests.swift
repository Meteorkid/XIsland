import XCTest
import SwiftUI
import AppKit
@testable import XIsland

@MainActor
final class SessionFinalityRenderTests: XCTestCase {
    func testRenderUnconfirmedSessionWithStaleToolActivity() throws {
        guard ProcessInfo.processInfo.environment["X_ISLAND_RENDER_SESSION_FINALITY"] == "1" else {
            throw XCTSkip("显式启用隔离的会话完成状态快照")
        }
        guard AppPreferences.isIsolated else {
            XCTFail("渲染测试必须使用隔离的应用偏好")
            return
        }

        let defaults = AppPreferences.defaults
        let keys = ["appLanguage", "appearanceMode", "disableAnimations"]
        let originalValues = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, originalValues) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set("zh", forKey: "appLanguage")
        defaults.set("dark", forKey: "appearanceMode")
        defaults.set(true, forKey: "disableAnimations")
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let theme = ThemeManager()

        let pending = AgentSession(id: "render-session-unconfirmed", agentType: .codex,
            workingDirectory: "/tmp/session-finality", prompt: "检查结果已返回，但尚无最终完成回执。")
        pending.status = .completionUnconfirmed
        pending.currentTool = "过期工具：不应继续显示运行提示"
        pending.statusText = "旧的运行状态文本"
        pending.events = [ToolEvent(tool: "Read", input: "/tmp/unfinished-before-stop.swift", toolCallId: "old-read")]

        let active = AgentSession(id: "render-session-active", agentType: .codex)
        active.status = .active
        active.currentTool = "Read"
        let idle = AgentSession(id: "render-session-idle", agentType: .codex)
        idle.status = .idle
        idle.statusText = L10n.idle
        let comparisons = [active, pending, idle]

        XCTAssertFalse(pending.events[0].isComplete)
        XCTAssertNotNil(pending.currentTool)
        XCTAssertEqual(pending.lastActivity, L10n.completionUnconfirmed)
        XCTAssertEqual(NotchContentView.activityTickerText(for: pending),
                       "\(pending.agentType.shortName) · \(L10n.completionUnconfirmed)")

        let view = VStack(alignment: .leading, spacing: 16) {
            ExpandedSessionView(session: pending)
                .frame(height: 300)
            Divider()
            HStack(alignment: .top, spacing: 16) {
                ForEach(comparisons) { session in
                    VStack(spacing: 8) {
                        PillBadge(session: session)
                        HStack(spacing: 12) {
                            PillBadge(session: session, compact: true)
                            MascotView(status: session.status, size: 32)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .environment(theme)
        .defaultAppStorage(defaults)
        .frame(width: 720)
        .padding(16)
        .background(Color.black)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 100)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 100)
        let output = URL(fileURLWithPath: "/tmp/xisland-session-finality-render.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
    }
}
