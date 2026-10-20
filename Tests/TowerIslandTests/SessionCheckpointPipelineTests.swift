import DIShared
import Foundation
import SwiftData
import XCTest
@testable import XIsland

@MainActor
final class SessionCheckpointPipelineTests: XCTestCase {
    private func message(_ type: DIMessageType, id: String = "claude_code-pipeline") -> DIMessage {
        var message = DIMessage(type: type, sessionId: id)
        message.agentType = "claude_code"
        message.statusIsAssistantReply = false
        return message
    }

    private func manager(beforeCommit: @escaping @Sendable () throws -> Void = {}) -> SessionManager {
        let persistence = SessionPersistenceManager(usesBackgroundWrites: true, beforeBackgroundCommit: beforeCommit)
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        return manager
    }

    func testMessageBurstYieldsToUIAndPreservesFinalOrder() async throws {
        let manager = manager()
        let session = AgentSession(id: "claude_code-pipeline", agentType: .claudeCode)
        manager.sessions = [session]
        for index in 0..<512 {
            var update = message(.progress)
            update.status = "progress-\(index)"
            manager.handleMessage(update)
        }
        let uiCallback = Task { @MainActor in manager.handledMessageCount }
        let countAtCallback = await uiCallback.value
        XCTAssertLessThan(countAtCallback, 512, "无落盘的突发事件也必须让出界面执行器")
        let saved = await manager.drainPersistenceOperations()
        XCTAssertTrue(saved)
        XCTAssertEqual(manager.handledMessageCount, 512)
        XCTAssertEqual(session.statusText, "progress-511")
    }

    func testDefaultSynchronousEntryStillReturnsWithDurableHistory() throws {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        var start = message(.sessionStart)
        start.prompt = "Synchronous fixture"

        manager.handleMessage(start)

        XCTAssertEqual(manager.handledMessageCount, 1)
        XCTAssertEqual(try persistence.restoreSession(sessionId: start.sessionId)?.prompt, start.prompt)
    }

    func testMessageReceiptWaitsForActualBackgroundCommit() async throws {
        let entered = expectation(description: "Background checkpoint reached commit")
        let gate = CheckpointCommitGate(entered: entered)
        defer { gate.release() }
        let manager = manager(beforeCommit: { try gate.waitForRelease() })
        var start = message(.sessionStart)
        start.prompt = "Keep the checkpoint"

        manager.handleMessage(start)
        XCTAssertEqual(manager.handledMessageCount, 0)
        await fulfillment(of: [entered], timeout: 5)

        XCTAssertEqual(manager.sessions.first?.prompt, start.prompt)
        XCTAssertEqual(manager.handledMessageCount, 0)
        XCTAssertTrue(manager.unsavedSessionIDs.isEmpty)
        gate.release()
        let saved = await manager.drainPersistenceOperations()

        XCTAssertTrue(saved)
        XCTAssertEqual(manager.handledMessageCount, 1)
        XCTAssertEqual(try manager.persistenceManager?.restoreSession(sessionId: start.sessionId)?.prompt, start.prompt)
    }

    func testDismissKeepsVisibleSessionUntilItsCommitCompletes() async throws {
        let entered = expectation(description: "Dismiss checkpoint reached commit")
        let gate = CheckpointCommitGate(entered: entered)
        defer { gate.release() }
        let manager = manager(beforeCommit: { try gate.waitForRelease() })
        let session = AgentSession(id: "dismiss-pipeline", agentType: .claudeCode, prompt: "Do not discard before commit")
        session.appendEvent(ToolEvent(tool: "Read", input: "Retain this event"))
        manager.sessions = [session]

        manager.dismissSession(session)
        await fulfillment(of: [entered], timeout: 5)

        XCTAssertTrue(manager.sessions.first === session)
        XCTAssertTrue(manager.unsavedSessionIDs.isEmpty)
        gate.release()
        let saved = await manager.drainPersistenceOperations()

        XCTAssertTrue(saved)
        XCTAssertTrue(manager.sessions.isEmpty)
        let restored = try XCTUnwrap(manager.persistenceManager?.restoreSession(sessionId: session.id))
        XCTAssertEqual(restored.events.map(\.id), session.events.map(\.id))
        XCTAssertEqual(restored.prompt, session.prompt)
    }

