import XCTest
import DIShared
@testable import XIsland

@MainActor
final class CumulativeUsageTests: XCTestCase {
    func testRepeatedCumulativeSnapshotDoesNotDoubleCount() throws {
        let manager = SessionManager()
        let message = usageMessage(input: 100, output: 40, total: 140, cost: 0.25)
        manager.handleMessage(message)
        manager.handleMessage(message)

        assertUsage(try XCTUnwrap(manager.sessions.first), input: 100, output: 40, total: 140, cost: 0.25)
    }

    func testIncreasingCumulativeSnapshotReplacesPreviousAmounts() throws {
        let manager = SessionManager()
        manager.handleMessage(usageMessage(input: 100, output: 40, total: 140, cost: 0.25))
        manager.handleMessage(usageMessage(input: 180, output: 70, total: 250, cost: 0.5))

        assertUsage(try XCTUnwrap(manager.sessions.first), input: 180, output: 70, total: 250, cost: 0.5)
    }

    func testOutOfOrderCumulativeSnapshotCannotDecreaseUsage() throws {
        let manager = SessionManager()
        manager.handleMessage(usageMessage(input: 180, output: 70, total: 250, cost: 0.5))
        manager.handleMessage(usageMessage(input: 100, output: 40, total: 140, cost: 0.25))

        assertUsage(try XCTUnwrap(manager.sessions.first), input: 180, output: 70, total: 250, cost: 0.5)
    }

    func testPartialCumulativeSnapshotsPreserveMissingFieldsAndAdvanceIndependently() throws {
        let manager = SessionManager()
        manager.handleMessage(usageMessage(input: 100, output: 40, total: 140, cost: 0.25))
        var partial = usageMessage(input: 180, output: 20, total: 200, cost: 0.5)
        partial.tokensOut = nil
        partial.costUSD = nil
        manager.handleMessage(partial)
        manager.handleMessage(usageMessage(input: 50, output: 80, total: 130, cost: 0.125))

        assertUsage(try XCTUnwrap(manager.sessions.first), input: 180, output: 80, total: 200, cost: 0.25)
    }

    func testDefaultAndExplicitFalseKeepLegacyIncrementalUsage() throws {
        for flag: Bool? in [nil, false] {
            let manager = SessionManager()
            var message = usageMessage(input: 100, output: 40, total: 140, cost: 0.25)
            message.usageIsCumulative = flag
            manager.handleMessage(message)
            message.totalTokens = 120
            manager.handleMessage(message)

            assertUsage(try XCTUnwrap(manager.sessions.first), input: 200, output: 80, total: 120, cost: 0.5)
        }
    }

    func testOptionalUsageAndNativeEventFieldsRoundTrip() throws {
        for flag in [true, false] {
            var message = usageMessage(input: 100, output: 40, total: 140, cost: 0.25)
            message.usageIsCumulative = flag
            message.nativeEvent = "turn_end"
            let decoded = try DIProtocol.decode(DIProtocol.encode(message))

            XCTAssertEqual(decoded.usageIsCumulative, flag)
            XCTAssertEqual(decoded.nativeEvent, "turn_end")
            XCTAssertEqual(decoded.tokensIn, 100)
            XCTAssertEqual(decoded.tokensOut, 40)
            XCTAssertEqual(decoded.totalTokens, 140)
            XCTAssertEqual(decoded.costUSD, 0.25)
        }
    }

    func testLegacyProtocolMessageDecodesWithoutNewOptionalFields() throws {
        let payload = Data(#"{"type":"status_update","sessionId":"legacy","timestamp":"2026-09-24T00:00:00Z","tokensIn":100,"tokensOut":40,"totalTokens":140,"costUSD":0.25}"#.utf8)
        let decoded = try DIProtocol.decode(payload)

        XCTAssertNil(decoded.usageIsCumulative)
        XCTAssertNil(decoded.nativeEvent)
        let encoded = try DIProtocol.encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["usageIsCumulative"])
        XCTAssertNil(object["nativeEvent"])
        let manager = SessionManager()
        manager.handleMessage(decoded)
        manager.handleMessage(decoded)
        assertUsage(try XCTUnwrap(manager.sessions.first), input: 200, output: 80, total: 140, cost: 0.5)
    }

    private func usageMessage(input: Int, output: Int, total: Int, cost: Double) -> DIMessage {
        var message = DIMessage(type: .statusUpdate, sessionId: "usage-session")
        message.agentType = "deepseek"
        message.statusIsAssistantReply = false
        message.tokensIn = input
        message.tokensOut = output
        message.totalTokens = total
        message.costUSD = cost
        message.usageIsCumulative = true
        return message
    }

    private func assertUsage(
        _ session: AgentSession, input: Int, output: Int, total: Int, cost: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(session.tokenUsage.inputTokens, input, file: file, line: line)
        XCTAssertEqual(session.tokenUsage.outputTokens, output, file: file, line: line)
        XCTAssertEqual(session.tokenUsage.totalTokens, total, file: file, line: line)
        XCTAssertEqual(session.tokenUsage.estimatedCostUSD, cost, accuracy: 0.000001, file: file, line: line)
    }
}

