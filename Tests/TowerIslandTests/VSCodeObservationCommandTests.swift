import XCTest
import DIShared
@testable import DIBridge
@testable import XIsland

final class VSCodeObservationCommandTests: XCTestCase {
    func testObservationTypesAndIdentityArePreserved() throws {
        for agent in ["roo_code", "pearai"] {
            for type in ["session_start", "status_update", "subagent_start", "subagent_end",
                         "observation_heartbeat", "observation_ended"] {
                let data = try frame(["type": type, "agentType": agent])
                try VSCodeObservationCommand.validate(data)
                let message = try DIProtocol.decode(data)
                XCTAssertEqual(message.type.rawValue, type)
                XCTAssertEqual(message.agentType, agent)
                XCTAssertEqual(message.sessionId, type.hasPrefix("observation_") ? source(agent) : session(agent, "原生任务🙂"))
                XCTAssertEqual(message.sourceNamespace, String(repeating: "a", count: 24))
                XCTAssertEqual(message.sourceInstanceId, "11111111-1111-4111-8111-111111111111")
                XCTAssertEqual(message.nativeTaskId, type.hasPrefix("observation_") ? nil : "原生任务🙂")
                XCTAssertEqual(message.nativeMessageId, "123")
                XCTAssertEqual(message.observationSequence, 42)
                XCTAssertEqual(message.timestamp.timeIntervalSince1970, 1_790_208_000)
                var ledger = ObservationLeaseLedger()
                XCTAssertNotEqual(ledger.accept(message, now: 0, wallTime: message.timestamp), .rejected)
            }
        }
    }

    func testRejectsOtherAgentsAndEveryNonObservationType() throws {
        for agent in ["claude_code", "copilot", "roo_code ", ""] {
            XCTAssertThrowsError(try VSCodeObservationCommand.validate(frame(["agentType": agent])))
        }
        for type in ["permission_request", "permission_response", "question", "question_response",
                     "plan_review", "plan_response", "interaction_resolved", "session_end", "tool_start", "recap", "unknown"] {
            XCTAssertThrowsError(try VSCodeObservationCommand.validate(frame(["type": type])))
        }
        for field in ["nativeRequestId", "nativeRequestKind", "permDescription", "approved", "questionText", "options",
                      "allowsCustomAnswer", "allowsMultipleAnswers", "answer", "selectedAnswers", "planMarkdown",
                      "planApproved", "feedback", "tool", "unknownFutureField"] {
            XCTAssertThrowsError(try VSCodeObservationCommand.validate(frame([field: NSNull()])), field)
        }
    }

    func testRejectsMissingOrMismatchedObservationIdentity() throws {
        for fields: [String: Any] in [
            ["sourceNamespace": NSNull()], ["sourceNamespace": String(repeating: "A", count: 24)],
            ["sourceInstanceId": NSNull()], ["sourceInstanceId": "invalid"], ["observationSequence": NSNull()],
            ["observationSequence": 0], ["observationSequence": 9_007_199_254_740_992],
            ["nativeTaskId": NSNull()], ["nativeTaskId": ""], ["nativeTaskId": "a\n"],
            ["sessionId": "unrelated-native-session"], ["parentSessionId": "unrelated-native-session"],
            ["type": "observation_heartbeat", "sessionId": session("roo_code", "原生任务🙂")],
            ["type": "observation_ended", "nativeTaskId": "forbidden-control-task"],
            ["type": "subagent_start", "parentSessionId": "unrelated-native-session"],
            ["type": "subagent_end", "subagentId": session("pearai", "child")],
            ["type": "subagent_start", "subagentId": source("roo_code") + "-YQ=="],
        ] {
            XCTAssertThrowsError(try VSCodeObservationCommand.validate(frame(fields)), String(describing: fields))
        }
        for type in ["session_start", "session_end", "status_update"] {
            var data = try JSONSerialization.data(withJSONObject: ["type": type, "sessionId": "legacy-target",
                "agentType": "roo_code", "timestamp": "2026-09-24T00:00:00Z"])
            data.append(0x0A)
            XCTAssertThrowsError(try VSCodeObservationCommand.validate(data))
        }
    }

