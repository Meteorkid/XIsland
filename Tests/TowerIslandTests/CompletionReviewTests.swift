import DIShared
import SwiftData
import XCTest
@testable import XIsland

@MainActor
final class CompletionReviewTests: XCTestCase {
    private func context(backgroundWrites: Bool = false) throws -> (SessionManager, SessionPersistenceManager, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-completion-review-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("history.store")
        let persistence = SessionPersistenceManager(usesBackgroundWrites: backgroundWrites)
        XCTAssertTrue(persistence.setupContainer(storeURL: store), persistence.lastSaveError ?? "")
        let manager = SessionManager()
        manager.persistenceManager = persistence
        return (manager, persistence, store)
    }

    private func message(_ type: DIMessageType, id: String = "codex-review", agent: AgentType = .codex) -> DIMessage {
        var value = DIMessage(type: type, sessionId: id)
        value.agentType = agent.rawValue
        value.statusIsAssistantReply = false
        if type == .sessionEnd { value.observedState = "completed" }
        return value
    }

    func testNewAndLegacyRecordsDoNotInventAReviewState() throws {
        let (_, persistence, _) = try context()
        let fresh = AgentSession(id: "fresh", agentType: .codex)
        XCTAssertFalse(fresh.completionNeedsReview)
        XCTAssertFalse(SessionSaveSnapshot(session: fresh).completionNeedsReview)
        XCTAssertEqual(StoredSession(from: fresh).completionNeedsReview, false)

        let legacy = StoredSession(sessionId: "legacy", agentTypeRaw: "codex", startTime: Date(),
            completedAt: Date(), prompt: "Legacy result", workingDirectory: "", terminal: "",
            statusRaw: SessionStatus.completed.rawValue)
        XCTAssertNil(legacy.completionNeedsReview)
        XCTAssertFalse(HistorySessionRow(legacy).completionNeedsReview)
        let container = try XCTUnwrap(persistence.modelContainer)
        container.mainContext.insert(legacy)
        try container.mainContext.save()

        let restored = try XCTUnwrap(persistence.restoreSession(sessionId: legacy.sessionId))
        XCTAssertEqual(restored.status, .completed)
        XCTAssertFalse(restored.completionNeedsReview)
        XCTAssertNil(persistence.fetchHistory().first?.completionNeedsReview)
    }

    func testHistoryReviewIndicatorRequiresAConfirmedCompletedStatus() {
        let stored = StoredSession(sessionId: "review-indicator", agentTypeRaw: "codex", startTime: Date(),
            completedAt: Date(), prompt: "Result", workingDirectory: "", terminal: "",
            statusRaw: SessionStatus.completed.rawValue)
        stored.completionNeedsReview = true
        XCTAssertTrue(HistorySessionRow(stored).completionNeedsReview)
        for status in [SessionStatus.active, .idle, .completionUnconfirmed, .observationUnavailable] {
            stored.statusRaw = status.rawValue
            XCTAssertFalse(HistorySessionRow(stored).completionNeedsReview, status.rawValue)
            XCTAssertEqual(stored.completionNeedsReview, true)
        }
        stored.statusRaw = "future-status"
        XCTAssertFalse(HistorySessionRow(stored).completionNeedsReview)
    }

    func testCompletionAndReviewSurviveDiskReopenWithoutDuplicateReminders() throws {
        let (manager, persistence, store) = try context()
        manager.handleMessage(message(.sessionStart))
        manager.handleMessage(message(.sessionEnd))
        let session = try XCTUnwrap(manager.sessions.first)
        let completedAt = try XCTUnwrap(session.completedAt)
        XCTAssertTrue(session.completionNeedsReview)
        XCTAssertTrue(try XCTUnwrap(persistence.restoreSession(sessionId: session.id)).completionNeedsReview)
        XCTAssertTrue(HistorySessionRow(try XCTUnwrap(persistence.fetchHistory().first)).completionNeedsReview)

        manager.markCompletionReviewed(sessionID: session.id)
        XCTAssertFalse(session.completionNeedsReview)
        manager.handleMessage(message(.sessionEnd))
        var replay = message(.sessionEnd)
        replay.nativeMessageReplay = true
        manager.handleMessage(replay)
        XCTAssertEqual(session.completedAt, completedAt)
        XCTAssertFalse(session.completionNeedsReview)

        let reopened = SessionPersistenceManager()
        XCTAssertTrue(reopened.setupContainer(storeURL: store), reopened.lastSaveError ?? "")
        let restored = try XCTUnwrap(reopened.restoreSession(sessionId: session.id))
        XCTAssertEqual(restored.status, .completed)
        XCTAssertEqual(restored.completedAt, completedAt)
        XCTAssertFalse(restored.completionNeedsReview)
        XCTAssertEqual(reopened.fetchHistory().first?.completionNeedsReview, false)
    }

