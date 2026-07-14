import XCTest
@testable import XIsland

/// Agent Flow 聚合服务的单元测试。
///
/// 复用项目既有 Fixture 风格（参考 `AgentSessionTests` / `SessionFilterTests`）：
/// - 使用 `makeSession(...)` 私有 helper 构造可控测试数据；
/// - 不依赖 `SessionManager` / `DIMessage`，直接喂入 `AgentSession` 实例；
/// - 不需要 `@MainActor`，因为 `AgentFlowAggregator` 是纯静态服务。
final class AgentFlowAggregatorTests: XCTestCase {
    private var previousAppLanguage: String?

    override func setUp() {
        super.setUp()
        previousAppLanguage = UserDefaults.standard.string(forKey: "appLanguage")
        UserDefaults.standard.set("zh", forKey: "appLanguage")
    }

    override func tearDown() {
        if let previousAppLanguage {
            UserDefaults.standard.set(previousAppLanguage, forKey: "appLanguage")
        } else {
            UserDefaults.standard.removeObject(forKey: "appLanguage")
        }
        super.tearDown()
    }

    // MARK: - Helpers

    /// 构造可配置的 AgentSession 测试数据。
    /// 默认值与项目其它测试保持一致（参考 `SessionFilterTests.makeSession`）。
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

    /// 构造一个等待人工回答（问题）的会话。
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

    /// 构造一个等待权限批准的会话。
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

    /// 构造一个工具失败的会话。
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

    // MARK: - Empty & Fallback

    func testEmptySessionsReturnsEmptyProjects() {
        XCTAssertTrue(AgentFlowAggregator.group(sessions: []).isEmpty)
    }

