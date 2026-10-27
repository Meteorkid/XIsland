import AppKit
import DIShared
import XCTest
import os
@testable import XIsland

@MainActor
final class LicenseRuntimeTests: XCTestCase {
    func testSuspendingLicensePreservesSessionsAndRejectsNewMessagesUntilResume() {
        let manager = SessionManager()
        var first = DIMessage(type: .sessionStart, sessionId: "licensed-existing")
        first.agentType = "codex"
        manager.handleMessage(first)
        XCTAssertEqual(manager.sessions.count, 1)
        manager.suspendForLicense()
        var second = DIMessage(type: .sessionStart, sessionId: "licensed-new")
        second.agentType = "codex"
        manager.handleMessage(second)
        XCTAssertEqual(manager.sessions.map(\.id), ["licensed-existing"])
        manager.resumeAcceptingPersistenceOperations()
        manager.handleMessage(second)
        XCTAssertEqual(manager.sessions.count, 2)
    }

    func testSuspendingLicenseCancelsPendingPermissionWithoutApprovingIt() throws {
        let manager = SessionManager()
        var first = DIMessage(type: .sessionStart, sessionId: "licensed-permission")
        first.agentType = "codex"
        manager.handleMessage(first)
        var permission = DIMessage(type: .permissionRequest, sessionId: first.sessionId)
        permission.agentType = "codex"
        permission.tool = "Bash"
        permission.permDescription = "An operation requiring user consent"
        let result = OSAllocatedUnfairLock(initialState: (cancelled: false, approved: false))
        manager.handlePermissionRequest(permission, cancel: { result.withLock { $0.cancelled = true } }) { approved in
            result.withLock { $0.approved = approved }
        }
        XCTAssertNotNil(manager.sessions.first?.pendingPermission)
        manager.suspendForLicense()
        XCTAssertTrue(result.withLock { $0.cancelled })
        XCTAssertFalse(result.withLock { $0.approved })
        XCTAssertNil(manager.sessions.first?.pendingPermission)
    }

    func testQuotaPollingDoesNotStartBeforeLicenseAdmission() {
        let tracker = QuotaTracker(startImmediately: false)
        XCTAssertFalse(tracker.isPolling)
        tracker.suspendPolling()
        tracker.fetchAll()
        XCTAssertFalse(tracker.isPolling)
        XCTAssertTrue(tracker.quotas.isEmpty)
    }
}
