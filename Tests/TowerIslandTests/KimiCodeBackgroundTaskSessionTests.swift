import DIShared
import SwiftData
import XCTest
@testable import XIsland

@MainActor
final class KimiCodeBackgroundTaskSessionTests: XCTestCase {
    func testParentStopKeepsRunningBackgroundAgentVisibleUntilItsOwnResult() throws {
        let manager = memoryManager()
        manager.handleMessage(turn())
        manager.handleMessage(start("task-a"))
        manager.handleMessage(stop())

        let session = try XCTUnwrap(manager.sessions.first)
        let event = try XCTUnwrap(session.events.first)
        XCTAssertEqual(session.status, .completionUnconfirmed)
        XCTAssertNil(session.completedAt)
        XCTAssertTrue(session.hasRunningSubagents)
        XCTAssertEqual(manager.trulyActiveSessions.map(\.id), [session.id])
        XCTAssertEqual(event.tool, "Subagent")
        XCTAssertNil(event.toolCallId)
        XCTAssertTrue(event.isRunning)

        manager.handleMessage(result("task-a", output: "Child finished"))

        XCTAssertEqual(session.events.count, 1)
        XCTAssertEqual(session.events[0].id, event.id)
        XCTAssertTrue(session.events[0].isComplete)
        XCTAssertEqual(session.events[0].result, "Child finished")
        XCTAssertFalse(session.hasRunningSubagents)
        XCTAssertTrue(manager.trulyActiveSessions.isEmpty)
        XCTAssertEqual(session.status, .completionUnconfirmed)
        XCTAssertNil(session.completedAt)
        let stored = try XCTUnwrap(manager.persistenceManager?.restoreSession(sessionId: session.id))
        XCTAssertEqual(stored.status, .completionUnconfirmed)
        XCTAssertEqual(stored.events.count, 1)
        XCTAssertTrue(stored.events[0].isComplete)
    }

    func testParallelTasksAndEqualTaskIDsInDifferentSessionsStayIndependent() throws {
        let manager = memoryManager()
        let firstID = "kimi_code-first", secondID = "kimi_code-second"
        manager.handleMessage(turn(sessionID: firstID))
        manager.handleMessage(turn(sessionID: secondID))
        manager.handleMessage(start("shared", sessionID: firstID))
        manager.handleMessage(start("other", sessionID: firstID))
        manager.handleMessage(start("shared", sessionID: secondID))
        manager.handleMessage(stop(sessionID: firstID))
        manager.handleMessage(stop(sessionID: secondID))
        let first = try XCTUnwrap(manager.sessions.first { $0.id == firstID })
        let second = try XCTUnwrap(manager.sessions.first { $0.id == secondID })
        let firstShared = try XCTUnwrap(first.events.first { $0.input == "Task shared" })
        let firstOther = try XCTUnwrap(first.events.first { $0.input == "Task other" })
        let secondShared = try XCTUnwrap(second.events.first)
        XCTAssertEqual(Set([firstShared.id, firstOther.id, secondShared.id]).count, 3)

        manager.handleMessage(result("shared", output: "Only first shared finished", sessionID: firstID))

        XCTAssertTrue(try XCTUnwrap(first.events.first { $0.id == firstShared.id }).isComplete)
        XCTAssertTrue(try XCTUnwrap(first.events.first { $0.id == firstOther.id }).isRunning)
        XCTAssertTrue(second.events[0].isRunning)
        XCTAssertNil(second.events[0].result)
        XCTAssertEqual(Set(manager.trulyActiveSessions.map(\.id)), [firstID, secondID])
        manager.handleMessage(result("other", sessionID: firstID))
        XCTAssertFalse(first.hasRunningSubagents)
        XCTAssertEqual(manager.trulyActiveSessions.map(\.id), [secondID])
    }

