import AppKit
import XCTest
@testable import XIsland

@MainActor
final class LinkedIslandPreviewIntegrationTests: XCTestCase {
    func testMissingTargetAfterCanvasUnlocksBeforeRollback() {
        let (switcher, state, peer) = fixture(installed: false)
        state.switching = true

        switcher.switchToIsland(named: peer, direction: .left, animationAlreadyPresented: true)

        XCTAssertEqual(state.cancelPreviewLocks, [false], "回滚回调不能再被提交中的窗口保护拦住")
        XCTAssertEqual(state.restoreSourceLocks, [false])
        XCTAssertFalse(state.switching)
        XCTAssertFalse(switcher.isSwitchInProgress)
        XCTAssertTrue(switcher.lastSwitchFailed)
        XCTAssertTrue(state.openedURLs.isEmpty)
        XCTAssertTrue(state.scheduledDelays.isEmpty, "尚未发请求的失败不能依赖后续超时解锁")
    }

    func testInvalidTargetAfterCanvasUnlocksBeforeCancellation() throws {
        let (switcher, state, _) = fixture()
        for target in ["unknown-island", try XCTUnwrap(switcher.currentAppName)] {
            state.switching = true
            switcher.switchToIsland(named: target, direction: .right, animationAlreadyPresented: true)
            XCTAssertFalse(state.switching)
        }
        XCTAssertEqual(state.cancelPreviewLocks, [false, false])
        XCTAssertTrue(state.restoreSourceLocks.isEmpty)
        XCTAssertTrue(state.openedURLs.isEmpty)
        XCTAssertTrue(state.scheduledDelays.isEmpty)
    }

    func testInvalidPlainRequestDoesNotReleaseUnrelatedInteractiveLock() {
        let (switcher, state, _) = fixture()
        state.switching = true

        switcher.switchToIsland(named: "unknown-island")

        XCTAssertTrue(state.switching)
        XCTAssertEqual(state.cancelPreviewLocks, [true])
        XCTAssertTrue(state.openedURLs.isEmpty)
    }

    func testFailedOpenAfterCanvasUnlocksBeforeRollback() throws {
        let (switcher, state, peer) = fixture()
        state.switching = true
        switcher.switchToIsland(named: peer, direction: .left, animationAlreadyPresented: true)
        XCTAssertTrue(switcher.isSwitchInProgress)
        let opened = try XCTUnwrap(state.openCompletion)

        opened(false)

        XCTAssertEqual(state.cancelPreviewLocks, [false])
        XCTAssertEqual(state.restoreSourceLocks, [false])
        XCTAssertFalse(state.switching)
        XCTAssertFalse(switcher.isSwitchInProgress)
        XCTAssertTrue(switcher.lastSwitchFailed)
    }

    func testPresentedCanvasRequestsNativeTakeoverWithoutAnotherAnimation() throws {
        let (switcher, state, peer) = fixture()

        switcher.switchToIsland(named: peer, direction: .right, animationAlreadyPresented: true)

        let url = try XCTUnwrap(state.openedURLs.first)
        let motion = try XCTUnwrap(try IslandSwitchMotion.decode(url: url))
        XCTAssertEqual(motion.direction, .right)
        XCTAssertTrue(motion.reduceMotion, "画布已完成翻页，真实窗口接管不能再播一次滑动")
        XCTAssertTrue(state.switching)
    }

    private final class State {
        var switching = false
        var cancelPreviewLocks: [Bool] = []
        var restoreSourceLocks: [Bool] = []
        var openedURLs: [URL] = []
        var openCompletion: (@MainActor (Bool) -> Void)?
        var scheduledDelays: [TimeInterval] = []
    }

    private func fixture(installed: Bool = true) -> (AppSwitcher, State, String) {
        let state = State()
        let switcher = AppSwitcher(environment: .init(
            applicationURL: { _ in installed ? URL(fileURLWithPath: "/Fixture/Peer.app") : nil },
            open: { url, _, completion in state.openedURLs.append(url); state.openCompletion = completion },
            isVisible: { _ in false }, isFrontmost: { _ in false },
            setSwitching: { state.switching = $0 }, hideSource: {},
            restoreSource: { state.restoreSourceLocks.append(state.switching) },
            schedule: { delay, _ in state.scheduledDelays.append(delay); return {} },
            cancelPreview: { state.cancelPreviewLocks.append(state.switching) },
            reduceMotion: { false }, uptime: { 100 }
        ))
        let peer = switcher.currentAppName == "xisland" ? "xnook" : "xisland"
        return (switcher, state, peer)
    }
}
