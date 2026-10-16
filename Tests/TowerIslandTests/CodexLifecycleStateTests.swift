import DIShared
import XCTest
@testable import DIBridge
@testable import XIsland

@MainActor
final class CodexLifecycleStateTests: XCTestCase {
    private func event(_ name: String, turn: String = "turn-1", fields: [String: Any] = [:],
                       hookArgument: String? = nil) throws -> DIMessage {
        var payload: [String: Any] = ["hook_event_name": name, "session_id": "lifecycle",
                                      "cwd": "/tmp/codex-lifecycle", "turn_id": turn]
        if name == "PreCompact" || name == "PostCompact" { payload["trigger"] = "manual" }
        payload.merge(fields) { _, new in new }
        return try DIBridge.makeMessage(agentType: "codex", hookType: hookArgument ?? name,
                                       sessionId: "codex-lifecycle", stdinData: payload)
    }

    private func start(_ manager: SessionManager, turn: String = "turn-1") throws -> AgentSession {
        manager.handleMessage(try event("UserPromptSubmit", turn: turn, fields: ["prompt": "Review fixture"]))
        return try XCTUnwrap(manager.sessions.first)
    }

    func testExistingHooksPreserveNativeTurnIdentityIncludingLegacyArguments() throws {
        for (name, argument) in [("UserPromptSubmit", "session_start"), ("PreToolUse", "PreToolUse"),
                                 ("PostToolUse", "PostToolUse"), ("PermissionRequest", "PermissionRequest"),
                                 ("Stop", "notification"), ("SubagentStart", "subagent_start"),
                                 ("SubagentStop", "subagent_end")] {
            let message = try event(name, fields: ["tool_name": "Bash", "tool_input": ["command": "pwd"],
                "agent_id": "child", "agent_type": "reviewer"], hookArgument: argument)
            XCTAssertEqual(message.nativeEvent, name)
            XCTAssertEqual(message.nativeTurnId, "turn-1")
            XCTAssertNil(message.nativeTaskId)
            XCTAssertFalse(message.hasObservationMetadata)
        }
    }

    func testNativeCompactionAndInterruptHaveDistinctNonReplySemantics() throws {
        let pre = try event("PreCompact")
        XCTAssertEqual(pre.type, .contextCompact)
        XCTAssertEqual(pre.nativeEvent, "PreCompact")
        XCTAssertEqual(pre.nativeTurnId, "turn-1")
        XCTAssertEqual(pre.statusIsAssistantReply, false)
        for trigger in ["manual", "auto"] {
            let post = try event("PostCompact", fields: ["trigger": trigger])
            XCTAssertEqual(post.type, .statusUpdate)
            XCTAssertEqual(post.observedState, "completionUnconfirmed")
            XCTAssertEqual(post.statusIsAssistantReply, false)
        }
        let interrupted = try event("Interrupt", fields: ["permission_mode": "default"])
        XCTAssertEqual(interrupted.type, .statusUpdate)
        XCTAssertEqual(interrupted.observedState, "completionUnconfirmed")
        XCTAssertEqual(interrupted.statusIsAssistantReply, false)
        XCTAssertNil(interrupted.subagentId)
        XCTAssertNil(interrupted.nativeTaskId)
    }

