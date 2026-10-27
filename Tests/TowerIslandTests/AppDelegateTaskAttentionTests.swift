import AppKit
import DIShared
import XCTest
@testable import DIBridge
@testable import XIsland

@MainActor
final class AppDelegateTaskAttentionTests: XCTestCase {
    func testRealCompletionCancelsOldHandoffAndNotifiesOnlyItsWindowWithoutAcknowledging() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let oldGeneration = fixture.window.beginInboundHandoff { _ in
            XCTFail("优先提醒后旧交接不能再显示")
        }
        var received: [(AnyObject?, TaskAttentionEvent?)] = []
        let observer = NotificationCenter.default.addObserver(forName: .xislandTaskAttention,
            object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    received.append((note.object as AnyObject?, note.userInfo?["event"] as? TaskAttentionEvent))
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        fixture.delegate.sessionManager.onTaskAttention = { [weak delegate = fixture.delegate] event in
            delegate?.presentTaskAttention(event)
        }
        fixture.delegate.sessionManager.handleMessage(message(.sessionStart))
        fixture.delegate.sessionManager.handleMessage(message(.sessionEnd))

        XCTAssertEqual(fixture.harness.orderFrontCount, 1)
        XCTAssertEqual(fixture.harness.orderOutCount, 0)
        XCTAssertFalse(fixture.window.isVisible, "呈现由注入计数器接收，不能显示真实窗口")
        XCTAssertNil(fixture.window.handoffState.pendingPreparation)
        XCTAssertFalse(fixture.window.isSwitchingApps)
        XCTAssertFalse(fixture.window.completeInboundHandoffPreparation(generation: oldGeneration))
        XCTAssertEqual(received.count, 1)
        XCTAssertTrue(received.first?.0 === fixture.window)
        XCTAssertEqual(received.first?.1?.kind, .completion)
        XCTAssertEqual(fixture.window.islandState, .collapsed)
        XCTAssertTrue(try XCTUnwrap(fixture.delegate.sessionManager.sessions.first).completionNeedsReview)
    }

    func testDefaultCallbackCoalescesRealRequestsAndPreservesTheirPendingState() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let delivered = expectation(description: "真实管理器回调经提醒队列呈现")
        var received: [TaskAttentionEvent] = []
        let observer = NotificationCenter.default.addObserver(forName: .xislandTaskAttention,
            object: fixture.window, queue: .main) { note in
                MainActor.assumeIsolated {
                    if let event = note.userInfo?["event"] as? TaskAttentionEvent {
                        received.append(event)
                        delivered.fulfill()
                    }
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        var permission = message(.permissionRequest)
        permission.nativeRequestId = "native-request"
        permission.tool = "Read"
        permission.permDescription = "Review the operation"
        fixture.delegate.sessionManager.handlePermissionRequest(permission, respond: { _ in
            XCTFail("显示提醒不能代替用户审批")
        })
        fixture.delegate.sessionManager.handlePermissionRequest(permission, respond: { _ in
            XCTFail("重复请求提醒不能代替用户审批")
        })
        await fulfillment(of: [delivered], timeout: 1)

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.kind, .permission)
        XCTAssertEqual(fixture.harness.orderFrontCount, 1)
        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertNotNil(fixture.delegate.sessionManager.sessions.first?.pendingPermission)
        XCTAssertTrue(fixture.delegate.sessionManager.hasInteraction)
        XCTAssertTrue(fixture.delegate.sessionManager.isCurrentTaskAttention(try XCTUnwrap(received.first)))
    }

