import AppKit
import DIShared
import SwiftUI
import XCTest
@testable import XIsland

@MainActor
final class NotchContentHandoffTests: XCTestCase {
    func testColdHandoffKeepsQuestionDraftAndCollapsedGeometryAfterSessionChanges() async throws {
        let session = AgentSession(id: "handoff-question", agentType: .openCode)
        session.status = .waitingAnswer
        let question = PendingQuestion(
            requestingAgent: .openCode,
            text: "请选择项目目录。",
            options: ["当前项目", "新建目录"],
            respond: { _ in XCTFail("交接不应提交问答") },
            cancel: { XCTFail("交接不应取消问答") },
            allowsCustomAnswer: true,
            allowsMultipleAnswers: true
        )
        question.state.draftAnswer = "/tmp/保留中的项目草稿"
        question.state.selectedAnswers = ["当前项目"]
        session.pendingQuestion = question
        let fixture = try makeFixture(sessions: [session])
        defer { fixture.close() }
        let prepared = expectation(description: "冷挂载视图完成交接准备")
        var completedGenerations: [UInt64] = []
        let generation = fixture.window.beginInboundHandoff { generation in
            completedGenerations.append(generation)
            self.assertCollapsed(fixture)
            fixture.window.showPreparedHandoff(generation: generation)
            prepared.fulfill()
        }

        XCTAssertEqual(fixture.window.handoffState.pendingPreparation, generation)
        try fixture.mount()

        assertCollapsed(fixture)
        XCTAssertEqual(fixture.window.handoffState.pendingPreparation, generation)
        XCTAssertEqual(fixture.harness.orderFrontCount, 0, "准备完成前不能显示旧问答面板")
        assertQuestionPreserved(session, question: question)
        await fulfillment(of: [prepared], timeout: 1)
        await pump(fixture, for: 0.05)

        XCTAssertEqual(completedGenerations, [generation])
        XCTAssertNil(fixture.window.handoffState.pendingPreparation)
        XCTAssertEqual(fixture.harness.orderFrontCount, 1)
        XCTAssertTrue(fixture.harness.sizeReports.isEmpty, "冷交接应直接设置收起尺寸，不能经过通用展开 padding")
        assertCollapsed(fixture)
        assertQuestionPreserved(session, question: question)

        let addedSession = AgentSession(id: "handoff-active", agentType: .codex)
        addedSession.status = .active
        fixture.manager.sessions.append(addedSession)
        await pump(fixture, for: 0.05)

        XCTAssertEqual(fixture.manager.sessions.count, 2)
        XCTAssertTrue(fixture.harness.sizeReports.isEmpty, "会话变化不能把收起窗口改走通用 padding 路径")
        assertCollapsed(fixture)
        assertQuestionPreserved(session, question: question)
        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertEqual(fixture.harness.orderOutCount, 0)
    }

    func testRapidHandoffAfterScrollExpansionRejectsLateExpansionCallbacks() async throws {
        for disableAnimations in [true, false] {
            let session = AgentSession(id: "handoff-scroll-\(disableAnimations)", agentType: .codex)
            session.status = .active
            let fixture = try makeFixture(sessions: [session], disableAnimations: disableAnimations)
            defer { fixture.close() }
            let initialPreparation = expectation(description: "挂载初始交接视图")
            fixture.window.beginInboundHandoff { generation in
                fixture.window.showPreparedHandoff(generation: generation)
                initialPreparation.fulfill()
            }
            try fixture.mount()
            await fulfillment(of: [initialPreparation], timeout: 1)
            await pump(fixture, for: 0.05)
            assertCollapsed(fixture)

            NotificationCenter.default.post(name: .xislandScrollDown, object: nil)

            XCTAssertEqual(fixture.window.islandState, .expanded)
            XCTAssertGreaterThan(fixture.window.frame.height, collapsedWindowHeight)
            XCTAssertFalse(fixture.harness.sizeReports.isEmpty, "滚动通知必须实际触发展开路径")
            // 开启动画时立即交接，让 expandStartDelay 的旧回调留在主队列中。
            let nextPreparation = expectation(description: "快速交接重新准备收起视图")
            let generation = fixture.window.beginInboundHandoff { generation in
                self.assertCollapsed(fixture)
                fixture.window.showPreparedHandoff(generation: generation)
                nextPreparation.fulfill()
            }
            let reportCountAtHandoff = fixture.harness.sizeReports.count

            assertCollapsed(fixture)
            XCTAssertEqual(fixture.window.handoffState.pendingPreparation, generation)
            fixture.layout()
            await fulfillment(of: [nextPreparation], timeout: 1)
            await pump(fixture, for: 0.7)

            assertCollapsed(fixture)
            XCTAssertTrue(fixture.window.isCurrentHandoff(generation))
            XCTAssertNil(fixture.window.handoffState.pendingPreparation)
            XCTAssertEqual(fixture.harness.sizeReports.count, reportCountAtHandoff, "旧展开延迟不能再次上报展开尺寸")
            XCTAssertEqual(fixture.manager.sessions.map(\.id), [session.id])
            XCTAssertEqual(fixture.harness.orderFrontCount, 2)
            XCTAssertEqual(fixture.harness.orderOutCount, 0)
            XCTAssertFalse(fixture.window.isVisible)
        }
    }

