import Foundation
import CoreFoundation

@MainActor
final class HistoryRetentionMaintenance {
    private let manager: SessionPersistenceManager
    private let defaults: UserDefaults
    private let interval: TimeInterval
    nonisolated(unsafe) private var timer: Timer?
    private var backgroundTask: Task<Void, Never>?
    private var usesBackground = false
    private var backgroundGeneration = 0

    var isRunning: Bool { timer?.isValid == true }

    init(manager: SessionPersistenceManager, defaults: UserDefaults, interval: TimeInterval = 3600) {
        precondition(interval.isFinite && interval > 0)
        self.manager = manager
        self.defaults = defaults
        self.interval = interval
    }

    deinit {
        timer?.invalidate()
        backgroundTask?.cancel()
    }

    func start() {
        guard !isRunning else { return }
        usesBackground = false
        run()
        installTimer()
    }

    func startInBackground() {
        guard !isRunning else { return }
        usesBackground = true
        installTimer()
        scheduleBackgroundRun()
    }

    private func installTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self, weak timer] in
                // stop 或重新 start 后，旧计时器已排队的回调也不能执行清理。
                guard let self, let timer, self.timer === timer, timer.isValid else { return }
                if self.usesBackground { self.scheduleBackgroundRun() } else { self.run() }
            }
        }
    }

    func stop() {
        backgroundGeneration += 1
        timer?.invalidate()
        timer = nil
        backgroundTask?.cancel()
        backgroundTask = nil
    }

    func run() {
        if let days = retentionDays() { manager.cleanup(olderThanDays: days) }
    }

    func runInBackground() async {
        guard let days = retentionDays(), days != .max else { return }
        do { try await manager.cleanupAsync(olderThanDays: days) }
        catch { /* 管理器保留真实存储错误；取消/被新写入取代时等待下一周期。 */ }
    }

    private func scheduleBackgroundRun() {
        guard backgroundTask == nil else { return }
        backgroundGeneration += 1
        let generation = backgroundGeneration
        backgroundTask = Task { [weak self] in
            await self?.runInBackground()
            if self?.backgroundGeneration == generation { self?.backgroundTask = nil }
        }
    }

    private func retentionDays() -> Int? {
        guard let value = defaults.object(forKey: "historyRetentionDays") else {
            return 30
        }
        // integer(forKey:) 会把非法值转换为 0；0 是显式清空语义，不能用于自动维护。
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
              let days = Int(number.stringValue), days > 0 else { return nil }
        return days
    }
}
