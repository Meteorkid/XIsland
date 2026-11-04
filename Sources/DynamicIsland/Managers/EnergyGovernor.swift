import Foundation
import Observation
import AppKit

/// 应用整体的运行档位。参照 ping-island 的 `EnergyGovernor`，但只保留本项目真正消费的维度。
enum EnergyMode: String, Equatable {
    /// 有会话活动或面板展开：全速。
    case active
    /// 岛可见但一段时间没有新事件：降低刷新。
    case idleVisible
    /// 长时间无事件：停止动画。
    case quietBackground
    /// 锁屏或合盖：停止一切定时工作。
    case systemSuspended
    /// 刚唤醒：先给系统一点恢复时间，不要立刻跑全套刷新。
    case wakeGrace
}

enum EnergyAnimationLevel: Equatable {
    case full
    /// 保留接口；当前与 `full` 同义，避免在没有实测数据时臆造降帧策略。
    case reduced
    /// 停止推进动画时钟。
    case staticFrames
}

struct EnergyPolicy: Equatable {
    let animationLevel: EnergyAnimationLevel
    /// 是否允许文件监听在失败后自动重试。
    let allowsFileWatcherRetry: Bool

    static func policy(for mode: EnergyMode) -> EnergyPolicy {
        switch mode {
        case .active:
            return EnergyPolicy(animationLevel: .full, allowsFileWatcherRetry: true)
        case .idleVisible:
            // 不臆造帧率：实测前维持 full。
            return EnergyPolicy(animationLevel: .full, allowsFileWatcherRetry: true)
        case .quietBackground:
            return EnergyPolicy(animationLevel: .staticFrames, allowsFileWatcherRetry: true)
        case .systemSuspended:
            return EnergyPolicy(animationLevel: .staticFrames, allowsFileWatcherRetry: false)
        case .wakeGrace:
            return EnergyPolicy(animationLevel: .full, allowsFileWatcherRetry: true)
        }
    }
}

/// 跨线程的"有活动"信号。合并同一轮内的多次投递，避免主线程被高频事件淹没。
private final class PendingActivitySignal: @unchecked Sendable {
    private let lock = NSLock()
    private var queued = false

    /// 返回 true 表示本次需要投递；false 表示已有一个在排队，直接合并。
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

/// 根据系统事件与会话活动决定运行档位，并驱动 `FrameTicker` 起停。
///
/// 只做两件事：给出 `mode`，以及在档位变化时通知订阅方重新评估。
/// 具体某个功能是否降频仍由各自模块决定，避免把策略集中成一个上帝对象。
@MainActor
@Observable
final class EnergyGovernor {
    static let shared = EnergyGovernor()

    /// 闲置多久后进入 `idleVisible`。标 `nonisolated`：`resolveMode` 是非隔离纯函数，
    /// Swift 6 语言模式下从非隔离上下文引用主 actor 隔离的静态属性会报错。
    nonisolated static let idleThreshold: TimeInterval = 30
    /// 闲置多久后进入 `quietBackground`。
    nonisolated static let quietThreshold: TimeInterval = 5 * 60
    /// 唤醒后的宽限期，期间不进入低功耗档。
    nonisolated static let wakeGraceDuration: TimeInterval = 8

    private(set) var mode: EnergyMode = .active
    private(set) var isPanelExpanded = false

    private var lastActivityAt = Date()
    private var suspended = false
    private var wakeGraceUntil: Date?
    private var evaluateTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// 跨线程活动信号。`nonisolated` 才能被后台线程访问。
    private nonisolated static let pendingSignal = PendingActivitySignal()

    var policy: EnergyPolicy { EnergyPolicy.policy(for: mode) }

    private init() {}

    /// 开始监听锁屏、睡眠与唤醒。重复调用无副作用。
    func start() {
        guard observers.isEmpty else { return }

        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        add(workspace, NSWorkspace.willSleepNotification) { [weak self] in
            self?.suspend()
        }
        add(workspace, NSWorkspace.didWakeNotification) { [weak self] in
            self?.resumeAfterGrace()
        }
        add(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.suspend()
        }
        add(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.resumeAfterGrace()
        }
        // 锁屏不等于睡眠：合盖会睡眠，仅锁屏（Ctrl+Cmd+Q）不触发 willSleep。
        add(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            self?.suspend()
        }
        add(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in
            self?.resumeAfterGrace()
        }

        startEvaluating()
    }

    /// 有新的会话事件、用户交互或面板状态变化时调用。
    func noteActivity() {
        lastActivityAt = Date()
        evaluate()
    }

    /// 从后台线程标记"有活动"。
    ///
    /// 合并同一轮 runloop 内的多次调用：高频 hook 下每次消息都往主线程投递
    /// 一个 Task 会造成明显堆积，而活动时间只需要精确到秒级。
    nonisolated static func signalActivityFromBackground() {
        // 已有一次待处理的投递就不再排队，多个事件合并为一次主线程更新。
        guard pendingSignal.begin() else { return }
        DispatchQueue.main.async {
            pendingSignal.end()
            MainActor.assumeIsolated { shared.noteActivity() }
        }
    }

    func notePanelExpanded(_ expanded: Bool) {
        isPanelExpanded = expanded
        if expanded { lastActivityAt = Date() }
        evaluate()
    }

    /// 供测试注入的评估入口：给定时刻与闲置时长，返回应处于的档位。
    nonisolated static func resolveMode(
        suspended: Bool,
        inWakeGrace: Bool,
        isPanelExpanded: Bool,
        idleFor: TimeInterval
    ) -> EnergyMode {
        if suspended { return .systemSuspended }
        if inWakeGrace { return .wakeGrace }
        if isPanelExpanded { return .active }
        if idleFor < idleThreshold { return .active }
        if idleFor < quietThreshold { return .idleVisible }
        return .quietBackground
    }

    // MARK: - 内部

    private func add(_ center: NotificationCenter, _ name: Notification.Name,
                     handler: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        observers.append(token)
    }

    /// 停止监听并清理评估任务。单例场景下不会走到，但测试与将来的多实例需要它，
    /// 否则观察者会一直挂在通知中心上。
    func stop() {
        evaluateTask?.cancel()
        evaluateTask = nil
        for token in observers {
            // 两个中心都尝试移除，移除不存在的观察者是无害的。
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            DistributedNotificationCenter.default().removeObserver(token)
        }
        observers.removeAll()
    }

    private func suspend() {
        suspended = true
        evaluate()
    }

    private func resumeAfterGrace() {
        suspended = false
        wakeGraceUntil = Date().addingTimeInterval(Self.wakeGraceDuration)
        lastActivityAt = Date()
        evaluate()
    }

    private func startEvaluating() {
        evaluateTask?.cancel()
        // 30 秒评估一次足够：档位切换的粒度是分钟级，更密的轮询本身违反低功耗目的。
        evaluateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.evaluate()
            }
        }
    }

    private func evaluate() {
        let now = Date()
        let inGrace = wakeGraceUntil.map { now < $0 } ?? false
        let next = Self.resolveMode(
            suspended: suspended,
            inWakeGrace: inGrace,
            isPanelExpanded: isPanelExpanded,
            idleFor: now.timeIntervalSince(lastActivityAt)
        )
        guard next != mode else { return }
        mode = next
        FrameTicker.shared.reevaluate()
    }
}