    func testNewEventsRejectMissingOrMalformedIdentityAndUnknownTrigger() throws {
        for name in ["Interrupt", "PreCompact", "PostCompact"] {
            var valid: [String: Any] = ["hook_event_name": name, "session_id": "lifecycle",
                "cwd": "/tmp/codex-lifecycle", "turn_id": "turn-1", "trigger": "manual"]
            if name == "Interrupt" { valid.removeValue(forKey: "trigger") }
            for field in ["session_id", "turn_id"] {
                var missing = valid
                missing.removeValue(forKey: field)
                XCTAssertThrowsError(try DIBridge.makeMessage(agentType: "codex", hookType: name,
                    sessionId: "codex-lifecycle", stdinData: missing), "\(name): missing \(field)")
                for value: Any in ["", "  ", "bad\0identity", 7, NSNull(), String(repeating: "x", count: 4097)] {
                    var invalid = valid
                    invalid[field] = value
                    XCTAssertThrowsError(try DIBridge.makeMessage(agentType: "codex", hookType: name,
                        sessionId: "codex-lifecycle", stdinData: invalid), "\(name): invalid \(field)")
                }
            }
            if name != "Interrupt" {
                for value: Any in ["unknown", "", true, NSNull()] {
                    XCTAssertThrowsError(try event(name, fields: ["trigger": value]))
                }
                valid.removeValue(forKey: "trigger")
                XCTAssertThrowsError(try DIBridge.makeMessage(agentType: "codex", hookType: name,
                    sessionId: "codex-lifecycle", stdinData: valid))
            }
        }
    }

    func testCompactionReceiptDoesNotProveTurnCompletionOrCreateAnAssistantReply() throws {
        for trigger in ["manual", "auto"] {
            let manager = SessionManager()
            let session = try start(manager)
            manager.handleMessage(try event("Stop", fields: ["last_assistant_message": "Reply before compaction"]))
            let replies = session.chatHistory.filter { $0.role == .assistant }.map(\.content)
            manager.handleMessage(try event("PreCompact", fields: ["trigger": trigger]))
            XCTAssertEqual(session.status, .compacting)
            manager.handleMessage(try event("PostCompact", fields: ["trigger": trigger]))
            XCTAssertEqual(session.status, .completionUnconfirmed)
            XCTAssertNil(session.completedAt)
            XCTAssertEqual(session.agentResponse, "Reply before compaction")
            XCTAssertEqual(session.chatHistory.filter { $0.role == .assistant }.map(\.content), replies)
        }
    }

    func testNativeCompactionDoesNotResumeFromTheLegacyThreeSecondTimer() async throws {
        let manager = SessionManager()
        let session = try start(manager)
        manager.handleMessage(try event("PreCompact", fields: ["trigger": "auto"]))
        XCTAssertEqual(session.status, .compacting)
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertEqual(session.status, .compacting)
        XCTAssertNil(session.completedAt)
    }

    func testDelayedLifecycleEventsCannotOverrideNewTurnOrFinishItsChild() throws {
        let manager = SessionManager()
        let session = try start(manager)
        _ = try start(manager, turn: "turn-2")
        manager.handleMessage(try event("PreToolUse", turn: "turn-2", fields: [
            "tool_name": "Bash", "tool_use_id": "new-tool", "tool_input": ["command": "pwd"]]))
        manager.handleMessage(try event("SubagentStart", turn: "turn-2", fields: [
            "agent_id": "child", "agent_type": "reviewer"]))
        let currentTool = session.currentTool
        let activity = session.lastActivityTime
        for name in ["Interrupt", "PreCompact", "PostCompact"] {
            manager.handleMessage(try event(name))
            XCTAssertEqual(session.status, .active, name)
            XCTAssertEqual(session.currentTool, currentTool, name)
            XCTAssertEqual(session.lastActivityTime, activity, name)
            XCTAssertTrue(session.hasRunningSubagents, name)
            XCTAssertNil(session.completedAt, name)
        }
        manager.handleMessage(try event("Interrupt", turn: "turn-2"))
        XCTAssertEqual(session.status, .completionUnconfirmed)
        XCTAssertTrue(session.hasRunningSubagents)
        XCTAssertNil(session.completedAt)
    }