    func testBackgroundResultClearsItsToolIndicatorWhileParentCanContinue() throws {
        let manager = memoryManager()
        manager.handleMessage(turn())
        var launch = message("PreToolUse", type: .toolStart)
        launch.tool = "Agent"
        launch.toolCallId = "launch"
        manager.handleMessage(launch)
        manager.handleMessage(start("child"))
        var returned = message("PostToolUse", type: .toolComplete)
        returned.tool = "Agent"
        returned.toolCallId = "launch"
        manager.handleMessage(returned)
        XCTAssertEqual(manager.sessions.first?.currentTool, "Subagent")
        manager.handleMessage(result("child"))
        XCTAssertNil(manager.sessions.first?.currentTool)
        XCTAssertEqual(manager.sessions.first?.status, .active)
    }

    func testTerminalBeforeStartAndDuplicateDeliveryNeverRecreateRunningWork() throws {
        let manager = memoryManager()
        manager.handleMessage(turn())
        manager.handleMessage(stop())
        manager.handleMessage(result("reordered", output: "Already finished"))
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertFalse(session.hasRunningSubagents)
        manager.handleMessage(start("reordered"))
        let completed = try XCTUnwrap(session.events.first)
        XCTAssertTrue(completed.isComplete)
        XCTAssertEqual(completed.result, "Already finished")
        XCTAssertNil(completed.toolCallId)

        manager.handleMessage(start("reordered"))
        manager.handleMessage(result("reordered", output: "Already finished"))

        XCTAssertEqual(session.events.count, 1)
        XCTAssertEqual(session.events[0].id, completed.id)
        XCTAssertTrue(session.events[0].isComplete)
        XCTAssertFalse(session.hasRunningSubagents)
        XCTAssertTrue(manager.trulyActiveSessions.isEmpty)
        XCTAssertEqual(session.status, .completionUnconfirmed)
    }

    func testFailureTimeoutAndKillKeepTheirOwnResultWithoutCompletingTheSession() throws {
        for status in ["failed", "timed_out", "killed"] {
            let manager = memoryManager()
            manager.handleMessage(turn())
            manager.handleMessage(start("terminal"))
            manager.handleMessage(stop())
            let output = "Native task.\(status): exact diagnostic"
            manager.handleMessage(result("terminal", status: status, output: output))
            let session = try XCTUnwrap(manager.sessions.first)
            let event = try XCTUnwrap(session.events.first)
            XCTAssertTrue(event.isComplete, status)
            XCTAssertFalse(event.isRunning, status)
            XCTAssertFalse(event.completionUnconfirmed, status)
            XCTAssertEqual(event.result, output, status)
            let taskStatus = session.kimiCodeApprovalObservation?.backgroundTaskStatuses(sessionID: session.id)[event.id]
            XCTAssertEqual(taskStatus, status)
            XCTAssertTrue(KimiCodeApprovalObservation.isFailedBackgroundTask(taskStatus))
            XCTAssertEqual(AgentActivityView(event: event, nativeTaskStatus: taskStatus).completionSymbol, "xmark.circle")
            XCTAssertFalse(session.hasRunningSubagents, status)
            XCTAssertNotEqual(session.status, .completed, status)
            XCTAssertNil(session.completedAt, status)
            let restored = try XCTUnwrap(manager.persistenceManager?.restoreSession(sessionId: session.id))
            XCTAssertEqual(restored.events.first?.result, output, status)
        }
    }

