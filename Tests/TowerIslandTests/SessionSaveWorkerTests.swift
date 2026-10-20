import XCTest
import SwiftData
@testable import XIsland

@MainActor
final class SessionSaveWorkerTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self, StoredKimiCodeApprovalOrphan.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func request(_ id: String = "approval") throws -> KimiCodeApprovalObservation.Request {
        try XCTUnwrap(KimiCodeApprovalObservation.Request(id: id, agentID: "agent", turnID: "turn", toolCallID: "tool"))
    }

    func testDetachedSaveUsesCapturedParentAndChildValues() async throws {
        let container = try makeContainer()
        let startTime = Date(timeIntervalSince1970: 1_700_000_000)
        let session = AgentSession(id: "captured", agentType: .kimi, terminal: "ttys001",
            workingDirectory: "/tmp/captured", prompt: "captured prompt", startTime: startTime)
        session.status = .observationUnavailable
        session.statusText = "captured status"
        session.sourceNamespace = "kimi_code"
        session.sourceInstanceId = "instance"
        session.nativeTaskId = "native-task"
        session.observationEndedAt = startTime.addingTimeInterval(60)
        session.recapText = "captured recap"
        session.tokenUsage = TokenUsage(inputTokens: 10, outputTokens: 20, totalTokens: 30,
            estimatedCostUSD: 0.1, model: "model")
        session.appendEvent(ToolEvent(tool: "Read", input: "captured.swift"))
        session.appendChatMessage(ChatMessage(timestamp: startTime, role: .user, content: "captured message"))
        let snapshot = SessionSaveSnapshot(session: session)
        session.prompt = "new prompt"
        session.updateEvent(at: 0) { $0.result = "new result" }
        session.appendChatMessage(ChatMessage(timestamp: startTime, role: .assistant, content: "new message"))

        let result = try await Task.detached {
            try SessionSaveWorker.save(snapshot: snapshot, previousChildren: nil, container: container)
        }.value

        let context = ModelContext(container)
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<StoredSession>()).first)
        XCTAssertEqual(stored.sessionId, snapshot.id)
        XCTAssertEqual(stored.agentType, .kimi)
        XCTAssertEqual(stored.startTime, startTime)
        XCTAssertEqual(stored.prompt, "captured prompt")
        XCTAssertEqual(stored.workingDirectory, "/tmp/captured")
        XCTAssertEqual(stored.terminal, "ttys001")
        XCTAssertEqual(stored.sourceNamespace, "kimi_code")
        XCTAssertEqual(stored.sourceInstanceId, "instance")
        XCTAssertEqual(stored.nativeTaskId, "native-task")
        XCTAssertEqual(stored.observationEndedAt, snapshot.observationEndedAt)
        XCTAssertEqual(stored.historyDate, snapshot.observationEndedAt)
        XCTAssertEqual(stored.recapText, "captured recap")
        XCTAssertEqual(stored.inputTokens, 10)
        XCTAssertEqual(stored.outputTokens, 20)
        XCTAssertEqual(stored.totalTokens, 30)
        XCTAssertEqual(stored.estimatedCostUSD, 0.1)
        XCTAssertEqual(stored.model, "model")
        XCTAssertEqual(stored.toolEvents.count, 1)
        XCTAssertNil(stored.toolEvents.first?.result)
        XCTAssertEqual(stored.chatMessages.map(\.content), ["captured message"])
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.childWriteCount, 2)
        XCTAssertEqual(result.committedChildren.events.count, 1)
        XCTAssertEqual(result.committedChildren.messages.count, 1)
        XCTAssertEqual(result.storedStatus, .observationUnavailable)
        XCTAssertNil(result.projectedStatusText)
        XCTAssertFalse(session.markChildrenPersisted(ifUnchangedSince: snapshot.childRevision))
    }

    func testOldReceiptPreservesNewTrackedChangesAndCheckpointUsesOnlyCommittedValues() throws {
        let container = try makeContainer(), session = AgentSession(id: "tracked", agentType: .codex)
        let initial = SessionSaveSnapshot(session: session)
        let baseline = try SessionSaveWorker.save(snapshot: initial, previousChildren: nil, container: container)
        XCTAssertTrue(session.markChildrenPersisted(ifUnchangedSince: initial.childRevision))
        let event = ToolEvent(tool: "Read")
        session.appendEvent(event)
        let snapshot = SessionSaveSnapshot(session: session)
        session.updateEvent(at: 0) { $0.result = "late result"; $0.isComplete = true }
        let message = ChatMessage(timestamp: Date(), role: .assistant, content: "late message")
        session.appendChatMessage(message)

        let saved = try SessionSaveWorker.save(snapshot: snapshot, previousChildren: baseline.committedChildren, container: container)
        XCTAssertEqual(saved.childWriteCount, 1)
        XCTAssertNil(saved.committedChildren.events[event.id]?.result)
        XCTAssertTrue(saved.committedChildren.messages.isEmpty)
        XCTAssertFalse(session.markChildrenPersisted(ifUnchangedSince: snapshot.childRevision))
        XCTAssertEqual(session.pendingChildChanges?.events.count, 1)
        XCTAssertEqual(session.pendingChildChanges?.messages.count, 1)

        let latest = SessionSaveSnapshot(session: session)
        let retried = try SessionSaveWorker.save(snapshot: latest, previousChildren: saved.committedChildren, container: container)
        XCTAssertEqual(retried.childWriteCount, 2)
        XCTAssertTrue(session.markChildrenPersisted(ifUnchangedSince: latest.childRevision))
        XCTAssertEqual(session.pendingChildChanges?.events.count, 0)
        let fresh = ModelContext(container)
        let stored = try XCTUnwrap(fresh.fetch(FetchDescriptor<StoredSession>()).first)
        XCTAssertEqual(stored.toolEvents.count, 1)
        XCTAssertEqual(stored.toolEvents.first?.result, "late result")
        XCTAssertEqual(stored.chatMessages.map(\.content), ["late message"])
    }

    func testDirectMutationAfterSnapshotKeepsFullScanFallbackForRetry() throws {
        let container = try makeContainer(), session = AgentSession(id: "direct", agentType: .codex)
        session.appendEvent(ToolEvent(tool: "Read"))
        let initial = SessionSaveSnapshot(session: session)
        let baseline = try SessionSaveWorker.save(snapshot: initial, previousChildren: nil, container: container)
        XCTAssertTrue(session.markChildrenPersisted(ifUnchangedSince: initial.childRevision))
        session.appendEvent(ToolEvent(tool: "Write"))
        let snapshot = SessionSaveSnapshot(session: session)
        session.events[0].result = "direct change"
        session.appendEvent(ToolEvent(tool: "Bash"))
        XCTAssertNil(session.pendingChildChanges)

        let saved = try SessionSaveWorker.save(snapshot: snapshot, previousChildren: baseline.committedChildren, container: container)
        XCTAssertFalse(session.markChildrenPersisted(ifUnchangedSince: snapshot.childRevision))
        XCTAssertNil(session.pendingChildChanges)
        let latest = SessionSaveSnapshot(session: session)
        let retried = try SessionSaveWorker.save(snapshot: latest, previousChildren: saved.committedChildren, container: container)
        XCTAssertEqual(retried.childWriteCount, 2)
        XCTAssertTrue(session.markChildrenPersisted(ifUnchangedSince: latest.childRevision))
        let fresh = ModelContext(container)
        let stored = try XCTUnwrap(fresh.fetch(FetchDescriptor<StoredSession>()).first)
        XCTAssertEqual(stored.toolEvents.count, 3)
        XCTAssertEqual(stored.toolEvents.first { $0.tool == "Read" }?.result, "direct change")
    }

    func testUnchangedSaveSkipsCommitCallbackAndChildWrites() throws {
        let container = try makeContainer(), session = AgentSession(id: "unchanged", agentType: .codex)
        session.appendEvent(ToolEvent(tool: "Read"))
        let snapshot = SessionSaveSnapshot(session: session)
        let initial = try SessionSaveWorker.save(snapshot: snapshot, previousChildren: nil, container: container)
        XCTAssertTrue(session.markChildrenPersisted(ifUnchangedSince: snapshot.childRevision))
        let result = try SessionSaveWorker.save(snapshot: SessionSaveSnapshot(session: session),
            previousChildren: initial.committedChildren, container: container,
            beforeCommit: { throw CocoaError(.userCancelled) })
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.childWriteCount, 0)
    }

    func testOrphanTransferPreservesBaseStateAndReturnsConsumedFactsWithoutChangingSession() throws {
        let container = try makeContainer(), session = AgentSession(id: "kimi_code-transfer", agentType: .kimi)
        let approval = try request()
        var observation = KimiCodeApprovalObservation(baseStatus: .idle, baseStatusText: "idle base")
        observation.observeRequest(approval)
        session.kimiCodeApprovalObservation = observation
        session.status = .waitingPermission
        var facts = KimiCodeApprovalObservation(baseStatus: .thinking, baseStatusText: "orphan base")
        facts.observeResult(approval)
        let fixture = ModelContext(container)
        fixture.insert(StoredKimiCodeApprovalOrphan(sessionId: session.id, observationData: try JSONEncoder().encode(facts)))
        try fixture.save()

        let result = try SessionSaveWorker.save(snapshot: SessionSaveSnapshot(session: session), previousChildren: nil, container: container)

        XCTAssertEqual(result.mergedOrphanObservation, facts)
        XCTAssertEqual(result.mergedApprovalObservation?.baseStatus, .idle)
        XCTAssertEqual(result.mergedApprovalObservation?.resolved.count, 1)
        XCTAssertEqual(result.mergedApprovalObservation?.pending.count, 0)
        XCTAssertEqual(result.storedStatus, .idle)
        XCTAssertEqual(result.projectedStatusText, "idle base")
        XCTAssertEqual(session.kimiCodeApprovalObservation, observation)
        XCTAssertEqual(session.status, .waitingPermission)
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<StoredKimiCodeApprovalOrphan>()), 0)
        let stored = try XCTUnwrap(fresh.fetch(FetchDescriptor<StoredSession>()).first)
        XCTAssertEqual(stored.status, .idle)
        let storedApprovalData = try XCTUnwrap(stored.kimiCodeApprovalObservationData)
        XCTAssertEqual(try KimiCodeApprovalObservation.decode(storedApprovalData), result.mergedApprovalObservation)
    }

    func testCommitFailureRollsBackParentChildrenAndOrphanTogether() throws {
        let container = try makeContainer(), session = AgentSession(id: "rollback", agentType: .kimi, prompt: "original")
        let snapshot = SessionSaveSnapshot(session: session)
        let baseline = try SessionSaveWorker.save(snapshot: snapshot, previousChildren: nil, container: container)
        XCTAssertTrue(session.markChildrenPersisted(ifUnchangedSince: snapshot.childRevision))
        var facts = KimiCodeApprovalObservation()
        facts.observeResult(try request())
        let fixture = ModelContext(container)
        fixture.insert(StoredKimiCodeApprovalOrphan(sessionId: session.id, observationData: try JSONEncoder().encode(facts)))
        try fixture.save()
        session.prompt = "unsaved"
        session.appendEvent(ToolEvent(tool: "Read"))
        session.appendChatMessage(ChatMessage(timestamp: Date(), role: .assistant, content: "unsaved"))

        XCTAssertThrowsError(try SessionSaveWorker.save(snapshot: SessionSaveSnapshot(session: session),
            previousChildren: baseline.committedChildren, container: container,
            beforeCommit: { throw CocoaError(.userCancelled) }))

        let fresh = ModelContext(container)
        let stored = try XCTUnwrap(fresh.fetch(FetchDescriptor<StoredSession>()).first)
        XCTAssertEqual(stored.prompt, "original")
        XCTAssertTrue(stored.toolEvents.isEmpty)
        XCTAssertTrue(stored.chatMessages.isEmpty)
        XCTAssertNil(stored.kimiCodeApprovalObservationData)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<StoredKimiCodeApprovalOrphan>()), 1)
        XCTAssertNil(session.kimiCodeApprovalObservation)
        XCTAssertEqual(session.pendingChildChanges?.events.count, 1)
        XCTAssertEqual(session.pendingChildChanges?.messages.count, 1)
        let retried = try SessionSaveWorker.save(snapshot: SessionSaveSnapshot(session: session),
            previousChildren: baseline.committedChildren, container: container)
        XCTAssertEqual(retried.childWriteCount, 2)
        XCTAssertEqual(retried.mergedApprovalObservation?.resolved.count, 1)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<StoredKimiCodeApprovalOrphan>()), 0)
    }

    func testObservedUpdatesKeepEarliestStartAndMonotonicUsage() throws {
        let container = try makeContainer(), startTime = Date(timeIntervalSince1970: 1_700_000_000)
        let original = AgentSession(id: "observed", agentType: .kimi, startTime: startTime)
        original.sourceInstanceId = "instance"
        original.tokenUsage = TokenUsage(inputTokens: 100, outputTokens: 200, totalTokens: 300, estimatedCostUSD: 0.5, model: "old")
        let baseline = try SessionSaveWorker.save(snapshot: SessionSaveSnapshot(session: original), previousChildren: nil, container: container)
        let resumed = AgentSession(id: original.id, agentType: .kimi, startTime: startTime.addingTimeInterval(60))
        resumed.sourceInstanceId = "instance"
        resumed.tokenUsage = TokenUsage(inputTokens: 10, outputTokens: 20, totalTokens: 30, estimatedCostUSD: 0.1, model: "new")
        _ = try SessionSaveWorker.save(snapshot: SessionSaveSnapshot(session: resumed), previousChildren: baseline.committedChildren, container: container)

        let fresh = ModelContext(container)
        let stored = try XCTUnwrap(fresh.fetch(FetchDescriptor<StoredSession>()).first)
        XCTAssertEqual(stored.startTime, startTime)
        XCTAssertEqual(stored.inputTokens, 100)
        XCTAssertEqual(stored.outputTokens, 200)
        XCTAssertEqual(stored.totalTokens, 300)
        XCTAssertEqual(stored.estimatedCostUSD, 0.5)
        XCTAssertEqual(stored.model, "new")
    }

    func testCorruptOrphanFailsWithoutCreatingParentOrChangingMemory() throws {
        let container = try makeContainer(), session = AgentSession(id: "corrupt", agentType: .kimi)
        let fixture = ModelContext(container)
        fixture.insert(StoredKimiCodeApprovalOrphan(sessionId: session.id, observationData: Data("broken json".utf8)))
        try fixture.save()
        session.appendEvent(ToolEvent(tool: "Read"))

        XCTAssertThrowsError(try SessionSaveWorker.save(snapshot: SessionSaveSnapshot(session: session), previousChildren: nil, container: container))

        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<StoredSession>()), 0)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<StoredToolEvent>()), 0)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<StoredKimiCodeApprovalOrphan>()), 1)
        XCTAssertNil(session.kimiCodeApprovalObservation)
        XCTAssertEqual(session.events.count, 1)
    }

    func testQueuedSnapshotRetainsOrphanFactsConsumedByEarlierSnapshot() throws {
        let container = try makeContainer(), session = AgentSession(id: "kimi_code-queued", agentType: .kimi)
        session.sourceNamespace = "kimi_code"
        session.sourceInstanceId = "instance"
        session.nativeTaskId = "task"
        let approval = try request()
        var facts = KimiCodeApprovalObservation(baseStatus: .idle, baseStatusText: "orphan base")
        facts.observeResult(approval)
        let fixture = ModelContext(container)
        fixture.insert(StoredKimiCodeApprovalOrphan(sessionId: session.id, observationData: try JSONEncoder().encode(facts)))
        try fixture.save()
        let first = SessionSaveSnapshot(session: session)
        session.status = .thinking
        session.statusText = "new state"
        let queued = SessionSaveSnapshot(session: session)

        let consumed = try SessionSaveWorker.save(snapshot: first, previousChildren: nil, container: container)
        let saved = try SessionSaveWorker.save(snapshot: queued, previousChildren: consumed.committedChildren, container: container)

        XCTAssertEqual(saved.mergedApprovalObservation?.resolved[approval.id], approval)
        XCTAssertEqual(saved.mergedApprovalObservation?.baseStatus, .thinking)
        XCTAssertEqual(saved.mergedApprovalObservation?.baseStatusText, "new state")
        XCTAssertEqual(saved.storedStatus, .thinking)
        let reader = SessionPersistenceManager()
        reader.modelContainer = container
        let restored = try XCTUnwrap(reader.restoreSession(sessionId: session.id))
        XCTAssertEqual(restored.kimiCodeApprovalObservation?.resolved[approval.id], approval)
        XCTAssertEqual(restored.status, .thinking)
    }

    func testCommittedKimiFactsAreNotInheritedAcrossClientIdentityChanges() throws {
        for changedField in ["agent", "namespace", "instance", "task"] {
            let container = try makeContainer(), original = AgentSession(id: "kimi_code-identity", agentType: .kimi)
            original.sourceNamespace = "kimi_code"
            original.sourceInstanceId = "instance"
            original.nativeTaskId = "task"
            var facts = KimiCodeApprovalObservation()
            facts.observeResult(try request())
            original.kimiCodeApprovalObservation = facts
            let initial = try SessionSaveWorker.save(snapshot: SessionSaveSnapshot(session: original), previousChildren: nil, container: container)
            let replacement = AgentSession(id: original.id, agentType: .kimi)
            replacement.sourceNamespace = original.sourceNamespace
            replacement.sourceInstanceId = original.sourceInstanceId
            replacement.nativeTaskId = original.nativeTaskId
            switch changedField {
            case "agent": replacement.agentType = .codex
            case "namespace": replacement.sourceNamespace = "another-client"
            case "instance": replacement.sourceInstanceId = "another-instance"
            default: replacement.nativeTaskId = "another-task"
            }

            let result = try SessionSaveWorker.save(snapshot: SessionSaveSnapshot(session: replacement),
                previousChildren: initial.committedChildren, container: container)

            XCTAssertNil(result.mergedApprovalObservation, changedField)
            let reader = SessionPersistenceManager()
            reader.modelContainer = container
            XCTAssertNil(try reader.restoreSession(sessionId: replacement.id)?.kimiCodeApprovalObservation, changedField)
        }
    }

    func testCommittedApprovalFactsPreserveNewBaseAndDoNotReopenCompletedSnapshot() throws {
        let container = try makeContainer(), session = AgentSession(id: "kimi_code-terminal", agentType: .kimi)
        let approval = try request()
        var pending = KimiCodeApprovalObservation(baseStatus: .idle, baseStatusText: "old base")
        pending.observeRequest(approval)
        session.kimiCodeApprovalObservation = pending
        let first = try SessionSaveWorker.save(snapshot: SessionSaveSnapshot(session: session), previousChildren: nil, container: container)
        var latest = KimiCodeApprovalObservation(baseStatus: .thinking, baseStatusText: "new base")
        latest.observeResult(approval)
        session.kimiCodeApprovalObservation = latest
        session.status = .thinking
        let second = try SessionSaveWorker.save(snapshot: SessionSaveSnapshot(session: session),
            previousChildren: first.committedChildren, container: container)
        XCTAssertEqual(second.mergedApprovalObservation?.baseStatus, .thinking)
        XCTAssertEqual(second.projectedStatusText, "new base")
        XCTAssertEqual(second.mergedApprovalObservation?.pending.count, 0)

        let lateApproval = try request("late-approval")
        latest.observeRequest(lateApproval)
        session.kimiCodeApprovalObservation = latest
        let beforeEnd = try SessionSaveWorker.save(snapshot: SessionSaveSnapshot(session: session),
            previousChildren: second.committedChildren, container: container)
        session.status = .completed
        session.completedAt = Date()
        session.kimiCodeApprovalObservation = nil
        let ended = try SessionSaveWorker.save(snapshot: SessionSaveSnapshot(session: session),
            previousChildren: beforeEnd.committedChildren, container: container)
        XCTAssertEqual(ended.storedStatus, .completed)
        XCTAssertEqual(ended.mergedApprovalObservation?.baseStatus, .completed)
        XCTAssertEqual(ended.mergedApprovalObservation?.pending.count, 0)
        XCTAssertEqual(ended.mergedApprovalObservation?.resolved[lateApproval.id], lateApproval)
        XCTAssertNil(ended.projectedStatusText)
    }
}
