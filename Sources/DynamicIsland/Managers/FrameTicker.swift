import Foundation
import Observation
import SwiftUI

/// 全应用共享的动画时钟。
///
/// 动机：`TimelineView(.periodic(from: .now, by: x))` 每个实例各起一个 timer，且以各自
/// 的 `.now` 为起点，相位互不对齐。收起态同时显示多个吉祥物时，系统里会同时存在多个
/// 非对齐唤醒源，能耗高于一个对齐的时钟。
///
/// 做法参照 CodeIsland 的 `FrameTicker`：所有订阅者共用一个 60Hz 网格，按需取整到网格
/// 的整数倍分频，且**没有任何订阅者时立即停止**。
///
/// 注意 `grid` 是网格粒度而非帧率：订阅 `0.15` 秒得到的是 6.7Hz，不是 60Hz。
@MainActor
@Observable
final class FrameTicker {
    static let shared = FrameTicker()

    /// 网格粒度。订阅间隔一律取整到它的整数倍。
    nonisolated static let grid: TimeInterval = 1.0 / 60

    /// 一个订阅频率。多个视图共享同一 `steps` 时拿到同一个实例。
    @Observable
    final class Beat {
        /// 只在属于本档的格点上前进。
        fileprivate(set) var now: Date = .now
        let steps: Int
        fileprivate var subscribers = 0
        /// 上次推进的时刻。不参与观察，否则每次 tick 都会多触发一轮无关重绘。
        @ObservationIgnored fileprivate var lastAdvancedAt: Date = .distantPast

        fileprivate init(steps: Int) { self.steps = steps }

        fileprivate var interval: TimeInterval { TimeInterval(steps) * FrameTicker.grid }
    }

    private var beats: [Int: Beat] = [:]
    /// 自增代号。旧循环退出时只在代号未变的情况下清空 `tickerTask`，
    /// 否则会把新一轮启动的 task 误清成 nil，导致动画永久停摆。
    private var taskGeneration: UInt64 = 0
    private var tickerTask: Task<Void, Never>?

    /// 是否有活跃订阅。供测试与诊断使用。
    var isRunning: Bool { tickerTask != nil }

    /// 当前活跃订阅数合计。
    var activeSubscriberCount: Int { beats.values.reduce(0) { $0 + $1.subscribers } }

    private init() {}

    /// 取订阅间隔对应的 `Beat`。同一间隔返回同一实例。
    func beat(every interval: TimeInterval) -> Beat {
        let steps = Self.steps(for: interval)
        if let existing = beats[steps] { return existing }
        let beat = Beat(steps: steps)
        beats[steps] = beat
        return beat
    }

    func acquire(_ beat: Beat) {
        beat.subscribers += 1
        startIfNeeded()
    }

    func release(_ beat: Beat) {
        beat.subscribers = max(0, beat.subscribers - 1)
        if activeSubscriberCount == 0 { stop() }
    }

    /// 把间隔取整到网格，至少一格。
    nonisolated static func steps(for interval: TimeInterval) -> Int {
        guard interval.isFinite, interval > 0 else { return 1 }
        return max(1, Int((interval / grid).rounded()))
    }

    private func startIfNeeded() {
        guard tickerTask == nil else { return }
        guard allowsAnimation else { return }
        taskGeneration &+= 1
        let generation = taskGeneration
        tickerTask = Task { [weak self] in
            while let self, self.activeSubscriberCount > 0, !Task.isCancelled {
                guard self.allowsAnimation else { break }
                // 对齐到绝对时间网格：按"到下一个格点还差多久"睡眠，避免误差累积。
                let remainder = Date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: Self.grid)
                let wait = Self.grid - remainder
                try? await Task.sleep(nanoseconds: UInt64(max(wait, 0) * 1_000_000_000))
                self.tick()
            }
            // 只有仍是本轮启动的 task 才允许清空，避免清掉新一轮的 task。
            if let self, self.taskGeneration == generation {
                self.tickerTask = nil
            }
        }
    }

    /// 能耗档位允许推进动画。锁屏、睡眠与长时间无事件时返回 false。
    private var allowsAnimation: Bool {
        EnergyGovernor.shared.policy.animationLevel != .staticFrames
    }

    /// 档位变化后重新决定起停。订阅者仍然存在，只是暂时不推进。
    func reevaluate() {
        if allowsAnimation {
            if activeSubscriberCount > 0 { startIfNeeded() }
        } else {
            stop()
        }
    }

    private func stop() {
        taskGeneration &+= 1
        tickerTask?.cancel()
        tickerTask = nil
    }

    private func tick() {
        guard allowsAnimation else { return }
        let now = Date()
        for beat in beats.values where beat.subscribers > 0 {
            // 按"距上次推进是否已过一个间隔"判断，而不是 `tickIndex % steps == 0`。
            //
            // 原因：`Task.sleep` 不保证准时，一次超时就会让取模判断跳过整拍，
            // 该档动画会卡住直到下一次对齐——表现为偶发的短暂停顿。
            // 时间差判断天然容忍抖动，最多晚一个间隔。
            guard now.timeIntervalSince(beat.lastAdvancedAt) >= beat.interval else { continue }
            beat.lastAdvancedAt = now
            beat.now = now
        }
    }
}

/// 把 `FrameTicker` 接到 SwiftUI 视图上，替代 `TimelineView(.periodic(from: .now, by:))`。
///
/// 与 `TimelineView` 的差别：多个实例订阅同一间隔时共用一个 timer，且视图全部离屏后
/// ticker 自动停止，不再有后台唤醒。
///
/// 订阅生命周期挂在 `.task` 上：视图消失时 SwiftUI 取消 task，`defer` 随之释放订阅，
/// 不需要额外维护 `@State` 计数。
@MainActor
struct SharedFrameClock<Content: View>: View {
    let interval: TimeInterval
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        // body 本身是 @MainActor，可直接取共享 Beat；同一 interval 返回同一实例，
        // 读取 `beat.now` 让 Observation 建立依赖，tick 时只有这一档订阅者重算。
        let beat = FrameTicker.shared.beat(every: interval)
        content(beat.now)
            .task(id: interval) {
                let ticker = FrameTicker.shared
                ticker.acquire(beat)
                defer { ticker.release(beat) }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                }
            }
    }
}
