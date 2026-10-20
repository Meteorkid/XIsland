import AppKit
import XCTest
@testable import XIsland

@MainActor
final class SettingsRoutingTests: XCTestCase {
    override func setUpWithError() throws {
        _ = try XCTUnwrap(AppPreferences.isIsolated ? true : nil, "设置测试必须使用隔离偏好")
        _ = NSApplication.shared
    }

    func testLocalizedSystemSettingsShortcutRoutesToExistingPreferencesHandler() {
        let delegate = makeDelegate()
        for title in ["Settings…", "设置…", "設定…", "Paramètres…"] {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "About", action: nil, keyEquivalent: ""))
            let item = NSMenuItem(title: title, action: NSSelectorFromString("menuAction:"), keyEquivalent: ",")
            item.keyEquivalentModifierMask = .command
            menu.addItem(item)

            XCTAssertEqual(delegate.routeSettingsMenuItem(in: menu), 1)
            XCTAssertTrue(item.target === delegate)
            XCTAssertEqual(item.action, #selector(AppDelegate.openPreferences))
            XCTAssertEqual(item.title, title)
            XCTAssertEqual(item.keyEquivalent, ",")
        }
    }

    func testMenuRoutingCanRetryAfterMenuBecomesAvailableAndRemainsIdempotent() {
        let delegate = makeDelegate()
        let menu = NSMenu()
        XCTAssertNil(delegate.routeSettingsMenuItem(in: menu))
        let item = NSMenuItem(title: "设置", action: NSSelectorFromString("menuAction:"), keyEquivalent: ",")
        item.keyEquivalentModifierMask = .command
        menu.addItem(item)
        XCTAssertEqual(delegate.routeSettingsMenuItem(in: menu), 0)
        item.action = NSSelectorFromString("menuAction:")
        item.target = nil
        XCTAssertEqual(delegate.routeSettingsMenuItem(in: menu), 0)
        XCTAssertEqual(menu.items.count, 1)
        XCTAssertTrue(item.target === delegate)
        XCTAssertEqual(item.action, #selector(AppDelegate.openPreferences))
    }

    func testSettingsTitleAloneDoesNotRetargetAnUnrelatedMenuItem() {
        let delegate = makeDelegate()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Settings", action: NSSelectorFromString("unrelatedAction:"), keyEquivalent: ",")
        item.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(item)

        XCTAssertNil(delegate.routeSettingsMenuItem(in: menu))
        XCTAssertEqual(item.action, NSSelectorFromString("unrelatedAction:"))
        XCTAssertNil(item.target)
    }

    func testVisibleSceneRedirectClosesOnlyItsOwnHostOnce() async {
        let host = makeWindow()
        let unrelated = makeWindow()
        defer { host.close(); unrelated.close() }
        let routed = expectation(description: "settings scene routed")
        routed.assertForOverFulfill = true
        var requests = 0
        let view = SettingsSceneRedirectView { requests += 1; routed.fulfill() }
        host.contentView = view
        host.orderFront(nil)
        unrelated.orderFront(nil)
        view.scheduleRedirect()
        view.scheduleRedirect()

        await fulfillment(of: [routed], timeout: 2)
        await drainMainQueue()

        XCTAssertEqual(requests, 1)
        XCTAssertEqual(host.closeCount, 1)
        XCTAssertFalse(host.isVisible)
        XCTAssertEqual(unrelated.closeCount, 0)
        XCTAssertTrue(unrelated.isVisible)
    }

    func testHiddenSceneWaitsUntilItsHostIsShown() async {
        let host = makeWindow()
        defer { host.close() }
        let routed = expectation(description: "visible scene routed")
        var requests = 0
        let view = SettingsSceneRedirectView { requests += 1; routed.fulfill() }
        host.contentView = view
        await drainMainQueue()
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(host.closeCount, 0)

        host.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: host)
        await fulfillment(of: [routed], timeout: 2)

        XCTAssertEqual(requests, 1)
        XCTAssertFalse(host.isVisible)
    }

    func testDetachedSceneCannotCloseItsPreviousHost() async {
        let host = makeWindow()
        defer { host.close() }
        var requests = 0
        let view = SettingsSceneRedirectView { requests += 1 }
        host.contentView = view
        host.orderFront(nil)
        view.scheduleRedirect()
        host.contentView = NSView()
        await drainMainQueue()

        XCTAssertEqual(requests, 0)
        XCTAssertEqual(host.closeCount, 0)
        XCTAssertTrue(host.isVisible)
    }

    func testRestoredSceneCanRedirectAgainWhenTheSameHostReopens() async {
        let host = makeWindow()
        defer { host.close() }
        var requests = 0
        let first = expectation(description: "first scene opening")
        let second = expectation(description: "restored scene opening")
        let view = SettingsSceneRedirectView {
            requests += 1
            if requests == 1 { first.fulfill() }
            else if requests == 2 { second.fulfill() }
            else { XCTFail("每次显示只应路由一次") }
        }
        host.contentView = view
        host.orderFront(nil)
        view.scheduleRedirect()
        await fulfillment(of: [first], timeout: 2)
        await drainMainQueue()

        host.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: host)
        await fulfillment(of: [second], timeout: 2)

        XCTAssertEqual(requests, 2)
        XCTAssertEqual(host.closeCount, 2)
        XCTAssertFalse(host.isVisible)
    }

    func testStartupRestorationDoesNotOpenSettingsBeforeInitialDiscovery() {
        let delegate = makeDelegate()
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))

        delegate.routeSettingsScene()

        XCTAssertTrue(delegate.integrationSetupManager.rows.isEmpty)
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), existingWindows)
    }

    private func makeDelegate() -> AppDelegate {
        AppDelegate(testConfiguration: AppTestConfiguration.make(arguments: ["--ui-test-mode"], environment: [:]))
    }

    private func makeWindow() -> TestWindow {
        let window = TestWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 100, height: 80),
                                styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func drainMainQueue() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @MainActor
    private final class TestWindow: NSWindow {
        var closeCount = 0

        override func close() {
            closeCount += 1
            super.close()
        }
    }
}
