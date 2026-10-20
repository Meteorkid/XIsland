import Foundation

enum RecentActivitySelection {
    private struct Candidate {
        let session: AgentSession
        let event: ToolEvent
        let ordinal: Int
    }

    /// 扫描完整历史处理迟到事件；候选最多 30 项，不创建全量活动副本。
    static func latest(in sessions: [AgentSession], limit: Int = 30) -> [(session: AgentSession, event: ToolEvent)] {
        let capacity = min(max(limit, 0), 30)
        guard capacity > 0 else { return [] }
        var heap: [Candidate] = []
        heap.reserveCapacity(capacity)
        var ordinal = 0
        for session in sessions {
            for event in session.events {
                let candidate = Candidate(session: session, event: event, ordinal: ordinal)
                ordinal += 1
                if heap.count < capacity {
                    heap.append(candidate)
                    var child = heap.count - 1
                    while child > 0 {
                        let parent = (child - 1) / 2
                        guard precedes(heap[parent], heap[child]) else { break }
                        heap.swapAt(parent, child)
                        child = parent
                    }
                } else if precedes(candidate, heap[0]) {
                    // 根节点始终是当前最差候选，新事件只有更靠前才替换它。
                    heap[0] = candidate
                    var parent = 0
                    while parent * 2 + 1 < heap.count {
                        var child = parent * 2 + 1
                        let right = child + 1
                        if right < heap.count, precedes(heap[child], heap[right]) { child = right }
                        guard precedes(heap[parent], heap[child]) else { break }
                        heap.swapAt(parent, child)
                        parent = child
                    }
                }
            }
        }
        return heap.sorted(by: precedes).map { (session: $0.session, event: $0.event) }
    }

    private static func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.event.timestamp != rhs.event.timestamp { return lhs.event.timestamp > rhs.event.timestamp }
        if lhs.session.id != rhs.session.id { return lhs.session.id < rhs.session.id }
        if lhs.event.id != rhs.event.id { return lhs.event.id.uuidString < rhs.event.id.uuidString }
        return lhs.ordinal < rhs.ordinal
    }
}