    func testNewRunClearsOldReviewStateAndItsCompletionNeedsReviewAgain() throws {
        for reviewed in [false, true] {
            let (manager, persistence, _) = try context()
            manager.handleMessage(message(.sessionStart))
            manager.handleMessage(message(.sessionEnd))
            let session = try XCTUnwrap(manager.sessions.first)
            if reviewed { manager.markCompletionReviewed(sessionID: session.id) }

            var resume = message(.sessionStart)
            resume.prompt = "Next run"
            resume.nativeMessageId = "next-prompt"
            manager.handleMessage(resume)
            XCTAssertEqual(session.status, .active)
            XCTAssertNil(session.completedAt)
            XCTAssertFalse(session.completionNeedsReview)
            XCTAssertFalse(try XCTUnwrap(persistence.restoreSession(sessionId: session.id)).completionNeedsReview)

            manager.handleMessage(message(.sessionEnd))
            XCTAssertEqual(session.status, .completed)
            XCTAssertTrue(session.completionNeedsReview)
            XCTAssertTrue(try XCTUnwrap(persistence.restoreSession(sessionId: session.id)).completionNeedsReview)
        }
    }

    func testIdleUnconfirmedReplayedEndAndObservationLossDoNotCreateCompletion() throws {
        for state in [SessionStatus.idle, .completionUnconfirmed] {
            let (manager, _, _) = try context()
            manager.handleMessage(message(.sessionStart))
            let session = try XCTUnwrap(manager.sessions.first)
            var status = message(.statusUpdate)
            status.observedState = state.rawValue
            manager.handleMessage(status)
            var replay = message(.sessionEnd)
            replay.nativeMessageReplay = true
            manager.handleMessage(replay)
            XCTAssertEqual(session.status, state)
            XCTAssertNil(session.completedAt)
            XCTAssertFalse(session.completionNeedsReview)
        }

        let (manager, _, _) = try context()
        manager.handleMessage(message(.sessionStart, id: "claude_code-review", agent: .claudeCode))
        manager.checkProcessesAlive { _ in false }
        let interrupted = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(interrupted.status, .observationUnavailable)
        XCTAssertNil(interrupted.completedAt)
        XCTAssertFalse(interrupted.completionNeedsReview)
    }

    func testReviewRequiresCompletedSessionWithoutPendingInteraction() throws {
        let (manager, persistence, _) = try context()
        manager.handleMessage(message(.sessionStart))
        manager.handleMessage(message(.sessionEnd))
        let session = try XCTUnwrap(manager.sessions.first)
        session.pendingPermission = PendingPermission(requestingAgent: .codex, tool: "Bash",
            description: "Pending decision", diff: nil, filePath: nil, respond: { _ in })
        manager.markCompletionReviewed(sessionID: session.id)
        XCTAssertTrue(session.completionNeedsReview)
        XCTAssertEqual(persistence.fetchHistory().first?.completionNeedsReview, true)
        session.pendingPermission = nil
        for state in [SessionStatus.active, .idle, .completionUnconfirmed, .observationUnavailable] {
            session.status = state
            manager.markCompletionReviewed(sessionID: session.id)
            XCTAssertTrue(session.completionNeedsReview, state.rawValue)
        }
        manager.markCompletionReviewed(sessionID: "missing")
        XCTAssertTrue(session.completionNeedsReview)
        session.status = .completed
        manager.markCompletionReviewed(sessionID: session.id)
        XCTAssertFalse(session.completionNeedsReview)
    }

