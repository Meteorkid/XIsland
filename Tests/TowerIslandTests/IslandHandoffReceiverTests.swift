import AppKit
import XCTest
@testable import XIsland

@MainActor
final class IslandHandoffReceiverTests: XCTestCase {
    func testHideRequestWithoutVisiblePeerKeepsSourceWindow() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let window = NotchWindow()
        delegate.notchWindow = window
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let switcher = AppSwitcher(environment: .init(
            applicationURL: { _ in nil }, open: { _, _, _ in },
            isVisible: { _ in false }, isFrontmost: { _ in false },
            setSwitching: { _ in }, hideSource: {}, restoreSource: {},
            schedule: { _, _ in {} }
        ))
        delegate.hideIslandForSwitch(using: switcher)
        XCTAssertTrue(window.isVisible, "目标尚未显示时不能隐藏当前岛")
        XCTAssertFalse(window.isHiddenByIslandSwitch)
    }
    func testIncomingShowBeforeWindowSetupIsRetainedThroughStartup() {
        _ = NSApplication.shared
        let delegate = AppDelegate(
            testConfiguration: AppTestConfiguration(isEnabled: true, fixtureName: nil, fixturePath: nil,
                                                   diagnosticsPath: nil, disableAnimations: true),
            launchHooks: .init(performInitialStartup: { $0.notchWindow = NotchWindow() },
                              performProductionGlobalStartup: { _ in XCTFail("隔离测试不能触碰生产环境") })
        )
        delegate.application(NSApp, open: [URL(string: "xisland://xisland/show")!])
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.notchWindow?.orderOut(nil) }
        XCTAssertTrue(delegate.notchWindow?.isVisible == true)
        XCTAssertFalse(delegate.notchWindow?.isHiddenByIslandSwitch ?? true)
    }

    func testOldInboundTimerCannotClearNewOutboundSwitchProtection() {
        let delegate = AppDelegate()
        let window = NotchWindow()
        defer { window.orderOut(nil) }
        let switcher = AppSwitcher(environment: .init(
            applicationURL: { _ in URL(fileURLWithPath: "/Applications/X Nook.app") },
            open: { _, _, _ in }, isVisible: { _ in false }, isFrontmost: { _ in false },
            setSwitching: { window.isSwitchingApps = $0 }, hideSource: {}, restoreSource: {},
            schedule: { _, _ in {} }
        ))
        switcher.switchToIsland(named: "xnook")
        delegate.clearSwitchingProtection(window: window, using: switcher)
        XCTAssertTrue(window.isSwitchingApps)
        switcher.cancelSwitch()
        delegate.clearSwitchingProtection(window: window, using: switcher)
        XCTAssertFalse(window.isSwitchingApps)
    }

}
