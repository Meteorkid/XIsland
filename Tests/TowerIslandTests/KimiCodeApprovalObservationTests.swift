import DIShared
import SwiftData
import XCTest
@testable import XIsland

@MainActor
final class KimiCodeApprovalObservationTests: XCTestCase {
    func testObservedPermissionDiagnosticsDoNotClaimLocalInteractionControls() throws {
        let manager = SessionManager()
        manager.handleMessage(permission("PermissionRequest", requestID: "approval-observed"))
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.status, .waitingPermission)
        XCTAssertNil(session.pendingPermission)
        XCTAssertFalse(session.hasPendingInteraction)
        let snapshot = AppDiagnosticsSnapshot.make(sessionManager: manager, updateManager: UpdateManager(),
            islandState: manager.diagnosticsIslandState)
        XCTAssertEqual(snapshot.islandState, "collapsed")
        XCTAssertNil(snapshot.pendingInteraction)
        XCTAssertEqual(snapshot.visibleSessions.first?.status, "waitingPermission")
        XCTAssertNil(snapshot.visibleSessions.first?.pendingInteraction)
        XCTAssertEqual(snapshot.visibleAccessibilityIdentifiers, [TestAccessibility.collapsedPill])
    }

    func testMissingApprovalMetadataDoesNotTurnLegacyOrWireHistoryIntoNodeState() throws {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        for id in ["kimi-legacy", "kimi-wire-connection-fixture", "kimi_code-node"] {
            let session = AgentSession(id: id, agentType: .kimi)
            session.status = .waitingPermission
            XCTAssertTrue(persistence.save(session: session))
            let restored = try XCTUnwrap(persistence.restoreSession(sessionId: id))
            if id.hasPrefix("kimi_code-") {
                XCTAssertEqual(restored.status, .completionUnconfirmed)
                XCTAssertTrue(restored.kimiCodeApprovalObservation?.hasUnidentifiedRequest == true)
            } else {
                XCTAssertEqual(restored.status, .waitingPermission)
                XCTAssertNil(restored.kimiCodeApprovalObservation)
            }
        }
    }

    func testEdgeUnknownSessionEndPersistsClosureBeforeOrAfterAnyResult() throws {
        for receivesResultFirst in [false, true] {
            let (manager, store) = try diskManager()
            if receivesResultFirst { manager.handleMessage(permission("PermissionResult", requestID: "approval-a")) }
            manager.handleMessage(end())
            XCTAssertTrue(manager.sessions.isEmpty)
            XCTAssertEqual(manager.persistenceManager?.totalCount(), 0)
            let facts = try manager.persistenceManager?.kimiCodeApprovalOrphan(sessionId: "kimi_code-session")
            XCTAssertEqual(facts?.baseStatus, .completed)
            manager.handleMessage(permission("PermissionRequest", requestID: "late-request"))
            XCTAssertTrue(manager.sessions.isEmpty)
            let restarted = reopened(store)
            restarted.handleMessage(permission("PermissionRequest", requestID: "another-late-request"))
            XCTAssertTrue(restarted.sessions.isEmpty)
            var resumed = message(receivesResultFirst ? "SessionStart" : "TurnStarted")
            resumed.observedState = receivesResultFirst ? "idle" : "active"
            restarted.handleMessage(resumed)
            XCTAssertEqual(restarted.sessions.first?.status, receivesResultFirst ? .idle : .active)
            if receivesResultFirst {
                restarted.handleMessage(permission("PermissionRequest", requestID: "approval-a"))
                XCTAssertEqual(restarted.sessions.first?.status, .idle)
            }
            restarted.handleMessage(permission("PermissionRequest", requestID: "fresh-request"))
            XCTAssertEqual(restarted.sessions.first?.status, .waitingPermission)
        }
    }

    func testEdgePersistedOrphanCannotReturnFromMemoryAfterRetentionCleanup() throws {
        let (manager, _) = try diskManager()
        manager.handleMessage(permission("PermissionResult", requestID: "approval-a"))
        let persistence = try XCTUnwrap(manager.persistenceManager)
        let context = ModelContext(try XCTUnwrap(persistence.modelContainer))
        let orphan = try XCTUnwrap(context.fetch(FetchDescriptor<StoredKimiCodeApprovalOrphan>()).first)
        orphan.updatedAt = Date(timeIntervalSinceNow: -40 * 86400)
        try context.save()
        persistence.cleanup(olderThanDays: 30)
        XCTAssertNil(try persistence.kimiCodeApprovalOrphan(sessionId: "kimi_code-session"))
        manager.handleMessage(permission("PermissionRequest", requestID: "approval-a"))
        XCTAssertEqual(manager.sessions.first?.status, .waitingPermission)
        XCTAssertEqual(manager.sessions.first?.kimiCodeApprovalObservation?.pending.count, 1)
    }

    func testEdgeClosedOrphanRejectsInformationalEventsAndUnstartedPrompts() throws {
        let (manager, _) = try diskManager()
        manager.handleMessage(end())
        var prompt = message("UserPromptSubmit", type: .sessionStart)
        prompt.prompt = "May be blocked by another hook"
        var stop = message("Stop")
        stop.observedState = "completionUnconfirmed"
        var interrupt = message("Interrupt")
        interrupt.observedState = "completionUnconfirmed"
        for passive in [message("Notification"), message("TaskStarted"), message("UserPromptQueued"),
                        message("SessionHeartbeat"), prompt, stop, interrupt, message("PostToolUse", type: .toolComplete)] {
            manager.handleMessage(passive)
            XCTAssertTrue(manager.sessions.isEmpty, passive.nativeEvent ?? "")
            XCTAssertEqual(manager.persistenceManager?.totalCount(), 0)
        }
    }

    func testEdgeFailedOrphanSaveRetriesAndSuccessReleasesMemoryCopy() throws {
        let (manager, store) = try diskManager()
        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self, StoredKimiCodeApprovalOrphan.self])
        let readOnly = ModelConfiguration(schema: schema, url: store, allowsSave: false)
        let unavailable = SessionPersistenceManager()
        unavailable.modelContainer = try ModelContainer(for: schema, configurations: [readOnly])
        manager.persistenceManager = unavailable
        manager.handleMessage(permission("PermissionResult", requestID: "approval-a"))
        XCTAssertNotNil(unavailable.lastSaveError)
        XCTAssertNil(try unavailable.kimiCodeApprovalOrphan(sessionId: "kimi_code-session"))
        let writable = try XCTUnwrap(reopened(store).persistenceManager)
        manager.persistenceManager = writable
        manager.retryPendingHistorySaves()
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertEqual(writable.totalCount(), 0)
        XCTAssertEqual(try writable.kimiCodeApprovalOrphan(sessionId: "kimi_code-session")?.resolved.count, 1)
        let context = ModelContext(try XCTUnwrap(writable.modelContainer))
        for orphan in try context.fetch(FetchDescriptor<StoredKimiCodeApprovalOrphan>()) { context.delete(orphan) }
        try context.save()
        manager.retryPendingHistorySaves()
        XCTAssertNil(try writable.kimiCodeApprovalOrphan(sessionId: "kimi_code-session"))
        manager.handleMessage(permission("PermissionRequest", requestID: "approval-a"))
        XCTAssertEqual(manager.sessions.first?.status, .waitingPermission)
    }

    func testIdentityLimitMatchesBridgeWithoutLosingValidLongRequestIDs() throws {
        let manager = SessionManager()
        let identifier = String(repeating: "a", count: 1024)
        manager.handleMessage(permission("PermissionRequest", requestID: identifier))
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertFalse(session.kimiCodeApprovalObservation?.hasUnidentifiedRequest == true)
        XCTAssertEqual(session.kimiCodeApprovalObservation?.pending.count, 1)
        manager.handleMessage(permission("PermissionResult", requestID: identifier))
        XCTAssertEqual(session.status, .idle)
        XCTAssertTrue(session.kimiCodeApprovalObservation?.pending.isEmpty == true)
    }

    func testConcurrentRequestsRequireTheirExactAgentTurnAndToolResult() throws {
        let manager = SessionManager()
        manager.handleMessage(permission("PermissionRequest", requestID: "approval-a"))
        manager.handleMessage(permission("PermissionRequest", requestID: "approval-b", agentID: "child"))
        let session = try XCTUnwrap(manager.sessions.first)
        for mismatch in [permission("PermissionResult", requestID: "approval-a", agentID: "other"),
                         permission("PermissionResult", requestID: "approval-a", turnID: "2"),
                         permission("PermissionResult", requestID: "approval-a", toolID: "other")] {
            manager.handleMessage(mismatch)
            XCTAssertEqual(session.kimiCodeApprovalObservation?.pending.count, 2)
        }
        manager.handleMessage(permission("PermissionResult", requestID: "approval-a"))
        manager.handleMessage(permission("PermissionResult", requestID: "approval-a"))
        XCTAssertEqual(session.kimiCodeApprovalObservation?.pending.count, 1)
        XCTAssertEqual(session.status, .waitingPermission)
        XCTAssertNil(session.pendingPermission)
        XCTAssertFalse(manager.hasInteraction)
        manager.handleMessage(permission("PermissionResult", requestID: "approval-b", agentID: "child"))
        XCTAssertEqual(session.kimiCodeApprovalObservation?.pending.count, 0)
        XCTAssertEqual(session.status, .idle)
    }

    func testOrdinaryActivityAndTurnStartedCannotClearObservedWaiting() throws {
        let manager = SessionManager()
        manager.handleMessage(permission("PermissionRequest", requestID: "approval-a"))
        let session = try XCTUnwrap(manager.sessions.first)
        var turn = message("TurnStarted")
        turn.observedState = "active"
        var tool = message("PreToolUse", type: .toolStart)
        tool.tool = "read_file"
        tool.toolCallId = "independent-tool"
        var complete = message("PostToolUse", type: .toolComplete)
        complete.tool = "read_file"
        complete.toolCallId = "independent-tool"
        var stop = message("Stop")
        stop.observedState = "completionUnconfirmed"
        for event in [turn, tool, complete, message("SessionHeartbeat"), message("Notification"), stop] {
            manager.handleMessage(event)
            XCTAssertEqual(session.status, .waitingPermission, event.nativeEvent ?? "")
            XCTAssertEqual(session.kimiCodeApprovalObservation?.pending.count, 1)
        }
        XCTAssertEqual(session.events.count, 1)
        XCTAssertTrue(session.events[0].isComplete)
        manager.handleMessage(permission("PermissionResult", requestID: "approval-a"))
        XCTAssertEqual(session.status, .completionUnconfirmed)
        XCTAssertFalse(try XCTUnwrap(session.kimiCodeApprovalObservation).hasPendingApproval)
    }

    func testCompactionWaitsForNativeReceiptWhileApprovalRemains() async throws {
        let manager = SessionManager()
        manager.handleMessage(permission("PermissionRequest", requestID: "approval-a"))
        let session = try XCTUnwrap(manager.sessions.first)
        manager.handleMessage(message("PreCompact", type: .contextCompact))
        XCTAssertEqual(session.status, .waitingPermission)
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertEqual(session.status, .waitingPermission)
        XCTAssertEqual(session.kimiCodeApprovalObservation?.baseStatus, .compacting)
        var finished = message("PostCompact")
        finished.observedState = "active"
        manager.handleMessage(finished)
        XCTAssertEqual(session.status, .waitingPermission)
        manager.handleMessage(permission("PermissionResult", requestID: "approval-a"))
        XCTAssertEqual(session.status, .active)
    }

    func testPromptSubmissionPreservesBaseStateAndSessionStartDoesNotClearLedger() throws {
        let manager = SessionManager()
        var connected = message("SessionStart")
        connected.observedState = "idle"
        manager.handleMessage(connected)
        var prompt = message("UserPromptSubmit", type: .sessionStart)
        prompt.prompt = "A user prompt"
        manager.handleMessage(prompt)
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.chatHistory.last?.content, "A user prompt")
        manager.handleMessage(permission("PermissionRequest", requestID: "approval-a"))
        manager.handleMessage(connected)
        manager.handleMessage(prompt)
        XCTAssertEqual(session.status, .waitingPermission)
        XCTAssertEqual(session.kimiCodeApprovalObservation?.pending.count, 1)
    }

    func testIncompleteRequestRemainsUnconfirmedAfterOtherRequestsResolve() throws {
        let manager = SessionManager()
        var incomplete = permission("PermissionRequest", requestID: "approval-unknown")
        incomplete.nativeRequestId = nil
        manager.handleMessage(incomplete)
        manager.handleMessage(permission("PermissionRequest", requestID: "approval-known"))
        manager.handleMessage(permission("PermissionResult", requestID: "approval-known"))
        manager.handleMessage(permission("PermissionResult", requestID: "approval-unrelated"))
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.status, .completionUnconfirmed)
        XCTAssertTrue(session.kimiCodeApprovalObservation?.hasUnidentifiedRequest == true)
        XCTAssertTrue(session.statusText.contains("unconfirmed"))
        manager.handleMessage(end())
        XCTAssertEqual(session.status, .completed)
        XCTAssertFalse(try XCTUnwrap(session.kimiCodeApprovalObservation).hasPendingApproval)
    }

    func testInterruptCannotDisambiguateSameTurnAcrossAgents() throws {
        let manager = SessionManager()
        manager.handleMessage(permission("PermissionRequest", requestID: "approval-a"))
        manager.handleMessage(permission("PermissionRequest", requestID: "approval-b", agentID: "child"))
        var interrupt = message("Interrupt")
        interrupt.nativeTurnId = "1"
        interrupt.observedState = "completionUnconfirmed"
        manager.handleMessage(interrupt)
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.kimiCodeApprovalObservation?.pending.count, 2)
        XCTAssertTrue(session.kimiCodeApprovalObservation?.wasInterrupted == true)
        XCTAssertTrue(session.statusText.contains("unconfirmed"))
        var turn = message("TurnStarted")
        turn.observedState = "active"
        manager.handleMessage(turn)
        manager.handleMessage(permission("PermissionResult", requestID: "approval-a"))
        XCTAssertEqual(session.status, .completionUnconfirmed)
        XCTAssertEqual(session.kimiCodeApprovalObservation?.pending.count, 1)
        manager.handleMessage(permission("PermissionResult", requestID: "approval-b", agentID: "child"))
        XCTAssertEqual(session.status, .active)
        XCTAssertFalse(try XCTUnwrap(session.kimiCodeApprovalObservation).hasPendingApproval)
    }

    func testLocalInteractionTakesPriorityWithoutBeingAnsweredByObservation() throws {
        let manager = SessionManager()
        manager.handleMessage(permission("PermissionRequest", requestID: "approval-observed"))
        let session = try XCTUnwrap(manager.sessions.first)
        var local = message("LocalQuestion", type: .question)
        local.questionText = "Choose"
        local.options = ["Continue", "Stop"]
        local.nativeRequestId = "local-question"
        manager.handleQuestionRequest(local, respond: { _ in XCTFail("观察事件不能回答本地交互") })
        let localID = session.pendingQuestion?.id
        manager.handleMessage(permission("PermissionResult", requestID: "unknown-result"))
        var tool = message("PreToolUse", type: .toolStart)
        tool.tool = "read_file"
        tool.toolCallId = "concurrent-tool"
        manager.handleMessage(tool)
        XCTAssertEqual(session.pendingQuestion?.id, localID)
        XCTAssertEqual(session.status, .waitingAnswer)
        XCTAssertTrue(manager.hasInteraction)
        var resolved = DIMessage(type: .interactionResolved, sessionId: session.id)
        resolved.nativeRequestKind = "question"
        resolved.nativeRequestId = "local-question"
        manager.handleMessage(resolved)
        XCTAssertNil(session.pendingQuestion)
        XCTAssertEqual(session.status, .waitingPermission)
        XCTAssertFalse(manager.hasInteraction)
    }

    func testClosedAndArchivedSessionsIgnoreLateResultsRequestsAndHeartbeat() throws {
        let (manager, store) = try diskManager()
        manager.handleMessage(permission("PermissionRequest", requestID: "approval-a"))
        let session = try XCTUnwrap(manager.sessions.first)
        manager.handleMessage(end())
        let completedAt = session.completedAt
        for event in [permission("PermissionResult", requestID: "approval-a"),
                      permission("PermissionRequest", requestID: "new-request"), message("SessionHeartbeat")] {
            manager.handleMessage(event)
            XCTAssertEqual(session.status, .completed)
            XCTAssertEqual(session.completedAt, completedAt)
        }
        manager.dismissSession(session)
        let restarted = reopened(store)
        restarted.handleMessage(permission("PermissionResult", requestID: "unknown-result"))
        restarted.handleMessage(permission("PermissionRequest", requestID: "new-request"))
        restarted.handleMessage(message("SessionHeartbeat"))
        XCTAssertTrue(restarted.sessions.isEmpty)
        XCTAssertEqual(restarted.persistenceManager?.fetchHistory().first?.status, .completed)
        var resumed = message("TurnStarted")
        resumed.observedState = "active"
        restarted.handleMessage(resumed)
        restarted.handleMessage(permission("PermissionRequest", requestID: "approval-a"))
        XCTAssertEqual(restarted.sessions.first?.status, .active)
        XCTAssertTrue(restarted.sessions.first?.kimiCodeApprovalObservation?.pending.isEmpty == true)
    }

    func testResultBeforeRequestPersistsWithoutCreatingHistoryOrVisibleActivity() throws {
        let (manager, store) = try diskManager()
        manager.handleMessage(permission("PermissionResult", requestID: "approval-a"))
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertEqual(manager.persistenceManager?.totalCount(), 0)
        XCTAssertNotNil(try manager.persistenceManager?.kimiCodeApprovalOrphan(sessionId: "kimi_code-session"))
        let restarted = reopened(store)
        restarted.handleMessage(permission("PermissionRequest", requestID: "approval-a"))
        XCTAssertTrue(restarted.sessions.isEmpty)
        XCTAssertEqual(restarted.persistenceManager?.totalCount(), 0)
        var other = permission("PermissionRequest", requestID: "approval-a")
        other.sessionId = "kimi_code-other-session"
        restarted.handleMessage(other)
        XCTAssertEqual(restarted.sessions.map(\.id), ["kimi_code-other-session"])
        XCTAssertEqual(restarted.sessions.first?.status, .waitingPermission)
    }

    func testTrueActivityTransfersOrphanInSameSaveAndRetainsDuplicateSuppression() throws {
        let (manager, store) = try diskManager()
        manager.handleMessage(permission("PermissionResult", requestID: "approval-a"))
        let restarted = reopened(store)
        var connected = message("SessionStart")
        connected.observedState = "idle"
        restarted.handleMessage(connected)
        XCTAssertNil(try restarted.persistenceManager?.kimiCodeApprovalOrphan(sessionId: "kimi_code-session"))
        XCTAssertEqual(restarted.persistenceManager?.totalCount(), 1)
        restarted.handleMessage(permission("PermissionRequest", requestID: "approval-a"))
        XCTAssertEqual(restarted.sessions.first?.status, .idle)
        XCTAssertEqual(restarted.sessions.first?.kimiCodeApprovalObservation?.resolved.count, 1)
    }

    func testRestartRestoresPendingAndBaseStateButNoInteractionCallbacks() throws {
        let (manager, store) = try diskManager()
        manager.handleMessage(permission("PermissionRequest", requestID: "approval-a"))
        manager.handleMessage(permission("PermissionRequest", requestID: "approval-b", agentID: "child"))
        let restarted = reopened(store)
        restarted.handleMessage(permission("PermissionResult", requestID: "approval-a"))
        XCTAssertTrue(restarted.sessions.isEmpty)
        var turn = message("TurnStarted")
        turn.observedState = "active"
        restarted.handleMessage(turn)
        let session = try XCTUnwrap(restarted.sessions.first)
        XCTAssertEqual(session.status, .waitingPermission)
        XCTAssertEqual(session.kimiCodeApprovalObservation?.pending.count, 1)
        XCTAssertNil(session.pendingPermission)
        XCTAssertNil(session.pendingQuestion)
        restarted.handleMessage(permission("PermissionResult", requestID: "approval-b", agentID: "child"))
        XCTAssertEqual(session.status, .active)
        XCTAssertNil(session.completedAt)
    }

    func testNodeWaitingWithoutLedgerIsUnconfirmedAndCorruptLedgerFailsExplicitly() throws {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let session = AgentSession(id: "kimi_code-session", agentType: .kimi)
        session.status = .waitingPermission
        XCTAssertTrue(persistence.save(session: session))
        let restored = try XCTUnwrap(persistence.restoreSession(sessionId: session.id))
        XCTAssertTrue(restored.kimiCodeApprovalObservation?.hasUnidentifiedRequest == true)
        XCTAssertNil(restored.pendingPermission)
        let context = ModelContext(try XCTUnwrap(persistence.modelContainer))
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<StoredSession>()).first)
        stored.kimiCodeApprovalObservationData = Data("broken json".utf8)
        try context.save()
        XCTAssertThrowsError(try persistence.restoreSession(sessionId: session.id))
        XCTAssertNotNil(persistence.lastSaveError)
        let manager = SessionManager()
        manager.persistenceManager = persistence
        manager.handleMessage(permission("PermissionRequest", requestID: "approval-a"))
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredSession>()).first?.kimiCodeApprovalObservationData, Data("broken json".utf8))
    }

    func testReadOnlyOrphanTransferFailureLeavesOrphanAndMemoryUntouchedForRetry() throws {
        let (manager, store) = try diskManager()
        manager.handleMessage(permission("PermissionResult", requestID: "approval-a"))
        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self, StoredKimiCodeApprovalOrphan.self])
        let readOnly = ModelConfiguration(schema: schema, url: store, allowsSave: false)
        let persistence = SessionPersistenceManager()
        persistence.modelContainer = try ModelContainer(for: schema, configurations: [readOnly])
        let session = AgentSession(id: "kimi_code-session", agentType: .kimi)
        XCTAssertFalse(persistence.save(session: session))
        XCTAssertNil(session.kimiCodeApprovalObservation)
        XCTAssertNotNil(try persistence.kimiCodeApprovalOrphan(sessionId: session.id))
        XCTAssertEqual(persistence.totalCount(), 0)
        XCTAssertNotNil(persistence.lastSaveError)
        let writable = try XCTUnwrap(reopened(store).persistenceManager)
        XCTAssertTrue(writable.save(session: session))
        XCTAssertNil(try writable.kimiCodeApprovalOrphan(sessionId: session.id))
        XCTAssertEqual(session.kimiCodeApprovalObservation?.resolved.count, 1)
    }

    func testHistoryDeletionAndRetentionRemoveOnlyCorrespondingOrphans() throws {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let session = AgentSession(id: "to-delete", agentType: .kimi)
        XCTAssertTrue(persistence.save(session: session))
        var facts = KimiCodeApprovalObservation()
        facts.observeResult(.init(id: "approval-a", agentID: "main", turnID: "1", toolCallID: "tool"))
        XCTAssertTrue(persistence.saveKimiCodeApprovalOrphan(sessionId: session.id, observation: facts))
        XCTAssertTrue(persistence.saveKimiCodeApprovalOrphan(sessionId: "expired", observation: facts))
        XCTAssertTrue(persistence.saveKimiCodeApprovalOrphan(sessionId: "retained", observation: facts))
        let context = ModelContext(try XCTUnwrap(persistence.modelContainer))
        let orphans = try context.fetch(FetchDescriptor<StoredKimiCodeApprovalOrphan>())
        let expired = try XCTUnwrap(orphans.first { $0.sessionId == "expired" })
        expired.updatedAt = Date(timeIntervalSinceNow: -40 * 86400)
        try context.save()
        persistence.deleteSession(try XCTUnwrap(persistence.fetchHistory().first))
        XCTAssertNil(try persistence.kimiCodeApprovalOrphan(sessionId: "to-delete"))
        persistence.cleanup(olderThanDays: 30)
        XCTAssertNil(try persistence.kimiCodeApprovalOrphan(sessionId: "expired"))
        XCTAssertNotNil(try persistence.kimiCodeApprovalOrphan(sessionId: "retained"))
    }

    private func permission(_ event: String, requestID: String, agentID: String = "main", turnID: String = "1", toolID: String = "tool") -> DIMessage {
        var result = message(event)
        result.nativeRequestId = requestID
        result.nativeAgentId = agentID
        result.nativeTurnId = turnID
        result.toolCallId = toolID
        return result
    }

    private func message(_ event: String, type: DIMessageType = .statusUpdate) -> DIMessage {
        var result = DIMessage(type: type, sessionId: "kimi_code-session")
        result.agentType = "kimi"
        result.nativeEvent = "kimi_code." + event
        result.statusIsAssistantReply = false
        return result
    }

    private func end() -> DIMessage {
        var result = message("SessionEnd", type: .sessionEnd)
        result.observedState = "completed"
        return result
    }

    private func diskManager() throws -> (SessionManager, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xi-kimi-approval-\(UUID())")
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
