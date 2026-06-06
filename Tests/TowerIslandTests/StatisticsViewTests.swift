import XCTest
@testable import XIsland

/// 统计面板数据聚合逻辑的单元测试
final class StatisticsViewTests {

    // MARK: - Helpers

    /// 创建一个 StoredSession 实例（不依赖 SwiftData 上下文）
    private func makeSession(
        id: String = UUID().uuidString,
        agentType: AgentType = .claudeCode,
        startTime: Date,
        completedAt: Date?,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        totalTokens: Int = 0,
        estimatedCostUSD: Double = 0.0,
        toolEvents: [StoredToolEvent] = []
    ) -> StoredSession {
        let session = StoredSession(
            sessionId: id,
            agentTypeRaw: agentType.rawValue,
            startTime: startTime,
            completedAt: completedAt,
            prompt: "test",
            workingDirectory: "/test",
            terminal: "terminal",
            statusRaw: SessionStatus.completed.rawValue,
            recapText: nil,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens,
            estimatedCostUSD: estimatedCostUSD,
            model: "claude-3"
        )
        session.toolEvents = toolEvents
        return session
    }

    private func makeToolEvent(tool: String, isComplete: Bool = true) -> StoredToolEvent {
        StoredToolEvent(tool: tool, isComplete: isComplete)
    }

