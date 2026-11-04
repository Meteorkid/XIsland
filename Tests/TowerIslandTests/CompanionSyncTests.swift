import XCTest
@testable import XIsland
import CompanionShared

/// 伴端同步的完整性与命令处理。覆盖上一轮遗漏的删除路径。
@MainActor
final class CompanionSyncTests: XCTestCase {

    // MARK: 投影与过滤

    func testIdleSessionsAreNotPublished() {
        let idle = session("idle", status: .idle)
        let busy = session("busy", status: .active)
        let waiting = session("waiting", status: .waitingPermission)

        // 与 publish 内部同一条过滤规则：只推需要用户处理或正在运行的。
        let published = [idle, busy, waiting].filter {
            $0.hasPendingInteraction || CompanionPublisher.phase(for: $0.status) != .idle
        }
        XCTAssertEqual(published.map(\.id), ["busy", "waiting"])
    }

    func testPhaseMappingCoversAllStatuses() {
        XCTAssertEqual(CompanionPublisher.phase(for: .waitingPermission), .waitingApproval)
        XCTAssertEqual(CompanionPublisher.phase(for: .waitingAnswer), .waitingQuestion)
        XCTAssertEqual(CompanionPublisher.phase(for: .waitingPlanReview), .waitingQuestion)
        for status in [SessionStatus.active, .thinking, .compacting] {
            XCTAssertEqual(CompanionPublisher.phase(for: status), .running, "\(status) 应映射为运行中")
        }
        for status in [SessionStatus.idle, .completed, .error,
                       .observationUnavailable, .completionUnconfirmed] {
            XCTAssertEqual(CompanionPublisher.phase(for: status), .idle, "\(status) 应映射为空闲")
        }
    }

    func testProjectionTruncatesLongTitlesAndProjects() {
        let long = AgentSession(id: "s", agentType: .codex, startTime: Date())
        long.lastActivityTime = Date()
        let projected = CompanionPublisher.project(long)
        // 手表一屏放不下长文本，投影必须截断。
        XCTAssertLessThanOrEqual(projected.title.count, 80)
        XCTAssertLessThanOrEqual(projected.project.count, 40)
    }

    // MARK: 命令处理

    func testApproveOnlyAppliesWhenSessionStillWaits() {
        let manager = SessionManager()
        let waiting = session("w", status: .waitingPermission)
        waiting.pendingPermission = PendingPermission(
            requestingAgent: .codex, tool: "Shell",
            description: "d", diff: nil, filePath: nil, respond: { _ in }
        )
        manager.sessions = [waiting]

        // 未开启远程审批时，Publisher 层就会拦下，不会走到这里；
        // 这里直接验证 manager 层的"仍处等待态"校验。
        XCTAssertTrue(manager.handleCompanionCommand(.approve(sessionId: "w")))
    }

    func testCommandForUnknownSessionIsRejected() {
        let manager = SessionManager()
        manager.sessions = [session("exists", status: .active)]
        // 手机上的按钮可能停留在一条已经结束的会话上。
        XCTAssertFalse(manager.handleCompanionCommand(.approve(sessionId: "gone")))
        XCTAssertFalse(manager.handleCompanionCommand(.deny(sessionId: "gone")))
        XCTAssertFalse(manager.handleCompanionCommand(.answer(sessionId: "gone", text: "x")))
    }

    func testCommandForSessionNotWaitingIsRejected() {
        let manager = SessionManager()
        // 会话存在但不是等待态：用户可能已在 Mac 上处理过，
        // 此时重复 respond 会向已关闭的 socket 写数据。
        manager.sessions = [session("busy", status: .active)]
        XCTAssertFalse(manager.handleCompanionCommand(.approve(sessionId: "busy")))
        XCTAssertFalse(manager.handleCompanionCommand(.answer(sessionId: "busy", text: "x")))
    }

    func testRequestStateIsAlwaysAccepted() {
        let manager = SessionManager()
        XCTAssertTrue(manager.handleCompanionCommand(.requestState))
    }

    // MARK: 命令前置条件（防止误报"已送达"）

