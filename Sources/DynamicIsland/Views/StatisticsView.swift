import SwiftUI
import Charts
import SwiftData

/// 统计分析面板 —— 展示会话历史的汇总卡片和四张图表
struct StatisticsView: View {
    @Environment(SessionPersistenceManager.self) private var persistenceManager
    @Environment(ThemeManager.self) private var themeManager
    @State private var timeRange: TimeRange = .week
    @State private var sessions: [StoredSession] = []

    // MARK: - Time Range

    enum TimeRange: String, CaseIterable {
        case week, month, all

        var displayName: String {
            switch self {
            case .week: return L10n.timeRangeWeek
            case .month: return L10n.timeRangeMonth
            case .all: return L10n.timeRangeAll
            }
        }
    }

    // MARK: - Aggregation Models

    struct DailyUsage: Identifiable {
        let id = UUID()
        let date: Date
        var sessionCount: Int
        var totalDuration: TimeInterval
        var totalTokens: Int
        var totalCost: Double
    }

    struct AgentUsage: Identifiable {
        let id = UUID()
        let agentType: AgentType
        var sessionCount: Int
    }

    struct ToolFrequency: Identifiable {
        let id = UUID()
        let toolName: String
        var callCount: Int
    }

    // MARK: - Computed Aggregated Data

    private var filteredSessions: [StoredSession] {
        let calendar = Calendar.current
        let now = Date()
        switch timeRange {
        case .week:
            let cutoff = calendar.date(byAdding: .day, value: -7, to: now) ?? now
            return sessions.filter { $0.startTime >= cutoff }
        case .month:
            let cutoff = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            return sessions.filter { $0.startTime >= cutoff }
        case .all:
            return sessions
        }
    }

    private var dailyUsages: [DailyUsage] {
        let calendar = Calendar.current
        var map: [Date: DailyUsage] = [:]
        for session in filteredSessions {
            let day = calendar.startOfDay(for: session.startTime)
            if map[day] == nil {
                map[day] = DailyUsage(date: day, sessionCount: 0, totalDuration: 0, totalTokens: 0, totalCost: 0)
            }
            map[day]?.sessionCount += 1
            map[day]?.totalDuration += session.duration
            map[day]?.totalTokens += session.totalTokens
            map[day]?.totalCost += session.estimatedCostUSD
        }
        return map.values.sorted { $0.date < $1.date }
    }

    private var agentUsages: [AgentUsage] {
        var map: [AgentType: Int] = [:]
        for session in filteredSessions {
            map[session.agentType, default: 0] += 1
        }
        return map.map { AgentUsage(agentType: $0.key, sessionCount: $0.value) }
            .sorted { $0.sessionCount > $1.sessionCount }
    }

    private var toolFrequencies: [ToolFrequency] {
        var map: [String: Int] = [:]
        for session in filteredSessions {
            for event in session.toolEvents where event.isComplete {
                map[event.tool, default: 0] += 1
            }
        }
        return map.map { ToolFrequency(toolName: $0.key, callCount: $0.value) }
            .sorted { $0.callCount > $1.callCount }
            .prefix(10)
            .map { $0 }
    }

    private var tokenTrend: [DailyUsage] {
        dailyUsages
    }

    // MARK: - Summary

    private var totalCount: Int { filteredSessions.count }

