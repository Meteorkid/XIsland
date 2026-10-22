import AppKit
import SwiftUI
import XCTest
@testable import XIsland

@MainActor
final class CollapsedRecentTaskRenderTests: XCTestCase {
    func testRecentLimitChangesRenderedIconsAndNotchUsesRecentTask() throws {
        guard ProcessInfo.processInfo.environment["X_ISLAND_RENDER_COLLAPSED_PILL"] == "1" else {
            throw XCTSkip("显式启用隔离的最近任务显示验证")
        }
        XCTAssertTrue(AppPreferences.isIsolated)
        _ = NSApplication.shared
        let defaults = AppPreferences.defaults
        let keys = ["appearanceMode", "reduceMotion", "disableAnimations", "showCollapsedAgentIcon",
                    "collapsedRecentTaskLimit", "showCollapsedSessionCount", "showCollapsedQuota",
                    "audio.quietHoursEnabled", "bypassMode"]
        let originals = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, originals) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set("dark", forKey: "appearanceMode")
        defaults.set(true, forKey: "reduceMotion")
        defaults.set(true, forKey: "disableAnimations")
        defaults.set(true, forKey: "showCollapsedAgentIcon")
        for key in ["showCollapsedSessionCount", "showCollapsedQuota", "audio.quietHoursEnabled", "bypassMode"] {
            defaults.set(false, forKey: key)
        }
        let manager = SessionManager(), audio = AudioEngine(), quota = QuotaTracker(), theme = ThemeManager()
        XCTAssertFalse(quota.isPolling)
        let sessions = (1...8).map { index in
            let session = AgentSession(id: "recent-render-\(index)", agentType: .codex, prompt: "Task \(index)")
            session.status = index == 8 ? .active : .idle
            session.lastActivityTime = Date(timeIntervalSince1970: Double(index))
            return session
        }
        manager.sessions = sessions
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["X_ISLAND_RENDER_COLLAPSED_PILL_DIR"]
            ?? "/tmp/xisland-collapsed-recent-render", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        func render(_ name: String, limit: Int, obscured: Bool) throws -> Data {
            defaults.set(limit, forKey: "collapsedRecentTaskLimit")
            let view = CollapsedPillView(obscuredByNotch: obscured, isExpanded: true,
                onTap: { XCTFail("渲染不能触发实际点击") })
                .environment(manager).environment(audio).environment(quota).environment(theme)
                .defaultAppStorage(defaults)
                .frame(width: 261.34, height: 38.77)
                .background(Color.black)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(x: 0, y: 0, width: 261.34, height: 38.77)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent(name + ".png"))
            return data
        }

        let one = try render("recent-limit-1", limit: 1, obscured: false)
        let three = try render("recent-limit-3", limit: 3, obscured: false)
        let five = try render("recent-limit-5", limit: 5, obscured: false)
        XCTAssertNotEqual(one, three, "改变偏好必须真正改变收起态图标")
        XCTAssertNotEqual(three, five, "不能继续固定显示前五项")

        let notchRecent = try render("notch-recent-1", limit: 1, obscured: true)
        manager.sessions = [sessions[7]]
        let notchExpected = try render("notch-expected-latest", limit: 1, obscured: true)
        XCTAssertEqual(notchRecent, notchExpected, "减少动态效果时应显示最近任务，而不是数组第一项")

        manager.sessions = sessions
        defaults.set(true, forKey: "showCollapsedSessionCount")
        for limit in [1, 3, 5] {
            _ = try render("recent-limit-\(limit)-total", limit: limit, obscured: false)
            _ = try render("notch-limit-\(limit)-total", limit: limit, obscured: true)
        }
        defaults.set(false, forKey: "showCollapsedAgentIcon")
        let hiddenOne = try render("icons-off-limit-1", limit: 1, obscured: false)
        let hiddenFive = try render("icons-off-limit-5", limit: 5, obscured: false)
        XCTAssertEqual(hiddenOne, hiddenFive, "关闭图标后数量不应改变计数或其他模块")
        XCTAssertEqual(manager.sessions.count, 8)
    }
}