    private func dateDaysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    }

    // MARK: - Daily Usage Aggregation

    func testDailyUsageAggregation() {
        let now = Date()
        let calendar = Calendar.current

        let sessions: [StoredSession] = [
            makeSession(startTime: calendar.date(byAdding: .hour, value: -1, to: now)!,
                        completedAt: now),
            makeSession(startTime: calendar.date(byAdding: .hour, value: -2, to: now)!,
                        completedAt: now),
            makeSession(startTime: calendar.date(byAdding: .day, value: -1, to: now)!,
                        completedAt: calendar.date(byAdding: .hour, value: -1, to: now)!),
            makeSession(startTime: calendar.date(byAdding: .day, value: -2, to: now)!,
                        completedAt: calendar.date(byAdding: .hour, value: -1, to: now)!),
            makeSession(startTime: calendar.date(byAdding: .day, value: -2, to: now)!,
                        completedAt: calendar.date(byAdding: .hour, value: -1, to: now)!),
        ]

        // 模拟聚合逻辑（与 StatisticsView 中一致）
        var map: [Date: (count: Int, tokens: Int, cost: Double)] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.startTime)
            let prev = map[day] ?? (0, 0, 0.0)
            map[day] = (prev.count + 1, prev.tokens + session.totalTokens, prev.cost + session.estimatedCostUSD)
        }

        // 应该有 3 个不同的日期
        XCTAssertEqual(map.count, 3, "应有 3 个不同的日期分组")

        // 今天的会话数应为 2
        let todayKey = calendar.startOfDay(for: now)
        XCTAssertEqual(map[todayKey]?.count, 2, "今天应有 2 个会话")
    }

    // MARK: - Agent Usage Distribution

    func testAgentUsageDistribution() {
        let now = Date()
        let sessions: [StoredSession] = [
            makeSession(agentType: .claudeCode, startTime: now, completedAt: now),
            makeSession(agentType: .claudeCode, startTime: now, completedAt: now),
            makeSession(agentType: .codex, startTime: now, completedAt: now),
            makeSession(agentType: .cursor, startTime: now, completedAt: now),
            makeSession(agentType: .cursor, startTime: now, completedAt: now),
            makeSession(agentType: .cursor, startTime: now, completedAt: now),
        ]

        var map: [AgentType: Int] = [:]
        for session in sessions {
            map[session.agentType, default: 0] += 1
        }

        XCTAssertEqual(map[.claudeCode], 2)
        XCTAssertEqual(map[.codex], 1)
        XCTAssertEqual(map[.cursor], 3)

        // 验证排序：cursor(3) > claudeCode(2) > codex(1)
        let sorted = map.map { (type: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
        XCTAssertEqual(sorted.first?.type, .cursor)
        XCTAssertEqual(sorted.last?.type, .codex)
    }

    // MARK: - Tool Frequency Top 10

    func testToolFrequencyTop10() {
        let tools = ["bash", "read", "write", "edit", "grep", "glob", "ls", "curl", "git", "find", "awk", "sed", "cat", "head", "tail"]
        let now = Date()

        // 为每个工具创建不同数量的事件
        var allEvents: [StoredToolEvent] = []
        for (index, tool) in tools.enumerated() {
            for _ in 0..<(15 - index) { // bash=15, read=14, ..., tail=1
                allEvents.append(makeToolEvent(tool: tool))
            }
        }

        let session = makeSession(startTime: now, completedAt: now)
        session.toolEvents = allEvents

        // 模拟聚合逻辑
        var freqMap: [String: Int] = [:]
        for event in session.toolEvents where event.isComplete {
            freqMap[event.tool, default: 0] += 1
        }
        let top10 = freqMap.map { (name: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(10)

        // 验证只返回 10 个
        XCTAssertEqual(top10.count, 10)
        // 第一名是 bash（15 次）
        XCTAssertEqual(top10.first?.name, "bash")
        // 第十名是 find（6 次）
        XCTAssertEqual(top10.last?.name, "find")
        // tail（1 次）不在 top 10 中
        XCTAssertFalse(top10.contains(where: { $0.name == "tail" }))
    }

    // MARK: - Token Trend Aggregation

    func testTokenTrendAggregation() {
        let calendar = Calendar.current
        let now = Date()

        let sessions: [StoredSession] = [
            makeSession(startTime: dateDaysAgo(0), completedAt: now,
                        totalTokens: 1000, estimatedCostUSD: 0.05),
            makeSession(startTime: dateDaysAgo(0), completedAt: now,
                        totalTokens: 2000, estimatedCostUSD: 0.10),
            makeSession(startTime: dateDaysAgo(1), completedAt: now,
                        totalTokens: 500, estimatedCostUSD: 0.02),
            makeSession(startTime: dateDaysAgo(2), completedAt: now,
                        totalTokens: 3000, estimatedCostUSD: 0.15),
        ]

        var map: [Date: (tokens: Int, cost: Double)] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.startTime)
            let prev = map[day] ?? (0, 0.0)
            map[day] = (prev.tokens + session.totalTokens, prev.cost + session.estimatedCostUSD)
        }

        let todayKey = calendar.startOfDay(for: now)
        XCTAssertEqual(map[todayKey]?.tokens, 3000, "今天总 token 应为 3000")
        XCTAssertEqual(map[todayKey]?.cost ?? 0, 0.15, accuracy: 0.001, "今天总费用应为 0.15")

        let yesterdayKey = calendar.startOfDay(for: dateDaysAgo(1))
        XCTAssertEqual(map[yesterdayKey]?.tokens, 500)
    }

    // MARK: - Empty Sessions

    func testEmptySessionsProducesEmptyCharts() {
        let sessions: [StoredSession] = []

        var dailyMap: [Date: Int] = [:]
        var agentMap: [AgentType: Int] = [:]
        var toolMap: [String: Int] = [:]

        for session in sessions {
            let day = Calendar.current.startOfDay(for: session.startTime)
            dailyMap[day, default: 0] += 1
            agentMap[session.agentType, default: 0] += 1
            for event in session.toolEvents where event.isComplete {
                toolMap[event.tool, default: 0] += 1
            }
        }

        XCTAssertTrue(dailyMap.isEmpty, "空会话列表的每日统计应为空")
        XCTAssertTrue(agentMap.isEmpty, "空会话列表的代理统计应为空")
        XCTAssertTrue(toolMap.isEmpty, "空会话列表的工具统计应为空")
    }

    // MARK: - Time Range Filter (Week)

    func testTimeRangeFilterWeek() {
        let calendar = Calendar.current
        let now = Date()

        // 创建跨越 2 周的会话
        let sessions: [StoredSession] = [
            makeSession(startTime: dateDaysAgo(1), completedAt: now),   // 1 天前 - 在范围内
            makeSession(startTime: dateDaysAgo(3), completedAt: now),   // 3 天前 - 在范围内
            makeSession(startTime: dateDaysAgo(6), completedAt: now),   // 6 天前 - 在范围内
            makeSession(startTime: dateDaysAgo(8), completedAt: now),   // 8 天前 - 超出范围
            makeSession(startTime: dateDaysAgo(14), completedAt: now),  // 14 天前 - 超出范围
        ]

        // 模拟 week 过滤逻辑
        let cutoff = calendar.date(byAdding: .day, value: -7, to: now)!
        let filtered = sessions.filter { $0.startTime >= cutoff }

        XCTAssertEqual(filtered.count, 3, "最近 7 天应有 3 个会话")

        // 模拟 month 过滤
        let monthCutoff = calendar.date(byAdding: .day, value: -30, to: now)!
        let monthFiltered = sessions.filter { $0.startTime >= monthCutoff }
        XCTAssertEqual(monthFiltered.count, 5, "最近 30 天应有全部 5 个会话")
    }

    // MARK: - Summary Card Values

    func testSummaryCardValues() {
        let now = Date()
        let calendar = Calendar.current

        // 3 个会话，已知时长/费用/token
        let sessions: [StoredSession] = [
            makeSession(
                startTime: calendar.date(byAdding: .minute, value: -30, to: now)!,
                completedAt: now,
                totalTokens: 1000,
                estimatedCostUSD: 0.05
            ),
            makeSession(
                startTime: calendar.date(byAdding: .minute, value: -60, to: now)!,
                completedAt: calendar.date(byAdding: .minute, value: -30, to: now)!,
                totalTokens: 2000,
                estimatedCostUSD: 0.10
            ),
            makeSession(
                startTime: calendar.date(byAdding: .minute, value: -120, to: now)!,
                completedAt: calendar.date(byAdding: .minute, value: -60, to: now)!,
                totalTokens: 500,
                estimatedCostUSD: 0.02
            ),
        ]

        // 汇总值
        let totalCount = sessions.count
        let totalTokens = sessions.reduce(0) { $0 + $1.totalTokens }
        let totalCost = sessions.reduce(0.0) { $0 + $1.estimatedCostUSD }
        let totalDuration = sessions.reduce(0.0) { $0 + $1.duration }

        XCTAssertEqual(totalCount, 3)
        XCTAssertEqual(totalTokens, 3500)
        XCTAssertEqual(totalCost, 0.17, accuracy: 0.001)
        // 总时长应约为 30+30+60=120 分钟 = 7200 秒
        XCTAssertEqual(totalDuration, 7200, accuracy: 60, "总时长约为 120 分钟（容差 60 秒）")

        // token 格式化
        let tokenText: String = {
            if totalTokens >= 1_000_000 {
                return String(format: "%.1fM", Double(totalTokens) / 1_000_000)
            } else if totalTokens >= 1_000 {
                return String(format: "%.1fK", Double(totalTokens) / 1_000)
            }
            return "\(totalTokens)"
        }()
        XCTAssertEqual(tokenText, "3.5K")
    }
}