    private var totalDurationText: String {
        let total = filteredSessions.reduce(0) { $0 + $1.duration }
        let hours = Int(total) / 3600
        let mins = (Int(total) % 3600) / 60
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    private var totalCostText: String {
        let total = filteredSessions.reduce(0) { $0 + $1.estimatedCostUSD }
        return String(format: "$%.2f", total)
    }

    private var totalTokensText: String {
        let total = filteredSessions.reduce(0) { $0 + $1.totalTokens }
        if total >= 1_000_000 {
            return String(format: "%.1fM", Double(total) / 1_000_000)
        } else if total >= 1_000 {
            return String(format: "%.1fK", Double(total) / 1_000)
        }
        return "\(total)"
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 时间范围选择器
                timeRangePicker

                if filteredSessions.isEmpty {
                    emptyState
                } else {
                    summaryCards
                    dailyUsageChart
                    agentDistributionChart
                    topToolsChart
                    tokenTrendChart
                }
            }
            .padding(.vertical, 16)
        }
        .task {
            sessions = persistenceManager.fetchHistory(limit: 5000)
        }
    }

    // MARK: - Time Range Picker

    private var timeRangePicker: some View {
        HStack {
            Text(L10n.sectionStatistics)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
            Spacer()
            Picker("", selection: $timeRange) {
                ForEach(TimeRange.allCases, id: \.self) { range in
                    Text(range.displayName).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(L10n.noHistory)
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        HStack(spacing: 12) {
            summaryCard(title: L10n.statTotalSessions, value: "\(totalCount)", icon: "list.bullet")
            summaryCard(title: L10n.statTotalDuration, value: totalDurationText, icon: "clock.fill")
            summaryCard(title: L10n.statTotalCost, value: totalCostText, icon: "dollarsign.circle.fill")
            summaryCard(title: L10n.statTotalTokens, value: totalTokensText, icon: "cpu")
        }
    }

    private func summaryCard(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.blue)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.quaternary.opacity(0.5), lineWidth: 0.5)
        )
    }

    // MARK: - Daily Usage Bar Chart

    private var dailyUsageChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.statDailyUsage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)

            if dailyUsages.isEmpty {
                emptyChartPlaceholder
            } else {
                Chart(dailyUsages) { usage in
                    BarMark(
                        x: .value("Date", usage.date, unit: .day),
                        y: .value("Sessions", usage.sessionCount)
                    )
                    .foregroundStyle(by: .value("Date", usage.date, unit: .day))
                    .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3, dash: [4]))
                        AxisValueLabel(format: .dateTime.month().day(), centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3, dash: [4]))
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 200)
            }
        }
    }

    // MARK: - Agent Distribution Donut Chart

    private var agentDistributionChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.statAgentDistribution)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)

            if agentUsages.isEmpty {
                emptyChartPlaceholder
            } else {
                Chart(agentUsages) { usage in
                    SectorMark(
                        angle: .value("Sessions", usage.sessionCount),
                        innerRadius: .ratio(0.6)
                    )
                    .foregroundStyle(usage.agentType.color)
                    .annotation(position: .overlay) {
                        if Double(usage.sessionCount) / Double(totalCount) > 0.1 {
                            Text("\(usage.sessionCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .chartLegend(position: .bottom) {
                    HStack(spacing: 12) {
                        ForEach(agentUsages) { usage in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(usage.agentType.color)
                                    .frame(width: 8, height: 8)
                                Text(usage.agentType.shortName)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(height: 200)
            }
        }
    }

    // MARK: - Top Tools Horizontal Bar Chart

    private var topToolsChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.statTopTools)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)

            if toolFrequencies.isEmpty {
                emptyChartPlaceholder
            } else {
                Chart(toolFrequencies) { tool in
                    BarMark(
                        x: .value("Count", tool.callCount),
                        y: .value("Tool", tool.toolName)
                    )
                    .foregroundStyle(.blue.gradient)
                    .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3, dash: [4]))
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0))
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 200)
            }
        }
    }

    // MARK: - Token Trend Line Chart

    private var tokenTrendChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.statTokenTrend)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)

            if tokenTrend.isEmpty {
                emptyChartPlaceholder
            } else {
                Chart(tokenTrend) { usage in
                    LineMark(
                        x: .value("Date", usage.date, unit: .day),
                        y: .value("Tokens", usage.totalTokens)
                    )
                    .foregroundStyle(.blue)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Date", usage.date, unit: .day),
                        y: .value("Tokens", usage.totalTokens)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue.opacity(0.3), .blue.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3, dash: [4]))
                        AxisValueLabel(format: .dateTime.month().day(), centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3, dash: [4]))
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 200)
            }
        }
    }

    // MARK: - Helpers

    private var emptyChartPlaceholder: some View {
        Text(L10n.noHistory)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 120)
    }
}
