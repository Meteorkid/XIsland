import XCTest
import DIShared
@testable import XIsland

@MainActor
final class PermissionQueueTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var values: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
        func record(_ value: String) {
            lock.lock(); defer { lock.unlock() }
            recorded.append(value)
        }
    }
    private func permission(_ sessionID: String, _ nativeID: String, tool: String = "Bash") -> DIMessage {
        var message = DIMessage(type: .permissionRequest, sessionId: sessionID)
        message.agentType = AgentType.claudeCode.rawValue
        message.tool = tool
        message.permDescription = "Run \(tool)"
        message.nativeRequestId = nativeID
        return message
    }

    func testSecondPermissionIsQueuedInsteadOfCancellingTheBlockingHook() throws {
        let manager = SessionManager()
        let cancellations = Recorder()
        manager.handlePermissionRequest(permission("queue", "first"),
                                        cancel: { cancellations.record("first") },
                                        respond: { _ in })
        manager.handlePermissionRequest(permission("queue", "second"),
                                        cancel: { cancellations.record("second") },
                                        respond: { _ in })

        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.pendingPermission?.nativeRequestId, "first")
        XCTAssertEqual(session.pendingPermissionQueue.map(\.nativeRequestId), ["second"])
        XCTAssertTrue(cancellations.values.isEmpty)
        XCTAssertEqual(session.pendingPermissionDepth, 2)
        XCTAssertEqual(session.status, .waitingPermission)
    }

    func testApprovingCurrentPermissionPromotesTheNextQueuedRequest() async throws {
        let manager = SessionManager()
        var approved: [String] = []
        manager.handlePermissionRequest(permission("queue", "first"),
                                        respond: { _ in approved.append("first") })
        manager.handlePermissionRequest(permission("queue", "second"),
                                        respond: { _ in approved.append("second") })

        let session = try XCTUnwrap(manager.sessions.first)
        let first = try XCTUnwrap(session.pendingPermission)
        manager.approvePermission(session: session, requestID: first.id)
        _ = await manager.drainPersistenceOperations()

        XCTAssertEqual(approved, ["first"])
        XCTAssertEqual(session.pendingPermission?.nativeRequestId, "second")
        XCTAssertTrue(session.pendingPermissionQueue.isEmpty)
        XCTAssertEqual(session.status, .waitingPermission)
        XCTAssertEqual(manager.focusedInteraction?.requestID, session.pendingPermission?.id)
    }

    func testNativeResolutionRemovesOnlyTheMatchingQueuedPermission() throws {
        let manager = SessionManager()
        let cancellations = Recorder()
        manager.handlePermissionRequest(permission("queue", "first"),
                                        cancel: { cancellations.record("first") },
                                        respond: { _ in })
        manager.handlePermissionRequest(permission("queue", "second"),
                                        cancel: { cancellations.record("second") },
                                        respond: { _ in })

        var resolved = DIMessage(type: .interactionResolved, sessionId: "queue")
        resolved.nativeRequestId = "second"
        resolved.nativeRequestKind = "permission"
        manager.handleMessage(resolved)

        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.pendingPermission?.nativeRequestId, "first")
        XCTAssertTrue(session.pendingPermissionQueue.isEmpty)
        XCTAssertEqual(cancellations.values, ["second"])
        XCTAssertEqual(session.status, .waitingPermission)
    }

    func testCursorPermissionCannotBeApprovedFromTheIsland() async throws {
        let manager = SessionManager()
        let deferred = expectation(description: "deferred to Cursor native prompt")
        var approvedCallbacks = 0

        var request = permission("cursor", "cursor-request")
        request.agentType = AgentType.cursor.rawValue
        manager.handlePermissionRequest(request, delivery: { decision in
            guard case .permissionDeferred = decision else { return false }
            deferred.fulfill()
            return true
        }, respond: { _ in approvedCallbacks += 1 })

        let session = try XCTUnwrap(manager.sessions.first)
        let pending = try XCTUnwrap(session.pendingPermission)
        XCTAssertFalse(pending.canApprove)

        manager.approvePermission(session: session, requestID: pending.id)
        XCTAssertEqual(approvedCallbacks, 0)
        XCTAssertEqual(pending.state.phase, .pending)

        manager.deferPermission(session: session, requestID: pending.id)
        await fulfillment(of: [deferred], timeout: 5)
        _ = await manager.drainPersistenceOperations()

        XCTAssertEqual(approvedCallbacks, 0)
        XCTAssertNil(session.pendingPermission)
        XCTAssertEqual(session.status, .active)
    }

    func testClaudeDenyCarriesReasonToDelivery() async throws {
        let manager = SessionManager()
        let reasons = Recorder()
        let delivered = expectation(description: "deny reason delivered")

        manager.handlePermissionRequest(permission("deny-reason", "request"),
                                        delivery: { decision in
            guard case .permissionDenial(let message) = decision else { return false }
            reasons.record(message)
            delivered.fulfill()
            return true
        }, respond: { _ in })

        let session = try XCTUnwrap(manager.sessions.first)
        let pending = try XCTUnwrap(session.pendingPermission)
        manager.denyPermission(session: session, requestID: pending.id,
                               message: "  Use rg instead  ")
        await fulfillment(of: [delivered], timeout: 5)
        _ = await manager.drainPersistenceOperations()

        XCTAssertEqual(reasons.values, ["Use rg instead"])
        XCTAssertNil(session.pendingPermission)
    }

    func testNonClaudeDenyReasonIsDroppedToPlainDenial() async throws {
        let manager = SessionManager()
        let decisionSeen = Recorder()
        let delivered = expectation(description: "plain denial delivered")

        var request = permission("trae-deny", "request")
        request.agentType = AgentType.trae.rawValue
        manager.handlePermissionRequest(request, delivery: { decision in
            switch decision {
            case .permission(false): decisionSeen.record("plain")
            case .permissionDenial: decisionSeen.record("with-message")
            default: return false
            }
            delivered.fulfill()
            return true
        }, respond: { _ in })

        let session = try XCTUnwrap(manager.sessions.first)
        let pending = try XCTUnwrap(session.pendingPermission)
        manager.denyPermission(session: session, requestID: pending.id,
                               message: "should not be forwarded")
        await fulfillment(of: [delivered], timeout: 5)
        _ = await manager.drainPersistenceOperations()

        XCTAssertEqual(decisionSeen.values, ["plain"])
    }

    func testClaudeEditedInputApprovesAndAuditsExecutedPayload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xisland-edited-input-audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ApprovalAuditStore(url: directory.appendingPathComponent("audit.jsonl"))
        let manager = SessionManager(approvalAuditStore: store)
        var request = permission("edited-input", "request")
        request.toolInput = #"{"command":"rm -rf build"}"#
        manager.handlePermissionRequest(request, cancel: {}, respond: { _ in })

        let session = try XCTUnwrap(manager.sessions.first)
        let pending = try XCTUnwrap(session.pendingPermission)
        let edited = #"{"command":"npm run lint"}"#
        XCTAssertTrue(manager.approvePermission(session: session, requestID: pending.id,
                                                updatedInput: edited))
        _ = await manager.drainPersistenceOperations()

        XCTAssertNil(session.pendingPermission)
        let record = try XCTUnwrap(store.records(sessionID: "edited-input").first)
        XCTAssertEqual(record.decision, .approved)
        XCTAssertEqual(record.payloadHash, ApprovalAuditStore.sha256(edited))
        XCTAssertNotEqual(record.payloadHash, ApprovalAuditStore.sha256(#"{"command":"rm -rf build"}"#))
    }

    func testInvalidEditedInputKeepsThePermissionPending() throws {
        let manager = SessionManager()
        manager.handlePermissionRequest(permission("invalid-edit", "request"), cancel: {}, respond: { _ in })

        let session = try XCTUnwrap(manager.sessions.first)
        let pending = try XCTUnwrap(session.pendingPermission)
        XCTAssertFalse(manager.approvePermission(session: session, requestID: pending.id,
                                                 updatedInput: "not-json"))
        XCTAssertEqual(pending.state.phase, .pending)
        XCTAssertNotNil(session.pendingPermission)
    }

    func testNonClaudeEditedInputIsRejected() throws {
        let manager = SessionManager()
        var request = permission("trae-edit", "request")
        request.agentType = AgentType.trae.rawValue
        manager.handlePermissionRequest(request, cancel: {}, respond: { _ in })

        let session = try XCTUnwrap(manager.sessions.first)
        let pending = try XCTUnwrap(session.pendingPermission)
        XCTAssertFalse(manager.approvePermission(session: session, requestID: pending.id,
                                                 updatedInput: #"{"command":"npm run lint"}"#))
        XCTAssertEqual(pending.state.phase, .pending)
    }

    func testEditedInputDeliveryReceivesEditedDecision() async throws {
        let manager = SessionManager()
        let delivered = expectation(description: "edited decision delivered")
        let recorder = Recorder()
        var request = permission("edited-delivery", "request")
        request.toolInput = #"{"command":"rm -rf build"}"#
        manager.handlePermissionRequest(request, delivery: { decision in
            if case .permissionEdited(let input) = decision {
                recorder.record(input)
            }
            delivered.fulfill()
            return true
        }, respond: { _ in })

        let session = try XCTUnwrap(manager.sessions.first)
        let pending = try XCTUnwrap(session.pendingPermission)
        XCTAssertTrue(manager.approvePermission(session: session, requestID: pending.id,
                                                updatedInput: #"{"command":"npm run lint"}"#))
        await fulfillment(of: [delivered], timeout: 5)
        _ = await manager.drainPersistenceOperations()

        XCTAssertEqual(recorder.values, [#"{"command":"npm run lint"}"#])
        XCTAssertNil(session.pendingPermission)
    }

    func testEditedInputRejectsNonObjectNulAndOversize() throws {
        let cases: [(String, String)] = [
            ("array", #"[1,2]"#),
            ("nul", "{\"command\":\"a\u{0}b\"}"),
            ("oversize", "{\"command\":\"\(String(repeating: "a", count: 70_000))\"}")
        ]
        for (id, input) in cases {
            let manager = SessionManager()
            var request = permission("edit-limits-\(id)", "request")
            request.toolInput = #"{"command":"ls"}"#
            manager.handlePermissionRequest(request, cancel: {}, respond: { _ in })
            let session = try XCTUnwrap(manager.sessions.first)
            let pending = try XCTUnwrap(session.pendingPermission)
            XCTAssertFalse(manager.approvePermission(session: session, requestID: pending.id,
                                                     updatedInput: input), id)
            XCTAssertNotNil(session.pendingPermission, id)
        }
    }

    func testClaudeInterruptDecisionIsDeliveredAndAuditedAsDenied() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xisland-interrupt-audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ApprovalAuditStore(url: directory.appendingPathComponent("audit.jsonl"))
        let manager = SessionManager(approvalAuditStore: store)
        let delivered = expectation(description: "interrupt decision delivered")
        let recorder = Recorder()
        var request = permission("interrupt-delivery", "request")
        request.toolInput = #"{"command":"rm -rf build"}"#
        manager.handlePermissionRequest(request, delivery: { decision in
            if case .permissionInterrupted(let message) = decision {
                recorder.record(message ?? "")
            }
            delivered.fulfill()
            return true
        }, respond: { _ in })

        let session = try XCTUnwrap(manager.sessions.first)
        let pending = try XCTUnwrap(session.pendingPermission)
        manager.denyPermission(session: session, requestID: pending.id,
                               message: "do not continue", interrupt: true)
        await fulfillment(of: [delivered], timeout: 5)
        _ = await manager.drainPersistenceOperations()

        XCTAssertEqual(recorder.values, ["do not continue"])
        XCTAssertNil(session.pendingPermission)
        let record = try XCTUnwrap(store.records(sessionID: "interrupt-delivery").first)
        XCTAssertEqual(record.decision, .denied)
    }

    func testNonClaudeInterruptIsRejectedInsteadOfDegrading() throws {
        let manager = SessionManager()
        let recorder = Recorder()
        var request = permission("trae-interrupt", "request")
        request.agentType = AgentType.trae.rawValue
        manager.handlePermissionRequest(request, cancel: {}, respond: { _ in
            recorder.record("responded")
        })

        let session = try XCTUnwrap(manager.sessions.first)
        let pending = try XCTUnwrap(session.pendingPermission)
        manager.denyPermission(session: session, requestID: pending.id, interrupt: true)

        XCTAssertTrue(recorder.values.isEmpty)
        XCTAssertEqual(pending.state.phase, .pending)
        XCTAssertNotNil(session.pendingPermission)
    }

    func testClaudeSessionRuleApprovesExactBashCommandAndAudits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xisland-session-rule-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ApprovalAuditStore(url: directory.appendingPathComponent("audit.jsonl"))
        let manager = SessionManager(approvalAuditStore: store)
        let delivered = expectation(description: "session rule delivered")
        let recorder = Recorder()
        var request = permission("session-rule", "request")
        request.toolInput = #"{"command":"npm test","description":"run tests"}"#
        manager.handlePermissionRequest(request, delivery: { decision in
            if case .permissionRemembered(let permissions) = decision {
                recorder.record(permissions)
            }
            delivered.fulfill()
            return true
        }, respond: { _ in })

        let session = try XCTUnwrap(manager.sessions.first)
        let pending = try XCTUnwrap(session.pendingPermission)
        XCTAssertTrue(manager.approvePermissionForSession(session: session, requestID: pending.id))
        await fulfillment(of: [delivered], timeout: 5)
        _ = await manager.drainPersistenceOperations()

        let permissions = try XCTUnwrap(recorder.values.first)
        let entries = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(permissions.utf8)) as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["type"] as? String, "addRules")
        XCTAssertEqual(entries[0]["behavior"] as? String, "allow")
        XCTAssertEqual(entries[0]["destination"] as? String, "session")
        let rules = try XCTUnwrap(entries[0]["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.first?["toolName"] as? String, "Bash")
        XCTAssertEqual(rules.first?["ruleContent"] as? String, "npm test")
        XCTAssertNil(session.pendingPermission)
        XCTAssertEqual(store.records(sessionID: "session-rule").first?.decision, .approved)
    }

    func testClaudeEditRequestCachesDiffPreview() throws {
        let manager = SessionManager()
        var request = permission("preview-request", "request", tool: "Edit")
        request.toolInput = #"{"file_path":"/tmp/Example.swift","old_string":"a","new_string":"b"}"#
        manager.handlePermissionRequest(request, cancel: {}, respond: { _ in })
        let session = try XCTUnwrap(manager.sessions.first)
        let pending = try XCTUnwrap(session.pendingPermission)
        XCTAssertEqual(pending.diffPreview?.kind, .edit)
        XCTAssertEqual(pending.diffPreview?.hunks.first?.oldLines, ["a"])
        XCTAssertEqual(pending.diffPreview?.hunks.first?.newLines, ["b"])
    }

    func testSessionRuleRejectsSubagentRequest() throws {        let manager = SessionManager()
        var request = permission("session-rule-child", "request")
        request.toolInput = #"{"command":"npm test"}"#
        request.nativeAgentId = "agent-child"
        manager.handlePermissionRequest(request, cancel: {}, respond: { _ in })
        let session = try XCTUnwrap(manager.sessions.first)
        let pending = try XCTUnwrap(session.pendingPermission)
        XCTAssertFalse(manager.approvePermissionForSession(session: session,
                                                          requestID: pending.id))
        XCTAssertNotNil(session.pendingPermission)
    }

    func testSessionRuleRejectsWildcardNonBashAndNonClaude() throws {
        let cases: [(String, String, String, String?)] = [
            ("wildcard", AgentType.claudeCode.rawValue, "Bash", #"{"command":"rm -rf *"}"#),
            ("non-bash", AgentType.claudeCode.rawValue, "Write", #"{"file_path":"/tmp/a"}"#),
            ("non-claude", AgentType.trae.rawValue, "Bash", #"{"command":"npm test"}"#),
            ("missing", AgentType.claudeCode.rawValue, "Bash", nil)
        ]
        for (id, agent, tool, input) in cases {
            let manager = SessionManager()
            var request = permission("session-rule-\(id)", "request", tool: tool)
            request.agentType = agent
            request.toolInput = input
            manager.handlePermissionRequest(request, cancel: {}, respond: { _ in })
            let session = try XCTUnwrap(manager.sessions.first)
            let pending = try XCTUnwrap(session.pendingPermission)
            XCTAssertFalse(manager.approvePermissionForSession(session: session,
                                                              requestID: pending.id), id)
            XCTAssertNotNil(session.pendingPermission, id)
        }
    }

    func testSubagentOriginIsPreservedOnTheParentSessionCard() throws {
        let manager = SessionManager()
        var request = permission("queue", "subagent-request")
        request.nativeAgentId = "agent-7"
        manager.handlePermissionRequest(request, respond: { _ in })

        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.pendingPermission?.originAgentID, "agent-7")
        // 请求仍属于父会话，不创建无法跳转的隐藏顶层会话。
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(session.pendingPermission?.nativeRequestId, "subagent-request")
    }

    func testDifferentSubagentsWithSameToolAreNotTreatedAsDuplicates() throws {
        let manager = SessionManager()
        var first = permission("queue", "same-native")
        first.nativeAgentId = "agent-a"
        var second = permission("queue", "same-native")
        second.nativeAgentId = "agent-b"
        manager.handlePermissionRequest(first, respond: { _ in })
        manager.handlePermissionRequest(second, respond: { _ in })

        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.pendingPermission?.originAgentID, "agent-a")
        XCTAssertEqual(session.pendingPermissionQueue.first?.originAgentID, "agent-b")
    }

    func testExpiredCurrentPermissionPromotesAnUnexpiredQueuedRequest() async throws {
        let manager = SessionManager()
        let cancellations = Recorder()
        manager.handlePermissionRequest(permission("queue", "first"),
                                        cancel: { cancellations.record("first") },
                                        respond: { _ in })
        manager.handlePermissionRequest(permission("queue", "second"),
                                        cancel: { cancellations.record("second") },
                                        respond: { _ in })

        let session = try XCTUnwrap(manager.sessions.first)
        session.pendingPermission?.expiresAt = Date(timeIntervalSinceNow: -1)
        session.pendingPermissionQueue[0].expiresAt = Date(timeIntervalSinceNow: 60)
        manager.cleanupStaleSessions()
        _ = await manager.drainPersistenceOperations()

        XCTAssertEqual(cancellations.values, ["first"])
        XCTAssertEqual(session.pendingPermission?.nativeRequestId, "second")
        XCTAssertTrue(session.pendingPermissionQueue.isEmpty)
        XCTAssertEqual(session.status, .waitingPermission)
    }

    func testExpiredQueuedPermissionIsCanceledWithoutTouchingTheCurrentRequest() async throws {
        let manager = SessionManager()
        let cancellations = Recorder()
        manager.handlePermissionRequest(permission("queue", "first"),
                                        cancel: { cancellations.record("first") },
                                        respond: { _ in })
        manager.handlePermissionRequest(permission("queue", "second"),
                                        cancel: { cancellations.record("second") },
                                        respond: { _ in })

        let session = try XCTUnwrap(manager.sessions.first)
        session.pendingPermission?.expiresAt = Date(timeIntervalSinceNow: 60)
        session.pendingPermissionQueue[0].expiresAt = Date(timeIntervalSinceNow: -1)
        manager.cleanupStaleSessions()
        _ = await manager.drainPersistenceOperations()

        XCTAssertEqual(cancellations.values, ["second"])
        XCTAssertEqual(session.pendingPermission?.nativeRequestId, "first")
        XCTAssertTrue(session.pendingPermissionQueue.isEmpty)
        XCTAssertEqual(session.status, .waitingPermission)
    }

    func testExpiredCurrentPermissionWithoutQueueClearsTheCard() async throws {
        let manager = SessionManager()
        let cancellations = Recorder()
        manager.handlePermissionRequest(permission("queue", "only"),
                                        cancel: { cancellations.record("only") },
                                        respond: { _ in })

        let session = try XCTUnwrap(manager.sessions.first)
        session.pendingPermission?.expiresAt = Date(timeIntervalSinceNow: -1)
        manager.cleanupStaleSessions()
        _ = await manager.drainPersistenceOperations()

        XCTAssertEqual(cancellations.values, ["only"])
        XCTAssertNil(session.pendingPermission)
        XCTAssertEqual(session.status, .active)
    }

    func testCancellingPendingInteractionsCancelsEveryQueuedHook() throws {
        let manager = SessionManager()
        let cancellations = Recorder()
        manager.handlePermissionRequest(permission("queue", "first"),
                                        cancel: { cancellations.record("first") },
                                        respond: { _ in })
        manager.handlePermissionRequest(permission("queue", "second"),
                                        cancel: { cancellations.record("second") },
                                        respond: { _ in })

        var end = DIMessage(type: .sessionEnd, sessionId: "queue")
        end.agentType = AgentType.claudeCode.rawValue
        end.status = "completed"
        manager.handleMessage(end)

        XCTAssertEqual(cancellations.values.sorted(), ["first", "second"])
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertNil(session.pendingPermission)
        XCTAssertTrue(session.pendingPermissionQueue.isEmpty)
    }
}
