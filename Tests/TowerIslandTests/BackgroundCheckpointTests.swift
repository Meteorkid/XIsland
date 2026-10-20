import Foundation
import SwiftData
import XCTest
@testable import XIsland

@MainActor
final class BackgroundCheckpointTests: XCTestCase {
    private final class CommitGate: @unchecked Sendable {
        let entered: XCTestExpectation
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var armed = true
        init(_ expectation: XCTestExpectation) { entered = expectation }
        func waitOnce() throws {
            XCTAssertFalse(Thread.isMainThread)
            lock.lock(); let wait = armed; armed = false; lock.unlock()
            if wait {
                entered.fulfill()
                guard release.wait(timeout: .now() + 10) == .success else { throw CocoaError(.userCancelled) }
            }
        }
    }

    private func manager(beforeCommit: @escaping @Sendable () throws -> Void = {}) throws -> SessionPersistenceManager {
        let value = SessionPersistenceManager(usesBackgroundWrites: true, beforeBackgroundCommit: beforeCommit)
        XCTAssertTrue(value.setupContainer(isStoredInMemoryOnly: true))
        return value
    }

    func testAcknowledgementDoesNotClearNewChildrenOrOverwriteNewStatus() async throws {
        let gate = CommitGate(expectation(description: "worker is ready to commit"))
        let manager = try manager(beforeCommit: gate.waitOnce)
        let session = AgentSession(id: "interleaving", agentType: .codex)
        let first = ToolEvent(tool: "Read"), second = ToolEvent(tool: "Write")
        session.appendEvent(first)
        let write = Task { await manager.saveAsync(session: session) }
        await fulfillment(of: [gate.entered], timeout: 3)
        session.appendEvent(second)
        session.status = .completed
        session.completedAt = Date()
        gate.release.signal()
        let saved = await write.value
        XCTAssertTrue(saved)
        XCTAssertEqual(session.status, .completed)
        XCTAssertNil(session.pendingChildChanges) // 未被旧回执清脏，仍走完整比较。
        XCTAssertEqual(try manager.restoreSession(sessionId: session.id)?.events.map(\.id), [first.id])
        let savedAgain = await manager.saveAsync(session: session)
        XCTAssertTrue(savedAgain)
        let restored = try XCTUnwrap(manager.restoreSession(sessionId: session.id))
        XCTAssertEqual(Set(restored.events.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(restored.status, .completed)
        XCTAssertEqual(session.pendingChildChanges?.events.count, 0)
    }

    func testContainerReplacementRejectsOldCommitAndReceipt() async throws {
        let gate = CommitGate(expectation(description: "old container commit"))
        let manager = try manager(beforeCommit: gate.waitOnce)
        let old = manager.modelContainer
        let session = AgentSession(id: "old-container", agentType: .codex)
        session.appendEvent(ToolEvent(tool: "Read"))
        let write = Task { await manager.saveAsync(session: session) }
        await fulfillment(of: [gate.entered], timeout: 3)
        let replacement = try self.manager()
        manager.modelContainer = replacement.modelContainer
        gate.release.signal()
        let saved = await write.value
        XCTAssertFalse(saved)
        XCTAssertEqual(manager.totalCount(), 0)
        let original = SessionPersistenceManager(); original.modelContainer = old
        XCTAssertEqual(original.totalCount(), 0)
        XCTAssertNil(session.pendingChildChanges)
    }

    func testObservationLossDuringSaveDoesNotResolvePendingOrphanApproval() async throws {
        let gate = CommitGate(expectation(description: "orphan merge commit"))
        let manager = try manager(beforeCommit: gate.waitOnce)
        let session = AgentSession(id: "kimi_code-lost-observation", agentType: .kimi)
        let request = try XCTUnwrap(KimiCodeApprovalObservation.Request(id: "request", agentID: "agent", turnID: "turn", toolCallID: "tool"))
        var orphan = KimiCodeApprovalObservation()
        orphan.observeRequest(request)
        XCTAssertTrue(manager.saveKimiCodeApprovalOrphan(sessionId: session.id, observation: orphan))
        let write = Task { await manager.saveAsync(session: session) }
        await fulfillment(of: [gate.entered], timeout: 3)
        session.status = .observationUnavailable
        gate.release.signal()
        let saved = await write.value
        XCTAssertTrue(saved)
        XCTAssertEqual(session.status, .observationUnavailable)
        XCTAssertEqual(session.kimiCodeApprovalObservation?.pending[request.id], request)
        XCTAssertNil(session.kimiCodeApprovalObservation?.resolved[request.id])
        let savedAgain = await manager.saveAsync(session: session)
        XCTAssertTrue(savedAgain)
        let restored = try XCTUnwrap(manager.restoreSession(sessionId: session.id))
        XCTAssertEqual(restored.status, .observationUnavailable)
        XCTAssertEqual(restored.kimiCodeApprovalObservation?.pending[request.id], request)
    }

    func testDeleteQueuedBehindSaveCannotBeUndoneByOlderWrite() async throws {
        let gate = CommitGate(expectation(description: "save commit"))
        let manager = try manager(beforeCommit: gate.waitOnce)
        let session = AgentSession(id: "ordered-delete", agentType: .codex)
        session.appendEvent(ToolEvent(tool: "Read"))
        let write = Task { await manager.saveAsync(session: session) }
        await fulfillment(of: [gate.entered], timeout: 3)
        let deletion = Task { try await manager.deleteHistoryAsync(sessionID: session.id) }
        while manager.pendingWriteCount < 2 { await Task.yield() }
        gate.release.signal()
        let saved = await write.value
        XCTAssertTrue(saved)
        try await deletion.value
        XCTAssertNil(try manager.restoreSession(sessionId: session.id))
        XCTAssertEqual(manager.pendingWriteCount, 0)
    }

    func testUnchangedBackgroundSavePreservesReadAndRevision() async throws {
        let manager = try manager(), session = AgentSession(id: "unchanged-background", agentType: .codex)
        let first = await manager.saveAsync(session: session)
        XCTAssertTrue(first)
        let revision = manager.revision
        let value: Int = try await manager.runHistoryJob { _, _ in
            let saved = await manager.saveAsync(session: session)
            XCTAssertTrue(saved)
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(manager.revision, revision)
    }

    func testSnapshotIsFrozenWhenCommandIsPrepared() async throws {
        let manager = try manager(), session = AgentSession(id: "frozen", agentType: .codex, prompt: "first")
        session.appendEvent(ToolEvent(tool: "Read"))
        let command = manager.makeSaveOperation(session: session)
        session.prompt = "second"
        session.appendEvent(ToolEvent(tool: "Write"))
        let saved = await command()
        XCTAssertTrue(saved)
        let restored = try XCTUnwrap(manager.restoreSession(sessionId: session.id))
        XCTAssertEqual(restored.prompt, "first")
        XCTAssertEqual(restored.events.count, 1)
        XCTAssertEqual(session.prompt, "second")
        XCTAssertEqual(session.events.count, 2)
    }

    func testCommitFailureDoesNotAcknowledgeChanges() async throws {
        let manager = try manager(beforeCommit: { throw CocoaError(.fileWriteNoPermission) })
        let session = AgentSession(id: "failure", agentType: .codex)
        session.appendEvent(ToolEvent(tool: "Read"))
        let saved = await manager.saveAsync(session: session)
        XCTAssertFalse(saved)
        XCTAssertNotNil(manager.lastSaveError)
        XCTAssertEqual(manager.totalCount(), 0)
        XCTAssertNil(session.pendingChildChanges)
        XCTAssertEqual(manager.pendingWriteCount, 0)
    }

    func testSerializedCommitInvalidationDoesNotBlockMainThread() async throws {
        let token = HistoryJobToken(serializedCommit: true)
        let entered = expectation(description: "committing")
        let release = DispatchSemaphore(value: 0)
        let worker = Task.detached {
            try token.withCommit {
                entered.fulfill()
                guard release.wait(timeout: .now() + 10) == .success else { throw CocoaError(.userCancelled) }
                return 42
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        token.invalidate() // 若仍把磁盘工作放在该锁内，此处会卡住，worker会超时失败。
        release.signal()
        let committed = try await worker.value
        XCTAssertEqual(committed, 42)
        XCTAssertThrowsError(try token.check())
    }
}
