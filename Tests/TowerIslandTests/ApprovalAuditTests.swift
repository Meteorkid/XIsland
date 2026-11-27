import XCTest
import DIShared
@testable import XIsland

@MainActor
final class ApprovalAuditStoreTests: XCTestCase {
    private func makeStore() -> (ApprovalAuditStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xisland-approval-audit-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("audit.jsonl")
        return (ApprovalAuditStore(url: url), url)
    }

    func testAppendCreatesHashChainAndDoesNotStoreRawToolInput() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let secretCommand = "rm -rf /tmp/xisland-audit-secret"

        let first = try XCTUnwrap(store.append(
            sessionID: "s1", agentType: "claudeCode", tool: "Bash",
            originAgentID: nil, nativeRequestID: "n1", decision: .approved,
            latencyMilliseconds: 42, toolInput: secretCommand))
        let second = try XCTUnwrap(store.append(
            sessionID: "s1", agentType: "claudeCode", tool: "Edit",
            originAgentID: "agent-7", nativeRequestID: "n2", decision: .denied,
            latencyMilliseconds: 9, toolInput: "file contents"))

        XCTAssertEqual(first.previousHash, "")
        XCTAssertEqual(second.previousHash, first.hash)
        XCTAssertEqual(ApprovalAuditStore.hash(first), first.hash)
        XCTAssertEqual(ApprovalAuditStore.hash(second), second.hash)
        XCTAssertEqual(first.payloadHash, ApprovalAuditStore.sha256(secretCommand))
        XCTAssertEqual(second.originAgentID, "agent-7")
        XCTAssertEqual(second.decision, .denied)

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains(secretCommand), "audit file must not copy raw tool input")
        XCTAssertFalse(raw.contains("file contents"))
    }

    func testReopeningStoreContinuesTheChain() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try XCTUnwrap(store.append(
            sessionID: "s1", agentType: "claudeCode", tool: "Bash",
            originAgentID: nil, nativeRequestID: "n1", decision: .approved,
            latencyMilliseconds: 1, toolInput: nil))
        let reopened = ApprovalAuditStore(url: url)
        let second = try XCTUnwrap(reopened.append(
            sessionID: "s1", agentType: "claudeCode", tool: "Bash",
            originAgentID: nil, nativeRequestID: "n2", decision: .denied,
            latencyMilliseconds: 2, toolInput: nil))
        XCTAssertEqual(second.previousHash, first.hash)
    }

    func testRecordsFilterBySessionAndReturnNewestFirst() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = store.append(sessionID: "s1", agentType: "claudeCode", tool: "Bash",
                         originAgentID: nil, nativeRequestID: "n1", decision: .approved,
                         latencyMilliseconds: 1, toolInput: nil)
        _ = store.append(sessionID: "s2", agentType: "codex", tool: "Read",
                         originAgentID: nil, nativeRequestID: "n2", decision: .denied,
                         latencyMilliseconds: 2, toolInput: nil)
        _ = store.append(sessionID: "s1", agentType: "claudeCode", tool: "Bash",
                         originAgentID: nil, nativeRequestID: "n3", decision: .cancelled,
                         latencyMilliseconds: 3, toolInput: nil)

        let records = store.records(sessionID: "s1", limit: 2)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.nativeRequestID, "n3")
        XCTAssertEqual(records.last?.nativeRequestID, "n1")
    }

    func testExpiredPermissionIsRecordedAsExpired() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = SessionManager(approvalAuditStore: store)
        var message = DIMessage(type: .permissionRequest, sessionId: "expired-session")
        message.agentType = AgentType.claudeCode.rawValue
        message.tool = "Bash"
        message.nativeRequestId = "native-expired"
        manager.handlePermissionRequest(message, cancel: {}, respond: { _ in })

        let session = try XCTUnwrap(manager.sessions.first)
        session.pendingPermission?.expiresAt = Date(timeIntervalSinceNow: -1)
        manager.cleanupStaleSessions()
        _ = await manager.drainPersistenceOperations()

        XCTAssertNil(session.pendingPermission)
        let records = store.records(sessionID: "expired-session")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.decision, .expired)
        XCTAssertEqual(records.first?.nativeRequestID, "native-expired")
    }

    func testNativeResolutionIsRecordedWithoutInventingAllowOrDeny() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = SessionManager(approvalAuditStore: store)
        var message = DIMessage(type: .permissionRequest, sessionId: "native-session")
        message.agentType = AgentType.codex.rawValue
        message.tool = "Shell"
        message.nativeRequestId = "native-resolution"
        manager.handlePermissionRequest(message, cancel: {}, respond: { _ in })

        var resolved = DIMessage(type: .interactionResolved, sessionId: "native-session")
        resolved.nativeRequestId = "native-resolution"
        resolved.nativeRequestKind = "permission"
        manager.handleMessage(resolved)

        let records = store.records(sessionID: "native-session")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.decision, .nativeResolved)
        XCTAssertNotEqual(records.first?.decision, .approved)
        XCTAssertNotEqual(records.first?.decision, .denied)
    }

    func testApprovingPermissionWritesADecisionRecord() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = SessionManager(approvalAuditStore: store)
        var message = DIMessage(type: .permissionRequest, sessionId: "audit-session")
        message.agentType = AgentType.claudeCode.rawValue
        message.tool = "Bash"
        message.permDescription = "Run a command"
        message.nativeRequestId = "native-1"
        manager.handlePermissionRequest(message, cancel: {}, respond: { _ in })

        let session = try XCTUnwrap(manager.sessions.first)
        let pending = try XCTUnwrap(session.pendingPermission)
        manager.approvePermission(session: session, requestID: pending.id)
        _ = await manager.drainPersistenceOperations()

        let records = store.records(sessionID: "audit-session")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.decision, .approved)
        XCTAssertEqual(records.first?.nativeRequestID, "native-1")
        XCTAssertEqual(records.first?.agentType, AgentType.claudeCode.rawValue)
        XCTAssertEqual(manager.approvalAuditRecords(for: session).first?.decision, .approved)
    }

    func testDenyWithReasonRecordsDeniedButDoesNotStoreReasonText() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = SessionManager(approvalAuditStore: store)
        var message = DIMessage(type: .permissionRequest, sessionId: "deny-audit")
        message.agentType = AgentType.claudeCode.rawValue
        message.tool = "Bash"
        message.permDescription = "Run a command"
        message.nativeRequestId = "native-deny"
        message.toolInput = "{\"command\":\"rm -rf build\"}"
        manager.handlePermissionRequest(message, cancel: {}, respond: { _ in })

        let session = try XCTUnwrap(manager.sessions.first)
        let pending = try XCTUnwrap(session.pendingPermission)
        manager.denyPermission(session: session, requestID: pending.id,
                               message: "Do not delete the build directory")
        _ = await manager.drainPersistenceOperations()

        let records = store.records(sessionID: "deny-audit")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.decision, .denied)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("Do not delete the build directory"))
        XCTAssertFalse(raw.contains("rm -rf build"))
    }

    func testVerifyAcceptsAnIntactChainAndExportsRawJSONL() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = store.append(sessionID: "s1", agentType: "claudeCode", tool: "Bash",
                         originAgentID: nil, nativeRequestID: "n1", decision: .approved,
                         latencyMilliseconds: 1, toolInput: "echo ok")
        _ = store.append(sessionID: "s1", agentType: "claudeCode", tool: "Edit",
                         originAgentID: nil, nativeRequestID: "n2", decision: .denied,
                         latencyMilliseconds: 2, toolInput: "file")

        let verification = store.verify()
        XCTAssertEqual(verification.state, .valid)
        XCTAssertEqual(verification.recordCount, 2)

        let exportURL = url.deletingLastPathComponent().appendingPathComponent("export.jsonl")
        try store.export(to: exportURL)
        XCTAssertEqual(try String(contentsOf: exportURL, encoding: .utf8),
                       try String(contentsOf: url, encoding: .utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: exportURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testVerifyDetectsTamperedDecision() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = store.append(sessionID: "s1", agentType: "claudeCode", tool: "Bash",
                         originAgentID: nil, nativeRequestID: "n1", decision: .approved,
                         latencyMilliseconds: 1, toolInput: nil)
        let original = try String(contentsOf: url, encoding: .utf8)
        try original.replacingOccurrences(of: "\"decision\":\"approved\"",
                                          with: "\"decision\":\"denied\"")
            .write(to: url, atomically: true, encoding: .utf8)

        let verification = store.verify()
        XCTAssertEqual(verification.state, .broken)
        XCTAssertEqual(verification.brokenLine, 1)
        XCTAssertEqual(verification.reason, "record hash mismatch")
    }

    func testVerifyRejectsDeletedPrefixInsteadOfTreatingItAsComplete() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = store.append(sessionID: "s1", agentType: "claudeCode", tool: "Bash",
                         originAgentID: nil, nativeRequestID: "n1", decision: .approved,
                         latencyMilliseconds: 1, toolInput: nil)
        _ = store.append(sessionID: "s1", agentType: "claudeCode", tool: "Edit",
                         originAgentID: "agent-7", nativeRequestID: "n2", decision: .denied,
                         latencyMilliseconds: 2, toolInput: nil)
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        try (lines.last.map(String.init) ?? "").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)

        let verification = store.verify()
        XCTAssertEqual(verification.state, .broken)
        XCTAssertEqual(verification.brokenLine, 1)
        XCTAssertEqual(verification.reason, "missing predecessor")
    }
}