    func testLifecycleObservationsPreservePendingApprovalAndKnownError() throws {
        let manager = SessionManager()
        let session = try start(manager)
        manager.handlePermissionRequest(try event("PermissionRequest", fields: [
            "tool_name": "Bash", "tool_input": ["command": "pwd"]])) { _ in
            XCTFail("Lifecycle observation must not answer an approval")
        }
        let request = try XCTUnwrap(session.pendingPermission).id
        let waitingText = session.statusText
        for name in ["Interrupt", "PreCompact", "PostCompact"] {
            manager.handleMessage(try event(name))
            XCTAssertEqual(session.status, .waitingPermission, name)
            XCTAssertEqual(session.pendingPermission?.id, request, name)
            XCTAssertEqual(session.statusText, waitingText, name)
        }
        let errorManager = SessionManager()
        let failed = try start(errorManager)
        failed.status = .error
        failed.statusText = "Known failure"
        for name in ["Interrupt", "PreCompact", "PostCompact"] {
            errorManager.handleMessage(try event(name))
            XCTAssertEqual(failed.status, .error, name)
            XCTAssertEqual(failed.statusText, "Known failure", name)
        }
    }

    func testToolAndApprovalCanSeedCurrentTurnWithoutOverwritingKnownTurn() throws {
        for seed in ["PreToolUse", "PermissionRequest"] {
            let manager = SessionManager()
            let first = try event(seed, fields: ["tool_name": "Bash", "tool_input": ["command": "pwd"]])
            if seed == "PermissionRequest" {
                manager.handlePermissionRequest(first) { _ in }
                let session = try XCTUnwrap(manager.sessions.first)
                manager.denyPermission(session: session)
            } else {
                manager.handleMessage(first)
            }
            let session = try XCTUnwrap(manager.sessions.first)
            manager.handleMessage(try event("PreCompact"))
            XCTAssertEqual(session.status, .compacting, seed)
            _ = try start(manager, turn: "turn-2")
            manager.handleMessage(try event("PostToolUse", fields: ["tool_name": "Bash", "tool_use_id": "old-tool",
                "tool_input": ["command": "pwd"], "tool_response": "old output"]))
            let state = session.status
            manager.handleMessage(try event("Interrupt"))
            XCTAssertEqual(session.status, state, seed)
            manager.handleMessage(try event("Interrupt", turn: "turn-2"))
            XCTAssertEqual(session.status, .completionUnconfirmed, seed)
        }
    }

    func testUnknownAndClosedSessionsAreNotReopenedByLifecycleObservations() throws {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        for name in ["Interrupt", "PreCompact", "PostCompact"] {
            manager.handleMessage(try event(name))
            XCTAssertTrue(manager.sessions.isEmpty, name)
        }
        let session = try start(manager)
        manager.handleMessage(try event("SessionEnd", fields: ["reason": "other"]))
        let ended = try XCTUnwrap(session.completedAt)
        for name in ["Interrupt", "PreCompact", "PostCompact"] {
            manager.handleMessage(try event(name))
            XCTAssertEqual(session.status, .completed, name)
            XCTAssertEqual(session.completedAt, ended, name)
        }
        manager.dismissSession(session)
        XCTAssertTrue(manager.sessions.isEmpty)
        for name in ["Interrupt", "PreCompact", "PostCompact"] {
            manager.handleMessage(try event(name))
            XCTAssertTrue(manager.sessions.isEmpty, name)
            XCTAssertEqual(persistence.fetchHistory().first?.status, .completed, name)
            XCTAssertEqual(persistence.fetchHistory().first?.completedAt, ended, name)
        }
    }

    func testCompactSessionStartDoesNotEraseObservedTurnIdentity() throws {
        let manager = SessionManager()
        let session = try start(manager)
        manager.handleMessage(try event("PreCompact"))
        manager.handleMessage(try event("PostCompact"))
        // SessionStart 的官方输入不含 turn_id；compact 来源不能抹掉刚观测到的回合。
        let compactStart = try DIBridge.makeMessage(agentType: "codex", hookType: "session_start",
            sessionId: session.id, stdinData: ["session_id": "lifecycle", "hook_event_name": "SessionStart",
                                               "source": "compact", "cwd": "/tmp/codex-lifecycle"])
        manager.handleMessage(compactStart)
        manager.handleMessage(try event("Interrupt"))
        XCTAssertEqual(session.status, .completionUnconfirmed)
        XCTAssertNil(session.completedAt)
    }