    func testLostAndUnconfirmedAreUnknownOutcomesRatherThanSuccessfulOrRunningTasks() throws {
        for status in ["lost", "unconfirmed"] {
            let manager = memoryManager()
            manager.handleMessage(turn())
            manager.handleMessage(start("uncertain"))
            manager.handleMessage(stop())
            manager.handleMessage(result("uncertain", status: status, output: "Native \(status)"))
            let session = try XCTUnwrap(manager.sessions.first)
            let event = try XCTUnwrap(session.events.first)
            XCTAssertFalse(event.isComplete, status)
            XCTAssertTrue(event.completionUnconfirmed, status)
            XCTAssertFalse(event.isRunning, status)
            XCTAssertEqual(event.result, "Native \(status)", status)
            XCTAssertEqual(session.status, .completionUnconfirmed, status)
            XCTAssertFalse(session.hasRunningSubagents, status)
            XCTAssertTrue(manager.trulyActiveSessions.isEmpty, status)
            let restored = try XCTUnwrap(manager.persistenceManager?.restoreSession(sessionId: session.id))
            XCTAssertFalse(try XCTUnwrap(restored.events.first).isComplete, status)
            XCTAssertTrue(try XCTUnwrap(restored.events.first).completionUnconfirmed, status)
        }
    }

    func testModelToolAndNativeTaskWithTheSameIdentifierCannotFinishEachOther() throws {
        for modelFinishesFirst in [false, true] {
            let manager = memoryManager()
            manager.handleMessage(turn())
            var modelStart = message("PreToolUse", type: .toolStart)
            modelStart.tool = "Read"
            modelStart.toolCallId = "shared"
            modelStart.toolInput = "/tmp/read-probe.txt"
            manager.handleMessage(modelStart)
            manager.handleMessage(start("shared"))
            let session = try XCTUnwrap(manager.sessions.first)
            let taskID = try XCTUnwrap(session.events.first { $0.tool == "Subagent" }).id
            var modelEnd = message("PostToolUse", type: .toolComplete)
            modelEnd.tool = "Read"
            modelEnd.toolCallId = "shared"
            modelEnd.toolResult = "Read contents"

            if modelFinishesFirst {
                manager.handleMessage(modelEnd)
                XCTAssertTrue(try XCTUnwrap(session.events.first { $0.tool == "Subagent" }).isRunning)
                manager.handleMessage(result("shared", output: "Agent contents"))
            } else {
                manager.handleMessage(result("shared", output: "Agent contents"))
                XCTAssertTrue(try XCTUnwrap(session.events.first { $0.tool == "Read" }).isRunning)
                manager.handleMessage(modelEnd)
            }
            manager.handleMessage(start("shared"))
            let task = try XCTUnwrap(session.events.first { $0.tool == "Subagent" })
            let model = try XCTUnwrap(session.events.first { $0.tool == "Read" })
            XCTAssertEqual(session.events.count, 2)
            XCTAssertEqual(task.id, taskID)
            XCTAssertNil(task.toolCallId)
            XCTAssertEqual(task.result, "Agent contents")
            XCTAssertEqual(model.toolCallId, "shared")
            XCTAssertEqual(model.result, "Read contents")
            XCTAssertTrue(task.isComplete)
            XCTAssertTrue(model.isComplete)
        }
    }

    func testSessionEndMarksUnfinishedTaskUnknownAndLateResultOnlyUpdatesHistory() throws {
        let (manager, store) = try diskManager()
        manager.handleMessage(turn())
        manager.handleMessage(start("running-at-close"))
        let session = try XCTUnwrap(manager.sessions.first)
        let eventID = try XCTUnwrap(session.events.first).id
        manager.handleMessage(end())
        let completedAt = try XCTUnwrap(session.completedAt)
        XCTAssertEqual(session.status, .completed)
        XCTAssertFalse(session.events[0].isComplete)
        XCTAssertTrue(session.events[0].completionUnconfirmed)
        XCTAssertFalse(session.hasRunningSubagents)

        manager.dismissSession(session)
        let restarted = reopened(store)
        restarted.handleMessage(result("running-at-close", output: "Arrived after session close"))
        restarted.handleMessage(start("running-at-close"))
        XCTAssertTrue(restarted.sessions.isEmpty)
        let history = try XCTUnwrap(restarted.persistenceManager?.restoreSession(sessionId: session.id))
        XCTAssertEqual(history.status, .completed)
        XCTAssertEqual(history.completedAt, completedAt)
        XCTAssertEqual(history.events.count, 1)
        XCTAssertEqual(history.events[0].id, eventID)
        XCTAssertTrue(history.events[0].isComplete)
        XCTAssertFalse(history.events[0].completionUnconfirmed)
        XCTAssertEqual(history.events[0].result, "Arrived after session close")

        restarted.handleMessage(turn())
        let resumed = try XCTUnwrap(restarted.sessions.first)
        XCTAssertEqual(resumed.status, .active)
        XCTAssertEqual(resumed.events.count, 1)
        XCTAssertEqual(resumed.events[0].id, eventID)
        XCTAssertTrue(resumed.events[0].isComplete)
        XCTAssertFalse(resumed.hasRunningSubagents)
    }

