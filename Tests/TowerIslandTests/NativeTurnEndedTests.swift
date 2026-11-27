import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

@MainActor
final class NativeTurnEndedTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        var recorded: [String] { lock.lock(); defer { lock.unlock() }; return values }
        func record(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    }

    private func makeAuditManager() -> (SessionManager, ApprovalAuditStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xisland-turn-ended-\(UUID().uuidString)", isDirectory: true)
        let store = ApprovalAuditStore(url: directory.appendingPathComponent("audit.jsonl"))
        return (SessionManager(approvalAuditStore: store), store, directory)
    }

    private func permission(_ sessionID: String, _ nativeID: String,
                            agentID: String? = nil,
                            agentType: AgentType = .claudeCode) -> DIMessage {
        var message = DIMessage(type: .permissionRequest, sessionId: sessionID)
        message.agentType = agentType.rawValue
        message.tool = "Bash"
        message.permDescription = "Run Bash"
        message.nativeRequestId = nativeID
        message.nativeAgentId = agentID
        return message
    }

    private func stop(_ sessionID: String, agentID: String? = nil) -> DIMessage {
        var message = DIMessage(type: .statusUpdate, sessionId: sessionID)
        message.agentType = AgentType.claudeCode.rawValue
        message.nativeEvent = "Stop"
        message.nativeAgentId = agentID
        message.observedState = SessionStatus.completionUnconfirmed.rawValue
        message.statusIsAssistantReply = true
        return message
    }

    func testClaudeStopClearsNativePermissionAndWritesTurnEndedAudit() throws {
        let (manager, store, directory) = makeAuditManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cancelled = Recorder()
        manager.handlePermissionRequest(permission("turn-main", "native-1"),
                                        cancel: { cancelled.record("native-1") }, respond: { _ in })
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.status, .waitingPermission)

        manager.handleMessage(stop("turn-main"))

        XCTAssertNil(session.pendingPermission)
        XCTAssertEqual(cancelled.recorded, ["native-1"])
        XCTAssertEqual(session.status, .completionUnconfirmed)
        XCTAssertNil(session.currentTool)
        let record = try XCTUnwrap(store.records(sessionID: "turn-main").first)
        XCTAssertEqual(record.decision, .nativeTurnEnded)
        XCTAssertEqual(record.nativeRequestID, "native-1")
    }

    func testSubagentStopDoesNotClearMainPermission() throws {
        let (manager, store, directory) = makeAuditManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cancelled = Recorder()
        manager.handlePermissionRequest(permission("turn-agent", "main-1"),
                                        cancel: { cancelled.record("main-1") }, respond: { _ in })
        manager.handlePermissionRequest(permission("turn-agent", "child-1", agentID: "agent-7"),
                                        cancel: { cancelled.record("child-1") }, respond: { _ in })
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.pendingPermission?.nativeRequestId, "main-1")
        XCTAssertEqual(session.pendingPermissionQueue.map(\.nativeRequestId), ["child-1"])

        manager.handleMessage(stop("turn-agent", agentID: "agent-7"))

        XCTAssertEqual(session.pendingPermission?.nativeRequestId, "main-1")
        XCTAssertTrue(session.pendingPermissionQueue.isEmpty)
        XCTAssertEqual(cancelled.recorded, ["child-1"])
        XCTAssertEqual(session.status, .waitingPermission)
        XCTAssertEqual(store.records(sessionID: "turn-agent").first?.decision, .nativeTurnEnded)
        XCTAssertEqual(store.records(sessionID: "turn-agent").first?.originAgentID, "agent-7")
    }

    func testMainStopAfterSubagentStopClearsRemainingMainPermission() throws {
        let (manager, store, directory) = makeAuditManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        manager.handlePermissionRequest(permission("turn-two", "main-2"), cancel: {}, respond: { _ in })
        manager.handlePermissionRequest(permission("turn-two", "child-2", agentID: "agent-8"),
                                        cancel: {}, respond: { _ in })
        let session = try XCTUnwrap(manager.sessions.first)

        manager.handleMessage(stop("turn-two", agentID: "agent-8"))
        XCTAssertNotNil(session.pendingPermission)
        manager.handleMessage(stop("turn-two"))

        XCTAssertNil(session.pendingPermission)
        XCTAssertTrue(session.pendingPermissionQueue.isEmpty)
        XCTAssertEqual(session.status, .completionUnconfirmed)
        let decisions = store.records(sessionID: "turn-two").map(\.decision)
        XCTAssertEqual(decisions.prefix(2), [.nativeTurnEnded, .nativeTurnEnded])
    }

    func testSubagentStopClearsItsQueuedPermissionWithoutTouchingMain() throws {
        let manager = SessionManager()
        manager.handlePermissionRequest(permission("turn-sub-stop", "main-3"),
                                        cancel: {}, respond: { _ in })
        manager.handlePermissionRequest(permission("turn-sub-stop", "child-3", agentID: "agent-10"),
                                        cancel: {}, respond: { _ in })
        let session = try XCTUnwrap(manager.sessions.first)

        var subStop = DIMessage(type: .subagentEnd, sessionId: "turn-sub-stop")
        subStop.agentType = AgentType.claudeCode.rawValue
        subStop.nativeEvent = "SubagentStop"
        subStop.nativeAgentId = "agent-10"
        subStop.subagentId = "claude_code-agent-10"
        manager.handleMessage(subStop)

        XCTAssertEqual(session.pendingPermission?.nativeRequestId, "main-3")
        XCTAssertTrue(session.pendingPermissionQueue.isEmpty)
        XCTAssertEqual(session.status, .waitingPermission)
    }

    func testClaudeStopDoesNotClearCursorPermissionOnMirroredSession() throws {
        let manager = SessionManager()
        manager.handlePermissionRequest(permission("mirrored", "cursor-1", agentType: .cursor),
                                        cancel: {}, respond: { _ in })
        let session = try XCTUnwrap(manager.sessions.first)
        manager.handleMessage(stop("mirrored"))
        XCTAssertEqual(session.pendingPermission?.nativeRequestId, "cursor-1")
        XCTAssertEqual(session.status, .waitingPermission)
    }

    func testClaudeStopBridgeCarriesNativeEventAndSubagentIdentity() throws {
        let main = try DIBridge.makeMessage(
            agentType: "claude_code", hookType: "Stop", sessionId: "bridge-stop",
            stdinData: [
                "session_id": "bridge-stop", "hook_event_name": "Stop"
            ] as [String: Any]
        )
        XCTAssertEqual(main.nativeEvent, "Stop")
        XCTAssertEqual(main.observedState, SessionStatus.completionUnconfirmed.rawValue)
        XCTAssertNil(main.nativeAgentId)

        let child = try DIBridge.makeMessage(
            agentType: "claude_code", hookType: "Stop", sessionId: "bridge-stop",
            stdinData: [
                "session_id": "bridge-stop", "hook_event_name": "Stop", "agent_id": "agent-9"
            ] as [String: Any]
        )
        XCTAssertEqual(child.nativeAgentId, "agent-9")

        let subStop = try DIBridge.makeMessage(
            agentType: "claude_code", hookType: "SubagentStop", sessionId: "bridge-stop",
            stdinData: [
                "session_id": "bridge-stop", "hook_event_name": "SubagentStop",
                "agent_id": "agent-11", "agent_type": "reviewer"
            ] as [String: Any]
        )
        XCTAssertEqual(subStop.nativeAgentId, "agent-11")
        XCTAssertEqual(subStop.subagentId, "claude_code-agent-11")
    }
}
