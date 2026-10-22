import XCTest
@testable import XIsland

@MainActor
final class AppSwitcherTests: XCTestCase {
    func testCurrentAppIdentityIsXIsland() {
        XCTAssertEqual(AppSwitcher.shared.currentAppName, "xisland")
        XCTAssertEqual(AppSwitcher.shared.currentURLScheme, "xisland")
    }

    func testSwitchURLUsesTargetSpecificScheme() {
        XCTAssertEqual(
            AppSwitcher.shared.switchURL(for: "xnook"),
            URL(string: "xnook://xnook/show")
        )
        XCTAssertEqual(
            AppSwitcher.shared.switchURL(for: "xisland"),
            URL(string: "xisland://xisland/show")
        )
    }
    func testColdTargetIsOpenedWithExplicitApplicationAndSourceStaysVisible() {
        let harness = Harness()
        let switcher = harness.makeSwitcher()
        switcher.switchToIsland(named: "xnook")
        XCTAssertEqual(harness.openedURLs, [URL(string: "xnook://xnook/show")!])
        XCTAssertEqual(harness.applicationURLs, [URL(fileURLWithPath: "/Applications/X Nook.app")])
        XCTAssertEqual(harness.hideCount, 0)
        harness.completions[0](true)
        XCTAssertEqual(harness.hideCount, 0, "成功投递 URL 不能代替显示确认")
        harness.visible = true
        harness.run(delay: 0.1)
        XCTAssertEqual(harness.hideCount, 1)
        XCTAssertFalse(harness.switching)
    }

    func testTargetLaunchFailureKeepsSourceAndAllowsRetry() {
        let harness = Harness()
        let switcher = harness.makeSwitcher()
        switcher.switchToIsland(named: "xnook")
        harness.completions[0](false)
        XCTAssertEqual(harness.hideCount, 0)
        XCTAssertEqual(harness.restoreCount, 1)
        XCTAssertTrue(switcher.lastSwitchFailed)
        XCTAssertFalse(harness.switching)
        switcher.switchToIsland(named: "xnook")
        XCTAssertEqual(harness.completions.count, 2)
    }

    func testTimeoutAlsoCoversAnOpenerThatNeverReturns() {
        let harness = Harness()
        let switcher = harness.makeSwitcher()
        switcher.switchToIsland(named: "xnook")
        harness.run(delay: 8)
        XCTAssertEqual(harness.restoreCount, 1)
        harness.visible = true
        harness.completions[0](true)
        XCTAssertEqual(harness.hideCount, 0)
    }

    func testSuccessfulOpenWithoutWindowTimesOutWithoutHidingSource() {
        let harness = Harness()
        let switcher = harness.makeSwitcher()
        switcher.switchToIsland(named: "xnook")
        harness.completions[0](true)
        harness.run(delay: 8)
        harness.visible = true
        harness.run(delay: 0.1)
        XCTAssertEqual(harness.hideCount, 0)
        XCTAssertEqual(harness.restoreCount, 1)
    }

    func testDuplicateGestureDoesNotOpenTwiceAndExplicitShowCancelsOldCallbacks() {
        let harness = Harness()
        let switcher = harness.makeSwitcher()
        switcher.switchToIsland(named: "xnook")
        switcher.switchToIsland(named: "xnook")
        XCTAssertEqual(harness.completions.count, 1)
        switcher.cancelSwitch()
        harness.visible = true
        harness.completions[0](true)
        harness.run(delay: 8)
        XCTAssertEqual(harness.hideCount, 0)
        XCTAssertEqual(harness.restoreCount, 0)
    }

    func testLegacyHideCannotHideSourceWhenTargetIsMissingOrBehindNewShow() {
        let harness = Harness()
        let switcher = harness.makeSwitcher()
        XCTAssertFalse(switcher.acceptPeerHideRequest())
        harness.visible = true
        XCTAssertFalse(switcher.acceptPeerHideRequest())
        harness.frontmost = true
        XCTAssertTrue(switcher.acceptPeerHideRequest())
    }

    func testPendingSwitchCanYieldToVisibleLowerLevelTarget() {
        let harness = Harness()
        let switcher = harness.makeSwitcher()
        switcher.switchToIsland(named: "xnook")
        XCTAssertFalse(switcher.acceptPeerHideRequest())
        harness.visible = true
        XCTAssertTrue(switcher.acceptPeerHideRequest())
        harness.completions[0](true)
        harness.run(delay: 8)
        XCTAssertEqual(harness.restoreCount, 0)
        XCTAssertEqual(harness.hideCount, 0, "接收方负责隐藏，不能被旧回调重复切换")
    }

    func testMissingAppOrInvalidTargetDoesNotChangeSource() {
        let harness = Harness()
        harness.installed = false
        let switcher = harness.makeSwitcher()
        switcher.switchToIsland(named: "xnook")
        switcher.switchToIsland(named: "xisland")
        switcher.switchToIsland(named: "unknown")
        XCTAssertTrue(harness.openedURLs.isEmpty)
        XCTAssertEqual(harness.hideCount, 0)
        XCTAssertEqual(harness.restoreCount, 1)
    }

    func testFreshShowNotificationCanYieldToLowerLayerButStaleNotificationCannot() {
        let harness = Harness()
        harness.visible = true
        let switcher = harness.makeSwitcher()
        XCTAssertTrue(switcher.acceptPeerHideRequest(from: "xnook", shownAt: 11, after: 10))
        XCTAssertFalse(switcher.acceptPeerHideRequest(from: "xnook", shownAt: 9, after: 10))
        XCTAssertFalse(switcher.acceptPeerHideRequest(from: "xnook", shownAt: 10, after: 10))
        XCTAssertFalse(switcher.acceptPeerHideRequest(from: "xnook", shownAt: .nan, after: 10))
        XCTAssertFalse(switcher.acceptPeerHideRequest(from: "xisland", shownAt: 11, after: 10))
        harness.visible = false
        XCTAssertFalse(switcher.acceptPeerHideRequest(from: "xnook", shownAt: 11, after: 10))
    }

    @MainActor
    private final class Harness {
        var installed = true
        var visible = false
        var frontmost = false
        var switching = false
        var hideCount = 0
        var restoreCount = 0
        var openedURLs: [URL] = []
        var applicationURLs: [URL] = []
        var completions: [@MainActor (Bool) -> Void] = []
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []

        func makeSwitcher() -> AppSwitcher {
            AppSwitcher(environment: .init(
                applicationURL: { [unowned self] _ in installed ? URL(fileURLWithPath: "/Applications/X Nook.app") : nil },
                open: { [unowned self] url, appURL, completion in
                    openedURLs.append(url); applicationURLs.append(appURL); completions.append(completion)
                },
                isVisible: { [unowned self] _ in visible },
                isFrontmost: { [unowned self] _ in frontmost },
                setSwitching: { [unowned self] in switching = $0 },
                hideSource: { [unowned self] in hideCount += 1 },
                restoreSource: { [unowned self] in restoreCount += 1 },
                schedule: { [unowned self] delay, action in
                    scheduled.append((delay, action))
                    // 故意模拟取消后仍迟到的回调，验证请求 ID 防护。
                    return {}
                }
            ))
        }

        func run(delay: TimeInterval) {
            let actions = scheduled.filter { $0.0 == delay }
            scheduled.removeAll { $0.0 == delay }
            actions.forEach { $0.1() }
        }
    }

}