    func testOrphanTerminalSurvivesRestartAndLateStartWithoutCreatingASessionShell() throws {
        let (manager, store) = try diskManager()
        manager.handleMessage(result("orphan", output: "Terminal received first"))
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertEqual(manager.persistenceManager?.totalCount(), 0)
        XCTAssertNotNil(try manager.persistenceManager?.kimiCodeApprovalOrphan(sessionId: "kimi_code-session"))

        let restarted = reopened(store)
        restarted.handleMessage(start("orphan"))
        XCTAssertTrue(restarted.sessions.isEmpty)
        XCTAssertTrue(restarted.trulyActiveSessions.isEmpty)
        XCTAssertEqual(restarted.persistenceManager?.totalCount(), 0)

        restarted.handleMessage(turn())
        let session = try XCTUnwrap(restarted.sessions.first)
        let event = try XCTUnwrap(session.events.first)
        XCTAssertEqual(session.status, .active)
        XCTAssertEqual(session.events.count, 1)
        XCTAssertEqual(event.tool, "Subagent")
        XCTAssertNil(event.toolCallId)
        XCTAssertTrue(event.isComplete)
        XCTAssertEqual(event.result, "Terminal received first")
        XCTAssertFalse(session.hasRunningSubagents)
        XCTAssertNil(try restarted.persistenceManager?.kimiCodeApprovalOrphan(sessionId: session.id))
        let history = try XCTUnwrap(restarted.persistenceManager?.restoreSession(sessionId: session.id))
        XCTAssertEqual(history.events.first?.id, event.id)
        XCTAssertTrue(try XCTUnwrap(history.events.first).isComplete)
    }

    func testNonAgentBackgroundKindsNeverBecomeSubagents() throws {
        let manager = memoryManager()
        manager.handleMessage(turn())
        for kind in ["process", "question"] {
            manager.handleMessage(start(kind, kind: kind))
            manager.handleMessage(result(kind))
        }
        manager.handleMessage(stop())
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertFalse(session.events.contains { $0.tool == "Subagent" })
        XCTAssertFalse(session.hasRunningSubagents)
        XCTAssertTrue(manager.trulyActiveSessions.isEmpty)
        XCTAssertEqual(session.status, .completionUnconfirmed)
    }

