/// 记录这一轮待办是否借用了 xnook 的显示权，重复请求不会累加恢复次数。
struct ApprovalInterruptionState {
    private var needsRestore = false

    mutating func markInterrupted() {
        needsRestore = true
    }

    mutating func takeRestorationIfReady(hasPendingInteractions: Bool) -> Bool {
        guard needsRestore, !hasPendingInteractions else { return false }
        needsRestore = false
        return true
    }

    mutating func cancelIfFinished(hasPendingInteractions: Bool) {
        // 外部处理或新一轮任务使最后一个旧请求失效时，不再抢回显示权。
        if !hasPendingInteractions { needsRestore = false }
    }
}
