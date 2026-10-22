import AppKit
import XCTest
@testable import XIsland

@MainActor
final class NotchWindowVisibilityTests: XCTestCase {
    func testEachExplicitShowRecordsTimeAndCancelsPendingSwitch() throws {
        var cancellations = 0
        var visibleMarks = 0
        let fixture = try makeFixture(
            markVisible: { visibleMarks += 1 },
            onExplicitShow: { cancellations += 1 }
        )
        defer { fixture.close() }
        XCTAssertEqual(fixture.window.lastExplicitShowTime, 0)

        for show in explicitShows(of: fixture.window) {
            fixture.window.isHiddenByIslandSwitch = true
            let before = Date().timeIntervalSince1970
            show()
            XCTAssertGreaterThanOrEqual(fixture.window.lastExplicitShowTime, before)
            XCTAssertFalse(fixture.window.isHiddenByIslandSwitch)
            XCTAssertTrue(fixture.window.isVisible)
        }
        XCTAssertEqual(cancellations, 3)
        XCTAssertEqual(visibleMarks, 3)
    }

    func testExplicitShowsDiscardEarlierFullscreenResult() async throws {
        for showIndex in 0..<3 {
            let started = expectation(description: "全屏检查开始")
            let probe = FullscreenProbe(started: [started])
            let fixture = try makeFixture(probe: { await probe.result() })
            defer { fixture.close() }
            fixture.window.showWindow()
            let check = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
            await fulfillment(of: [started], timeout: 1)

            explicitShows(of: fixture.window)[showIndex]()
            await probe.complete(0, fullscreen: true)
            await check.value

            XCTAssertTrue(fixture.window.isVisible, "显式显示应淘汰之前的全屏结果")
        }
    }

    func testCompletedSwitchProtectionDiscardsEarlierFullscreenResult() async throws {
        let started = expectation(description: "全屏检查开始")
        let probe = FullscreenProbe(started: [started])
        let fixture = try makeFixture(probe: { await probe.result() })
        defer { fixture.close() }
        fixture.window.showWindow()
        let check = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
        await fulfillment(of: [started], timeout: 1)

        fixture.window.isSwitchingApps = true
        fixture.window.isSwitchingApps = false
        await probe.complete(0, fullscreen: true)
        await check.value

        XCTAssertTrue(fixture.window.isVisible)
    }

    func testIslandHiddenFlagChangesDiscardEarlierFullscreenResult() async throws {
        let started = expectation(description: "全屏检查开始")
        let probe = FullscreenProbe(started: [started])
        let fixture = try makeFixture(probe: { await probe.result() })
        defer { fixture.close() }
        fixture.window.showWindow()
        let check = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
        await fulfillment(of: [started], timeout: 1)

        fixture.window.isHiddenByIslandSwitch = true
        fixture.window.isHiddenByIslandSwitch = false
        await probe.complete(0, fullscreen: true)
        await check.value

        XCTAssertTrue(fixture.window.isVisible)
    }

    func testNewerFullscreenCheckDiscardsOlderResult() async throws {
        let firstStarted = expectation(description: "第一次检查开始")
        let secondStarted = expectation(description: "第二次检查开始")
        let probe = FullscreenProbe(started: [firstStarted, secondStarted])
        let fixture = try makeFixture(probe: { await probe.result() })
        defer { fixture.close() }
        fixture.window.showWindow()
        let first = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
        await fulfillment(of: [firstStarted], timeout: 1)
        let second = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
        await fulfillment(of: [secondStarted], timeout: 1)

        await probe.complete(1, fullscreen: false)
        await second.value
        await probe.complete(0, fullscreen: true)
        await first.value

        XCTAssertTrue(fixture.window.isVisible)
    }

    func testDisablingFullscreenHidingDiscardsPendingResult() async throws {
        let started = expectation(description: "全屏检查开始")
        let probe = FullscreenProbe(started: [started])
        let fixture = try makeFixture(probe: { await probe.result() })
        defer { fixture.close() }
        fixture.window.showWindow()
        let check = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
        await fulfillment(of: [started], timeout: 1)

        fixture.defaults.set(false, forKey: "hideInFullscreen")
        await probe.complete(0, fullscreen: true)
        await check.value

        XCTAssertTrue(fixture.window.isVisible)
    }

    func testIslandHandoffKeepsWindowHiddenAfterPendingRestore() async throws {
        let started = expectation(description: "全屏检查开始")
        let probe = FullscreenProbe(started: [started])
        let fixture = try makeFixture(probe: { await probe.result() })
        defer { fixture.close() }
        fixture.window.showWindow()
        let check = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
        await fulfillment(of: [started], timeout: 1)

        fixture.window.isHiddenByIslandSwitch = true
        fixture.window.orderOut(nil)
        await probe.complete(0, fullscreen: false)
        await check.value

        XCTAssertFalse(fixture.window.isVisible)
    }

    func testCurrentFullscreenResultsStillHideAndRestore() async throws {
        let firstStarted = expectation(description: "进入全屏检查开始")
        let secondStarted = expectation(description: "退出全屏检查开始")
        let probe = FullscreenProbe(started: [firstStarted, secondStarted])
        let fixture = try makeFixture(probe: { await probe.result() })
        defer { fixture.close() }
        fixture.window.showWindow()
        let first = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
        await fulfillment(of: [firstStarted], timeout: 1)
        await probe.complete(0, fullscreen: true)
        await first.value
        XCTAssertFalse(fixture.window.isVisible)

        let second = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
        await fulfillment(of: [secondStarted], timeout: 1)
        await probe.complete(1, fullscreen: false)
        await second.value
        XCTAssertTrue(fixture.window.isVisible)
    }

    private func explicitShows(of window: NotchWindow) -> [() -> Void] {
        [window.showWindow, window.showAtMouseScreen, window.showAtActiveScreen]
    }

    private func makeFixture(
        markVisible: @escaping @MainActor () -> Void = {},
        onExplicitShow: @escaping @MainActor () -> Void = {},
        probe: (@Sendable () async -> Bool)? = nil
    ) throws -> Fixture {
        _ = try XCTUnwrap(AppPreferences.isIsolated ? true : nil, "必须先进入隔离测试模式")
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else {
            throw XCTSkip("隔离窗口验证需要 WindowServer 和可用屏幕")
        }
        let suite = "XIslandTests.NotchWindowVisibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "hideInFullscreen")
        defaults.set(true, forKey: "showOnAllSpaces")
        let window = NotchWindow(
            defaults: defaults, markVisible: markVisible, onExplicitShow: onExplicitShow, fullscreenProbe: probe
        )
        // 仅控制本测试创建的窗口，避免桌面通知混入可控的异步序列。
        NSWorkspace.shared.notificationCenter.removeObserver(window)
        return Fixture(window: window, defaults: defaults, suite: suite)
    }

    @MainActor
    private struct Fixture {
        let window: NotchWindow
        let defaults: UserDefaults
        let suite: String

        func close() {
            window.close()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

private actor FullscreenProbe {
    private let started: [XCTestExpectation]
    private var continuations: [CheckedContinuation<Bool, Never>] = []

    init(started: [XCTestExpectation]) {
        self.started = started
    }

    func result() async -> Bool {
        await withCheckedContinuation { continuation in
            let index = continuations.count
            continuations.append(continuation)
            started[index].fulfill()
        }
    }

    func complete(_ index: Int, fullscreen: Bool) {
        continuations[index].resume(returning: fullscreen)
    }
}