    func testFailedDismissRetainsFactsUntilRetryReallyCommits() async throws {
        let failure = CheckpointFailureSwitch()
        let manager = manager(beforeCommit: { try failure.check() })
        let session = AgentSession(id: "failed-pipeline", agentType: .claudeCode, prompt: "Retry this checkpoint")
        let event = ToolEvent(tool: "Write", input: "Pending data")
        session.appendEvent(event)
        manager.sessions = [session]

        manager.dismissSession(session)
        let firstSave = await manager.drainPersistenceOperations()

        XCTAssertFalse(firstSave)
        XCTAssertTrue(manager.sessions.first === session)
        XCTAssertEqual(manager.unsavedSessionIDs, [session.id])
        XCTAssertNotNil(manager.persistenceManager?.lastSaveError)
        XCTAssertNil(try manager.persistenceManager?.restoreSession(sessionId: session.id))
        XCTAssertEqual(session.events.map(\.id), [event.id])

        failure.allowWrites()
        manager.retryPendingHistorySaves()
        let retried = await manager.drainPersistenceOperations()
        XCTAssertTrue(retried)
        XCTAssertTrue(manager.unsavedSessionIDs.isEmpty)
        XCTAssertEqual(try manager.persistenceManager?.restoreSession(sessionId: session.id)?.events.map(\.id), [event.id])

        manager.dismissSession(session)
        let dismissed = await manager.drainPersistenceOperations()
        XCTAssertTrue(dismissed)
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    func testResumeCannotOvertakePendingTerminalCheckpoint() async throws {
        let entered = expectation(description: "Terminal checkpoint reached commit")
        let gate = CheckpointCommitGate(entered: entered)
        defer { gate.release() }
        let manager = manager(beforeCommit: { try gate.waitForRelease() })
        let session = AgentSession(id: "claude_code-pipeline", agentType: .claudeCode, prompt: "Before terminal")
        let event = ToolEvent(tool: "Read", isComplete: true)
        session.appendEvent(event)
        manager.sessions = [session]
        XCTAssertTrue(try XCTUnwrap(manager.persistenceManager).save(session: session))
        var end = message(.sessionEnd)
        end.observedState = "completed"
        var resume = message(.sessionStart)
        resume.prompt = "Resume after terminal commit"
        resume.nativeMessageId = "new-prompt"

        manager.handleMessage(end)
        manager.handleMessage(resume)
        await fulfillment(of: [entered], timeout: 5)

        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(session.prompt, "Before terminal")
        XCTAssertEqual(manager.handledMessageCount, 0)
        gate.release()
        let saved = await manager.drainPersistenceOperations()

        XCTAssertTrue(saved)
        XCTAssertEqual(manager.handledMessageCount, 2)
        XCTAssertEqual(session.status, .active)
        XCTAssertNil(session.completedAt)
        let restored = try XCTUnwrap(manager.persistenceManager?.restoreSession(sessionId: session.id))
        XCTAssertEqual(restored.status, .active)
        XCTAssertNil(restored.completedAt)
        XCTAssertEqual(restored.prompt, resume.prompt)
        XCTAssertEqual(restored.events.map(\.id), [event.id])
    }

    func testApprovalClickShowsSendingWhileCommitIsBlockedAndCannotSendTwice() async throws {
        let entered = expectation(description: "Approval checkpoint reached commit")
        let gate = CheckpointCommitGate(entered: entered)
        defer { gate.release() }
        let manager = manager(beforeCommit: { try gate.waitForRelease() })
        let session = AgentSession(id: "claude_code-pipeline", agentType: .claudeCode)
        session.status = .completed
        session.completedAt = Date()
        manager.sessions = [session]
        let deliveries = CheckpointDeliveryRecorder()
        var request = message(.permissionRequest)
        request.tool = "Bash"
        request.nativeRequestId = "single-send"
        manager.handlePermissionRequest(request, delivery: { _ in deliveries.send() }, respond: { _ in
            XCTFail("Expected asynchronous socket delivery")
        })
        await fulfillment(of: [entered], timeout: 5)
        let pending = try XCTUnwrap(session.pendingPermission)

        manager.approvePermission(session: session, requestID: pending.id)
        XCTAssertEqual(pending.state.phase, .sending)
        XCTAssertEqual(deliveries.count, 0)
        manager.approvePermission(session: session, requestID: pending.id)
        XCTAssertEqual(pending.state.phase, .sending)
        XCTAssertEqual(deliveries.count, 0)

        gate.release()
        let saved = await manager.drainPersistenceOperations()
        XCTAssertTrue(saved)
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(pending.state.phase, .sent)
        XCTAssertNil(session.pendingPermission)
    }

    func testQueuedReplacementInvalidatesAnOlderReservedApprovalClick() async throws {
        let entered = expectation(description: "Original approval checkpoint reached commit")
        let gate = CheckpointCommitGate(entered: entered)
        defer { gate.release() }
        let manager = manager(beforeCommit: { try gate.waitForRelease() })
        let session = AgentSession(id: "claude_code-pipeline", agentType: .claudeCode)
        session.status = .completed
        session.completedAt = Date()
        manager.sessions = [session]
        let oldDeliveries = CheckpointDeliveryRecorder()
        let replacementDeliveries = CheckpointDeliveryRecorder()
        var request = message(.permissionRequest)
        request.tool = "Bash"
        request.nativeRequestId = "old-request"
        manager.handlePermissionRequest(request, delivery: { _ in oldDeliveries.send() }, respond: { _ in
            XCTFail("Expected asynchronous socket delivery")
        })
        await fulfillment(of: [entered], timeout: 5)
        let old = try XCTUnwrap(session.pendingPermission)
        request.nativeRequestId = "replacement-request"
        manager.handlePermissionRequest(request, delivery: { _ in replacementDeliveries.send() }, respond: { _ in
            XCTFail("Replacement must wait for its own user decision")
        })

        manager.approvePermission(session: session, requestID: old.id)
        XCTAssertEqual(old.state.phase, .sending)
        gate.release()
        let saved = await manager.drainPersistenceOperations()

        XCTAssertTrue(saved)
        XCTAssertEqual(oldDeliveries.count, 0)
        XCTAssertEqual(replacementDeliveries.count, 0)
        let replacement = try XCTUnwrap(session.pendingPermission)
        XCTAssertNotEqual(replacement.id, old.id)
        XCTAssertEqual(replacement.nativeRequestId, "replacement-request")
        XCTAssertEqual(replacement.state.phase, .pending)
    }

    func testHiddenKimiTaskSaveFailureRetainsFactsForBackgroundRetry() async throws {
        let failure = CheckpointFailureSwitch()
        let manager = manager(beforeCommit: { try failure.check() })
        let persistence = try XCTUnwrap(manager.persistenceManager)
        let session = AgentSession(id: "kimi_code-hidden-pipeline", agentType: .kimi)
        session.status = .completionUnconfirmed
        var observation = KimiCodeApprovalObservation(baseStatus: .completionUnconfirmed)
        observation.observeBackgroundTask(DINativeBackgroundTask(id: "retry-child", kind: "agent", status: "running",
            description: "Task retry-child", startedAtMilliseconds: 1_791_886_744_559))
        session.kimiCodeApprovalObservation = observation
        let eventID = KimiCodeApprovalObservation.backgroundTaskEventID(sessionID: session.id, taskID: "retry-child")
        session.appendEvent(ToolEvent(tool: "Subagent", input: "Task retry-child", id: eventID))
        // 夹具先落盘，生产入口只接收隐藏会话的迟到结果。
        XCTAssertTrue(persistence.save(session: session))
        XCTAssertTrue(manager.sessions.isEmpty)
        var result = DIMessage(type: .statusUpdate, sessionId: session.id)
        result.agentType = "kimi"
        result.nativeEvent = "kimi_code.Notification"
        result.statusIsAssistantReply = false
        result.nativeBackgroundTask = DINativeBackgroundTask(id: "retry-child", status: "completed", result: "Durable child result")

        manager.handleMessage(result)
        let failed = await manager.drainPersistenceOperations()

        XCTAssertFalse(failed)
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertEqual(manager.unsavedSessionIDs, [session.id])
        XCTAssertNotNil(persistence.lastSaveError)
        let beforeRetry = try XCTUnwrap(persistence.restoreSession(sessionId: session.id))
        XCTAssertEqual(beforeRetry.events.map(\.id), [eventID])
        XCTAssertFalse(try XCTUnwrap(beforeRetry.events.first).isComplete)

        failure.allowWrites()
        manager.retryPendingHistorySaves()
        let saved = await manager.drainPersistenceOperations()

        XCTAssertTrue(saved)
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(manager.unsavedSessionIDs.isEmpty)
        let restored = try XCTUnwrap(persistence.restoreSession(sessionId: session.id))
        XCTAssertEqual(restored.events.map(\.id), [eventID])
        XCTAssertTrue(try XCTUnwrap(restored.events.first).isComplete)
        XCTAssertEqual(restored.events.first?.result, "Durable child result")
        XCTAssertEqual(restored.status, .completionUnconfirmed)
    }

    func testStopAndDrainIncludesAlreadyStartedApprovalDelivery() async throws {
        let manager = manager()
        let session = AgentSession(id: "kimi_code-shutdown", agentType: .kimi)
        session.status = .completed
        session.completedAt = Date()
        session.kimiCodeApprovalObservation = KimiCodeApprovalObservation(baseStatus: .active)
        manager.sessions = [session]
        let deliveryStarted = expectation(description: "Approval delivery started")
        let delivery = CheckpointDeliveryGate(started: deliveryStarted)
        var request = DIMessage(type: .permissionRequest, sessionId: session.id)
        request.agentType = "kimi"
        request.tool = "Bash"
        manager.handlePermissionRequest(request, delivery: { _ in await delivery.send() }, respond: { _ in
            XCTFail("Real delivery must not invoke the legacy callback")
        })
        let prepared = await manager.drainPersistenceOperations()
        XCTAssertTrue(prepared)
        let state = try XCTUnwrap(session.pendingPermission?.state)
        manager.approvePermission(session: session)
        await fulfillment(of: [deliveryStarted], timeout: 5)
        manager.stopAcceptingPersistenceOperations()

        let rejected = expectation(description: "New request cancelled after stop")
        manager.handlePermissionRequest(request, cancel: { rejected.fulfill() }, respond: { _ in XCTFail("Stopped request responded") })
        manager.handleMessage(message(.sessionStart, id: "rejected-after-stop"))
        await fulfillment(of: [rejected], timeout: 5)
        let drainStarted = expectation(description: "Drain began while delivery is in flight")
        var finishedDraining = false
        let drain = Task { @MainActor in
            drainStarted.fulfill()
            let result = await manager.drainPersistenceOperations()
            finishedDraining = true
            return result
        }
        await fulfillment(of: [drainStarted], timeout: 5)
        XCTAssertFalse(finishedDraining)
        XCTAssertEqual(state.phase, .sending)
        XCTAssertNotNil(session.pendingPermission)

        await delivery.finish()
        let saved = await drain.value

        XCTAssertTrue(saved)
        XCTAssertTrue(finishedDraining)
        XCTAssertEqual(state.phase, .sent)
        XCTAssertNil(session.pendingPermission)
        XCTAssertEqual(session.status, .active)
        XCTAssertNil(manager.sessions.first { $0.id == "rejected-after-stop" })
        XCTAssertEqual(try manager.persistenceManager?.restoreSession(sessionId: session.id)?.status, .active)
    }
}

private final class CheckpointCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let entered: XCTestExpectation
    private var didWait = false

    init(entered: XCTestExpectation) { self.entered = entered }

    func waitForRelease() throws {
        lock.lock()
        let shouldWait = !didWait
        didWait = true
        lock.unlock()
        guard shouldWait else { return }
        XCTAssertFalse(Thread.isMainThread)
        entered.fulfill()
        guard semaphore.wait(timeout: .now() + 15) == .success else { throw CocoaError(.fileWriteUnknown) }
    }

    func release() { semaphore.signal() }
}

private final class CheckpointFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func check() throws {
        lock.lock()
        let fail = shouldFail
        lock.unlock()
        if fail { throw CocoaError(.fileWriteNoPermission) }
    }

    func allowWrites() {
        lock.lock()
        shouldFail = false
        lock.unlock()
    }
}

private actor CheckpointDeliveryGate {
    private let started: XCTestExpectation
    private var continuation: CheckedContinuation<Bool, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func send() async -> Bool {
        started.fulfill()
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume(returning: true)
        continuation = nil
    }
}

private final class CheckpointDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveries = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return deliveries
    }

    func send() -> Bool {
        lock.lock()
        deliveries += 1
        lock.unlock()
        return true
    }
}
