import Foundation

/// 统计只保留汇总与镜像去重所需的值，不持有跨批次的 SwiftData 对象。
struct HistoryStatistics: Sendable {
    enum TimeRange: String, CaseIterable, Sendable {
        case week, month, all

        func cutoff(now: Date, calendar: Calendar) -> Date? {
            switch self {
            case .week: return calendar.date(byAdding: .day, value: -7, to: now)
            case .month: return calendar.date(byAdding: .day, value: -30, to: now)
            case .all: return nil
            }
        }
    }

    struct DailyUsage: Identifiable, Sendable {
        var id: Date { date }
        let date: Date
        var sessionCount: Int = 0
        var totalDuration: TimeInterval = 0
        var totalTokens: Int = 0
        var totalCost: Double = 0
    }

    struct AgentUsage: Identifiable, Sendable {
        var id: String { agentType.rawValue }
        let agentType: AgentType
        let sessionCount: Int
    }

    struct ToolFrequency: Identifiable, Sendable {
        var id: String { toolName }
        let toolName: String
        let callCount: Int
    }

    /// SwiftUI 的任务身份同时包含范围和持久化修订号。
    struct LoadRequest: Equatable, Sendable {
        let timeRange: TimeRange
        let revision: Int
        var retry = 0
    }

    struct LoadState {
        private(set) var statistics: HistoryStatistics?
        private(set) var errorMessage: String?

        mutating func begin() { statistics = nil; errorMessage = nil }
        mutating func accept(_ result: HistoryStatistics) { statistics = result; errorMessage = nil }
        mutating func fail(_ error: Error) { statistics = nil; errorMessage = error.localizedDescription }

