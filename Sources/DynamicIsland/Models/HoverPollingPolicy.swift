import Foundation

enum HoverPollingPolicy {
    static func canSample(windowVisible: Bool, windowOccluded: Bool,
                          applicationHidden: Bool, hiddenByIslandSwitch: Bool) -> Bool {
        windowVisible && !windowOccluded && !applicationHidden && !hiddenByIslandSwitch
    }

    enum Cadence: Equatable {
        case paused
        case idle
        case responsive
        case reducedMotion

        var interval: TimeInterval? {
            switch self {
            case .paused: nil
            case .idle, .reducedMotion: 0.2
            case .responsive: 1.0 / 60.0
            }
        }
    }

    static func cadence(
        isVisible: Bool,
        isDragging: Bool,
        pointerLocation: CGPoint,
        hoverFrame: CGRect,
        allowsContinuousMotion: Bool,
        recentPointerMovement: Bool = true
    ) -> Cadence {
        guard isVisible else { return .paused }
        guard !isDragging else { return .idle }
        guard allowsContinuousMotion else { return .reducedMotion }
        guard recentPointerMovement else { return .idle }
        // 磁吸会在窗口外生效；提前升频，保留接近药丸时的反馈。
        return hoverFrame.insetBy(dx: -80, dy: -80).contains(pointerLocation) ? .responsive : .idle
    }
}

/// 仅由主线程调用。隐藏时取消 Timer，显示通知会重新建立采样。
final class HoverPollingController {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Timer
    private let schedule: Scheduler
    private var timer: Timer?
    private var generation: UInt = 0
    private(set) var cadence: HoverPollingPolicy.Cadence = .paused

    init(schedule: @escaping Scheduler = { interval, action in
        let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }) {
        self.schedule = schedule
    }

    func update(cadence: HoverPollingPolicy.Cadence, action: @escaping () -> Void) {
        guard self.cadence != cadence else { return }
        stop()
        self.cadence = cadence
        guard let interval = cadence.interval else { return }
        let currentGeneration = generation
        timer = schedule(interval) { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            action()
        }
    }

    func stop() {
        generation &+= 1
        timer?.invalidate()
        timer = nil
        cadence = .paused
    }

    deinit { timer?.invalidate() }
}
