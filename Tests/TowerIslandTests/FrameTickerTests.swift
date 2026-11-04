import XCTest
@testable import XIsland

/// 共享时钟：订阅计数、起停生命周期、分频取整、竞态回归。
@MainActor
final class FrameTickerTests: XCTestCase {

    // MARK: 间隔取整

    func testIntervalRoundsToGridMultiples() {
        let grid = FrameTicker.grid
        XCTAssertEqual(FrameTicker.steps(for: grid), 1)
        XCTAssertEqual(FrameTicker.steps(for: grid * 9), 9)
        // 0.15s 在 60Hz 网格上取整为 9 格。
        XCTAssertEqual(FrameTicker.steps(for: 0.15), 9)
        // 比一格还小也要至少订阅一格，否则永远不推进。
        XCTAssertEqual(FrameTicker.steps(for: 0.0001), 1)
    }

    func testInvalidIntervalsDegradeToOneStep() {
        for bad in [0.0, -1.0, .infinity, .nan] {
            XCTAssertEqual(FrameTicker.steps(for: bad), 1, "\(bad) 应退化为 1 格")
        }
    }

    func testSameIntervalYieldsSameBeat() {
        let ticker = FrameTicker.shared
        let a = ticker.beat(every: 0.15)
        let b = ticker.beat(every: 0.15)
        XCTAssertTrue(a === b, "同一间隔必须复用同一个 Beat，否则分频失效")
        // 取整后相同的间隔也应命中同一 Beat。
        XCTAssertTrue(ticker.beat(every: 0.1501) === a)
    }

    // MARK: 订阅计数

    func testSubscriberCountTracksAcquireAndRelease() {
        let ticker = FrameTicker.shared
        let beat = ticker.beat(every: 0.2)
        let before = ticker.activeSubscriberCount

        ticker.acquire(beat)
        XCTAssertEqual(ticker.activeSubscriberCount, before + 1)
        ticker.acquire(beat)
        XCTAssertEqual(ticker.activeSubscriberCount, before + 2)
        ticker.release(beat)
        ticker.release(beat)
        XCTAssertEqual(ticker.activeSubscriberCount, before)
    }

    func testReleaseIsIdempotentAndNeverGoesNegative() {
        let ticker = FrameTicker.shared
        let beat = ticker.beat(every: 0.25)
        let before = ticker.activeSubscriberCount
        // 多释放一次不应把计数减成负数。
        ticker.release(beat)
        ticker.release(beat)
        XCTAssertEqual(ticker.activeSubscriberCount, before)
    }

    // MARK: 竞态回归

    func testReevaluateWhileRunningDoesNotLoseTheTask() {
        // 回归：旧实现里退出中的旧循环会执行 `tickerTask = nil`，
        // 把刚被 reevaluate 启动的新 task 一并清掉，导致动画永久停摆。
        let ticker = FrameTicker.shared
        let beat = ticker.beat(every: 0.15)
        ticker.acquire(beat)
        defer { ticker.release(beat) }

        // 连续多次 reevaluate 相当于反复停/启，代号机制保证不会互相清空。
        for _ in 0..<5 { ticker.reevaluate() }
        XCTAssertTrue(ticker.isRunning, "反复 reevaluate 后时钟仍应在运行")
    }

    func testStopThenStartLeavesTickerRunning() {
        let ticker = FrameTicker.shared
        let beat = ticker.beat(every: 0.15)
        ticker.acquire(beat)
        defer { ticker.release(beat) }

        // 模拟一次能耗档位切换：停 → 再启。
        ticker.reevaluate()
        ticker.reevaluate()
        XCTAssertTrue(ticker.isRunning)
    }
}