    func testArchivedKimiCompletionCreatesOnlyOneReviewReminder() throws {
        let (manager, persistence, _) = try context()
        let session = AgentSession(id: "kimi_code-archived-review", agentType: .kimi)
        session.status = .idle
        XCTAssertTrue(persistence.save(session: session))
        var end = message(.sessionEnd, id: session.id, agent: .kimi)
        end.nativeEvent = "kimi_code.SessionEnd"
        manager.handleMessage(end)
        XCTAssertTrue(manager.sessions.isEmpty)
        let restored = try XCTUnwrap(persistence.restoreSession(sessionId: session.id))
        XCTAssertEqual(restored.status, .completed)
        XCTAssertTrue(restored.completionNeedsReview)

        manager.sessions = [restored]
        manager.markCompletionReviewed(sessionID: restored.id)
        manager.dismissSession(restored)
        manager.handleMessage(end)
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertFalse(try XCTUnwrap(persistence.restoreSession(sessionId: session.id)).completionNeedsReview)
    }

    func testQueuedReviewOfOldResultCannotAcknowledgeNewCompletion() async throws {
        let (manager, persistence, _) = try context(backgroundWrites: true)
        manager.handleMessage(message(.sessionStart))
        manager.handleMessage(message(.sessionEnd))
        let initialSaved = await manager.drainPersistenceOperations()
        XCTAssertTrue(initialSaved)
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertTrue(session.completionNeedsReview)

        manager.handleMessage(message(.sessionStart))
        manager.handleMessage(message(.sessionEnd))
        manager.markCompletionReviewed(sessionID: session.id)
        let nextSaved = await manager.drainPersistenceOperations()
        XCTAssertTrue(nextSaved)
        XCTAssertTrue(session.completionNeedsReview)
        XCTAssertTrue(try XCTUnwrap(persistence.restoreSession(sessionId: session.id)).completionNeedsReview)

        manager.markCompletionReviewed(sessionID: session.id)
        let reviewedSaved = await manager.drainPersistenceOperations()
        XCTAssertTrue(reviewedSaved)
        XCTAssertFalse(session.completionNeedsReview)
        XCTAssertFalse(try XCTUnwrap(persistence.restoreSession(sessionId: session.id)).completionNeedsReview)
    }

    func testPersistedOrphanCompletionProjectsAReviewReminder() throws {
        let (_, persistence, _) = try context()
        let session = AgentSession(id: "kimi_code-orphan-review", agentType: .kimi)
        var ended = KimiCodeApprovalObservation(baseStatus: .idle)
        ended.endSession()
        let container = try XCTUnwrap(persistence.modelContainer)
        container.mainContext.insert(StoredKimiCodeApprovalOrphan(sessionId: session.id,
            observationData: try JSONEncoder().encode(ended)))
        try container.mainContext.save()

        XCTAssertTrue(persistence.save(session: session))
        XCTAssertEqual(session.status, .completed)
        XCTAssertTrue(session.completionNeedsReview)
        XCTAssertTrue(try XCTUnwrap(persistence.restoreSession(sessionId: session.id)).completionNeedsReview)
    }

    func testArchivedReviewOnlyChangesMatchingRowAndPreservesItsChildren() async throws {
        let (manager, persistence, store) = try context()
        let completedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let target = AgentSession(id: "archived-target", agentType: .codex, prompt: "Keep this prompt")
        target.status = .completed
        target.completedAt = completedAt
        target.completionNeedsReview = true
        target.events = [ToolEvent(tool: "Read", result: "Keep this tool result", isComplete: true)]
        target.chatHistory = [ChatMessage(timestamp: completedAt, role: .assistant, content: "Keep this answer")]
        target.tokenUsage.totalTokens = 37
        let other = AgentSession(id: "archived-other", agentType: .codex)
        other.status = .completed
        other.completedAt = completedAt
        other.completionNeedsReview = true
        XCTAssertTrue(persistence.save(session: target))
        XCTAssertTrue(persistence.save(session: other))
        XCTAssertTrue(manager.sessions.isEmpty)
        let page = try await persistence.readHistoryPageAsync()
        let row = try XCTUnwrap(page.sessions.first { $0.sessionId == target.id })

        try await persistence.markHistoryCompletionReviewedAsync(sessionID: row.sessionId, completedAt: row.completedAt)
        let revision = persistence.revision
        try await persistence.markHistoryCompletionReviewedAsync(sessionID: row.sessionId, completedAt: row.completedAt)
        XCTAssertEqual(persistence.revision, revision)
        XCTAssertTrue(manager.sessions.isEmpty)

        let reopened = SessionPersistenceManager()
        XCTAssertTrue(reopened.setupContainer(storeURL: store), reopened.lastSaveError ?? "")
        let restored = try XCTUnwrap(reopened.restoreSession(sessionId: target.id))
        XCTAssertFalse(restored.completionNeedsReview)
        XCTAssertEqual(restored.completedAt, completedAt)
        XCTAssertEqual(restored.prompt, target.prompt)
        XCTAssertEqual(restored.tokenUsage.totalTokens, 37)
        XCTAssertEqual(restored.events.map(\.id), target.events.map(\.id))
        XCTAssertEqual(restored.events.map(\.result), target.events.map(\.result))
        XCTAssertEqual(restored.chatHistory, target.chatHistory)
        XCTAssertTrue(try XCTUnwrap(reopened.restoreSession(sessionId: other.id)).completionNeedsReview)
        XCTAssertEqual(reopened.totalCount(), 2)
    }