    func testWorkBuddyCompletionUsesDefaultQueueCancelsOldHandoffAndDoesNotRepeat() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let receptionKey = "autoConfigure.workbuddy"
        let previousReception = AppPreferences.defaults.object(forKey: receptionKey)
        AppPreferences.defaults.set(true, forKey: receptionKey)
        defer {
            if let previousReception { AppPreferences.defaults.set(previousReception, forKey: receptionKey) }
            else { AppPreferences.defaults.removeObject(forKey: receptionKey) }
        }
        let oldGeneration = fixture.window.beginInboundHandoff { _ in
            XCTFail("WorkBuddy 完成提醒后旧交接不能再显示")
        }
        let delivered = expectation(description: "WorkBuddy 完成经默认提醒队列呈现")
        let repeated = expectation(description: "重复 FinalStop 不能再次呈现")
        repeated.isInverted = true
        var received: [TaskAttentionEvent] = []
        let observer = NotificationCenter.default.addObserver(forName: .xislandTaskAttention,
            object: fixture.window, queue: .main) { note in
                MainActor.assumeIsolated {
                    if let event = note.userInfo?["event"] as? TaskAttentionEvent {
                        received.append(event)
                        if received.count == 1 { delivered.fulfill() }
                        else { repeated.fulfill() }
                    }
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        func workBuddyMessage(_ event: String, fields: [String: Any]) throws -> DIMessage {
            var input: [String: Any] = ["hook_event_name": event,
                                       "session_id": "delegate-workbuddy-session", "cwd": "/tmp/project"]
            input.merge(fields) { _, value in value }
            return try WorkBuddyHookAdapter.normalize(hookType: event, stdinData: input)
        }
        let manager = fixture.delegate.sessionManager
        manager.handleMessage(try workBuddyMessage("UserPromptSubmit", fields: ["prompt": "完成提醒回归"]))
        manager.handleMessage(try workBuddyMessage("Stop", fields: ["last_assistant_message": "处理完成"]))
        XCTAssertEqual(manager.sessions.first?.status, .completionUnconfirmed)
        XCTAssertEqual(fixture.harness.orderFrontCount, 0)
        let completed = try workBuddyMessage("FinalStop", fields: ["final_stop_reason": "completed"])
        manager.handleMessage(completed)
        XCTAssertEqual(fixture.harness.orderFrontCount, 0, "保留默认 80ms 队列，不能直接呈现")
        await fulfillment(of: [delivered], timeout: 1)

        let session = try XCTUnwrap(manager.sessions.first)
        let event = try XCTUnwrap(received.first)
        XCTAssertEqual(event.kind, .completion)
        XCTAssertEqual(event.sessionID, session.id)
        XCTAssertEqual(fixture.harness.orderFrontCount, 1)
        XCTAssertEqual(fixture.harness.orderOutCount, 0)
        XCTAssertFalse(fixture.window.isVisible, "呈现由注入计数器接收，不能显示真实窗口")
        XCTAssertNil(fixture.window.handoffState.pendingPreparation)
        XCTAssertFalse(fixture.window.isSwitchingApps)
        XCTAssertFalse(fixture.window.completeInboundHandoffPreparation(generation: oldGeneration))
        XCTAssertTrue(session.completionNeedsReview)
        XCTAssertTrue(manager.isCurrentTaskAttention(event))

        manager.handleMessage(completed)
        await fulfillment(of: [repeated], timeout: 0.2)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(fixture.harness.orderFrontCount, 1)
        XCTAssertTrue(session.completionNeedsReview)
    }

    func testDisabledReviewedOrResolvedEventCannotPresentWindow() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        var received: [TaskAttentionEvent] = []
        fixture.delegate.sessionManager.onTaskAttention = { received.append($0) }
        fixture.delegate.sessionManager.handleMessage(message(.sessionStart))
        fixture.delegate.sessionManager.handleMessage(message(.sessionEnd))
        let completion = try XCTUnwrap(received.last)
        AppPreferences.defaults.set(false, forKey: TaskAttentionSettings.enabledKey)
        fixture.delegate.presentTaskAttention(completion)
        XCTAssertEqual(fixture.harness.orderFrontCount, 0)
        AppPreferences.defaults.set(true, forKey: TaskAttentionSettings.enabledKey)
        fixture.delegate.sessionManager.markCompletionReviewed(sessionID: completion.sessionID)
        fixture.delegate.presentTaskAttention(completion)
        XCTAssertEqual(fixture.harness.orderFrontCount, 0)

