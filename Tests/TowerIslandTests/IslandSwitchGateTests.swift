import XCTest
@testable import XIsland

/// 岛切换让位判定：核心约束是「没有对端在运行就不隐藏」。
final class IslandSwitchGateTests: XCTestCase {
    func testCannotInitiateSwitchWithoutRunningPeer() {
        XCTAssertFalse(IslandSwitchGate.canInitiateSwitch(isAnyPeerRunning: false))
        XCTAssertTrue(IslandSwitchGate.canInitiateSwitch(isAnyPeerRunning: true))
    }

    func testWatchdogRestoresOnlyWhenHiddenAndPeerAbsent() {
        XCTAssertTrue(IslandSwitchGate.shouldRestoreAfterHandoff(
            isHiddenByIslandSwitch: true, isVisible: false, isAnyPeerRunning: false))
        // 对端在运行：交给对端，不抢回来。
        XCTAssertFalse(IslandSwitchGate.shouldRestoreAfterHandoff(
            isHiddenByIslandSwitch: true, isVisible: false, isAnyPeerRunning: true))
        // 自己已经可见：无需恢复。
        XCTAssertFalse(IslandSwitchGate.shouldRestoreAfterHandoff(
            isHiddenByIslandSwitch: true, isVisible: true, isAnyPeerRunning: false))
        // 不是让位导致的隐藏：不干预。
        XCTAssertFalse(IslandSwitchGate.shouldRestoreAfterHandoff(
            isHiddenByIslandSwitch: false, isVisible: false, isAnyPeerRunning: false))
    }
}