    func testArchivedReviewRejectsStaleCompletionAndNoncompletedRows() async throws {
        let (_, persistence, _) = try context()
        let session = AgentSession(id: "archived-new-result", agentType: .codex)
        session.status = .completed
        session.completedAt = Date(timeIntervalSince1970: 1_700_000_200)
        session.completionNeedsReview = true
        XCTAssertTrue(persistence.save(session: session))
        let revision = persistence.revision
        for staleDate in [nil, Date(timeIntervalSince1970: 1_700_000_100)] {
            try await persistence.markHistoryCompletionReviewedAsync(sessionID: session.id, completedAt: staleDate)
            XCTAssertTrue(try XCTUnwrap(persistence.restoreSession(sessionId: session.id)).completionNeedsReview)
        }
        try await persistence.markHistoryCompletionReviewedAsync(sessionID: "missing", completedAt: nil)
        XCTAssertEqual(persistence.revision, revision)

        for status in [SessionStatus.active, .idle, .completionUnconfirmed, .observationUnavailable] {
            session.status = status
            XCTAssertTrue(persistence.save(session: session))
            try await persistence.markHistoryCompletionReviewedAsync(sessionID: session.id, completedAt: session.completedAt)
            let restored = try XCTUnwrap(persistence.restoreSession(sessionId: session.id))
            XCTAssertEqual(restored.status, status)
            XCTAssertTrue(restored.completionNeedsReview)
        }
    }

    func testArchivedReviewPreservesLegacyNilButCanConfirmUndatedKnownCompletion() async throws {
        let (_, persistence, _) = try context()
        let container = try XCTUnwrap(persistence.modelContainer)
        let legacy = StoredSession(sessionId: "legacy-undated", agentTypeRaw: "codex", startTime: Date(),
            prompt: "Legacy result", workingDirectory: "", terminal: "", statusRaw: SessionStatus.completed.rawValue)
        let known = StoredSession(sessionId: "known-undated", agentTypeRaw: "codex", startTime: Date(),
            prompt: "Known result", workingDirectory: "", terminal: "", statusRaw: SessionStatus.completed.rawValue)
        known.completionNeedsReview = true
        container.mainContext.insert(legacy)
        container.mainContext.insert(known)
        try container.mainContext.save()

        try await persistence.markHistoryCompletionReviewedAsync(sessionID: legacy.sessionId, completedAt: nil)
        try await persistence.markHistoryCompletionReviewedAsync(sessionID: known.sessionId, completedAt: nil)

        let rows = persistence.fetchHistory()
        XCTAssertNil(try XCTUnwrap(rows.first { $0.sessionId == legacy.sessionId }).completionNeedsReview)
        XCTAssertEqual(try XCTUnwrap(rows.first { $0.sessionId == known.sessionId }).completionNeedsReview, false)
    }

    func testArchivedReviewPropagatesUnavailableStorageAndCancelledWrites() async throws {
        let unavailable = SessionPersistenceManager()
        do {
            try await unavailable.markHistoryCompletionReviewedAsync(sessionID: "missing", completedAt: nil)
            XCTFail("Unavailable history must throw")
        } catch {
            guard case HistoryReadError.storageUnavailable = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let (_, persistence, _) = try context()
        let session = AgentSession(id: "cancelled-review", agentType: .codex)
        session.status = .completed
        session.completedAt = Date()
        session.completionNeedsReview = true
        XCTAssertTrue(persistence.save(session: session))
        let task = Task { try await persistence.markHistoryCompletionReviewedAsync(sessionID: session.id, completedAt: session.completedAt) }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled review must not commit")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try XCTUnwrap(persistence.restoreSession(sessionId: session.id)).completionNeedsReview)
    }
}