    @MainActor
    func testRejectedFramesCannotClearNativePendingPermission() throws {
        let manager = SessionManager()
        var permission = DIMessage(type: .permissionRequest, sessionId: "legacy-target")
        permission.agentType = "claude_code"
        permission.tool = "Bash"
        manager.handlePermissionRequest(permission, respond: { _ in XCTFail("Observation resolved native permission") })
        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertNotNil(session.pendingPermission)
        var missing = DIMessage(type: .sessionEnd, sessionId: session.id)
        missing.agentType = "roo_code"
        let frames = [try DIProtocol.encode(missing),
                      try frame(["sessionId": session.id]),
                      try frame(["type": "session_start", "sessionId": session.id, "sourceNamespace": NSNull()])]
        for data in frames {
            do {
                try VSCodeObservationCommand.validate(data)
                manager.handleMessage(try DIProtocol.decode(data))
                XCTFail("Malformed observation reached SessionManager")
            } catch { }
            XCTAssertNotNil(session.pendingPermission)
            XCTAssertEqual(session.status, .waitingPermission)
            XCTAssertNil(session.completedAt)
            XCTAssertEqual(manager.sessions.count, 1)
        }
    }

    func testRejectsOversizedMalformedAndMultipleFrames() throws {
        let data = try frame()
        XCTAssertThrowsError(try VSCodeObservationCommand.validate(data + data))
        XCTAssertThrowsError(try VSCodeObservationCommand.validate(data.dropLast()))
        XCTAssertThrowsError(try VSCodeObservationCommand.validate(frame(["timestamp": "invalid"])))
        XCTAssertThrowsError(try VSCodeObservationCommand.validate(frame(["observationSequence": "42"])))
        XCTAssertThrowsError(try VSCodeObservationCommand.validate(frame(["status": String(repeating: "x", count: 256 * 1024)])))
        let boundary = data.count
        let sized = try frame(["status": String(repeating: "x", count: 256 * 1024 - boundary - 12)])
        XCTAssertEqual(sized.count, VSCodeObservationCommand.maxFrameBytes)
        XCTAssertNoThrow(try VSCodeObservationCommand.validate(sized))
    }

    func testReadDeadlineDoesNotWaitForStdinClosure() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(VSCodeObservationCommand.readFrame(from: descriptors[0], deadline: start + 0.03))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
    }

    func testReadStopsAtSizeLimitBeforeEndOfInput() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x41, count: VSCodeObservationCommand.maxFrameBytes + 100_000).write(to: url)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        XCTAssertNil(VSCodeObservationCommand.readFrame(from: file.fileDescriptor,
            deadline: ProcessInfo.processInfo.systemUptime + 1))
        XCTAssertEqual(try file.offset(), UInt64(VSCodeObservationCommand.maxFrameBytes + 1))
    }

    func testBlockedSocketWriteUsesOneTotalDeadline() {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        var size: Int32 = 1024
        XCTAssertEqual(setsockopt(descriptors[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)), 0)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(VSCodeObservationCommand.sendFrame(fd: descriptors[0],
            frame: Data(repeating: 0x41, count: VSCodeObservationCommand.maxFrameBytes), deadline: start + 0.03))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
    }

    private func frame(_ fields: [String: Any] = [:]) throws -> Data {
        var payload: [String: Any] = ["type": "status_update", "sessionId": session("roo_code", "原生任务🙂"),
            "agentType": "roo_code", "timestamp": "2026-09-24T00:00:00Z", "sourceNamespace": String(repeating: "a", count: 24),
            "sourceInstanceId": "11111111-1111-4111-8111-111111111111", "nativeTaskId": "原生任务🙂",
            "nativeMessageId": "123", "observationSequence": 42]
        let agent = fields["agentType"] as? String ?? "roo_code"
        let type = fields["type"] as? String ?? "status_update"
        if type.hasPrefix("observation_") {
            payload["sessionId"] = source(agent)
            payload.removeValue(forKey: "nativeTaskId")
        } else {
            payload["sessionId"] = session(agent, "原生任务🙂")
            if type == "subagent_start" || type == "subagent_end" {
                payload["parentSessionId"] = payload["sessionId"]
                payload["subagentId"] = session(agent, "child")
            }
        }
        payload.merge(fields) { _, new in new }
        var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }
    private func source(_ agent: String) -> String {
        agent + "-" + String(repeating: "a", count: 24) + "-11111111-1111-4111-8111-111111111111"
    }

    private func session(_ agent: String, _ task: String) -> String {
        source(agent) + "-" + Data(task.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

}
