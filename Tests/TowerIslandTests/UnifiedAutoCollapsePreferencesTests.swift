import AppKit
import SwiftUI
import XCTest
@testable import XIsland

@MainActor
final class UnifiedAutoCollapsePreferencesTests: XCTestCase {
    func testNativeSliderAndStoredToggleKeepZeroDelayAcrossDisableAndReopen() async throws {
        guard ProcessInfo.processInfo.environment["X_ISLAND_RENDER_UNIFIED_COLLAPSE"] == "1" else {
            throw XCTSkip("显式启用隔离的统一收起设置控件验证")
        }
        XCTAssertTrue(AppPreferences.isIsolated)
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("离屏控件验证需要 WindowServer") }
        let suite = "dev.xisland.tests.unifiedcollapse.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AutoCollapseSettings.migrate(defaults, domainName: suite)
        // 固定其余控件状态，使真实原生控件可唯一定位；不依赖SwiftUI未导出的内部AX节点。
        for key in ["launchAtLogin", "showOnAllSpaces", "taskAttentionEnabled", "bypassMode",
                    "hideInFullscreen", "autoHideWhenNoActiveSessions", "smartSuppression"] {
            defaults.set(false, forKey: key)
        }
        defaults.set(120.0, forKey: "completedLingerDuration")
        // 旧字段故意保留不同值，验证界面只编辑新设置。
        defaults.set(2.0, forKey: "autoCollapseDelay")
        defaults.set(9.0, forKey: "expandedInactivityAutoHideDelay")
        defaults.set(0.3, forKey: "hoverExitCollapseDelay")

        let first = makeHost(defaults: defaults)
        defer { first.window.close() }
        await settle { self.sliders(in: first.host).count == 2 }
        // SwiftUI的原生NSSlider以0...1传值，产品数值通过Binding映射为0...600秒。
        let delaySliders = sliders(in: first.host).filter { abs($0.doubleValue - AutoCollapseSettings.defaultDelay / 600) < 0.000001 }
        XCTAssertEqual(delaySliders.count, 1)
        let slider = try XCTUnwrap(delaySliders.first)
        slider.scrollToVisible(slider.bounds.insetBy(dx: -12, dy: -75))
        slider.doubleValue = 0
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        await settle { defaults.double(forKey: AutoCollapseSettings.delayKey) == 0 }
        XCTAssertEqual(defaults.double(forKey: AutoCollapseSettings.delayKey), 0)
        try snapshot(first.host, name: "unified-delay-zero-enabled")

        // 此处验证偏好到控件的反向绑定；SwiftUI按钮未导出Cocoa action，真实点击另行验收。
        defaults.set(false, forKey: AutoCollapseSettings.enabledKey)
        await settle { !defaults.bool(forKey: AutoCollapseSettings.enabledKey) && !slider.isEnabled }
        XCTAssertFalse(defaults.bool(forKey: AutoCollapseSettings.enabledKey))
        XCTAssertFalse(slider.isEnabled)
        XCTAssertEqual(defaults.double(forKey: AutoCollapseSettings.delayKey), 0)
        try snapshot(first.host, name: "unified-delay-zero-disabled")

        defaults.set(true, forKey: AutoCollapseSettings.enabledKey)
        await settle { defaults.bool(forKey: AutoCollapseSettings.enabledKey) && slider.isEnabled }
        XCTAssertTrue(defaults.bool(forKey: AutoCollapseSettings.enabledKey))
        XCTAssertTrue(slider.isEnabled)
        XCTAssertEqual(defaults.double(forKey: AutoCollapseSettings.delayKey), 0)
        first.window.close()

        let reopened = makeHost(defaults: defaults)
        defer { reopened.window.close() }
        await settle { self.sliders(in: reopened.host).count == 2 }
        let reopenedSlider = try XCTUnwrap(sliders(in: reopened.host).first { $0.doubleValue == 0 })
        XCTAssertEqual(reopenedSlider.doubleValue, 0)
        XCTAssertTrue(reopenedSlider.isEnabled)
        reopenedSlider.scrollToVisible(reopenedSlider.bounds.insetBy(dx: -12, dy: -75))
        XCTAssertEqual(defaults.double(forKey: "autoCollapseDelay"), 2)
        XCTAssertEqual(defaults.double(forKey: "expandedInactivityAutoHideDelay"), 9)
        XCTAssertEqual(defaults.double(forKey: "hoverExitCollapseDelay"), 0.3, accuracy: 0.001)
        try snapshot(reopened.host, name: "unified-delay-zero-reopened")
    }

    private func makeHost(defaults: UserDefaults) -> (host: NSView, window: NSWindow) {
        let view = PreferencesView(initialPane: "general")
            .environment(SessionManager()).environment(AudioEngine()).environment(UpdateManager())
            .environment(QuotaTracker()).environment(SessionPersistenceManager()).environment(ThemeManager())
            .defaultAppStorage(defaults)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 760, height: 520),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func sliders(in host: NSView) -> [NSSlider] {
        descendants(host).compactMap { $0 as? NSSlider }
    }

    private func settle(until condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func snapshot(_ host: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["X_ISLAND_RENDER_UNIFIED_COLLAPSE_DIR"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent(name + ".png"))
    }
}
