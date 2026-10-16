import XCTest
import DIShared
@testable import XIsland

@MainActor
final class ObservationLeaseTests: XCTestCase {
    private let namespace = String(repeating: "a", count: 24)
    private let windowA = "00000000-0000-4000-8000-000000000001"
    private let windowB = "00000000-0000-4000-8000-000000000002"
    private var wall = Date()

    private func message(_ type: DIMessageType = .sessionStart, instance: String? = nil,
                         sequence: Int = 1, task: String = "任务🙂") -> DIMessage {
        var message = DIMessage(type: type, sessionId: "")
        message.agentType = "roo_code"
        message.sourceNamespace = namespace
        message.sourceInstanceId = instance ?? windowA
        message.observationSequence = sequence
        message.timestamp = wall
        message.statusIsAssistantReply = false
        let source = ObservationSource(message: message)!
        if type == .observationHeartbeat || type == .observationEnded {
            message.sessionId = source.id
        } else {
            message.nativeTaskId = task
            message.sessionId = source.sessionID(task: task)
        }
        return message
    }

    func testTwoWindowsKeepNativeTaskButNeverShareActiveOrHistoricalIdentity() throws {
        let manager = SessionManager(observationWallClock: { self.wall })
        let first = message(), second = message(instance: windowB)
        manager.handleMessage(first); manager.handleMessage(second)
        XCTAssertNotEqual(first.sessionId, second.sessionId)
        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertEqual(Set(manager.sessions.compactMap(\.nativeTaskId)), ["任务🙂"])
        manager.handleMessage(message(.observationEnded, sequence: 2))
        let a = try XCTUnwrap(manager.sessions.first { $0.id == first.sessionId })
        let b = try XCTUnwrap(manager.sessions.first { $0.id == second.sessionId })
        XCTAssertEqual(a.status, .observationUnavailable)
        XCTAssertNil(a.completedAt)
        XCTAssertNotNil(a.observationEndedAt)
        XCTAssertEqual(b.status, .active)
        XCTAssertEqual(manager.activeSessions.map(\.id), [b.id])
        XCTAssertEqual(manager.trulyActiveSessions.map(\.id), [b.id])
    }

    func testHeartbeatDoesNotCreateTaskOrChangeActivityAndOnlyFreshBusinessRestoresState() throws {
        var time: TimeInterval = 0
        let manager = SessionManager(observationClock: { time }, observationWallClock: { self.wall })
        manager.handleMessage(message(.observationHeartbeat))
        XCTAssertTrue(manager.sessions.isEmpty)
        manager.handleMessage(message(sequence: 2))
        let session = try XCTUnwrap(manager.sessions.first)
        let activity = Date(timeIntervalSince1970: 10)
        session.lastActivityTime = activity
        time = 20
        manager.handleMessage(message(.observationHeartbeat, sequence: 3))
        manager.cleanupStaleSessions()
        XCTAssertEqual(session.lastActivityTime, activity)
        XCTAssertEqual(session.status, .active, "传统120秒超时不能结束仍在观察的任务")
        time = 51
        manager.expireObservationSources()
        XCTAssertEqual(session.status, .observationUnavailable)
        XCTAssertNil(session.completedAt)
        manager.handleMessage(message(.observationHeartbeat, sequence: 4))
        XCTAssertEqual(session.status, .observationUnavailable)
        XCTAssertEqual(session.lastActivityTime, activity)
        var event = message(.statusUpdate, sequence: 5)
        event.status = "late preview"
        manager.handleMessage(event)
        XCTAssertEqual(session.status, .observationUnavailable)
        event.observationSequence = 6; event.observedState = "active"
        manager.handleMessage(event)
        XCTAssertEqual(session.status, .active)
        XCTAssertNil(session.observationEndedAt)
    }

    func testHeartbeatAfterUnobservedGapDoesNotConcealLeaseExpiry() throws {
        var time: TimeInterval = 0
        let manager = SessionManager(observationClock: { time }, observationWallClock: { self.wall })
        manager.handleMessage(message())
        time = 31
        manager.handleMessage(message(.observationHeartbeat, sequence: 2))
        XCTAssertEqual(manager.sessions.first?.status, .observationUnavailable)
    }

    func testEndedSourceRejectsLateFramesAndReloadUsesNewInstance() throws {
        let manager = SessionManager(observationWallClock: { self.wall })
        manager.handleMessage(message())
        manager.handleMessage(message(.observationEnded, sequence: 2))
        let session = try XCTUnwrap(manager.sessions.first)
        let ended = session.observationEndedAt
        manager.handleMessage(message(sequence: 3))
        manager.handleMessage(message(.observationHeartbeat, sequence: 4))
        manager.handleMessage(message(.observationEnded, sequence: 5))
        XCTAssertEqual(session.status, .observationUnavailable)
        XCTAssertEqual(session.observationEndedAt, ended)
        manager.handleMessage(message(instance: windowB))
        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertEqual(manager.sessions.last?.status, .active)
        XCTAssertEqual(manager.sessions.last?.nativeTaskId, session.nativeTaskId)
    }

    func testSequenceRejectsDuplicateAndOutOfOrderState() throws {
        let manager = SessionManager(observationWallClock: { self.wall })
        manager.handleMessage(message(sequence: 10))
        for sequence in [9, 10] {
            var stale = message(.statusUpdate, sequence: sequence)
            stale.observedState = "idle"
            manager.handleMessage(stale)
        }
        XCTAssertEqual(manager.sessions.first?.status, .active)
        var fresh = message(.statusUpdate, sequence: 11)
        fresh.observedState = "idle"
        manager.handleMessage(fresh)
        XCTAssertEqual(manager.sessions.first?.status, .idle)
    }