    func testNewQuestionDuringPreparationExpandsAfterHandoffWithoutPointerExit() async throws {
        let fixture = try makeFixture(sessions: [])
        defer { fixture.close() }
        let initialPreparation = expectation(description: "挂载无审批的交接视图")
        fixture.window.beginInboundHandoff { generation in
            fixture.window.showPreparedHandoff(generation: generation)
            initialPreparation.fulfill()
        }
        try fixture.mount()
        await fulfillment(of: [initialPreparation], timeout: 1)
        await pump(fixture, for: 0.05)

        let nextPreparation = expectation(description: "新问答到达期间完成交接准备")
        let generation = fixture.window.beginInboundHandoff { generation in
            self.assertCollapsed(fixture)
            fixture.window.showPreparedHandoff(generation: generation)
            nextPreparation.fulfill()
        }
        let session = AgentSession(id: "handoff-new-question", agentType: .openCode)
        session.status = .waitingAnswer
        session.pendingQuestion = PendingQuestion(
            requestingAgent: .openCode,
            text: "新的审批需要处理。",
            options: ["继续"],
            respond: { _ in XCTFail("展示新问答不应提交答案") },
            cancel: { XCTFail("展示新问答不应取消请求") }
        )
        let requestID = try XCTUnwrap(session.pendingQuestion?.id)
        fixture.manager.sessions.append(session)
        fixture.layout()

        XCTAssertEqual(fixture.window.handoffState.pendingPreparation, generation)
        assertCollapsed(fixture)
        XCTAssertTrue(fixture.window.observeHandoffPointer(isInside: true))
        await fulfillment(of: [nextPreparation], timeout: 1)
        await pump(fixture, for: 0.3)

        XCTAssertNil(fixture.window.handoffState.pendingPreparation)
        XCTAssertEqual(fixture.window.islandState, .question(session.id))
        XCTAssertEqual(fixture.manager.currentIslandState, .question(session.id))
        XCTAssertGreaterThan(fixture.window.frame.height, collapsedWindowHeight)
        XCTAssertTrue(fixture.window.observeHandoffPointer(isInside: true), "新审批展开不应依赖悬停保护解除")
        XCTAssertEqual(session.pendingQuestion?.id, requestID)
        XCTAssertEqual(session.status, .waitingAnswer)
        XCTAssertEqual(fixture.harness.orderFrontCount, 2)
        XCTAssertEqual(fixture.harness.orderOutCount, 0)
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testDirectionalHandoffDefersNewQuestionUntilIncomingAnimationFinishes() async throws {
        for arrivesDuringPreparation in [true, false] {
            let fixture = try makeFixture(sessions: [])
            defer { fixture.close() }
            let initialPreparation = expectation(description: "挂载无问答的收起视图")
            fixture.window.beginInboundHandoff { generation in
                fixture.window.showPreparedHandoff(generation: generation)
                initialPreparation.fulfill()
            }
            try fixture.mount()
            await fulfillment(of: [initialPreparation], timeout: 1)
            await pump(fixture, for: 0.05)
            fixture.harness.reduceMotion = false

            let finished = expectation(description: "真实方向入站动画完成")
            let token = NotificationCenter.default.addObserver(forName: .xislandDidFinishHandoff,
                object: fixture.window, queue: .main) { _ in finished.fulfill() }
            defer { NotificationCenter.default.removeObserver(token) }
            let prepared = expectation(description: "方向交接已准备并开始动画")
            let motion = IslandSwitchMotion(direction: .left, reduceMotion: false)
            fixture.window.beginInboundHandoff(motion: motion) { generation in
                fixture.window.showPreparedHandoff(generation: generation, motion: motion)
                prepared.fulfill()
            }
            let session = AgentSession(id: "directional-question-\(arrivesDuringPreparation)", agentType: .openCode)
            session.status = .waitingAnswer
            let question = PendingQuestion(requestingAgent: .openCode, text: "请确认保留草稿。",
                options: ["继续"], respond: { _ in XCTFail("恢复展示不能提交问答") },
                cancel: { XCTFail("恢复展示不能取消问答") })
            question.state.draftAnswer = "动画结束后继续处理"
            session.pendingQuestion = question
            if arrivesDuringPreparation {
                fixture.manager.sessions.append(session)
                fixture.layout()
            }
            await fulfillment(of: [prepared], timeout: 1)
            XCTAssertTrue(fixture.window.isSwitchingApps)
            XCTAssertTrue(fixture.window.handoffState.isPresentingInbound)
            if !arrivesDuringPreparation {
                fixture.manager.sessions.append(session)
                fixture.layout()
            }
            await pump(fixture, for: 0.05)

            NotificationCenter.default.post(name: .xislandScrollDown, object: nil)
            assertCollapsed(fixture)
            XCTAssertTrue(fixture.window.isSwitchingApps, "普通展开不能中断入站动画")
            XCTAssertEqual(question.state.draftAnswer, "动画结束后继续处理")
            await fulfillment(of: [finished], timeout: 1)
            await pump(fixture, for: 0.24)

            XCTAssertFalse(fixture.window.isSwitchingApps)
            XCTAssertEqual(fixture.window.islandState, .question(session.id))
            XCTAssertEqual(fixture.manager.currentIslandState, .question(session.id))
            XCTAssertEqual(session.pendingQuestion?.id, question.id)
            XCTAssertEqual(question.state.draftAnswer, "动画结束后继续处理")
            XCTAssertEqual(fixture.harness.orderFrontCount, 2, "完成通知不能再次发布普通显示")
            XCTAssertEqual(fixture.harness.orderOutCount, 0)
        }
    }

    func testOrdinaryExpansionCannotInterruptOutgoingAnimation() async throws {
        let fixture = try makeFixture(sessions: [])
        defer { fixture.close() }
        let prepared = expectation(description: "挂载收起视图")
        fixture.window.beginInboundHandoff { generation in
            fixture.window.showPreparedHandoff(generation: generation)
            prepared.fulfill()
        }
        try fixture.mount()
        await fulfillment(of: [prepared], timeout: 1)
        await pump(fixture, for: 0.05)
        fixture.harness.reduceMotion = false
        fixture.window.hideWindowForIslandSwitch(motion: IslandSwitchMotion(direction: .right, reduceMotion: false))

        NotificationCenter.default.post(name: .xislandScrollDown, object: nil)

        assertCollapsed(fixture)
        XCTAssertTrue(fixture.window.isSwitchingApps)
        XCTAssertTrue(fixture.harness.sizeReports.isEmpty, "出站期间普通展开不能排入尺寸动画")
        await pump(fixture, for: 0.35)
        XCTAssertEqual(fixture.harness.orderOutCount, 1)
        XCTAssertFalse(fixture.window.isSwitchingApps)
        assertCollapsed(fixture)
    }

    func testTickerResizeWaitsUntilDirectionalHandoffCompletes() async throws {
        let fixture = try makeFixture(sessions: [])
        defer { fixture.close() }
        let mounted = expectation(description: "挂载带ticker的收起视图")
        fixture.window.beginInboundHandoff { generation in
            fixture.window.showPreparedHandoff(generation: generation)
            mounted.fulfill()
        }
        try fixture.mount()
        await fulfillment(of: [mounted], timeout: 1)
        await pump(fixture, for: 0.05)
        fixture.harness.reduceMotion = false
        let prepared = expectation(description: "方向入站已开始")
        let finished = expectation(description: "尺寸锁随入站动画释放")
        let observer = NotificationCenter.default.addObserver(forName: .xislandHandoffLayoutDidUnlock,
            object: fixture.window, queue: .main) { _ in finished.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let motion = IslandSwitchMotion(direction: .left, reduceMotion: false)
        fixture.window.beginInboundHandoff(motion: motion) { generation in
            fixture.window.showPreparedHandoff(generation: generation, motion: motion)
            prepared.fulfill()
        }
        await fulfillment(of: [prepared], timeout: 1)
        let animatedFrame = fixture.window.frame

        fixture.defaults.set(false, forKey: "showActivityTicker")
        await pump(fixture, for: 0.05)

        XCTAssertTrue(fixture.window.isHandoffLayoutLocked)
        XCTAssertEqual(fixture.window.frame, animatedFrame, "ticker变化不能在固定mask动画中途缩窗")
        await fulfillment(of: [finished], timeout: 1)
        await pump(fixture, for: 0.05)
        XCTAssertFalse(fixture.window.isHandoffLayoutLocked)
        XCTAssertEqual(fixture.window.frame.height, animatedFrame.height - 22, accuracy: 0.01)
        XCTAssertEqual(fixture.harness.orderFrontCount, 2)
    }

    func testDelayedInteractionExpansionUsesReplacementQuestion() async throws {
        let fixture = try makeFixture(sessions: [])
        defer { fixture.close() }
        let initialPreparation = expectation(description: "挂载无审批的交接视图")
        fixture.window.beginInboundHandoff { generation in
            fixture.window.showPreparedHandoff(generation: generation)
            initialPreparation.fulfill()
        }
        try fixture.mount()
        await fulfillment(of: [initialPreparation], timeout: 1)
        await pump(fixture, for: 0.05)

        let firstSession = AgentSession(id: "handoff-question-a", agentType: .openCode)
        firstSession.status = .waitingAnswer
        firstSession.pendingQuestion = PendingQuestion(
            requestingAgent: .openCode, text: "请求 A", options: ["继续"],
            respond: { _ in XCTFail("展示过程不应提交请求 A") }, cancel: nil
        )
        let replacementSession = AgentSession(id: "handoff-question-b", agentType: .codex)
        replacementSession.status = .waitingAnswer
        replacementSession.pendingQuestion = PendingQuestion(
            requestingAgent: .codex, text: "请求 B", options: ["继续"],
            respond: { _ in XCTFail("展示过程不应提交请求 B") }, cancel: nil
        )
        let replacementID = try XCTUnwrap(replacementSession.pendingQuestion?.id)
        let replaced = expectation(description: "第一段展开后立即替换待处理问答")
        fixture.window.beginInboundHandoff { generation in
            fixture.window.showPreparedHandoff(generation: generation)
            // 下一轮主队列先于 0.18s 回调执行，不靠固定等待猜测第一段展开的时机。
            DispatchQueue.main.async {
                fixture.layout()
                XCTAssertEqual(fixture.window.islandState, .expanded)
                XCTAssertTrue(fixture.manager.hasInteraction)
                firstSession.pendingQuestion = nil
                firstSession.status = .idle
                fixture.manager.sessions = [replacementSession]
                XCTAssertTrue(fixture.manager.hasInteraction, "替换应保持交互存在，避免另起自动展开流程")
                replaced.fulfill()
            }
        }
        fixture.manager.sessions = [firstSession]
        fixture.layout()
        await fulfillment(of: [replaced], timeout: 1)
        await pump(fixture, for: 0.3)

        XCTAssertEqual(fixture.window.islandState, .question(replacementSession.id))
        XCTAssertEqual(fixture.manager.currentIslandState, .question(replacementSession.id))
        XCTAssertNotEqual(fixture.window.islandState, .question(firstSession.id))
        XCTAssertEqual(replacementSession.pendingQuestion?.id, replacementID)
        XCTAssertEqual(fixture.manager.sessions.map(\.id), [replacementSession.id])
        XCTAssertEqual(fixture.harness.orderFrontCount, 2)
        XCTAssertEqual(fixture.harness.orderOutCount, 0)
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testAttentionNotificationExpandsReplacementRequestWhenInteractionWasAlreadyPending() async throws {
        for kind in [TaskAttentionEvent.Kind.permission, .question] {
            let fixture = try makeFixture(sessions: [])
            defer { fixture.close() }
            enableAttentionForTest()
            var events: [TaskAttentionEvent] = []
            fixture.manager.onTaskAttention = { events.append($0) }
            var request = attentionMessage(kind == .permission ? .permissionRequest : .question)
            request.nativeRequestId = "first-request"
            request.tool = "Read"
            request.permDescription = "Approve file inspection"
            request.questionText = "Which option?"
            request.options = ["A", "B"]
            if kind == .permission {
                fixture.manager.handlePermissionRequest(request, respond: { _ in XCTFail("提醒不应审批") })
            } else {
                fixture.manager.handleQuestionRequest(request, respond: { _ in XCTFail("提醒不应回答") })
            }
            let mounted = expectation(description: "已有请求仍以收起状态挂载")
            fixture.window.beginInboundHandoff { generation in
                fixture.window.showPreparedHandoff(generation: generation)
                mounted.fulfill()
            }
            try fixture.mount()
            await fulfillment(of: [mounted], timeout: 1)
            await pump(fixture, for: 0.05)
            assertCollapsed(fixture)
            XCTAssertTrue(fixture.manager.hasInteraction)

            request.nativeRequestId = "replacement-request"
            if kind == .permission {
                fixture.manager.handlePermissionRequest(request, respond: { _ in XCTFail("提醒不应审批新请求") })
            } else {
                fixture.manager.handleQuestionRequest(request, respond: { _ in XCTFail("提醒不应回答新请求") })
            }
            fixture.layout()
            let event = try XCTUnwrap(events.last)
            XCTAssertTrue(fixture.manager.hasInteraction)
            XCTAssertEqual(events.count, 2)
            NotificationCenter.default.post(name: .xislandTaskAttention, object: fixture.window,
                                             userInfo: ["event": event])
            await pump(fixture, for: 0.3)

            let expected: IslandState = kind == .permission ? .permission(request.sessionId) : .question(request.sessionId)
            XCTAssertEqual(fixture.window.islandState, expected)
            XCTAssertEqual(fixture.manager.currentIslandState, expected)
            XCTAssertTrue(fixture.manager.isCurrentTaskAttention(event))
            XCTAssertFalse(fixture.window.isVisible, "离屏host只检查真实布局与状态，不显示正式窗口")
        }
    }

    func testCompletionAttentionStaysCollapsedAndDoesNotMarkResultReviewed() async throws {
        let fixture = try makeFixture(sessions: [])
        defer { fixture.close() }
        enableAttentionForTest()
        let mounted = expectation(description: "挂载收起视图")
        fixture.window.beginInboundHandoff { generation in
            fixture.window.showPreparedHandoff(generation: generation)
            mounted.fulfill()
        }
        try fixture.mount()
        await fulfillment(of: [mounted], timeout: 1)
        await pump(fixture, for: 0.05)
        var events: [TaskAttentionEvent] = []
        fixture.manager.onTaskAttention = { events.append($0) }
        fixture.manager.handleMessage(attentionMessage(.sessionStart))
        fixture.manager.handleMessage(attentionMessage(.sessionEnd))
        fixture.layout()
        let event = try XCTUnwrap(events.first)
        NotificationCenter.default.post(name: .xislandTaskAttention, object: fixture.window,
                                         userInfo: ["event": event])
        await pump(fixture, for: 0.3)

        assertCollapsed(fixture)
        XCTAssertTrue(try XCTUnwrap(fixture.manager.sessions.first).completionNeedsReview)
        XCTAssertTrue(fixture.manager.isCurrentTaskAttention(event))
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testObservedWaitingAttentionOpensOverviewWithoutLocalApprovalControls() async throws {
        let fixture = try makeFixture(sessions: [])
        defer { fixture.close() }
        enableAttentionForTest()
        let mounted = expectation(description: "挂载被动观察测试视图")
        fixture.window.beginInboundHandoff { generation in
            fixture.window.showPreparedHandoff(generation: generation)
            mounted.fulfill()
        }
        try fixture.mount()
        await fulfillment(of: [mounted], timeout: 1)
        await pump(fixture, for: 0.05)
        var events: [TaskAttentionEvent] = []
        fixture.manager.onTaskAttention = { events.append($0) }
        var waiting = attentionMessage(.statusUpdate)
        waiting.observedState = "waitingPermission"
        fixture.manager.handleMessage(waiting)
        fixture.layout()
        let event = try XCTUnwrap(events.first)
        NotificationCenter.default.post(name: .xislandTaskAttention, object: fixture.window,
                                         userInfo: ["event": event])
        await pump(fixture, for: 0.3)

        XCTAssertEqual(fixture.window.islandState, .expanded)
        XCTAssertEqual(fixture.manager.currentIslandState, .expanded)
        XCTAssertFalse(fixture.manager.hasInteraction)
        XCTAssertNil(fixture.manager.sessions.first?.pendingPermission)
        XCTAssertFalse(fixture.window.isVisible)
    }

    private func enableAttentionForTest() {
        let oldAttention = AppPreferences.defaults.object(forKey: TaskAttentionSettings.enabledKey)
        let oldBypass = AppPreferences.defaults.object(forKey: "bypassMode")
        AppPreferences.defaults.set(true, forKey: TaskAttentionSettings.enabledKey)
        AppPreferences.defaults.set(false, forKey: "bypassMode")
        addTeardownBlock {
            for (key, value) in [(TaskAttentionSettings.enabledKey, oldAttention), ("bypassMode", oldBypass)] {
                if let value { AppPreferences.defaults.set(value, forKey: key) }
                else { AppPreferences.defaults.removeObject(forKey: key) }
            }
        }
    }

    private func attentionMessage(_ type: DIMessageType) -> DIMessage {
        var value = DIMessage(type: type, sessionId: "content-attention-session")
        value.agentType = "codex"
        value.statusIsAssistantReply = false
        if type == .sessionEnd { value.observedState = "completed" }
        return value
    }

    private var collapsedWindowHeight: CGFloat {
        IslandSizeCalculator.collapsedShapeHeight + 22 + NotchWindow.windowTopExtension
    }

    private func assertCollapsed(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.window.islandState, .collapsed, file: file, line: line)
        XCTAssertEqual(fixture.manager.currentIslandState, .collapsed, file: file, line: line)
        // AppKit 将非整数窗口边界向整点对齐；1pt 容差仍能检出额外 8/16pt padding。
        XCTAssertEqual(fixture.window.frame.width, IslandSizeCalculator.pillWidth, accuracy: 1,
                       "收起窗口宽度不能包含通用 padding", file: file, line: line)
        XCTAssertEqual(fixture.window.frame.height, collapsedWindowHeight, accuracy: 1,
                       "收起高度应只含药丸、22pt ticker 和窗口顶部延伸", file: file, line: line)
    }

    private func assertQuestionPreserved(
        _ session: AgentSession,
        question: PendingQuestion,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(session.status, .waitingAnswer, file: file, line: line)
        XCTAssertEqual(session.pendingQuestion?.id, question.id, file: file, line: line)
        XCTAssertTrue(session.pendingQuestion?.state === question.state, file: file, line: line)
        XCTAssertEqual(session.pendingQuestion?.state.draftAnswer, "/tmp/保留中的项目草稿", file: file, line: line)
        XCTAssertEqual(session.pendingQuestion?.state.selectedAnswers, ["当前项目"], file: file, line: line)
    }

    private func pump(_ fixture: Fixture, for duration: TimeInterval) async {
        fixture.layout()
        let settled = expectation(description: "等待 SwiftUI 布局与已排队回调")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { settled.fulfill() }
        await fulfillment(of: [settled], timeout: duration + 1)
        fixture.layout()
    }

    private func makeFixture(sessions: [AgentSession], disableAnimations: Bool = true) throws -> Fixture {
        _ = try XCTUnwrap(AppPreferences.isIsolated ? true : nil, "必须先进入隔离测试模式")
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else {
            throw XCTSkip("隐藏视图验证需要 WindowServer 和可用屏幕")
        }
        let suite = "XIslandTests.NotchContentHandoff.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(disableAnimations, forKey: "disableAnimations")
        defaults.set(false, forKey: "reduceMotion")
        defaults.set(true, forKey: "showActivityTicker")
        defaults.set(false, forKey: "autoHideWhenNoActiveSessions")
        defaults.set(false, forKey: "hoverToExpandPanel")
        defaults.set(false, forKey: "smartSuppression")
        defaults.set(false, forKey: AutoCollapseSettings.enabledKey)
        defaults.set("medium", forKey: "animationIntensity")
        let configuration = AppTestConfiguration(isEnabled: true, fixtureName: nil, fixturePath: nil,
                                                diagnosticsPath: nil, disableAnimations: disableAnimations)
        let manager = SessionManager(testConfiguration: configuration)
        manager.sessions = sessions
        let audio = AudioEngine()
        let quota = QuotaTracker(testConfiguration: configuration)
        XCTAssertFalse(quota.isPolling)
        let previousAppearance = NSApp.appearance
        let theme = ThemeManager()
        let harness = Harness()
        let window = NotchWindow(
            defaults: defaults,
            markVisible: {},
            onExplicitShow: {},
            handoffEnvironment: harness.environment()
        )
        NSWorkspace.shared.notificationCenter.removeObserver(window)
        return Fixture(window: window, harness: harness, defaults: defaults, suite: suite,
                       manager: manager, audio: audio, quota: quota, theme: theme,
                       previousAppearance: previousAppearance)
    }

    @MainActor
    private final class Fixture {
        let window: NotchWindow
        let harness: Harness
        let defaults: UserDefaults
        let suite: String
        let manager: SessionManager
        let audio: AudioEngine
        let quota: QuotaTracker
        let theme: ThemeManager
        let previousAppearance: NSAppearance?
        private var host: NSHostingView<AnyView>?

        init(window: NotchWindow, harness: Harness, defaults: UserDefaults, suite: String,
             manager: SessionManager, audio: AudioEngine, quota: QuotaTracker, theme: ThemeManager,
             previousAppearance: NSAppearance?) {
            self.window = window
            self.harness = harness
            self.defaults = defaults
            self.suite = suite
            self.manager = manager
            self.audio = audio
            self.quota = quota
            self.theme = theme
            self.previousAppearance = previousAppearance
        }

        func mount() throws {
            let window = self.window
            let harness = self.harness
            let contentView = try XCTUnwrap(window.contentView)
            let view = NotchContentView(
                onSizeChange: { [weak window, weak harness] width, height, display in
                    harness?.sizeReports.append(CGSize(width: width, height: height))
                    window?.resizeToFit(contentWidth: width, contentHeight: height, display: display)
                },
                windowProvider: { [weak window] in window }
            )
            .environment(manager).environment(audio).environment(quota).environment(theme)
            .defaultAppStorage(defaults)
            let host = NSHostingView(rootView: AnyView(view))
            host.frame = contentView.bounds
            host.autoresizingMask = [.width, .height]
            self.host = host
            contentView.addSubview(host)
            layout()
        }

        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            host?.layoutSubtreeIfNeeded()
        }

        func close() {
            host?.rootView = AnyView(EmptyView())
            host?.layoutSubtreeIfNeeded()
            host?.removeFromSuperview()
            host = nil
            window.removeHandoffPreparationHandler()
            window.contentView = nil
            window.close()
            theme.stopObservingSystemAppearance()
            NSApp.appearance = previousAppearance
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @MainActor
    private final class Harness {
        var orderFrontCount = 0
        var orderOutCount = 0
        var sizeReports: [CGSize] = []
        var reduceMotion = true

        func environment() -> NotchWindow.HandoffEnvironment {
            .init(
                reduceMotion: { [unowned self] in reduceMotion },
                orderFront: { [unowned self] _ in orderFrontCount += 1 },
                orderOut: { [unowned self] _ in orderOutCount += 1 }
            )
        }
    }
}
