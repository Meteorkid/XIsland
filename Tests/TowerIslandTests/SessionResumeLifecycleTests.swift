import XCTest
import DIShared
@testable import XIsland

@MainActor
final class SessionResumeLifecycleTests: XCTestCase {
    private let terminalStates: [SessionStatus] = [.completed, .observationUnavailable]

    private func message(_ type: DIMessageType) -> DIMessage {
        var message = DIMessage(type: type, sessionId: "codex-resume")
        message.agentType = "codex"
        return message
    }

    private func temporaryStore() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("history.store")
    }

    private func context(status: SessionStatus) throws -> (SessionManager, AgentSession, URL) {
        let store = try temporaryStore()
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(storeURL: store))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        let session = AgentSession(id: "codex-resume", agentType: .codex,
                                   startTime: Date(timeIntervalSinceNow: -3600))
        manager.sessions = [session]
        var start = message(.sessionStart)
        start.prompt = "Original prompt"
        start.nativeMessageId = "old-prompt"
        manager.handleMessage(start)
        session.events = [ToolEvent(tool: "Read", isComplete: true, toolCallId: "old-tool")]
        session.status = status
        if terminalStates.contains(status) {
            session.completedAt = session.startTime.addingTimeInterval(60)
            session.observationEndedAt = session.startTime.addingTimeInterval(120)
        }
        var stop = message(.statusUpdate)
        stop.observedState = "completionUnconfirmed"
        stop.statusIsAssistantReply = false
        manager.handleMessage(stop)
        XCTAssertEqual(persistence.fetchHistory().first?.status, status)
        return (manager, session, store)
    }

    private func assertResumed(_ session: AgentSession, store: URL, status: SessionStatus = .active,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(session.status, status, file: file, line: line)
        XCTAssertNil(session.completedAt, file: file, line: line)
        XCTAssertNil(session.observationEndedAt, file: file, line: line)
        XCTAssertGreaterThan(session.duration, 3500, file: file, line: line)
        let reopened = SessionPersistenceManager()
        XCTAssertTrue(reopened.setupContainer(storeURL: store), file: file, line: line)
        let saved = try XCTUnwrap(reopened.fetchHistory().first, file: file, line: line)
        XCTAssertEqual(saved.status, status, file: file, line: line)
        XCTAssertNil(saved.completedAt, file: file, line: line)
        XCTAssertNil(saved.observationEndedAt, file: file, line: line)
        XCTAssertEqual(saved.historyDate, session.startTime, file: file, line: line)
        XCTAssertGreaterThan(saved.duration, 3500, file: file, line: line)
    }

    func testSilentLongToolAndExplicitIdleRemainOpenUntilSessionEnd() throws {
        for status in [SessionStatus.active, .idle] {
            let manager = SessionManager()
            manager.handleMessage(message(.sessionStart))
            var activity = message(status == .active ? .toolStart : .statusUpdate)
            activity.tool = "Bash"
            activity.toolCallId = "long-build"
            if status == .idle { activity.observedState = "idle" }
            manager.handleMessage(activity)
            let session = try XCTUnwrap(manager.sessions.first)
            session.lastActivityTime = Date(timeIntervalSinceNow: -3600)
            manager.cleanupStaleSessions()
            XCTAssertEqual(session.status, status)
            XCTAssertNil(session.completedAt)
            XCTAssertNil(session.observationEndedAt)
            if status == .active { XCTAssertEqual(session.currentTool, "Bash") }
            var end = message(.sessionEnd)
            end.observedState = "completed"
            manager.handleMessage(end)
            XCTAssertEqual(session.status, .completed)
            XCTAssertNotNil(session.completedAt)
        }
    }

    func testNewPromptClearsOldEndTimesAndRefreshesSavedCheckpoint() throws {
        for oldStatus in terminalStates + [.completionUnconfirmed] {
            let (manager, session, store) = try context(status: oldStatus)
            var prompt = message(.sessionStart)
            prompt.prompt = "Continue the review"
            prompt.nativeMessageId = "new-prompt"
            manager.handleMessage(prompt)
            try assertResumed(session, store: store)
            XCTAssertEqual(manager.persistenceManager?.fetchHistory().first?.prompt, prompt.prompt)
        }
    }

    func testNewToolClearsOldEndTimesAndRefreshesSavedCheckpoint() throws {
        for oldStatus in terminalStates + [.completionUnconfirmed] {
            let (manager, session, store) = try context(status: oldStatus)
            var tool = message(.toolStart)
            tool.tool = "Bash"
            tool.toolCallId = "new-tool"
            manager.handleMessage(tool)
            try assertResumed(session, store: store)
            XCTAssertEqual(session.currentTool, "Bash")
            XCTAssertEqual(manager.persistenceManager?.fetchHistory().first?.toolEvents.count, 2)
        }
    }

    func testExplicitCurrentStateClearsOldEndTimesAndRefreshesSavedCheckpoint() throws {
        for oldStatus in terminalStates {
            for observed in [SessionStatus.active, .idle, .waitingPermission, .waitingAnswer, .waitingPlanReview] {
                let (manager, session, store) = try context(status: oldStatus)
                var state = message(.statusUpdate)
                state.observedState = observed.rawValue
                state.statusIsAssistantReply = false
                manager.handleMessage(state)
                try assertResumed(session, store: store, status: observed)
            }
        }
    }

    func testAcceptedInteractionsClearOldEndTimesWithoutAnsweringRequests() throws {
        for oldStatus in terminalStates {
            for waiting in [SessionStatus.waitingPermission, .waitingAnswer, .waitingPlanReview] {
                let (manager, session, store) = try context(status: oldStatus)
                var request = message(.permissionRequest)
                request.nativeRequestId = "new-request"
                request.tool = "Bash"
                request.questionText = "Continue?"
                request.options = ["Yes", "No"]
                request.planMarkdown = "Review the changes"
                switch waiting {
                case .waitingPermission: manager.handlePermissionRequest(request) { _ in XCTFail("请求应保持待审批") }
                case .waitingAnswer: manager.handleQuestionRequest(request, respond: { _ in XCTFail("请求应保持待回答") })
                default: manager.handlePlanReview(request) { _, _ in XCTFail("请求应保持待审阅") }
                }
                XCTAssertTrue(session.hasPendingInteraction)
                try assertResumed(session, store: store, status: waiting)
            }
        }
    }

    func testLateInformationalAndToolResultEventsDoNotReopenTerminalSession() throws {
        for oldStatus in terminalStates {
            let (manager, session, store) = try context(status: oldStatus)
            let completed = session.completedAt, observationEnded = session.observationEndedAt
            var stop = message(.statusUpdate)
            stop.observedState = "completionUnconfirmed"
            var information = message(.statusUpdate)
            information.statusIsAssistantReply = false
            information.status = "Late notice"
            var duplicateTool = message(.toolStart)
            duplicateTool.tool = "Read"
            duplicateTool.toolCallId = "old-tool"
            var duplicateSnapshot = duplicateTool
            duplicateSnapshot.nativeEvent = "acp"
            var result = message(.toolComplete)
            result.tool = "Bash"
            result.toolCallId = "result-only"
            result.toolResult = "Late result"
            var recap = message(.recap)
            recap.recapText = "Historical recap"
            var error = message(.statusUpdate)
            error.observedState = "error"
            var legacyError = message(.statusUpdate)
            legacyError.status = "Late tool failed notice"
            for event in [stop, information, duplicateTool, duplicateSnapshot, result, recap, error, legacyError] {
                manager.handleMessage(event)
                XCTAssertEqual(session.status, oldStatus, "\(event.type)")
                XCTAssertEqual(session.completedAt, completed)
                XCTAssertEqual(session.observationEndedAt, observationEnded)
                XCTAssertNil(session.currentTool)
                XCTAssertEqual(session.events.first?.isComplete, true)
            }
            let reopened = SessionPersistenceManager()
            XCTAssertTrue(reopened.setupContainer(storeURL: store))
            XCTAssertEqual(reopened.fetchHistory().first?.status, oldStatus)
            XCTAssertEqual(reopened.fetchHistory().first?.completedAt, completed)
        }
    }

    func testReplayAndDuplicatePromptCannotResumeTerminalSession() throws {
        for oldStatus in terminalStates {
            let (manager, session, _) = try context(status: oldStatus)
            let completed = session.completedAt, observationEnded = session.observationEndedAt
            var duplicate = message(.sessionStart)
            duplicate.nativeMessageId = "old-prompt"
            duplicate.prompt = "Original prompt"
            manager.handleMessage(duplicate)
            XCTAssertEqual(session.status, oldStatus)
            for type in [DIMessageType.sessionStart, .toolStart, .statusUpdate, .contextCompact] {
                var replay = message(type)
                replay.nativeMessageReplay = true
                replay.nativeMessageId = "historical-prompt"
                replay.prompt = "Historical prompt"
                replay.tool = "Read"
                replay.toolCallId = "historical-tool"
                replay.observedState = "active"
                manager.handleMessage(replay)
                XCTAssertEqual(session.status, oldStatus, "\(type)")
                XCTAssertEqual(session.completedAt, completed)
                XCTAssertEqual(session.observationEndedAt, observationEnded)
            }
        }
    }

    func testContextCompactionIsFreshWorkAndRefreshesCheckpoint() throws {
        for oldStatus in terminalStates {
            let (manager, session, store) = try context(status: oldStatus)
            manager.handleMessage(message(.contextCompact))
            try assertResumed(session, store: store, status: .compacting)
        }
    }

    func testRealSessionEndThenNewPromptClearsThePersistedCompletionTime() throws {
        let (manager, session, store) = try context(status: .completionUnconfirmed)
        var end = message(.sessionEnd)
        end.observedState = "completed"
        manager.handleMessage(end)
        XCTAssertNotNil(manager.persistenceManager?.fetchHistory().first?.completedAt)
        var prompt = message(.sessionStart)
        prompt.prompt = "New work after SessionEnd"
        manager.handleMessage(prompt)
        try assertResumed(session, store: store)
    }

    func testExpiredObservationRequiresFreshStateToClearItsPersistedEndTime() throws {
        let store = try temporaryStore()
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(storeURL: store))
        var uptime: TimeInterval = 0
        let wall = Date(timeIntervalSinceNow: -3600)
        let manager = SessionManager(observationClock: { uptime }, observationWallClock: { wall })
        manager.persistenceManager = persistence
        var event = DIMessage(type: .sessionStart, sessionId: "")
        event.agentType = "roo_code"
        event.sourceNamespace = String(repeating: "a", count: 24)
        event.sourceInstanceId = "00000000-0000-4000-8000-000000000001"
        event.nativeTaskId = "resume"
        event.observationSequence = 1
        event.timestamp = wall
        event.sessionId = try XCTUnwrap(ObservationSource(message: event)).sessionID(task: "resume")
        manager.handleMessage(event)
        let session = try XCTUnwrap(manager.sessions.first)
        uptime = 31
        manager.cleanupStaleSessions()
        XCTAssertEqual(session.status, .observationUnavailable)
        XCTAssertNil(session.completedAt)
        XCTAssertEqual(persistence.fetchHistory().first?.observationEndedAt, wall)

        event.type = .statusUpdate
        event.statusIsAssistantReply = false
        event.status = "Late informational snapshot"
        event.observationSequence = 2
        manager.handleMessage(event)
        XCTAssertEqual(session.status, .observationUnavailable)
        XCTAssertEqual(session.observationEndedAt, wall)
        event.observedState = "active"
        event.nativeMessageReplay = true
        event.observationSequence = 3
        manager.handleMessage(event)
        XCTAssertEqual(session.status, .observationUnavailable)
        XCTAssertEqual(session.observationEndedAt, wall)
        event.nativeMessageReplay = false
        event.observationSequence = 4
        manager.handleMessage(event)
        try assertResumed(session, store: store)
    }
}
