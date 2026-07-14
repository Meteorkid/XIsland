import XCTest
@testable import XIsland

/// Agent Flow 展示层（`AgentFlowRegion`）的单元测试。
///
/// 测试策略与项目既有 View 测试一致（参考 `NotchContentViewTests` / `AgentFlowAggregatorTests`）：
/// - 测试 View 暴露的纯静态 helper，不渲染 SwiftUI 视图；
/// - 使用 `makeSession(...)` 私有 helper 构造可控测试数据；
/// - 不依赖 `SessionManager` / `DIMessage`，直接喂入 `AgentSession` 实例。
final class AgentFlowViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeSession(
        id: String = UUID().uuidString,
        agentType: AgentType = .claudeCode,
        status: SessionStatus = .active,
        workingDir: String = "/Users/test/project",
        prompt: String = "Fix the bug",
        lastActivityTime: Date = Date()
    ) -> AgentSession {
        let session = AgentSession(
            id: id,
            agentType: agentType,
            terminal: "ttys001",
            workingDirectory: workingDir,
            prompt: prompt
        )
        session.status = status
        session.lastActivityTime = lastActivityTime
        return session
    }

    private func makeWaitingAnswerSession(
        id: String = UUID().uuidString,
        questionText: String = "Continue?",
        workingDir: String = "/Users/test/project",
        lastActivityTime: Date = Date()
    ) -> AgentSession {
        let session = makeSession(id: id, status: .waitingAnswer, workingDir: workingDir, lastActivityTime: lastActivityTime)
        session.pendingQuestion = PendingQuestion(
            requestingAgent: .claudeCode,
            text: questionText,
            options: ["yes", "no"],
            respond: { _ in },
            cancel: nil
        )
        return session
    }

    private func makeWaitingPermissionSession(
        id: String = UUID().uuidString,
        tool: String = "Bash",
        workingDir: String = "/Users/test/project",
        lastActivityTime: Date = Date()
    ) -> AgentSession {
        let session = makeSession(id: id, status: .waitingPermission, workingDir: workingDir, lastActivityTime: lastActivityTime)
        session.pendingPermission = PendingPermission(
            requestingAgent: .claudeCode,
            tool: tool,
            description: "Run shell command",
            diff: nil,
            filePath: nil,
            respond: { _ in }
        )
        return session
    }

    private func makeToolFailureSession(
        id: String = UUID().uuidString,
        statusText: String = "permission denied",
        workingDir: String = "/Users/test/project",
        lastActivityTime: Date = Date()
    ) -> AgentSession {
        let session = makeSession(id: id, status: .error, workingDir: workingDir, lastActivityTime: lastActivityTime)
        session.statusText = statusText
        return session
    }

    // MARK: - Empty State

    func testNoProjectsYieldsEmptyState() {
        let projects = AgentFlowAggregator.group(sessions: [])

        XCTAssertTrue(AgentFlowRegion.blockedProjects(from: projects).isEmpty)
        XCTAssertFalse(AgentFlowRegion.hasAnyBlocker(projects))
        XCTAssertEqual(AgentFlowRegion.blockedProjectsCount(projects), 0)
        XCTAssertEqual(AgentFlowRegion.totalBlockersCount(projects), 0)
    }

    func testOnlyActiveSessionsYieldsEmptyState() {
        let active = makeSession(id: "a", status: .active, workingDir: "/proj")
        let projects = AgentFlowAggregator.group(sessions: [active])

        XCTAssertFalse(AgentFlowRegion.hasAnyBlocker(projects))
        XCTAssertTrue(AgentFlowRegion.blockedProjects(from: projects).isEmpty)
        XCTAssertEqual(AgentFlowRegion.totalBlockersCount(projects), 0)
    }

    func testCompletedSessionsYieldEmptyState() {
        let done = makeSession(id: "d", status: .completed, workingDir: "/proj")
        let projects = AgentFlowAggregator.group(sessions: [done])

        XCTAssertFalse(AgentFlowRegion.hasAnyBlocker(projects))
        XCTAssertTrue(AgentFlowRegion.blockedProjects(from: projects).isEmpty)
    }

    // MARK: - Has Blocked Projects

    func testHasAnyBlockerTrueWhenProjectHasBlocker() {
        let waiting = makeWaitingAnswerSession(id: "w", workingDir: "/proj")
        let projects = AgentFlowAggregator.group(sessions: [waiting])

        XCTAssertTrue(AgentFlowRegion.hasAnyBlocker(projects))
        XCTAssertEqual(AgentFlowRegion.blockedProjectsCount(projects), 1)
        XCTAssertEqual(AgentFlowRegion.totalBlockersCount(projects), 1)
    }

    func testBlockedProjectsOnlyIncludesBlockedOnes() {
        let blocked = makeWaitingAnswerSession(id: "b", workingDir: "/blocked")
        let active = makeSession(id: "a", status: .active, workingDir: "/active")

        let projects = AgentFlowAggregator.group(sessions: [blocked, active])
        let blockedOnly = AgentFlowRegion.blockedProjects(from: projects)

        XCTAssertEqual(blockedOnly.count, 1)
        XCTAssertEqual(blockedOnly.first?.name, "blocked")
        XCTAssertEqual(blockedOnly.first?.blockedCount, 1)
    }

    func testTotalBlockersCountAcrossMultipleProjects() {
        let p1A = makeWaitingAnswerSession(id: "p1-a", workingDir: "/proj-1")
        let p1B = makeWaitingPermissionSession(id: "p1-b", workingDir: "/proj-1")
        let p2A = makeToolFailureSession(id: "p2-a", workingDir: "/proj-2")

        let projects = AgentFlowAggregator.group(sessions: [p1A, p1B, p2A])

        XCTAssertEqual(AgentFlowRegion.blockedProjectsCount(projects), 2)
        XCTAssertEqual(AgentFlowRegion.totalBlockersCount(projects), 3)
    }

    func testBlockedProjectsExcludesZeroBlockerProjects() {
        let blocked = makeWaitingAnswerSession(id: "b", workingDir: "/blocked")
        let active = makeSession(id: "a", status: .active, workingDir: "/active")
        let done = makeSession(id: "d", status: .completed, workingDir: "/done")

        let projects = AgentFlowAggregator.group(sessions: [blocked, active, done])
        let blockedOnly = AgentFlowRegion.blockedProjects(from: projects)

        XCTAssertEqual(blockedOnly.count, 1)
        XCTAssertEqual(blockedOnly.first?.name, "blocked")
    }

    // MARK: - Multiple Projects Ordering

    func testBlockedProjectsPreserveAggregatorPriorityOrder() {
        let now = Date()
        // proj-active 仅活跃 → 最低优先级（应被过滤掉）
        // proj-failure 仅工具失败 → 中等
        // proj-permission 仅等待权限 → 较高
        // proj-answer 仅等待人工回答 → 最高
        let activeProject = makeSession(id: "a", status: .active, workingDir: "/proj-active", lastActivityTime: now)
        let failureProject = makeToolFailureSession(id: "f", workingDir: "/proj-failure", lastActivityTime: now)
        let permissionProject = makeWaitingPermissionSession(id: "p", workingDir: "/proj-permission", lastActivityTime: now)
        let answerProject = makeWaitingAnswerSession(id: "q", workingDir: "/proj-answer", lastActivityTime: now)

        let projects = AgentFlowAggregator.group(sessions: [activeProject, failureProject, permissionProject, answerProject])
        let blockedOnly = AgentFlowRegion.blockedProjects(from: projects)
        let order = blockedOnly.map(\.name)

        // 活跃项目应被过滤；剩余三个按阻塞优先级排序
        XCTAssertEqual(order, ["proj-answer", "proj-permission", "proj-failure"])
    }

    func testBlockedProjectsOrderDoesNotReSortInput() {
        // 构造已知顺序的输入，验证 blockedProjects 仅做过滤、不改顺序
        let waiting = makeWaitingAnswerSession(id: "w", workingDir: "/proj-waiting")
        let permission = makeWaitingPermissionSession(id: "p", workingDir: "/proj-permission")

        let projects = AgentFlowAggregator.group(sessions: [waiting, permission])
        let blockedOnly = AgentFlowRegion.blockedProjects(from: projects)

        // 聚合器已按优先级排序：waitingHumanInput(.blue) > waitingPermission(.orange)
        XCTAssertEqual(blockedOnly.first?.name, "proj-waiting")
        XCTAssertEqual(blockedOnly.last?.name, "proj-permission")
    }

    // MARK: - Count Consistency

    func testBlockedProjectsCountEqualsTotalBlockersCountWhenEachProjectHasOneBlocker() {
        let p1 = makeWaitingAnswerSession(id: "p1", workingDir: "/proj-1")
        let p2 = makeWaitingPermissionSession(id: "p2", workingDir: "/proj-2")
        let p3 = makeToolFailureSession(id: "p3", workingDir: "/proj-3")

        let projects = AgentFlowAggregator.group(sessions: [p1, p2, p3])

        // 每个项目恰好 1 个阻塞 → 项目数 == 阻塞会话数
        XCTAssertEqual(AgentFlowRegion.blockedProjectsCount(projects), AgentFlowRegion.totalBlockersCount(projects))
        XCTAssertEqual(AgentFlowRegion.totalBlockersCount(projects), 3)
    }

    func testCountsConsistentWithMultipleBlockersPerProject() {
        // 同一项目下 2 个阻塞会话
        let a = makeWaitingAnswerSession(id: "a", workingDir: "/proj-multi")
        let b = makeWaitingPermissionSession(id: "b", workingDir: "/proj-multi")

        let projects = AgentFlowAggregator.group(sessions: [a, b])

        XCTAssertEqual(AgentFlowRegion.blockedProjectsCount(projects), 1)
        XCTAssertEqual(AgentFlowRegion.totalBlockersCount(projects), 2)
    }
}