    func testRestoredHistoryDoesNotInventPersistedTurnIdentity() throws {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let original = SessionManager()
        original.persistenceManager = persistence
        let session = try start(original)
        original.dismissSession(session)

        let restarted = SessionManager()
        restarted.persistenceManager = persistence
        restarted.handleMessage(try DIBridge.makeMessage(agentType: "codex", hookType: "session_start",
            sessionId: session.id, stdinData: ["session_id": "lifecycle", "hook_event_name": "SessionStart",
                                               "source": "resume", "cwd": "/tmp/codex-lifecycle"]))
        let restored = try XCTUnwrap(restarted.sessions.first)
        for name in ["Interrupt", "PostCompact"] {
            restarted.handleMessage(try event(name))
            XCTAssertEqual(restored.status, .active, name)
        }
        // PreCompact 本身证明压缩开始，官方合同不要求它之前必须有 UserPromptSubmit。
        restarted.handleMessage(try event("PreCompact", turn: "turn-2"))
        XCTAssertEqual(restored.status, .compacting)
        restarted.handleMessage(try event("PostCompact", turn: "turn-2"))
        XCTAssertEqual(restored.status, .completionUnconfirmed)
        XCTAssertEqual(restored.chatHistory.filter { $0.role == .user }.count, 1)
    }

    func testFreshCompactionTurnNeedsNoSyntheticUserPromptAndCannotReturnToKnownOldTurn() throws {
        let manager = SessionManager()
        let session = try start(manager)
        manager.handleMessage(try event("Stop"))
        manager.handleMessage(try event("PreCompact", turn: "manual-compact-turn"))
        XCTAssertEqual(session.status, .compacting)
        manager.handleMessage(try event("PostCompact", turn: "manual-compact-turn"))
        XCTAssertEqual(session.status, .completionUnconfirmed)
        for name in ["PreCompact", "Interrupt", "PostCompact", "UserPromptSubmit"] {
            manager.handleMessage(try event(name, fields: ["prompt": "Stale prompt"]))
            XCTAssertEqual(session.status, .completionUnconfirmed, name)
        }
        XCTAssertEqual(session.chatHistory.filter { $0.role == .user }.map(\.content), ["Review fixture"])
    }

    func testAcceptedPromptAndCompactionStartImmediatelyPersistTheirState() throws {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        _ = try start(manager)
        XCTAssertEqual(persistence.fetchHistory().first?.status, .active)
        manager.handleMessage(try event("PreCompact", turn: "manual-compact-turn"))
        XCTAssertEqual(persistence.fetchHistory().first?.status, .compacting)
        XCTAssertNil(persistence.fetchHistory().first?.completedAt)
    }

    func testHiddenSessionResumeKeepsKnownOldTurnsWithinTheSameApp() throws {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        let session = try start(manager)
        _ = try start(manager, turn: "turn-2")
        manager.dismissSession(session)
        XCTAssertTrue(manager.sessions.isEmpty)
        manager.handleMessage(try event("UserPromptSubmit", fields: ["prompt": "Hidden stale prompt"]))
        XCTAssertTrue(manager.sessions.isEmpty)
        manager.handleMessage(try DIBridge.makeMessage(agentType: "codex", hookType: "session_start",
            sessionId: session.id, stdinData: ["session_id": "lifecycle", "hook_event_name": "SessionStart",
                                               "source": "resume", "cwd": "/tmp/codex-lifecycle"]))
        let resumed = try XCTUnwrap(manager.sessions.first)
        for name in ["PreCompact", "Interrupt", "PostCompact", "UserPromptSubmit"] {
            manager.handleMessage(try event(name, fields: ["prompt": "Stale prompt"]))
            XCTAssertEqual(resumed.status, .active, name)
        }
        XCTAssertEqual(resumed.chatHistory.filter { $0.role == .user }.count, 2)
        manager.handleMessage(try event("Interrupt", turn: "turn-2"))
        XCTAssertEqual(resumed.status, .completionUnconfirmed)
    }
}