        @MainActor
        mutating func reload(from manager: SessionPersistenceManager, timeRange: TimeRange,
                             now: Date = Date(), calendar: Calendar = .current) {
            do {
                statistics = try HistoryStatistics.load(from: manager, timeRange: timeRange,
                                                        now: now, calendar: calendar)
                errorMessage = nil
            } catch {
                // 失败不能显示为零，也不能继续把上一版统计当作当前结果。
                statistics = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    let totalCount: Int
    let totalDuration: TimeInterval
    let totalTokens: Int
    let totalCost: Double
    let dailyUsages: [DailyUsage]
    let agentUsages: [AgentUsage]
    let toolFrequencies: [ToolFrequency]

    @MainActor
    static func load(from manager: SessionPersistenceManager, timeRange: TimeRange,
                     now: Date = Date(), calendar: Calendar = .current) throws -> HistoryStatistics {
        try load(timeRange: timeRange, now: now, calendar: calendar) { visit in
            try manager.forEachHistoryBatch(visit)
        }
    }

    static func load(timeRange: TimeRange, now: Date = Date(), calendar: Calendar = .current,
                     forEachBatch: (_ visit: ([StoredSession]) throws -> Void) throws -> Void) throws -> HistoryStatistics {
        var accumulator = Accumulator(timeRange: timeRange, now: now, calendar: calendar)
        try forEachBatch {
            try Task.checkCancellation()
            accumulator.add($0)
        }
        try Task.checkCancellation()
        return accumulator.finish()
    }

    struct Accumulator {
        private struct NativeTaskKey: Hashable {
            let agent: String
            let namespace: String
            let task: Data
        }

        private enum ToolIdentity: Hashable {
            case native(Data)
            case event(UUID)
        }

        private struct NativeUsage {
            var startTime: Date
            let agentType: AgentType
            var intervals: [DateInterval] = []
            var totalTokens: Int
            var costUSD: Double
            var tools: Set<ToolIdentity> = []

            var summary: HistoryUsageSummary {
                var duration: TimeInterval = 0
                var end = startTime
                for interval in intervals.sorted(by: { $0.start < $1.start }) {
                    duration += max(0, interval.end.timeIntervalSince(max(end, interval.start)))
                    end = max(end, interval.end)
                }
                return HistoryUsageSummary(startTime: startTime, agentType: agentType,
                    duration: duration, totalTokens: totalTokens, costUSD: costUSD)
            }
        }

        private let cutoff: Date?
        private let now: Date
        private let calendar: Calendar
        private var nativeTasks: [NativeTaskKey: NativeUsage] = [:]
        private var daily: [Date: DailyUsage] = [:]
        private var agents: [AgentType: Int] = [:]
        private var tools: [String: Int] = [:]
        private var totalCount = 0
        private var totalDuration: TimeInterval = 0
        private var totalTokens = 0
        private var totalCost = 0.0

        init(timeRange: TimeRange, now: Date = Date(), calendar: Calendar = .current) {
            self.cutoff = timeRange.cutoff(now: now, calendar: calendar)
            self.now = now
            self.calendar = calendar
        }

        mutating func add(_ sessions: [StoredSession]) {
            for session in sessions {
                // 与原统计口径一致：先按片段开始时间筛选，再合并范围内的观察镜像。
                if let cutoff, session.startTime < cutoff { continue }
                if session.sourceInstanceId != nil,
                   let namespace = session.sourceNamespace, let task = session.nativeTaskId {
                    let key = NativeTaskKey(agent: session.agentTypeRaw, namespace: namespace,
                                            task: Data(task.utf8))
                    // 移出再更新，避免长任务的区间数组在每个片段追加时触发整份复制。
                    var usage = nativeTasks.removeValue(forKey: key) ?? NativeUsage(
                        startTime: session.startTime, agentType: session.agentType,
                        totalTokens: max(session.totalTokens, session.inputTokens + session.outputTokens),
                        costUSD: session.estimatedCostUSD)
                    usage.startTime = min(usage.startTime, session.startTime)
                    let stop = max(session.startTime, session.completedAt ?? session.observationEndedAt ?? now)
                    usage.intervals.append(DateInterval(start: session.startTime, end: stop))
                    usage.totalTokens = max(usage.totalTokens, max(session.totalTokens,
                                                                  session.inputTokens + session.outputTokens))
                    usage.costUSD = max(usage.costUSD, session.estimatedCostUSD)
                    for event in session.toolEvents where event.isComplete {
                        let identity: ToolIdentity?
                        if let callId = event.toolCallId, !callId.isEmpty {
                            identity = .native(Data(callId.utf8))
                        } else if let eventId = event.eventId {
                            identity = .event(eventId)
                        } else {
                            identity = nil
                        }
                        if let identity, !usage.tools.insert(identity).inserted { continue }
                        tools[event.tool, default: 0] += 1
                    }
                    nativeTasks[key] = usage
                } else {
                    // 普通会话立即汇总，不随历史总量保留每条会话。
                    if let summary = HistoryUsageSummary.aggregate([session], now: now).first {
                        addSummary(summary)
                    }
                    for event in session.toolEvents where event.isComplete {
                        tools[event.tool, default: 0] += 1
                    }
                }
            }
        }

        func finish() -> HistoryStatistics {
            var aggregate = self
            for usage in nativeTasks.values { aggregate.addSummary(usage.summary) }
            let dailyUsages: [DailyUsage] = aggregate.daily.values.sorted { $0.date < $1.date }
            let agentUsages: [AgentUsage] = aggregate.agents.map { AgentUsage(agentType: $0.key, sessionCount: $0.value) }
                .sorted { $0.sessionCount == $1.sessionCount
                    ? $0.agentType.rawValue < $1.agentType.rawValue : $0.sessionCount > $1.sessionCount }
            let sortedTools: [ToolFrequency] = aggregate.tools.map { ToolFrequency(toolName: $0.key, callCount: $0.value) }
                .sorted { $0.callCount == $1.callCount
                    ? $0.toolName < $1.toolName : $0.callCount > $1.callCount }
            return HistoryStatistics(totalCount: aggregate.totalCount, totalDuration: aggregate.totalDuration,
                totalTokens: aggregate.totalTokens, totalCost: aggregate.totalCost,
                dailyUsages: dailyUsages, agentUsages: agentUsages,
                toolFrequencies: Array(sortedTools.prefix(10)))
        }

        private mutating func addSummary(_ summary: HistoryUsageSummary) {
            totalCount += 1
            totalDuration += summary.duration
            totalTokens += summary.totalTokens
            totalCost += summary.costUSD
            agents[summary.agentType, default: 0] += 1
            let day = calendar.startOfDay(for: summary.startTime)
            var usage = daily[day] ?? DailyUsage(date: day)
            usage.sessionCount += 1
            usage.totalDuration += summary.duration
            usage.totalTokens += summary.totalTokens
            usage.totalCost += summary.costUSD
            daily[day] = usage
        }
    }
}