        var question = message(.question)
        question.nativeRequestId = "native-question"
        question.questionText = "Continue?"
        question.options = ["Yes", "No"]
        fixture.delegate.sessionManager.handleQuestionRequest(question, respond: { _ in
            XCTFail("原生端解决请求不能调用本地回答")
        })
        let questionEvent = try XCTUnwrap(received.last)
        var resolved = message(.interactionResolved)
        resolved.nativeRequestKind = "question"
        resolved.nativeRequestId = "native-question"
        fixture.delegate.sessionManager.handleMessage(resolved)
        fixture.delegate.presentTaskAttention(questionEvent)
        XCTAssertEqual(fixture.harness.orderFrontCount, 0)
        XCTAssertFalse(fixture.window.isVisible)
    }

    private func message(_ type: DIMessageType) -> DIMessage {
        var value = DIMessage(type: type, sessionId: "delegate-attention-session")
        value.agentType = "codex"
        value.statusIsAssistantReply = false
        if type == .sessionEnd { value.observedState = "completed" }
        return value
    }

    private func makeFixture() throws -> Fixture {
        XCTAssertTrue(AppPreferences.isIsolated)
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("隐藏窗口验证需要 WindowServer") }
        let suite = "XIslandTests.AppDelegateTaskAttention.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let keys = [TaskAttentionSettings.enabledKey, "bypassMode", IslandAttentionEpoch.defaultsKey]
        let previousDefaults = keys.map { ($0, AppPreferences.defaults.object(forKey: $0)) }
        AppPreferences.defaults.set(true, forKey: TaskAttentionSettings.enabledKey)
        AppPreferences.defaults.set(false, forKey: "bypassMode")
        let previousAppearance = NSApp.appearance
        let configuration = AppTestConfiguration(isEnabled: true, fixtureName: nil, fixturePath: nil,
                                                 diagnosticsPath: nil, disableAnimations: true)
        let delegate = AppDelegate(testConfiguration: configuration, launchHooks: .init(
            performInitialStartup: { _ in XCTFail("此测试不启动应用生命周期") },
            performProductionGlobalStartup: { _ in XCTFail("隔离测试不能启动正式服务") }))
        let harness = Harness()
        let window = NotchWindow(defaults: defaults, markVisible: {}, onExplicitShow: {},
            handoffEnvironment: .init(reduceMotion: { true },
                orderFront: { _ in harness.orderFrontCount += 1 },
                orderOut: { _ in harness.orderOutCount += 1 }))
        NSWorkspace.shared.notificationCenter.removeObserver(window)
        delegate.notchWindow = window
        return Fixture(delegate: delegate, window: window, harness: harness, defaults: defaults,
                       suite: suite, previousDefaults: previousDefaults, previousAppearance: previousAppearance)
    }

    @MainActor
    private final class Harness {
        var orderFrontCount = 0
        var orderOutCount = 0
    }

    @MainActor
    private struct Fixture {
        let delegate: AppDelegate
        let window: NotchWindow
        let harness: Harness
        let defaults: UserDefaults
        let suite: String
        let previousDefaults: [(String, Any?)]
        let previousAppearance: NSAppearance?

        func close() {
            delegate.sessionManager.onTaskAttention = nil
            delegate.notchWindow = nil
            window.close()
            delegate.themeManager.stopObservingSystemAppearance()
            NSApp.appearance = previousAppearance
            defaults.removePersistentDomain(forName: suite)
            for (key, value) in previousDefaults {
                if let value { AppPreferences.defaults.set(value, forKey: key) }
                else { AppPreferences.defaults.removeObject(forKey: key) }
            }
        }
    }
}
