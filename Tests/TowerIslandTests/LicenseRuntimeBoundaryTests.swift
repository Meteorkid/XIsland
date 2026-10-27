import AppKit
import DIShared
import Foundation
import XCTest
import os
@testable import XIsland

@MainActor
final class LicenseRuntimeBoundaryTests: XCTestCase {
    func testQueuedInteractionsAreCancelledWhenLicenseLocksBeforeReduction() async throws {
        try await assertQueuedInteractionsAreCancelled(bypass: false)
    }

    func testQueuedBypassCannotApproveOrAnswerAfterLicenseLocks() async throws {
        try await assertQueuedInteractionsAreCancelled(bypass: true)
    }

    private func assertQueuedInteractionsAreCancelled(bypass: Bool) async throws {
        XCTAssertTrue(AppPreferences.isIsolated)
        let previous = AppPreferences.defaults.object(forKey: "bypassMode")
        AppPreferences.defaults.set(bypass, forKey: "bypassMode")
        defer {
            if let previous { AppPreferences.defaults.set(previous, forKey: "bypassMode") }
            else { AppPreferences.defaults.removeObject(forKey: "bypassMode") }
        }
        let entered = expectation(description: "accepted session checkpoint suspended")
        let gate = LicenseCheckpointGate(entered: entered)
        defer { gate.release() }
        let persistence = SessionPersistenceManager(usesBackgroundWrites: true, beforeBackgroundCommit: { try gate.waitOnce() })
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        var start = DIMessage(type: .sessionStart, sessionId: "license-draining-interactions")
        start.agentType = "claude_code"
        start.statusIsAssistantReply = false
        start.prompt = "Preserve this accepted history"
        manager.handleMessage(start)
        await fulfillment(of: [entered], timeout: 5)

        let result = OSAllocatedUnfairLock(initialState: (cancelled: 0, responded: 0))
        var permission = DIMessage(type: .permissionRequest, sessionId: start.sessionId)
        permission.agentType = "claude_code"
        permission.tool = "Bash"
        permission.permDescription = "Requires consent"
        manager.handlePermissionRequest(permission, cancel: { result.withLock { $0.cancelled += 1 } }) { _ in
            result.withLock { $0.responded += 1 }
        }
        var question = DIMessage(type: .question, sessionId: start.sessionId)
        question.agentType = "claude_code"
        question.questionText = "Choose explicitly"
        question.options = ["Yes", "No"]
        manager.handleQuestionRequest(question, respond: { _ in result.withLock { $0.responded += 1 } },
            cancel: { result.withLock { $0.cancelled += 1 } })
        var plan = DIMessage(type: .planReview, sessionId: start.sessionId)
        plan.agentType = "claude_code"
        plan.planMarkdown = "Review this plan"
        manager.handlePlanReview(plan, cancel: { result.withLock { $0.cancelled += 1 } }) { _, _ in
            result.withLock { $0.responded += 1 }
        }

        manager.suspendForLicense()
        gate.release()
        let saved = await manager.drainPersistenceOperations()
        XCTAssertTrue(saved)
        XCTAssertEqual(result.withLock { $0.cancelled }, 3)
        XCTAssertEqual(result.withLock { $0.responded }, 0)
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertNil(session.pendingPermission)
        XCTAssertNil(session.pendingQuestion)
        XCTAssertNil(session.pendingPlanReview)
        XCTAssertEqual(try persistence.restoreSession(sessionId: start.sessionId)?.prompt, start.prompt)

        manager.resumeAcceptingPersistenceOperations()
        manager.handlePermissionRequest(permission, cancel: { result.withLock { $0.cancelled += 1 } }) { _ in
            result.withLock { $0.responded += 1 }
        }
        let resumed = await manager.drainPersistenceOperations()
        XCTAssertTrue(resumed)
        if bypass { XCTAssertEqual(result.withLock { $0.responded }, 1) }
        else { XCTAssertNotNil(session.pendingPermission) }
        manager.suspendForLicense()
    }
}

private final class LicenseCheckpointGate: @unchecked Sendable {
    private let entered: XCTestExpectation
    private let semaphore = DispatchSemaphore(value: 0)
    private let hasWaited = OSAllocatedUnfairLock(initialState: false)
    init(entered: XCTestExpectation) { self.entered = entered }
    func waitOnce() throws {
        let first = hasWaited.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
        guard first else { return }
        entered.fulfill()
        guard semaphore.wait(timeout: .now() + 5) == .success else { throw CocoaError(.userCancelled) }
    }
    func release() { semaphore.signal() }
}