@MainActor
final class DeepSeekSessionOrderingTests: XCTestCase {
    func testEndBeforeAnySessionBlocksLateSubmitAndToolEvents() {
        let manager = SessionManager()
        manager.handleMessage(nativeMessage(.sessionEnd, event: "session_end"))
        manager.handleMessage(nativeMessage(.sessionStart, event: "message_submit"))
        manager.handleMessage(nativeMessage(.toolStart, event: "tool_start"))
        manager.handleMessage(nativeMessage(.statusUpdate, event: "turn_end"))

        XCTAssertTrue(manager.sessions.isEmpty)
    }

    func testLateNativeEventsLeaveCompletedSessionAndFinalUsageUnchanged() throws {
        let manager = SessionManager()
        manager.handleMessage(nativeMessage(.statusUpdate, event: "turn_end"))
        var end = nativeMessage(.sessionEnd, event: "session_end")
        end.tokensIn = 100
        end.usageIsCumulative = true
        manager.handleMessage(end)
        let session = try XCTUnwrap(manager.sessions.first)
        let completedAt = session.completedAt

        var lateSubmit = nativeMessage(.sessionStart, event: "message_submit")
        lateSubmit.prompt = "Late prompt"
        lateSubmit.tokensIn = 200
        lateSubmit.usageIsCumulative = true
        manager.handleMessage(lateSubmit)
        manager.handleMessage(nativeMessage(.toolStart, event: "tool_start"))

        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(session.completedAt, completedAt)
        XCTAssertEqual(session.tokenUsage.inputTokens, 100)
        XCTAssertTrue(session.chatHistory.isEmpty)
        XCTAssertTrue(session.events.isEmpty)
    }

    func testDismissedCompletedSessionIsNotRecreatedByLateEvents() throws {
        let manager = SessionManager()
        manager.handleMessage(nativeMessage(.statusUpdate, event: "turn_end"))
        manager.handleMessage(nativeMessage(.sessionEnd, event: "session_end"))
        manager.dismissSession(try XCTUnwrap(manager.sessions.first))
        XCTAssertTrue(manager.sessions.isEmpty)

        manager.handleMessage(nativeMessage(.sessionStart, event: "message_submit"))
        manager.handleMessage(nativeMessage(.toolStart, event: "tool_start"))
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    func testClosingOneSessionDoesNotDiscardAnotherSessionsEvents() throws {
        let manager = SessionManager()
        manager.handleMessage(nativeMessage(.sessionEnd, event: "session_end"))
        manager.handleMessage(nativeMessage(.statusUpdate, event: "turn_end", sessionID: "deepseek-other"))
        manager.handleMessage(nativeMessage(.toolStart, event: "tool_start", sessionID: "deepseek-other"))

        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(session.id, "deepseek-other")
        XCTAssertEqual(session.status, .active)
        XCTAssertEqual(session.events.count, 1)
    }

    func testRealNativeSessionStartReopensSameSessionID() throws {
        let manager = SessionManager()
        manager.handleMessage(nativeMessage(.statusUpdate, event: "turn_end"))
        let session = try XCTUnwrap(manager.sessions.first)
        session.windowNumber = 1
        manager.handleMessage(nativeMessage(.sessionEnd, event: "session_end"))
        XCTAssertEqual(session.status, .completed)

        manager.handleMessage(nativeMessage(.sessionStart, event: "session_start"))
        manager.handleMessage(nativeMessage(.toolStart, event: "tool_start"))
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertTrue(manager.sessions.first === session)
        XCTAssertEqual(session.status, .active)
        XCTAssertEqual(session.events.count, 1)
    }

    func testNativeCloseDoesNotChangeLegacyDeepSeekHandling() throws {
        let manager = SessionManager()
        manager.handleMessage(nativeMessage(.sessionEnd, event: "session_end"))
        var legacy = nativeMessage(.toolStart, event: "tool_start")
        legacy.nativeEvent = nil
        manager.handleMessage(legacy)

        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.status, .active)
        XCTAssertEqual(session.events.count, 1)
    }

    func testNativeCloseDoesNotFilterOtherAgentTypes() throws {
        let manager = SessionManager()
        manager.handleMessage(nativeMessage(.sessionEnd, event: "session_end"))
        var otherAgent = nativeMessage(.toolStart, event: "tool_start")
        otherAgent.agentType = "codex"
        manager.handleMessage(otherAgent)

        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.agentType, .codex)
        XCTAssertEqual(session.status, .active)
    }

    private func nativeMessage(
        _ type: DIMessageType, event: String, sessionID: String = "deepseek-ordering"
    ) -> DIMessage {
        var message = DIMessage(type: type, sessionId: sessionID)
        message.agentType = "deepseek"
        message.nativeEvent = event
        message.statusIsAssistantReply = false
        if type == .sessionEnd { message.observedState = "completed" }
        if type == .toolStart { message.tool = "read_file" }
        return message
    }
}