    func testEmptyWorkingDirectoryFallsBackToUngroupedBucket() {
        let s = makeSession(workingDir: "")
        let projects = AgentFlowAggregator.group(sessions: [s])

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].id, AgentFlowAggregator.ungroupedId)
        XCTAssertEqual(projects[0].name, AgentFlowAggregator.ungroupedDisplayName)
        XCTAssertEqual(projects[0].workingDirectory, "")
    }

    func testWhitespaceOnlyWorkingDirectoryFallsBackToUngroupedBucket() {
        let s = makeSession(workingDir: "   \n  ")
        let projects = AgentFlowAggregator.group(sessions: [s])

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].id, AgentFlowAggregator.ungroupedId)
    }

    // MARK: - Project Grouping

    func testGroupByWorkingDirectory() {
        let a1 = makeSession(id: "a1", workingDir: "/Users/me/proj-a")
        let a2 = makeSession(id: "a2", workingDir: "/Users/me/proj-a")
        let b1 = makeSession(id: "b1", workingDir: "/Users/me/proj-b")

        let projects = AgentFlowAggregator.group(sessions: [a1, a2, b1])

        XCTAssertEqual(projects.count, 2)
        let projA = projects.first { $0.name == "proj-a" }!
        let projB = projects.first { $0.name == "proj-b" }!
        XCTAssertEqual(projA.totalSessions, 2)
        XCTAssertEqual(projB.totalSessions, 1)
    }

    func testTrailingSlashNormalizesToSameProject() {
        let s1 = makeSession(id: "s1", workingDir: "/Users/me/proj")
        let s2 = makeSession(id: "s2", workingDir: "/Users/me/proj/")

        let projects = AgentFlowAggregator.group(sessions: [s1, s2])

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].totalSessions, 2)
    }

    func testRootDirectoryIsItsOwnProject() {
        let s = makeSession(workingDir: "/")
        let projects = AgentFlowAggregator.group(sessions: [s])

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].id, "/")
    }

    // MARK: - Counts

    func testCountsPartitionTotalEqualsActivePlusCompletedPlusBlocked() {
        let active = makeSession(id: "active", status: .active)
        let waiting = makeWaitingAnswerSession(id: "waiting")
        let completed = makeSession(id: "done", status: .completed)
        let failed = makeToolFailureSession(id: "failed")

        let projects = AgentFlowAggregator.group(sessions: [active, waiting, completed, failed])
        let p = projects[0]

        XCTAssertEqual(p.totalSessions, 4)
        XCTAssertEqual(p.activeCount, 1)   // 仅 active；waiting/failed 属于阻塞，不再计入活跃
        XCTAssertEqual(p.completedCount, 1)
        XCTAssertEqual(p.blockedCount, 2)  // waiting + failed
        XCTAssertEqual(p.totalSessions, p.activeCount + p.completedCount + p.blockedCount)
    }

    /// 阻塞会话不计入活跃——这是 UI 徽标"活跃"语义的核心约束。
    /// 覆盖三种阻塞类型：等待人工输入、等待权限、工具失败。
    func testBlockedSessionsAreNotCountedAsActive() {
        let active = makeSession(id: "active", status: .active, workingDir: "/proj")
        let waitingAnswer = makeWaitingAnswerSession(id: "wa", workingDir: "/proj")
        let waitingPermission = makeWaitingPermissionSession(id: "wp", workingDir: "/proj")
        let toolFailure = makeToolFailureSession(id: "tf", workingDir: "/proj")

        let projects = AgentFlowAggregator.group(sessions: [active, waitingAnswer, waitingPermission, toolFailure])
        let p = projects[0]

        XCTAssertEqual(p.activeCount, 1, "只有 .active 会话应计入活跃；三种阻塞会话均不应计入")
        XCTAssertEqual(p.blockedCount, 3)
    }

    func testBlockedCountIsMutuallyExclusiveWithActiveCount() {
        let active = makeSession(id: "active", status: .active)
        let waiting = makeWaitingAnswerSession(id: "waiting")
        let completed = makeSession(id: "done", status: .completed)

        let projects = AgentFlowAggregator.group(sessions: [active, waiting, completed])
        let p = projects[0]

        XCTAssertEqual(p.activeCount, 1)
        XCTAssertEqual(p.blockedCount, 1)
        XCTAssertEqual(p.totalSessions, p.activeCount + p.completedCount + p.blockedCount,
                       "活跃与阻塞互斥，不应重叠")
    }

    // MARK: - Blocker Kind Classification

    func testClassifyWaitingAnswerAsWaitingHumanInput() {
        XCTAssertEqual(AgentFlowBlockerKind.classify(makeWaitingAnswerSession()), .waitingHumanInput)
    }

    func testClassifyWaitingPlanReviewAsWaitingHumanInput() {
        let s = makeSession(status: .waitingPlanReview)
        s.pendingPlanReview = PendingPlanReview(
            requestingAgent: .claudeCode,
            markdown: "## Plan",
            respond: { _, _ in }
        )
        XCTAssertEqual(AgentFlowBlockerKind.classify(s), .waitingHumanInput)
    }

    func testClassifyWaitingPermissionAsWaitingPermission() {
        XCTAssertEqual(AgentFlowBlockerKind.classify(makeWaitingPermissionSession()), .waitingPermission)
    }

    func testClassifyErrorAsToolFailure() {
        XCTAssertEqual(AgentFlowBlockerKind.classify(makeToolFailureSession()), .toolFailure)
    }

    func testClassifyActiveAsNone() {
        XCTAssertEqual(AgentFlowBlockerKind.classify(makeSession(status: .active)), .none)
    }

    func testClassifyCompletedAsNone() {
        XCTAssertEqual(AgentFlowBlockerKind.classify(makeSession(status: .completed)), .none)
    }

    func testClassifyThinkingAsNone() {
        XCTAssertEqual(AgentFlowBlockerKind.classify(makeSession(status: .thinking)), .none)
    }

    func testClassifyCompactingAsNone() {
        XCTAssertEqual(AgentFlowBlockerKind.classify(makeSession(status: .compacting)), .none)
    }

    func testClassifyIdleAsNone() {
        XCTAssertEqual(AgentFlowBlockerKind.classify(makeSession(status: .idle)), .none)
    }

    func testBlockerKindDisplayNameUsesLocalizationOverride() {
        UserDefaults.standard.set("en", forKey: "appLanguage")

        XCTAssertEqual(AgentFlowBlockerKind.waitingHumanInput.displayName, "Needs input")
        XCTAssertEqual(AgentFlowBlockerKind.waitingPermission.displayName, "Needs approval")
        XCTAssertEqual(AgentFlowBlockerKind.toolFailure.displayName, "Tool failed")
        XCTAssertEqual(AgentFlowBlockerKind.none.displayName, "No blocker")
        XCTAssertEqual(AgentFlowAggregator.ungroupedDisplayName, "Ungrouped sessions")
    }

    // MARK: - Priority Order

    func testPriorityOrderWithinProjectIsHumanInputFirstThenPermissionThenToolFailure() {
        // lastActivityTime 都相同 → 完全按 kind 排序
        let now = Date()
        let failure = makeToolFailureSession(id: "f", lastActivityTime: now)
        let permission = makeWaitingPermissionSession(id: "p", lastActivityTime: now)
        let answer = makeWaitingAnswerSession(id: "a", lastActivityTime: now)
        let active = makeSession(id: "x", status: .active, lastActivityTime: now)

        let projects = AgentFlowAggregator.group(sessions: [active, failure, permission, answer])
        let sessions = projects[0].sessions.map(\.id)

        XCTAssertEqual(sessions, ["a", "p", "f", "x"])
    }

    func testSameBlockerKindSortedByLastActivityTimeDescending() {
        let older = makeWaitingAnswerSession(id: "older", lastActivityTime: Date(timeIntervalSince1970: 100))
        let newer = makeWaitingAnswerSession(id: "newer", lastActivityTime: Date(timeIntervalSince1970: 200))

        let projects = AgentFlowAggregator.group(sessions: [older, newer])
        XCTAssertEqual(projects[0].sessions.map(\.id), ["newer", "older"])
        XCTAssertEqual(projects[0].blockers.map(\.id), ["newer", "older"])
    }

    func testBlockersListExcludesNoneKind() {
        let active = makeSession(id: "active", status: .active)
        let waiting = makeWaitingAnswerSession(id: "waiting")

        let projects = AgentFlowAggregator.group(sessions: [active, waiting])
        XCTAssertEqual(projects[0].blockers.count, 1)
        XCTAssertEqual(projects[0].blockers.first?.id, "waiting")
    }

    // MARK: - Project Ordering

    func testProjectsOrderedByBlockerPriorityFirst() {
        // proj-active 仅活跃 → 最低优先级
        // proj-failure 仅工具失败 → 中等
        // proj-permission 仅等待权限 → 较高
        // proj-answer 仅等待人工回答 → 最高
        let now = Date()
        let activeProject = makeSession(id: "a", status: .active, workingDir: "/proj-active", lastActivityTime: now)
        let failureProject = makeToolFailureSession(id: "f", workingDir: "/proj-failure", lastActivityTime: now)
        let permissionProject = makeWaitingPermissionSession(id: "p", workingDir: "/proj-permission", lastActivityTime: now)
        let answerProject = makeWaitingAnswerSession(id: "q", workingDir: "/proj-answer", lastActivityTime: now)

        let projects = AgentFlowAggregator.group(sessions: [activeProject, failureProject, permissionProject, answerProject])
        let order = projects.map(\.name)

        XCTAssertEqual(order, ["proj-answer", "proj-permission", "proj-failure", "proj-active"])
    }

    func testProjectsWithoutBlockersOrderedByRecentActivity() {
        let older = makeSession(id: "older", status: .active, workingDir: "/older", lastActivityTime: Date(timeIntervalSince1970: 100))
        let newer = makeSession(id: "newer", status: .active, workingDir: "/newer", lastActivityTime: Date(timeIntervalSince1970: 200))

        let projects = AgentFlowAggregator.group(sessions: [older, newer])
        XCTAssertEqual(projects.map(\.name), ["newer", "older"])
    }

    func testProjectWithBlockedSessionBeatsProjectWithOnlyActiveSessions() {
        // 即使 active project 活动更近，blocked project 仍排在前
        let activeRecent = makeSession(id: "recent", status: .active, workingDir: "/active", lastActivityTime: Date(timeIntervalSince1970: 999))
        let blockedOlder = makeWaitingAnswerSession(id: "blocked", workingDir: "/blocked", lastActivityTime: Date(timeIntervalSince1970: 1))

        let projects = AgentFlowAggregator.group(sessions: [activeRecent, blockedOlder])
        XCTAssertEqual(projects.first?.name, "blocked")
    }

    // MARK: - Subagent Handling

    func testSubagentInSameDirectoryNotDoubleCountedAsSeparateProject() {
        let parent = makeSession(id: "parent", workingDir: "/Users/me/proj")
        let child = makeSession(id: "child", workingDir: "/Users/me/proj")
        child.parentSessionId = "parent"
        parent.subagentIds.append("child")

        let projects = AgentFlowAggregator.group(sessions: [parent, child])

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].totalSessions, 2)
    }

    func testSubagentWithDifferentDirectoryGoesToOwnProject() {
        let parent = makeSession(id: "parent", workingDir: "/Users/me/proj-a")
        let child = makeSession(id: "child", workingDir: "/Users/me/proj-b")
        child.parentSessionId = "parent"

        let projects = AgentFlowAggregator.group(sessions: [parent, child])

        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(projects[0].totalSessions + projects[1].totalSessions, 2)
    }

    /// 子 Agent 自身目录为空时，应继承父 Agent 所属项目的工作目录。
    func testSubagentWithEmptyDirectoryInheritsParentProject() {
        let parent = makeSession(id: "parent", workingDir: "/Users/me/proj-inherit")
        let child = makeSession(id: "child", workingDir: "")   // 空 → 继承父
        child.parentSessionId = "parent"

        let projects = AgentFlowAggregator.group(sessions: [parent, child])

        XCTAssertEqual(projects.count, 1, "子 Agent 应继承父项目，归入同一组")
        XCTAssertEqual(projects[0].name, "proj-inherit")
        XCTAssertEqual(projects[0].workingDirectory, "/Users/me/proj-inherit")
        XCTAssertEqual(projects[0].totalSessions, 2)
    }

    /// 多层子 Agent：孙 Agent 自身目录为空、父 Agent 目录也为空，应继承祖父 Agent 的工作目录。
    func testMultiLevelSubagentInheritsAncestorProject() {
        let grandparent = makeSession(id: "gp", workingDir: "/Users/me/ancestor-proj")
        let parent = makeSession(id: "p", workingDir: "")      // 空 → 继承祖父
        parent.parentSessionId = "gp"
        let child = makeSession(id: "c", workingDir: "")       // 空 → 继承父 → 继承祖父
        child.parentSessionId = "p"

        // 顺序乱序：子在前，祖父在后
        let projects = AgentFlowAggregator.group(sessions: [child, grandparent, parent])

        XCTAssertEqual(projects.count, 1, "多层子 Agent 应全部归入祖父项目")
        XCTAssertEqual(projects[0].name, "ancestor-proj")
        XCTAssertEqual(projects[0].workingDirectory, "/Users/me/ancestor-proj")
        XCTAssertEqual(projects[0].totalSessions, 3)
    }

    /// 孤儿子 Agent：父 ID 不在 sessions 中，且自身目录为空 → 安全归入未分组。
    func testOrphanSubagentWithEmptyDirectoryFallsBackToUngrouped() {
        let orphan = makeSession(id: "orphan", workingDir: "")
        orphan.parentSessionId = "nonexistent-parent"

        let projects = AgentFlowAggregator.group(sessions: [orphan])

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].id, AgentFlowAggregator.ungroupedId)
        XCTAssertEqual(projects[0].name, AgentFlowAggregator.ungroupedDisplayName)
        XCTAssertEqual(projects[0].workingDirectory, "")
    }

    /// 父链全部目录为空：祖父、父、子都没有目录 → 全部归入未分组（同组不重复计数为多个项目）。
    func testEmptyParentChainFallsBackToUngrouped() {
        let grandparent = makeSession(id: "gp", workingDir: "")
        let parent = makeSession(id: "p", workingDir: "")
        parent.parentSessionId = "gp"
        let child = makeSession(id: "c", workingDir: "")
        child.parentSessionId = "p"

        let projects = AgentFlowAggregator.group(sessions: [grandparent, parent, child])

        XCTAssertEqual(projects.count, 1, "空父链应统一归入未分组，不产生多个未分组项目")
        XCTAssertEqual(projects[0].id, AgentFlowAggregator.ungroupedId)
        XCTAssertEqual(projects[0].totalSessions, 3)
    }

    /// 循环引用防御：A → B → A 形成循环，应安全终止并归入未分组。
    func testCircularParentChainSafelyTerminates() {
        let a = makeSession(id: "a", workingDir: "")
        let b = makeSession(id: "b", workingDir: "")
        a.parentSessionId = "b"
        b.parentSessionId = "a"

        let projects = AgentFlowAggregator.group(sessions: [a, b])

        XCTAssertEqual(projects.count, 1, "循环引用应安全归并到未分组，不产生死循环")
        XCTAssertEqual(projects[0].id, AgentFlowAggregator.ungroupedId)
        XCTAssertEqual(projects[0].totalSessions, 2)
    }

    /// 自循环：会话把自己作为父。应被识别为循环并归入未分组。
    func testSelfReferencingParentSafelyTerminates() {
        let selfRef = makeSession(id: "loop", workingDir: "")
        selfRef.parentSessionId = "loop"

        let projects = AgentFlowAggregator.group(sessions: [selfRef])

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].id, AgentFlowAggregator.ungroupedId)
    }

    /// 自身目录非空时，即使父链有循环，也应优先使用自身目录（自身优先）。
    func testSelfDirectoryBeatsCircularParentChain() {
        let a = makeSession(id: "a", workingDir: "/Users/me/proj-self")
        let b = makeSession(id: "b", workingDir: "")
        a.parentSessionId = "b"
        b.parentSessionId = "a"

        let projects = AgentFlowAggregator.group(sessions: [a, b])

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].name, "proj-self")
        XCTAssertEqual(projects[0].totalSessions, 2, "b 应沿父链继承到 a 的目录")
    }

    // MARK: - Reason Generation

    func testReasonForWaitingAnswerIncludesQuestionPreview() {
        let s = makeWaitingAnswerSession(questionText: "Which payment gateway?")
        let reason = AgentFlowBlockerKind.reason(for: s)
        XCTAssertTrue(reason.contains("Which payment gateway?"))
        XCTAssertTrue(reason.hasPrefix("等待回答："))
    }

    func testReasonForWaitingPermissionIncludesToolName() {
        let s = makeWaitingPermissionSession(tool: "git push")
        let reason = AgentFlowBlockerKind.reason(for: s)
        XCTAssertTrue(reason.contains("git push"))
        XCTAssertTrue(reason.hasPrefix("等待批准："))
    }

    func testReasonForErrorIncludesStatusText() {
        let s = makeToolFailureSession(statusText: "permission denied")
        let reason = AgentFlowBlockerKind.reason(for: s)
        XCTAssertTrue(reason.contains("permission denied"))
        XCTAssertTrue(reason.hasPrefix("工具失败："))
    }

    func testReasonForWaitingAnswerFallsBackWhenPendingMissing() {
        // 极端情况：status 标了 waitingAnswer 但 pendingQuestion 已被外部清空
        let s = makeSession(status: .waitingAnswer)
        let reason = AgentFlowBlockerKind.reason(for: s)
        XCTAssertEqual(reason, "等待回答")
    }

    func testReasonForWaitingPermissionFallsBackWhenPendingMissing() {
        let s = makeSession(status: .waitingPermission)
        let reason = AgentFlowBlockerKind.reason(for: s)
        XCTAssertEqual(reason, "等待权限批准")
    }

    func testReasonForErrorFallsBackWhenStatusTextEmpty() {
        let s = makeSession(status: .error)
        let reason = AgentFlowBlockerKind.reason(for: s)
        XCTAssertEqual(reason, "工具失败")
    }

    func testLongReasonTextIsTruncatedWithEllipsis() {
        let longText = String(repeating: "x", count: 120)
        let s = makeToolFailureSession(statusText: longText)
        let reason = AgentFlowBlockerKind.reason(for: s)
        XCTAssertTrue(reason.hasSuffix("…"))
        // "工具失败：" (5 字符) + 60 字符 + "…" → 66 字符
        XCTAssertEqual(reason.count, "工具失败：".count + 60 + 1)
    }

    func testReasonGenerationUsesLocalizationOverride() {
        UserDefaults.standard.set("en", forKey: "appLanguage")

        let answer = AgentFlowBlockerKind.reason(for: makeWaitingAnswerSession(questionText: "Ship it?"))
        let permission = AgentFlowBlockerKind.reason(for: makeWaitingPermissionSession(tool: "git push"))
        let failure = AgentFlowBlockerKind.reason(for: makeToolFailureSession(statusText: "permission denied"))

        XCTAssertEqual(answer, "Waiting for answer: Ship it?")
        XCTAssertEqual(permission, "Waiting for approval: git push")
        XCTAssertEqual(failure, "Tool failed: permission denied")
    }

    // MARK: - Stability & No Side Effects

    func testAggregatorDoesNotMutateInputSessions() {
        let original = makeSession(id: "stable", status: .active)
        let originalStatus = original.status
        let originalActivity = original.lastActivityTime

        _ = AgentFlowAggregator.group(sessions: [original])

        XCTAssertEqual(original.status, originalStatus)
        XCTAssertEqual(original.lastActivityTime, originalActivity)
    }

    func testIdenticalInputProducesIdenticalOutput() {
        let sessions = [
            makeWaitingAnswerSession(id: "a"),
            makeWaitingPermissionSession(id: "b"),
            makeToolFailureSession(id: "c")
        ]
        let first = AgentFlowAggregator.group(sessions: sessions)
        let second = AgentFlowAggregator.group(sessions: sessions)

        XCTAssertEqual(first.count, second.count)
        zip(first, second).forEach { p1, p2 in
            XCTAssertEqual(p1.id, p2.id)
            XCTAssertEqual(p1.blockers.map(\.id), p2.blockers.map(\.id))
            XCTAssertEqual(p1.sessions.map(\.id), p2.sessions.map(\.id))
        }
    }
}
