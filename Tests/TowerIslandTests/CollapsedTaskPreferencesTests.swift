import AppKit
import SwiftUI
import XCTest
@testable import XIsland

@MainActor
final class CollapsedTaskPreferencesTests: XCTestCase {
    func testNativePickerPersistsSelectionAndRetainsItWhileIconsAreOff() async throws {
        guard ProcessInfo.processInfo.environment["X_ISLAND_RENDER_COLLAPSED_PILL"] == "1" else {
            throw XCTSkip("显式启用隔离的最近任务设置控件验证")
        }
        XCTAssertTrue(AppPreferences.isIsolated)
        _ = NSApplication.shared
        let suite = "dev.xisland.tests.recenttaskpicker.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "showCollapsedAgentIcon")

        let first = makeHost(defaults: defaults)
        defer { first.window.close() }
        await settle { self.limitControl(in: first.host) != nil }
        let control = try XCTUnwrap(limitControl(in: first.host))
        XCTAssertEqual(control.selectedSegment, 2, "新偏好默认显示最近三个任务")
        XCTAssertEqual((0..<5).compactMap { control.label(forSegment: $0) }, ["1", "2", "3", "4", "5"])
        control.scrollToVisible(control.bounds)
        try snapshot(first.host, name: "settings-default-3")

        for (segment, expected) in [(0, 1), (4, 5)] {
            control.selectedSegment = segment
            XCTAssertTrue(control.sendAction(control.action, to: control.target))
            await settle { defaults.integer(forKey: "collapsedRecentTaskLimit") == expected }
            XCTAssertEqual(defaults.integer(forKey: "collapsedRecentTaskLimit"), expected)
        }
        first.window.close()

        let reopened = makeHost(defaults: defaults)
        defer { reopened.window.close() }
        await settle { self.limitControl(in: reopened.host) != nil }
        let reopenedControl = try XCTUnwrap(limitControl(in: reopened.host))
        XCTAssertEqual(reopenedControl.selectedSegment, 4, "重新打开设置后保留已选数量")
        defaults.set(false, forKey: "showCollapsedAgentIcon")
        await settle { !reopenedControl.isEnabled }
        XCTAssertFalse(reopenedControl.isEnabled)
        XCTAssertEqual(defaults.integer(forKey: "collapsedRecentTaskLimit"), 5)
        reopenedControl.scrollToVisible(reopenedControl.bounds)
        try snapshot(reopened.host, name: "settings-icons-off-retains-5")

        defaults.set(true, forKey: "showCollapsedAgentIcon")
        defaults.set(99, forKey: "collapsedRecentTaskLimit")
        await settle { reopenedControl.isEnabled && reopenedControl.selectedSegment == 4 }
        XCTAssertTrue(reopenedControl.isEnabled)
        XCTAssertEqual(reopenedControl.selectedSegment, 4, "异常偏好也应显示有效选项")
    }

    private func makeHost(defaults: UserDefaults) -> (host: NSView, window: NSWindow) {
        let view = PreferencesView(initialPane: "display")
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

    private func limitControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl, control.segmentCount == 5 { return control }
        return view.subviews.lazy.compactMap { self.limitControl(in: $0) }.first
    }

    private func settle(until condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func snapshot(_ host: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["X_ISLAND_RENDER_COLLAPSED_PILL_DIR"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent(name + ".png"))
    }
}
