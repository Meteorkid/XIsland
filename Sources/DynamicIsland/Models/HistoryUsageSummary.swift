import Foundation

/// 保留历史片段，只在统计时合并同一来源原生任务的累计快照。
struct HistoryUsageSummary {
    private enum Key: Hashable {
        case native(agent: String, namespace: String, task: Data)
        case session(String)
    }
    let startTime: Date
    let agentType: AgentType
    let duration: TimeInterval
    let totalTokens: Int
    let costUSD: Double

    static func aggregate(_ sessions: [StoredSession], now: Date = Date()) -> [HistoryUsageSummary] {
        let groups = Dictionary(grouping: sessions) { session -> Key in
            if session.sourceInstanceId != nil, let namespace = session.sourceNamespace, let task = session.nativeTaskId {
                return .native(agent: session.agentTypeRaw, namespace: namespace, task: Data(task.utf8))
            }
            return .session(session.sessionId)
        }
        return groups.values.map { records in
            let sorted = records.sorted { $0.startTime < $1.startTime }
            let first = sorted[0]
            var duration: TimeInterval = 0
            var end = first.startTime
            for record in sorted {
                let stop = max(record.startTime, record.completedAt ?? record.observationEndedAt ?? now)
                duration += max(0, stop.timeIntervalSince(max(end, record.startTime)))
                end = max(end, stop)
            }
            return HistoryUsageSummary(startTime: first.startTime, agentType: first.agentType,
                duration: duration,
                totalTokens: records.map { record in
                    record.sourceInstanceId == nil ? record.totalTokens
                        : max(record.totalTokens, record.inputTokens + record.outputTokens)
                }.max() ?? 0,
                costUSD: records.map(\.estimatedCostUSD).max() ?? 0)
        }
    }
}
