import XCTest
import DIShared
@testable import XIsland

@MainActor
final class ArchivedSessionLifecycleTests: XCTestCase {
    private func message(_ type: DIMessageType, id: String = "codex-archived") -> DIMessage {
        var message = DIMessage(type: type, sessionId: id)
        message.agentType = "codex"
        return message
    }

    private func context() throws -> (SessionManager, AgentSession, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-archive-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("history.store")
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(storeURL: store))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        var start = message(.sessionStart)
        start.prompt = "Original prompt"
        start.nativeMessageId = "original-prompt"
        manager.handleMessage(start)
        let session = try XCTUnwrap(manager.sessions.first)
        session.events = [ToolEvent(tool: "Read", result: "Original result", isComplete: true, toolCallId: "old-tool")]
        session.tokenUsage = TokenUsage(inputTokens: 7, outputTokens: 9, totalTokens: 16, estimatedCostUSD: 0.1, model: "fixture")
        session.recapText = "Original recap"
        var end = message(.sessionEnd)
        end.observedState = "completed"
        manager.handleMessage(end)
        manager.dismissSession(session)
        XCTAssertTrue(manager.sessions.isEmpty)
        return (manager, session, store)
    }

    private func reopened(_ store: URL) -> SessionManager {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(storeURL: store))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        return manager
    }

    func testArchivedAndRestartedTerminalSessionsIgnoreLateEventsAndDuplicates() throws {
        for restart in [false, true] {
            let (original, closed, store) = try context()
            let manager = restart ? reopened(store) : original
            var stop = message(.statusUpdate)
            stop.observedState = "completionUnconfirmed"
            var info = message(.statusUpdate)
            info.statusIsAssistantReply = false
            info.status = "Late notice"
            var result = message(.toolComplete)
            result.tool = "Read"
            result.toolCallId = "old-tool"
            var recap = message(.recap)
            recap.recapText = "Late recap"
            var duplicatePrompt = message(.sessionStart)
            duplicatePrompt.nativeMessageId = "original-prompt"
            duplicatePrompt.prompt = "Original prompt"
            var duplicateTool = message(.toolStart)
            duplicateTool.toolCallId = "old-tool"
            duplicateTool.tool = "Read"
            var events = [stop, info, result, recap, duplicatePrompt, duplicateTool]
            for type in [DIMessageType.sessionStart, .toolStart, .contextCompact, .statusUpdate] {
                var replay = message(type)
                replay.nativeMessageReplay = true
                replay.observedState = "active"
                events.append(replay)
            }
            for event in events {
                manager.handleMessage(event)
                XCTAssertTrue(manager.sessions.isEmpty, "\(event.type), restart=\(restart)")
                let saved = try XCTUnwrap(manager.persistenceManager?.fetchHistory().first)
                XCTAssertEqual(saved.status, .completed)
                XCTAssertEqual(saved.completedAt, closed.completedAt)
                XCTAssertEqual(saved.startTime, closed.startTime)
                XCTAssertEqual(saved.recapText, "Original recap")
                XCTAssertEqual(saved.totalTokens, 16)
            }
        }
    }

    func testAcceptedResumeAfterRestartPreservesHistoryAndRefreshesCheckpoint() throws {
        for type in [DIMessageType.sessionStart, .toolStart, .statusUpdate, .contextCompact] {
            let (_, closed, store) = try context()
            let manager = reopened(store)
            var activity = message(type)
            activity.prompt = "New prompt"
            activity.nativeMessageId = "new-prompt"
            activity.tool = "Bash"
            activity.toolCallId = "new-tool"
            activity.observedState = "active"
            manager.handleMessage(activity)
            let resumed = try XCTUnwrap(manager.sessions.first)
            XCTAssertEqual(resumed.status, type == .contextCompact ? .compacting : .active)
            XCTAssertNil(resumed.completedAt)
            XCTAssertNil(resumed.observationEndedAt)
            XCTAssertEqual(resumed.startTime, closed.startTime)
            XCTAssertEqual(resumed.events.first?.id, closed.events.first?.id)
            XCTAssertEqual(resumed.events.first?.timestamp, closed.events.first?.timestamp)
            XCTAssertEqual(resumed.events.first?.result, "Original result")
            XCTAssertEqual(resumed.chatHistory.first?.id, closed.chatHistory.first?.id)
            XCTAssertEqual(resumed.tokenUsage.totalTokens, 16)
            XCTAssertEqual(resumed.recapText, "Original recap")
            let saved = try XCTUnwrap(reopened(store).persistenceManager?.fetchHistory().first)
            XCTAssertEqual(saved.status, resumed.status)
            XCTAssertNil(saved.completedAt)
            XCTAssertEqual(saved.startTime, closed.startTime)
            XCTAssertEqual(saved.toolEvents.filter { $0.toolCallId == "old-tool" }.count, 1)
        }
    }

    func testLingerRemovedObservationUnavailableRemainsHiddenUntilFreshPrompt() throws {
        let (manager, session, store) = try context()
        session.status = .observationUnavailable
        session.completedAt = nil
        session.observationEndedAt = Date(timeIntervalSinceNow: -600)
        XCTAssertTrue(manager.persistenceManager?.save(session: session) == true)
        manager.sessions = [session]
        let previous = AppPreferences.defaults.object(forKey: "completedLingerDuration")
        defer {
            if let previous { AppPreferences.defaults.set(previous, forKey: "completedLingerDuration") }
            else { AppPreferences.defaults.removeObject(forKey: "completedLingerDuration") }
        }
        AppPreferences.defaults.set(1, forKey: "completedLingerDuration")
        manager.cleanupLingeredSessions()
        XCTAssertTrue(manager.sessions.isEmpty)
        var stop = message(.statusUpdate)
        stop.observedState = "completionUnconfirmed"
        manager.handleMessage(stop)
        XCTAssertTrue(manager.sessions.isEmpty)
        var start = message(.sessionStart)
        start.prompt = "Resume observed work"
        manager.handleMessage(start)
        XCTAssertEqual(manager.sessions.first?.status, .active)
        XCTAssertNil(manager.sessions.first?.observationEndedAt)
        XCTAssertNil(reopened(store).persistenceManager?.fetchHistory().first?.observationEndedAt)
    }

    func testLookupIsNotLimitedToFirstPageAndDeletedHistoryIsNotCached() throws {
        let (manager, session, _) = try context()
        for index in 0..<105 {
            let newer = AgentSession(id: "codex-newer-\(index)", agentType: .codex)
            newer.status = .completed
            newer.completedAt = Date().addingTimeInterval(Double(index + 1))
            XCTAssertTrue(manager.persistenceManager?.save(session: newer) == true)
        }
        var stop = message(.statusUpdate)
        stop.observedState = "completionUnconfirmed"
        manager.handleMessage(stop)
        XCTAssertTrue(manager.sessions.isEmpty)
        let stored = try XCTUnwrap(manager.persistenceManager?.fetchHistory(limit: 200).first { $0.sessionId == session.id })
        manager.persistenceManager?.deleteSession(stored)
        manager.handleMessage(message(.sessionStart))
        XCTAssertEqual(manager.sessions.first?.status, .active)
        XCTAssertTrue(manager.sessions.first?.events.isEmpty == true)
    }

    func testSourceConflictAndUnreadableHistoryDoNotCreateReplacement() throws {
        let (manager, closed, store) = try context()
        closed.sourceNamespace = String(repeating: "a", count: 24)
        closed.sourceInstanceId = "00000000-0000-4000-8000-000000000001"
        closed.nativeTaskId = "original"
        XCTAssertTrue(manager.persistenceManager?.save(session: closed) == true)
        let restored = reopened(store)
        restored.handleMessage(message(.sessionStart))
        XCTAssertTrue(restored.sessions.isEmpty)
        let previous = AppPreferences.defaults.object(forKey: "bypassMode")
        defer {
            if let previous { AppPreferences.defaults.set(previous, forKey: "bypassMode") }
            else { AppPreferences.defaults.removeObject(forKey: "bypassMode") }
        }
        restored.bypassMode = true
        restored.handlePermissionRequest(message(.permissionRequest), respond: { _ in XCTFail("来源冲突不能自动审批") })
        XCTAssertTrue(restored.sessions.isEmpty)
        let unavailable = SessionManager()
        unavailable.persistenceManager = SessionPersistenceManager()
        unavailable.handleMessage(message(.sessionStart))
        XCTAssertTrue(unavailable.sessions.isEmpty)
        XCTAssertNotNil(unavailable.persistenceManager?.lastSaveError)
        XCTAssertTrue(unavailable.persistenceManager?.setupContainer(isStoredInMemoryOnly: true) == true)
        unavailable.handleMessage(message(.sessionStart))
        XCTAssertEqual(unavailable.sessions.first?.status, .active)
    }

    func testArchivedInteractionsRestoreHistoryButInvalidOrBypassedRequestsStayHidden() throws {
        let previous = AppPreferences.defaults.object(forKey: "bypassMode")
        defer {
            if let previous { AppPreferences.defaults.set(previous, forKey: "bypassMode") }
            else { AppPreferences.defaults.removeObject(forKey: "bypassMode") }
        }
        for type in [DIMessageType.permissionRequest, .question, .planReview] {
            let (manager, closed, store) = try context()
            manager.bypassMode = false
            var request = message(type)
            request.nativeRequestId = "new-interaction"
            request.questionText = "Continue?"
            request.options = ["Yes", "No"]
            request.planMarkdown = "Review plan"
            switch type {
            case .permissionRequest: manager.handlePermissionRequest(request, respond: { _ in XCTFail("应等待权限决定") })
            case .question: manager.handleQuestionRequest(request, respond: { _ in XCTFail("应等待用户回答") })
            default: manager.handlePlanReview(request, respond: { _, _ in XCTFail("应等待审阅") })
            }
            let resumed = try XCTUnwrap(manager.sessions.first)
            XCTAssertTrue(resumed.hasPendingInteraction)
            XCTAssertEqual(resumed.events.first?.id, closed.events.first?.id)
            XCTAssertNil(resumed.completedAt)
            XCTAssertNil(reopened(store).persistenceManager?.fetchHistory().first?.completedAt)
        }
        let (manager, _, _) = try context()
        manager.bypassMode = false
        manager.handleQuestionRequest(message(.question), respond: { _ in XCTFail("空问题不能回答") })
        XCTAssertTrue(manager.sessions.isEmpty)
        manager.bypassMode = true
        let response = expectation(description: "已有旁路设置仍生效")
        manager.handlePermissionRequest(message(.permissionRequest), respond: { allowed in
            XCTAssertTrue(allowed)
            response.fulfill()
        })
        wait(for: [response], timeout: 1)
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    func testArchivedMirrorsPreserveOwnershipAndIgnoreInheritedStart() throws {
        let (manager, _, _) = try context()
        let cursor = AgentSession(id: "cursor-shared", agentType: .cursor)
        cursor.status = .completed
        cursor.completedAt = Date()
        XCTAssertTrue(manager.persistenceManager?.save(session: cursor) == true)
        var inherited = DIMessage(type: .sessionStart, sessionId: "claude_code-shared")
        inherited.agentType = "claude_code"
        manager.handleMessage(inherited)
        XCTAssertTrue(manager.sessions.isEmpty)
        inherited.type = .toolStart
        inherited.tool = "Read"
        inherited.toolCallId = "new-mirrored-tool"
        manager.handleMessage(inherited)
        XCTAssertEqual(manager.sessions.map(\.id), [cursor.id])
        XCTAssertEqual(manager.sessions.first?.agentType, .cursor)
        XCTAssertEqual(manager.sessions.first?.status, .active)
        XCTAssertEqual(manager.sessions.first?.startTime, cursor.startTime)
    }

    func testArchivedAmbiguousMirrorsNeverMergeDifferentIDEs() throws {
        let (manager, _, _) = try context()
        for agent in [AgentType.claudeCode, .cursor, .trae] {
            let session = AgentSession(id: agent.rawValue + "-shared", agentType: agent)
            session.status = .completed
            session.completedAt = Date()
            XCTAssertTrue(manager.persistenceManager?.save(session: session) == true)
        }
        var incoming = DIMessage(type: .sessionStart, sessionId: "windsurf-shared")
        incoming.agentType = "windsurf"
        manager.handleMessage(incoming)
        XCTAssertTrue(manager.sessions.isEmpty)
        incoming.sessionId = "cursor-shared"
        incoming.agentType = "codex"
        manager.handleMessage(incoming)
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(manager.persistenceManager?.fetchHistory().allSatisfy { $0.status == .completed } == true)
    }

    func testArchivedMirroredQuestionUsesRestoredAgentIdentity() throws {
        let (manager, _, _) = try context()
        let cursor = AgentSession(id: "cursor-question", agentType: .cursor)
        cursor.status = .completed
        cursor.completedAt = Date()
        XCTAssertTrue(manager.persistenceManager?.save(session: cursor) == true)
        var question = DIMessage(type: .question, sessionId: "claude_code-question")
        question.agentType = "claude_code"
        question.questionText = "Continue?"
        question.nativeRequestId = "new-question"
        manager.handleQuestionRequest(question, respond: { _ in XCTFail("应保留待回答") })
        let restored = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(restored.agentType, .cursor)
        XCTAssertEqual(restored.pendingQuestion?.requestingAgent, .cursor)
    }
}