    func testHiddenTerminalSaveFailureRetriesWithoutReopeningHistory() throws {
        let (initial, store) = try diskManager()
        initial.handleMessage(turn())
        initial.handleMessage(start("retry"))
        initial.handleMessage(stop())
        let eventID = try XCTUnwrap(initial.sessions.first?.events.first?.id)
        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self, StoredKimiCodeApprovalOrphan.self])
        let readOnly = ModelConfiguration(schema: schema, url: store, allowsSave: false, cloudKitDatabase: .none)
        let unavailable = SessionPersistenceManager()
        unavailable.modelContainer = try ModelContainer(for: schema, configurations: [readOnly])
        let manager = SessionManager()
        manager.persistenceManager = unavailable
        manager.handleMessage(result("retry", output: "Durable native completion"))
        XCTAssertNotNil(unavailable.lastSaveError)
        XCTAssertTrue(manager.sessions.isEmpty)

        let writable = try XCTUnwrap(reopened(store).persistenceManager)
        XCTAssertFalse(try XCTUnwrap(writable.restoreSession(sessionId: "kimi_code-session")?.events.first).isComplete)
        manager.persistenceManager = writable
        manager.retryPendingHistorySaves()
        let restored = try XCTUnwrap(writable.restoreSession(sessionId: "kimi_code-session"))
        XCTAssertEqual(restored.events.first?.id, eventID)
        XCTAssertTrue(restored.events.first?.isComplete == true)
        XCTAssertEqual(restored.events.first?.result, "Durable native completion")
        XCTAssertTrue(manager.sessions.isEmpty)
        manager.handleMessage(start("retry"))
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    func testFreshActivityAfterDeletedHistoryDoesNotRestoreFailedSaveCache() throws {
        let (initial, store) = try diskManager()
        initial.handleMessage(turn())
        initial.handleMessage(start("deleted"))
        initial.handleMessage(stop())
        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self, StoredKimiCodeApprovalOrphan.self])
        let unavailable = SessionPersistenceManager()
        unavailable.modelContainer = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: store, allowsSave: false, cloudKitDatabase: .none)])
        let manager = SessionManager()
        manager.persistenceManager = unavailable
        manager.handleMessage(result("deleted"))
        XCTAssertNotNil(unavailable.lastSaveError)
        let writable = try XCTUnwrap(reopened(store).persistenceManager)
        let context = ModelContext(try XCTUnwrap(writable.modelContainer))
        for record in try context.fetch(FetchDescriptor<StoredSession>()) { context.delete(record) }
        try context.save()
        manager.persistenceManager = writable
        manager.handleMessage(turn())
        let fresh = try XCTUnwrap(manager.sessions.first)
        XCTAssertTrue(fresh.events.isEmpty)
        XCTAssertTrue(fresh.kimiCodeApprovalObservation?.backgroundTasks?.isEmpty ?? true)
        manager.retryPendingHistorySaves()
        XCTAssertTrue(try XCTUnwrap(writable.restoreSession(sessionId: fresh.id)).events.isEmpty)
    }

    func testLegacyApprovalJSONWithoutBackgroundTasksStillRestores() throws {
        let legacy = Data("""
        {"pending":{},"resolved":{},"hasUnidentifiedRequest":false,"wasInterrupted":false,
         "baseStatus":"completionUnconfirmed","baseStatusText":"Legacy observation"}
        """.utf8)
        let observation = try KimiCodeApprovalObservation.decode(legacy)
        XCTAssertEqual(observation.baseStatus, .completionUnconfirmed)
        XCTAssertEqual(observation.baseStatusText, "Legacy observation")
        XCTAssertFalse(observation.hasPendingApproval)
        let persistence = try XCTUnwrap(memoryManager().persistenceManager)
        let session = AgentSession(id: "kimi_code-legacy-json", agentType: .kimi)
        session.status = .completionUnconfirmed
        XCTAssertTrue(persistence.save(session: session))
        let context = ModelContext(try XCTUnwrap(persistence.modelContainer))
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<StoredSession>()).first)
        stored.kimiCodeApprovalObservationData = legacy
        try context.save()
        let restored = try XCTUnwrap(persistence.restoreSession(sessionId: session.id))
        XCTAssertEqual(restored.status, .completionUnconfirmed)
        XCTAssertFalse(restored.hasRunningSubagents)
        XCTAssertTrue(restored.events.isEmpty)
    }

    func testBackgroundFactsMergePreservesKindAndDefiniteOutcome() throws {
        var state = KimiCodeApprovalObservation(baseStatus: .active)
        state.observeBackgroundTask(DINativeBackgroundTask(id: "task", kind: "process", status: "running", description: "Original"))
        state.observeBackgroundTask(DINativeBackgroundTask(id: "task", kind: "agent", status: "completed", result: "Wrong kind"))
        XCTAssertEqual(state.backgroundTasks?["task"]?.kind, "process")
        XCTAssertEqual(state.backgroundTasks?["task"]?.status, "running")
        state.markBackgroundTasksUnconfirmed()
        XCTAssertEqual(state.backgroundTasks?["task"]?.status, "unconfirmed")
        var result = KimiCodeApprovalObservation()
        result.observeBackgroundTask(DINativeBackgroundTask(id: "task", status: "completed", result: "Native result"))
        state.merge(result)
        state.observeBackgroundTask(DINativeBackgroundTask(id: "task", kind: "process", status: "running", description: "Replay"))
        state.endSession()
        XCTAssertEqual(state.backgroundTasks?["task"]?.description, "Original")
        XCTAssertEqual(state.backgroundTasks?["task"]?.status, "completed")
        XCTAssertEqual(state.backgroundTasks?["task"]?.result, "Native result")
        XCTAssertEqual(try KimiCodeApprovalObservation.decode(JSONEncoder().encode(state)), state)
    }

    func testInvalidStoredTaskFactsAreRejectedRatherThanDropped() throws {
        var state = KimiCodeApprovalObservation()
        state.observeBackgroundTask(DINativeBackgroundTask(id: "task", kind: "agent", status: "running"))
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        for (field, value) in [("id", "other" as Any), ("kind", "unknown"), ("status", "unknown"),
                               ("startedAtMilliseconds", -1), ("result", "invalid\0text")] {
            var object = valid
            var task = try XCTUnwrap((object["backgroundTasks"] as? [String: [String: Any]])?["task"])
            task[field] = value
            object["backgroundTasks"] = ["task": task]
            XCTAssertThrowsError(try KimiCodeApprovalObservation.decode(JSONSerialization.data(withJSONObject: object)), field)
        }
        state.observeBackgroundTask(DINativeBackgroundTask(id: "bad\nidentity", kind: "agent", status: "running"))
        XCTAssertEqual(state.backgroundTasks?.count, 1)
    }

    private func message(_ event: String, type: DIMessageType = .statusUpdate,
                         sessionID: String = "kimi_code-session") -> DIMessage {
        var value = DIMessage(type: type, sessionId: sessionID)
        value.agentType = "kimi"
        value.nativeEvent = "kimi_code." + event
        value.statusIsAssistantReply = false
        return value
    }

    private func start(_ id: String, kind: String = "agent", sessionID: String = "kimi_code-session") -> DIMessage {
        var value = message("TaskStarted", sessionID: sessionID)
        value.nativeBackgroundTask = DINativeBackgroundTask(id: id, kind: kind, status: "running",
            description: "Task " + id, startedAtMilliseconds: 1_791_886_744_559)
        return value
    }

    private func result(_ id: String, status: String = "completed", output: String = "Finished",
                        sessionID: String = "kimi_code-session") -> DIMessage {
        var value = message("Notification", sessionID: sessionID)
        value.nativeBackgroundTask = DINativeBackgroundTask(id: id, status: status, result: output)
        return value
    }

    private func turn(sessionID: String = "kimi_code-session") -> DIMessage {
        var value = message("TurnStarted", sessionID: sessionID)
        value.observedState = "active"
        value.nativeTurnId = "1"
        return value
    }

    private func stop(sessionID: String = "kimi_code-session") -> DIMessage {
        var value = message("Stop", sessionID: sessionID)
        value.observedState = "completionUnconfirmed"
        return value
    }

    private func end() -> DIMessage {
        var value = message("SessionEnd", type: .sessionEnd)
        value.observedState = "completed"
        return value
    }

    private func memoryManager() -> SessionManager {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        return manager
    }

    private func diskManager() throws -> (SessionManager, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xi-kimi-tasks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("history.store")
        return (reopened(store), store)
    }

    private func reopened(_ store: URL) -> SessionManager {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(storeURL: store))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        return manager
    }
}