    func testExpiredMalformedAndMismatchedEnvelopesCannotCreateTask() {
        let manager = SessionManager(observationWallClock: { self.wall })
        var variants: [DIMessage] = []
        var input = message(); input.timestamp = wall.addingTimeInterval(-31); variants.append(input)
        input = message(); input.timestamp = wall.addingTimeInterval(6); variants.append(input)
        input = message(); input.sourceNamespace = "invalid"; variants.append(input)
        input = message(); input.sourceInstanceId = "not-uuid"; variants.append(input)
        input = message(); input.nativeTaskId = "different"; variants.append(input)
        input = message(); input.sessionId = "roo_code-someone-else"; variants.append(input)
        input = message(); input.observationSequence = 0; variants.append(input)
        input = message(); input.observationSequence = 9_007_199_254_740_992; variants.append(input)
        input = message(); input.agentType = "claude_code"; variants.append(input)
        input = message(); input.sourceNamespace = nil; variants.append(input)
        input = message(.observationHeartbeat); input.timestamp = wall.addingTimeInterval(-6); variants.append(input)
        input = message(.observationEnded); input.nativeTaskId = "task"; variants.append(input)
        for variant in variants { manager.handleMessage(variant) }
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    func testNativeUsageAloneDoesNotProveTaskIsRunning() {
        let manager = SessionManager(observationWallClock: { self.wall })
        var usage = message(.statusUpdate)
        usage.tokensIn = 100; usage.usageIsCumulative = true
        manager.handleMessage(usage)
        XCTAssertEqual(manager.sessions.first?.status, .observationUnavailable)
        XCTAssertTrue(manager.trulyActiveSessions.isEmpty)
    }

    func testObservationsCannotCreateActionableInteractionsOrLegacyCompletion() throws {
        let manager = SessionManager(observationWallClock: { self.wall })
        manager.handleMessage(message())
        let session = try XCTUnwrap(manager.sessions.first)
        var request = message(.question, sequence: 2)
        request.questionText = "Continue?"; request.options = ["Yes"]
        manager.handleQuestionRequest(request, respond: { _ in XCTFail("Observation answered a request") })
        manager.handlePermissionRequest(request, respond: { _ in XCTFail("Observation approved a request") })
        manager.handlePlanReview(request, respond: { _, _ in XCTFail("Observation approved a plan") })
        XCTAssertFalse(session.hasPendingInteraction)
        var legacy = DIMessage(type: .sessionEnd, sessionId: session.id)
        legacy.agentType = "roo_code"; legacy.observedState = "completed"
        manager.handleMessage(legacy)
        manager.handleMessage(message(.sessionEnd, sequence: 3))
        XCTAssertEqual(session.status, .active)
        XCTAssertNil(session.completedAt)
    }

    func testSubagentCannotAttachToAnotherWindow() throws {
        let manager = SessionManager(observationWallClock: { self.wall })
        let a = message(), b = message(instance: windowB)
        manager.handleMessage(a); manager.handleMessage(b)
        var spawned = message(.subagentStart, sequence: 2)
        spawned.parentSessionId = b.sessionId
        spawned.subagentId = ObservationSource(message: b)!.sessionID(task: "child")
        manager.handleMessage(spawned)
        XCTAssertTrue(manager.sessions.allSatisfy { $0.subagentIds.isEmpty })
        spawned.parentSessionId = a.sessionId
        spawned.subagentId = ObservationSource(message: a)!.sessionID(task: "child")
        manager.handleMessage(spawned)
        XCTAssertEqual(manager.sessions.first?.subagentIds, [spawned.subagentId!])
        XCTAssertTrue(manager.sessions.last?.subagentIds.isEmpty == true)
        var legacy = DIMessage(type: .subagentStart, sessionId: "claude_code-other")
        legacy.agentType = "claude_code"
        legacy.parentSessionId = a.sessionId; legacy.subagentId = "foreign"
        manager.handleMessage(legacy)
        XCTAssertEqual(manager.sessions.first?.subagentIds.count, 1)
        legacy.type = .subagentEnd; legacy.subagentId = spawned.subagentId
        legacy.tokensIn = 10000
        manager.handleMessage(legacy)
        XCTAssertEqual(manager.sessions.first?.events.first?.isComplete, false)
        XCTAssertEqual(manager.sessions.first?.tokenUsage.inputTokens, 0)
        spawned.observationSequence = 3
        spawned.subagentId = ObservationSource(message: a)!.id + "-"
        manager.handleMessage(spawned)
        XCTAssertEqual(manager.sessions.first?.subagentIds.count, 1)
    }

    func testCompiledTypeScriptObserverFramesMatchSwiftReceiver() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try Data(contentsOf: root.appendingPathComponent("Fixtures/companion/observation-events.json"))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        let rows = try XCTUnwrap(envelope["messages"] as? [[String: Any]])
        let messages = try rows.map { try DIProtocol.decode(JSONSerialization.data(withJSONObject: $0)) }
        wall = try XCTUnwrap(messages.map(\.timestamp).max())
        var ledger = ObservationLeaseLedger()
        let manager = SessionManager(observationWallClock: { self.wall })
        for message in messages {
            XCTAssertNotEqual(ledger.accept(message, now: 0, wallTime: wall), .rejected, message.type.rawValue)
            manager.handleMessage(message)
        }
        XCTAssertEqual(messages.count, 11)
        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertTrue(manager.sessions.allSatisfy { $0.status == .observationUnavailable && $0.completedAt == nil })
        XCTAssertTrue(manager.sessions.allSatisfy { $0.nativeTaskId == "同一任务/😀" })
    }
}
