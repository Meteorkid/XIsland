import Foundation

/// 合并同一批任务事件，展示前复核代次，避免已解决请求或旧完成抢走显示权。
@MainActor
final class TaskAttentionPresenter {
    struct Environment {
        var isEnabled: () -> Bool
        var isCurrent: (TaskAttentionEvent) -> Bool
        var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
        var present: (TaskAttentionEvent) -> Void
    }

    private let environment: Environment
    private var pending: [TaskAttentionEvent] = []
    private var cancelScheduled: (() -> Void)?
    private var generation: UInt64 = 0

    init(environment: Environment) { self.environment = environment }

    func enqueue(_ event: TaskAttentionEvent) {
        guard environment.isEnabled() else { return }
        pending.append(event)
        guard cancelScheduled == nil else { return }
        generation &+= 1
        let expected = generation
        cancelScheduled = environment.schedule(0.08) { [weak self] in
            guard let self, self.generation == expected else { return }
            self.cancelScheduled = nil
            let candidates = self.pending.filter(self.environment.isCurrent)
            self.pending.removeAll()
            guard self.environment.isEnabled() else { return }
            // 同批只显示一次；实际交互优先，多个完成选择最近到达者。
            guard let event = candidates.first(where: { $0.kind != .completion }) ?? candidates.last else { return }
            self.environment.present(event)
        }
    }

    func cancel() {
        generation &+= 1
        cancelScheduled?()
        cancelScheduled = nil
        pending.removeAll()
    }
}