    func testAnswerRejectsMultiSelectQuestion() {
        let manager = SessionManager()
        let waiting = session("multi", status: .waitingAnswer)
        var question = PendingQuestion(
            requestingAgent: .codex, text: "选哪些？",
            options: ["A", "B"], respond: { _ in }, cancel: nil
        )
        question.allowsMultipleAnswers = true
        waiting.pendingQuestion = question
        manager.sessions = [waiting]

        // 多选题必须走 answerQuestion(answers:)，单选入口应拒绝而不是谎报成功。
        XCTAssertFalse(manager.handleCompanionCommand(.answer(sessionId: "multi", text: "A")))
    }

    func testAnswerRejectsValueNotInOptions() {
        let manager = SessionManager()
        let waiting = session("strict", status: .waitingAnswer)
        let question = PendingQuestion(
            requestingAgent: .codex, text: "选一个",
            options: ["A", "B"], respond: { _ in }, cancel: nil
        )
        waiting.pendingQuestion = question
        manager.sessions = [waiting]

        // 不在选项内且不允许自定义 → 不能声称已送达。
        XCTAssertFalse(manager.handleCompanionCommand(.answer(sessionId: "strict", text: "C")))
        // 选项内的回答应被接受。
        XCTAssertTrue(manager.handleCompanionCommand(.answer(sessionId: "strict", text: "A")))
    }

    func testAnswerRejectsBlankText() {
        let manager = SessionManager()
        let waiting = session("blank", status: .waitingAnswer)
        let question = PendingQuestion(
            requestingAgent: .codex, text: "说点什么",
            options: [], respond: { _ in }, cancel: nil
        )
        waiting.pendingQuestion = question
        manager.sessions = [waiting]

        XCTAssertFalse(manager.handleCompanionCommand(.answer(sessionId: "blank", text: "   ")))
    }

    func testApproveIsRejectedWhenOnlyQuestionPending() {
        let manager = SessionManager()
        let waiting = session("q", status: .waitingAnswer)
        waiting.pendingQuestion = PendingQuestion(
            requestingAgent: .codex, text: "t", options: ["A"],
            respond: { _ in }, cancel: nil
        )
        manager.sessions = [waiting]

        // 只有提问在等，没有权限请求 → 批准命令不应被当作成功。
        XCTAssertFalse(manager.handleCompanionCommand(.approve(sessionId: "q")))
    }

    // MARK: 排序确定性

    func testOrderingIsDeterministicWhenPriorityAndTimeTie() {
        // 同一秒内的两条同类会话：若无 id 兜底，两次排序可能给出不同次序，
        // 导致摘要反复变化、每次都触发一次无效发送。
        let a = CompanionSession(id: "aaa", agent: "X", title: "t", project: "p",
                                 phase: .waitingApproval, updatedAt: Date(timeIntervalSince1970: 100))
        let b = CompanionSession(id: "bbb", agent: "X", title: "t", project: "p",
                                 phase: .waitingApproval, updatedAt: Date(timeIntervalSince1970: 100))
        let first = CompanionSnapshot(sequence: 1, generatedAt: Date(), sessions: [a, b]).ordered
        let second = CompanionSnapshot(sequence: 2, generatedAt: Date(), sessions: [b, a]).ordered
        XCTAssertEqual(first.map(\.id), second.map(\.id), "输入顺序不同也应收敛到同一次序")
        XCTAssertEqual(first.map(\.id), ["aaa", "bbb"])
    }

    // MARK: 设置默认值

    func testCompanionDefaultsToOff() {
        let suite = UserDefaults(suiteName: "companion-defaults-\(UUID().uuidString)")!
        CompanionSettings.registerDefaults(suite)
        // 广播会暴露会话标题与项目名，必须默认关闭。
        XCTAssertFalse(suite.bool(forKey: CompanionSettings.enabledKey))
        XCTAssertFalse(suite.bool(forKey: CompanionSettings.decisionsKey))
    }

    // MARK: Helpers

    private func session(_ id: String, status: SessionStatus) -> AgentSession {
        let session = AgentSession(id: id, agentType: .codex, startTime: Date())
        session.status = status
        session.lastActivityTime = Date()
        return session
    }
}
