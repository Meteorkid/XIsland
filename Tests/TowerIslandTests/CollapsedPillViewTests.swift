import AppKit
import SwiftUI
import XCTest
@testable import XIsland

final class CollapsedPillViewTests: XCTestCase {
    func testCollapsedCountsAlternateInFiveSecondSlots() {
        for elapsed in [0.0, 1.0, 4.999, 10.0, 14.999] {
            XCTAssertEqual(CollapsedPillView.countKind(isExpanded: false, at: Date(timeIntervalSince1970: elapsed)), .active)
        }
        for elapsed in [5.0, 6.0, 9.999, 15.0] {
            XCTAssertEqual(CollapsedPillView.countKind(isExpanded: false, at: Date(timeIntervalSince1970: elapsed)), .total)
        }
    }

    func testExpandedCountsAlwaysShowTotal() {
        for elapsed in [0.0, 4.999, 5.0, 10.0] {
            XCTAssertEqual(CollapsedPillView.countKind(isExpanded: true, at: Date(timeIntervalSince1970: elapsed)), .total)
        }
    }

    func testCountRotationContinuesWithAllMotionDisabled() {
        let policy = IslandMotionPolicy(reduceMotion: true, systemReduceMotion: true, disableAnimations: true)
        XCTAssertFalse(policy.allowsContinuousAnimation)
        // 计数是状态刷新，周期不受动画策略影响。
        XCTAssertEqual(CollapsedPillView.countKind(isExpanded: false, at: Date(timeIntervalSince1970: 0)), .active)
        XCTAssertEqual(CollapsedPillView.countKind(isExpanded: false, at: Date(timeIntervalSince1970: 5)), .total)
    }

    @MainActor
    func testRenderCollapsedPillIconVisibilityMatrix() throws {
        guard ProcessInfo.processInfo.environment["X_ISLAND_RENDER_COLLAPSED_PILL"] == "1" else {
            throw XCTSkip("显式启用隔离的收起态图标快照")
        }
        guard AppPreferences.isIsolated else {
            XCTFail("收起态渲染必须使用隔离的应用偏好")
            return
        }

        let defaults = AppPreferences.defaults
        let keys = ["appearanceMode", "reduceMotion", "disableAnimations", "showCollapsedAgentIcon",
                    "showCollapsedSessionCount", "showCollapsedQuota", "audio.quietHoursEnabled",
                    "audio.soundPackPath", "bypassMode"]
        let originalValues = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, originalValues) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set("dark", forKey: "appearanceMode")
        defaults.set(true, forKey: "reduceMotion")
        defaults.set(true, forKey: "disableAnimations")
        for key in ["showCollapsedSessionCount", "showCollapsedQuota", "audio.quietHoursEnabled", "bypassMode"] {
            defaults.set(false, forKey: key)
        }
        defaults.removeObject(forKey: "audio.soundPackPath")
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let manager = SessionManager(), audio = AudioEngine(), quota = QuotaTracker(), theme = ThemeManager()
        XCTAssertFalse(quota.isPolling)
        let session = AgentSession(id: "collapsed-pill-render", agentType: .codex)
        session.status = .idle
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["X_ISLAND_RENDER_COLLAPSED_PILL_DIR"]
            ?? "/tmp/xisland-collapsed-pill-render", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var images: [String: Data] = [:]
        var measurements: [String: [String: Double]] = [:]

        for obscured in [false, true] {
            for hasSessions in [false, true] {
                for showIcon in [false, true] {
                    manager.sessions = hasSessions ? [session] : []
                    defaults.set(showIcon, forKey: "showCollapsedAgentIcon")
                    let name = "\(obscured ? "notch" : "unobscured")-\(hasSessions ? "session" : "empty")-icon-\(showIcon ? "on" : "off")"
                    let view = CollapsedPillView(obscuredByNotch: obscured, isExpanded: false,
                        onTap: { XCTFail("渲染不应触发点击") })
                        .environment(manager).environment(audio).environment(quota).environment(theme)
                        .defaultAppStorage(defaults)
                        .frame(width: 220, height: 32)
                        .background(Color.black)
                    let host = NSHostingView(rootView: view)
                    host.appearance = NSAppearance(named: .darkAqua)
                    host.frame = NSRect(x: 0, y: 0, width: 220, height: 32)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    images[name] = png
                    try png.write(to: output.appendingPathComponent(name + ".png"))

                    var visiblePixels = 0, minX = bitmap.pixelsWide, maxX = -1
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            if color.alphaComponent > 0.1 && max(color.redComponent, color.greenComponent, color.blueComponent) > 0.1 {
                                visiblePixels += 1
                                minX = min(minX, x)
                                maxX = max(maxX, x)
                            }
                        }
                    }
                    let contentWidth = visiblePixels == 0 ? 0 : Double(maxX - minX + 1) * 220 / Double(bitmap.pixelsWide)
                    measurements[name] = ["visiblePixels": Double(visiblePixels), "contentWidth": contentWidth]
                    if showIcon {
                        XCTAssertGreaterThan(visiblePixels, 20, name + ": 应显示应用图标或会话图标")
                        XCTAssertLessThanOrEqual(contentWidth, 28, name + ": 不应增加空状态文字")
                    } else {
                        XCTAssertEqual(visiblePixels, 0, name + ": 关闭图标后应保持空白")
                    }
                }
            }
        }
        XCTAssertEqual(images.count, 8)
        for layout in ["notch", "unobscured"] {
            XCTAssertNotEqual(images[layout + "-empty-icon-on"], images[layout + "-session-icon-on"],
                              "\(layout): 空状态应用图标与会话图标应不同")
        }
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("measurements.json"))
    }
}
