import DIShared
import XCTest
@testable import DIBridge
@testable import XIsland

@MainActor
final class KimiCodeCompactionTests: XCTestCase {
    private func event(_ name: String, fields: [String: Any] = [:]) throws -> DIMessage {
        var payload: [String: Any] = ["hook_event_name": name, "session_id": "compact-fixture",
                                      "cwd": "/tmp/fixture", "client_type": "kimi_code_cli"]
        fields.forEach { payload[$0.key] = $0.value }
        return try KimiCodeHookAdapter.normalize(hookType: name, stdinData: payload)
    }

    private func compact(_ name: String, trigger: String) throws -> DIMessage {
        try event(name, fields: ["trigger": trigger,
            name == "PreCompact" ? "token_count" : "estimated_token_count": 100])
    }

    func testManualCompactionDoesNotInventAnotherRunningTurn() throws {
        let persistence = SessionPersistenceManager()
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        let manager = SessionManager()
        manager.persistenceManager = persistence
        manager.handleMessage(try event("SessionStart", fields: ["source": "startup"]))
        manager.handleMessage(try event("UserPromptSubmit", fields: [
            "prompt": [["type": "text", "text": "fixture prompt"]], "is_steer": false]))
        manager.handleMessage(try event("TurnStarted", fields: ["turn_id": 0, "origin_kind": "user"]))
        manager.handleMessage(try event("Stop", fields: ["stop_hook_active": false]))
        manager.handleMessage(try compact("PreCompact", trigger: "manual"))
        XCTAssertEqual(manager.sessions.first?.status, .compacting)
        let post = try compact("PostCompact", trigger: "manual")
        XCTAssertEqual(post.observedState, "completionUnconfirmed")
        manager.handleMessage(post)
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.status, .completionUnconfirmed)
        XCTAssertNil(session.completedAt)
        XCTAssertEqual(session.chatHistory.filter { $0.role == .user }.map(\.content), ["fixture prompt"])
        XCTAssertEqual(persistence.fetchHistory().first?.status, .completionUnconfirmed)
        XCTAssertNil(persistence.fetchHistory().first?.completedAt)
    }

    func testNativeCompactionWaitsForItsReceiptWhileLegacyKeepsItsFallback() async throws {
        let manager = SessionManager()
        manager.handleMessage(try compact("PreCompact", trigger: "auto"))
        let manual = SessionManager()
        manual.handleMessage(try compact("PreCompact", trigger: "manual"))
        let failed = SessionManager()
        failed.handleMessage(try compact("PreCompact", trigger: "manual"))
        failed.handleMessage(try event("StopFailure", fields: ["error_message": "Observed failure"]))
        let legacy = SessionManager()
        var legacyEvent = DIMessage(type: .contextCompact, sessionId: "kimi-legacy")
        legacyEvent.agentType = "kimi"
        legacyEvent.nativeEvent = "PreCompact"
        legacy.handleMessage(legacyEvent)
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertEqual(manager.sessions.first?.status, .compacting)
        XCTAssertEqual(manager.sessions.first?.kimiCodeApprovalObservation?.baseStatus, .compacting)
        XCTAssertEqual(manual.sessions.first?.status, .compacting)
        XCTAssertEqual(failed.sessions.first?.status, .error)
        XCTAssertEqual(legacy.sessions.first?.status, .active)
        manager.handleMessage(try compact("PostCompact", trigger: "auto"))
        XCTAssertEqual(manager.sessions.first?.status, .active)
        XCTAssertNil(manager.sessions.first?.completedAt)
        manual.handleMessage(try compact("PostCompact", trigger: "manual"))
        XCTAssertEqual(manual.sessions.first?.status, .completionUnconfirmed)
        failed.handleMessage(try compact("PostCompact", trigger: "manual"))
        XCTAssertEqual(failed.sessions.first?.status, .error)
    }

    func testManualCompactionCannotResolveAnObservedApproval() throws {
        let manager = SessionManager()
        let fields: [String: Any] = ["id": "approval-compact", "agent_id": "main", "turn_id": 0,
            "tool_call_id": "call-compact", "tool_name": "Bash", "action": "Run fixture",
            "display": [:], "tool_input": [:]]
        manager.handleMessage(try event("PermissionRequest", fields: fields))
        manager.handleMessage(try compact("PreCompact", trigger: "manual"))
        manager.handleMessage(try compact("PostCompact", trigger: "manual"))
        XCTAssertEqual(manager.sessions.first?.status, .waitingPermission)
        XCTAssertEqual(manager.sessions.first?.kimiCodeApprovalObservation?.baseStatus, .completionUnconfirmed)
        var result = fields
        result["decision"] = "rejected"
        manager.handleMessage(try event("PermissionResult", fields: result))
        XCTAssertEqual(manager.sessions.first?.status, .completionUnconfirmed)
        XCTAssertFalse(manager.hasInteraction)
    }
}
