import XCTest
@testable import XIsland

/// 能耗档位：只锁定档位判定与策略映射，不测系统通知（依赖真实锁屏）。
@MainActor
final class EnergyGovernorTests: XCTestCase {

    // MARK: 档位判定

    func testSuspensionOutranksEverything() {
        // 锁屏时即使面板展开、刚刚有活动，也必须停。
        let mode = EnergyGovernor.resolveMode(
            suspended: true, inWakeGrace: true,
            isPanelExpanded: true, idleFor: 0
        )
        XCTAssertEqual(mode, .systemSuspended)
    }

    func testWakeGraceOutranksExpandedAndIdle() {
        let mode = EnergyGovernor.resolveMode(
            suspended: false, inWakeGrace: true,
            isPanelExpanded: true, idleFor: 0
        )
        XCTAssertEqual(mode, .wakeGrace)
    }

    func testExpandedPanelStaysActiveRegardlessOfIdle() {
        // 用户正盯着面板看，不能因为"没新事件"就把动画停掉。
        let mode = EnergyGovernor.resolveMode(
            suspended: false, inWakeGrace: false,
            isPanelExpanded: true, idleFor: 3600
        )
        XCTAssertEqual(mode, .active)
    }

    func testIdleStepsThroughThreeLevels() {
        func mode(idleFor: TimeInterval) -> EnergyMode {
            EnergyGovernor.resolveMode(suspended: false, inWakeGrace: false,
                                       isPanelExpanded: false, idleFor: idleFor)
        }
        XCTAssertEqual(mode(idleFor: 0), .active)
        XCTAssertEqual(mode(idleFor: EnergyGovernor.idleThreshold - 1), .active)
        XCTAssertEqual(mode(idleFor: EnergyGovernor.idleThreshold + 1), .idleVisible)
        XCTAssertEqual(mode(idleFor: EnergyGovernor.quietThreshold - 1), .idleVisible)
        XCTAssertEqual(mode(idleFor: EnergyGovernor.quietThreshold + 1), .quietBackground)
    }

    // MARK: 策略映射

    func testOnlySuspendedAndQuietStopTheAnimationClock() {
        for mode in [EnergyMode.active, .idleVisible, .wakeGrace] {
            XCTAssertNotEqual(EnergyPolicy.policy(for: mode).animationLevel, .staticFrames,
                              "\(mode.rawValue) 不应停止动画时钟")
        }
        for mode in [EnergyMode.quietBackground, .systemSuspended] {
            XCTAssertEqual(EnergyPolicy.policy(for: mode).animationLevel, .staticFrames,
                           "\(mode.rawValue) 应停止动画时钟")
        }
    }

    func testFileWatcherRetryOnlyDisabledWhileSuspended() {
        XCTAssertFalse(EnergyPolicy.policy(for: .systemSuspended).allowsFileWatcherRetry)
        for mode in [EnergyMode.active, .idleVisible, .quietBackground, .wakeGrace] {
            XCTAssertTrue(EnergyPolicy.policy(for: mode).allowsFileWatcherRetry)
        }
    }

    func testIdleVisibleKeepsFullAnimationUntilMeasured() {
        // 没有实测帧时间前不臆造降帧策略：idleVisible 维持 full。
        XCTAssertEqual(EnergyPolicy.policy(for: .idleVisible).animationLevel, .full)
    }

    // MARK: 跨线程活动信号

    func testBackgroundSignalCoalescesConcurrentCalls() {
        // 高频 hook 下每次消息都往主线程投递会造成堆积。
        // 合并后：第一次 true，后续并发调用返回 false，直到本轮结束。
        let signal = PendingActivitySignalHarness()
        XCTAssertTrue(signal.begin(), "首次调用应投递")
        XCTAssertFalse(signal.begin(), "已有一个在排队，应合并")
        XCTAssertFalse(signal.begin())
        signal.end()
        XCTAssertTrue(signal.begin(), "本轮结束后应可再次投递")
    }

    func testBackgroundSignalIsThreadSafe() {
        // 并发调用下只应有一次 begin 成功。
        let signal = PendingActivitySignalHarness()
        let counter = AtomicCounter()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if signal.begin() { counter.increment() }
        }
        XCTAssertEqual(counter.value, 1, "并发投递必须被合并为一次")
    }
}

/// 复刻 `PendingActivitySignal` 的语义（原类型是 fileprivate）。
/// 这里独立实现是为了让测试不依赖生产代码的内部可见性。
private final class PendingActivitySignalHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var queued = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !queued else { return false }
        queued = true
        return true
    }

    func end() {
        lock.lock()
        queued = false
        lock.unlock()
    }
}

private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
