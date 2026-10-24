import XCTest
import SwiftData
@testable import XIsland

@MainActor
final class HistoryArchiveExporterTests: XCTestCase {
    func testExportsAll10001SessionsAndCompleteChildren() throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("全部历史.json")
        let manager = try makeManager()
        let context = try XCTUnwrap(manager.modelContainer).mainContext
        context.autosaveEnabled = false
        let date = Date(timeIntervalSince1970: 1_700_000_000.123456)
        let richSession = makeSession(id: "session-00000", date: date)
        richSession.completedAt = date.addingTimeInterval(2)
        richSession.sourceNamespace = "native"
        richSession.sourceInstanceId = "instance-中文"
        richSession.nativeTaskId = "native-task"
        richSession.observationEndedAt = date.addingTimeInterval(1)
        richSession.kimiCodeApprovalObservationData = try JSONEncoder().encode(KimiCodeApprovalObservation())
        richSession.historyDate = date.addingTimeInterval(2)
        richSession.recapText = "完整总结\n下一行"
        richSession.inputTokens = 123
        richSession.outputTokens = 456
        richSession.totalTokens = 579
        richSession.estimatedCostUSD = 0.12345
        richSession.model = "model-原值"
        richSession.toolEvents = (0..<1_001).map { index in
            let event = StoredToolEvent(
                tool: "custom-tool-\(index)", input: "输入\n\"引号\"\\路径\t\(index)",
                result: "完整输出\n\(index)", timestamp: date.addingTimeInterval(Double(index)),
                linesAdded: index, linesRemoved: 2, isComplete: true,
                linesRead: 3, testPassed: 4, testFailed: 5, testSkipped: 6,
                completionUnconfirmed: true, toolCallId: "call-\(index)", nativeCompletionStatus: "failed"
            )
            event.eventId = UUID()
            return event
        }
        richSession.chatMessages = (0..<1_001).map { index in
            let message = StoredChatMessage(timestamp: date, role: "custom-role", content: "完整聊天\n第\(index)条 👋")
            message.messageId = UUID()
            return message
        }
        let eventIDs = Set(richSession.toolEvents.compactMap { $0.eventId?.uuidString })
        let messageIDs = Set(richSession.chatMessages.compactMap { $0.messageId?.uuidString })
        context.insert(richSession)
        for index in 1..<10_001 {
            context.insert(makeSession(id: String(format: "session-%05d", index), date: date))
        }
        try context.save()

        XCTAssertEqual(try HistoryArchiveExporter.export(from: manager, to: destination), 10_001)

        let root = try archive(at: destination)
        XCTAssertEqual(root["format"] as? String, "xisland.history")
        XCTAssertEqual(root["schemaVersion"] as? Int, 1)
        XCTAssertEqual(root["dateEncoding"] as? String, "secondsSince1970")
        XCTAssertEqual(root["binaryEncoding"] as? String, "base64")
        XCTAssertNotNil(root["exportedAt"] as? Double)
        XCTAssertEqual(root["sessionCount"] as? Int, 10_001)
        let sessions = try XCTUnwrap(root["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 10_001)
        XCTAssertEqual(Set(sessions.compactMap { $0["sessionId"] as? String }).count, 10_001)
        let session = try XCTUnwrap(sessions.first { $0["sessionId"] as? String == richSession.sessionId })
        XCTAssertEqual(session["agentTypeRaw"] as? String, "future-agent")
        XCTAssertEqual(session["startTime"] as? Double, date.timeIntervalSince1970)
        XCTAssertEqual(session["completedAt"] as? Double, richSession.completedAt?.timeIntervalSince1970)
        XCTAssertEqual(session["sourceNamespace"] as? String, "native")
        XCTAssertEqual(session["sourceInstanceId"] as? String, "instance-中文")
        XCTAssertEqual(session["nativeTaskId"] as? String, "native-task")
        XCTAssertEqual(session["observationEndedAt"] as? Double, richSession.observationEndedAt?.timeIntervalSince1970)
        XCTAssertEqual(session["kimiCodeApprovalObservationData"] as? String, richSession.kimiCodeApprovalObservationData?.base64EncodedString())
        XCTAssertEqual(session["historyDate"] as? Double, richSession.historyDate?.timeIntervalSince1970)
        XCTAssertEqual(session["prompt"] as? String, "中文请求\n保留第二行 👋")
        XCTAssertEqual(session["workingDirectory"] as? String, "/tmp/中文项目")
        XCTAssertEqual(session["terminal"] as? String, "ttys001")
        XCTAssertEqual(session["statusRaw"] as? String, "future-status")
        XCTAssertEqual(session["recapText"] as? String, "完整总结\n下一行")
        XCTAssertEqual(session["inputTokens"] as? Int, 123)
        XCTAssertEqual(session["outputTokens"] as? Int, 456)
        XCTAssertEqual(session["totalTokens"] as? Int, 579)
        XCTAssertEqual(session["estimatedCostUSD"] as? Double, 0.12345)
        XCTAssertEqual(session["model"] as? String, "model-原值")
        let events = try XCTUnwrap(session["toolEvents"] as? [[String: Any]])
        let messages = try XCTUnwrap(session["chatMessages"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1_001)
        XCTAssertEqual(messages.count, 1_001)
        XCTAssertEqual(Set(events.compactMap { $0["eventId"] as? String }), eventIDs)
        XCTAssertEqual(Set(messages.compactMap { $0["messageId"] as? String }), messageIDs)
        let event = try XCTUnwrap(events.first { $0["tool"] as? String == "custom-tool-1000" })
        XCTAssertEqual(event["input"] as? String, "输入\n\"引号\"\\路径\t1000")
        XCTAssertEqual(event["result"] as? String, "完整输出\n1000")
        XCTAssertEqual(event["timestamp"] as? Double, date.addingTimeInterval(1_000).timeIntervalSince1970)
        XCTAssertEqual(event["linesAdded"] as? Int, 1_000)
        XCTAssertEqual(event["linesRemoved"] as? Int, 2)
        XCTAssertEqual(event["linesRead"] as? Int, 3)
        XCTAssertEqual(event["testPassed"] as? Int, 4)
        XCTAssertEqual(event["testFailed"] as? Int, 5)
        XCTAssertEqual(event["testSkipped"] as? Int, 6)
        XCTAssertEqual(event["isComplete"] as? Bool, true)
        XCTAssertEqual(event["completionUnconfirmed"] as? Bool, true)
        XCTAssertEqual(event["nativeCompletionStatus"] as? String, "failed")
        XCTAssertEqual(event["toolCallId"] as? String, "call-1000")
        XCTAssertEqual(Set(messages.compactMap { $0["content"] as? String }), Set((0..<1_001).map { "完整聊天\n第\($0)条 👋" }))
        XCTAssertTrue(messages.allSatisfy { $0["role"] as? String == "custom-role" && $0["timestamp"] as? Double == date.timeIntervalSince1970 })
        try assertNoTemporaryFiles(in: directory)
    }

    func testNilFieldsAndEmptyHistoryRemainValidJSON() throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("history.json")
        let session = makeSession()
        session.historyDate = nil
        session.toolEvents = [StoredToolEvent(tool: "read")]
        session.chatMessages = [StoredChatMessage(content: "")]
        XCTAssertEqual(try HistoryArchiveExporter.export(to: destination, forEachBatch: { try $0([session]) }), 1)
        let root = try archive(at: destination)
        let record = try XCTUnwrap((root["sessions"] as? [[String: Any]])?.first)
        for key in ["completedAt", "sourceNamespace", "sourceInstanceId", "nativeTaskId", "observationEndedAt", "historyDate", "kimiCodeApprovalObservationData", "recapText"] {
            XCTAssertNil(record[key], key)
        }
        let event = try XCTUnwrap((record["toolEvents"] as? [[String: Any]])?.first)
        for key in ["eventId", "input", "result", "linesAdded", "linesRemoved", "linesRead", "toolCallId", "nativeCompletionStatus"] {
            XCTAssertNil(event[key], key)
        }
        let message = try XCTUnwrap((record["chatMessages"] as? [[String: Any]])?.first)
        XCTAssertNil(message["messageId"])
        XCTAssertEqual(message["content"] as? String, "")

        XCTAssertEqual(try HistoryArchiveExporter.export(from: makeManager(), to: destination), 0)
        let empty = try archive(at: destination)
        XCTAssertEqual(empty["sessionCount"] as? Int, 0)
        XCTAssertEqual((empty["sessions"] as? [Any])?.count, 0)
        try assertNoTemporaryFiles(in: directory)
    }

    func testCompletionReviewExportPreservesTrueFalseAndUnknownRawValues() throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("review-states.json")
        let states: [Bool?] = [true, false, nil]
        let sessions = states.enumerated().map { index, state in
            let session = makeSession(id: "review-\(index)")
            session.statusRaw = SessionStatus.active.rawValue
            session.completionNeedsReview = state
            return session
        }
        XCTAssertEqual(try HistoryArchiveExporter.export(to: destination, forEachBatch: { try $0(sessions) }), 3)

        let records = try XCTUnwrap(try archive(at: destination)["sessions"] as? [[String: Any]])
        XCTAssertEqual(records[0]["completionNeedsReview"] as? Bool, true)
        XCTAssertEqual(records[1]["completionNeedsReview"] as? Bool, false)
        XCTAssertTrue(records[2]["completionNeedsReview"] is NSNull)
        XCTAssertTrue(records.allSatisfy { $0["statusRaw"] as? String == SessionStatus.active.rawValue })
    }

    func testSourceFailureLeavesExistingFileAndRemovesTemporaryFile() throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("history.json")
        let original = Data("previous export".utf8)
        try original.write(to: destination)
        XCTAssertThrowsError(try HistoryArchiveExporter.export(to: destination, forEachBatch: { visit in
            try visit([makeSession()])
            throw TestFailure.source
        })) { error in
            XCTAssertEqual(error as? TestFailure, .source)
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        try assertNoTemporaryFiles(in: directory)
    }

    func testWriteFailurePropagatesWithoutReplacingExistingFile() throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("history.json")
        let original = Data("previous export".utf8)
        try original.write(to: destination)
        var writes = 0
        XCTAssertThrowsError(try HistoryArchiveExporter.export(
            to: destination,
            forEachBatch: { try $0([makeSession()]) },
            write: { handle, data in
                writes += 1
                if writes == 3 { throw CocoaError(.fileWriteOutOfSpace) }
                try handle.write(contentsOf: data)
            }
        )) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteOutOfSpace)
        }
        XCTAssertEqual(writes, 3)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        try assertNoTemporaryFiles(in: directory)
    }

    func testSynchronizationFailureDoesNotPublishCompletedBytes() throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("history.json")
        let original = Data("previous export".utf8)
        try original.write(to: destination)
        var wroteFinalChunk = false
        XCTAssertThrowsError(try HistoryArchiveExporter.export(
            to: destination,
            forEachBatch: { try $0([makeSession()]) },
            write: { handle, data in
                try handle.write(contentsOf: data)
                if data.starts(with: Data("],\"sessionCount\":".utf8)) {
                    wroteFinalChunk = true
                    // 所有字节写完但描述符已失效，随后的同步必须失败。
                    try handle.close()
                }
            }
        ))
        XCTAssertTrue(wroteFinalChunk)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        try assertNoTemporaryFiles(in: directory)
    }

    func testEncodingFailurePublishesNoPartialFile() throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("history.json")
        let invalid = makeSession(id: "invalid")
        invalid.estimatedCostUSD = .nan
        XCTAssertThrowsError(try HistoryArchiveExporter.export(to: destination, forEachBatch: { visit in
            try visit([makeSession()])
            try visit([invalid])
        })) { error in
            XCTAssertTrue(error is EncodingError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertNoTemporaryFiles(in: directory)
    }

    func testDirectorySymlinkAndReadOnlyDestinationsArePreserved() throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("history.json")
        let existingDirectory = directory.appendingPathComponent("existing-directory")
        try FileManager.default.createDirectory(at: existingDirectory, withIntermediateDirectories: true)
        let marker = existingDirectory.appendingPathComponent("keep.txt")
        let original = Data("keep me".utf8)
        try original.write(to: marker)
        XCTAssertThrowsError(try HistoryArchiveExporter.export(to: existingDirectory, forEachBatch: { try $0([makeSession()]) }))
        XCTAssertEqual(try Data(contentsOf: marker), original)

        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: marker)
        XCTAssertThrowsError(try HistoryArchiveExporter.export(to: destination, forEachBatch: { try $0([makeSession()]) }))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), marker.path)
        XCTAssertEqual(try Data(contentsOf: marker), original)
        try FileManager.default.removeItem(at: destination)
        try original.write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path) }
        XCTAssertThrowsError(try HistoryArchiveExporter.export(to: destination, forEachBatch: { try $0([makeSession()]) }))
        XCTAssertEqual(try Data(contentsOf: destination), original)
        try assertNoTemporaryFiles(in: directory)
    }

    func testDestinationReplacedDuringExportIsNotOverwritten() throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("history.json")
        try Data("original".utf8).write(to: destination)
        XCTAssertThrowsError(try HistoryArchiveExporter.export(to: destination, forEachBatch: { visit in
            try visit([makeSession()])
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        }))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        try assertNoTemporaryFiles(in: directory)
    }

    func testExistingFileChangedDuringExportIsNotOverwritten() throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("history.json")
        try Data("original".utf8).write(to: destination)
        let concurrentData = Data("replaced".utf8)
        XCTAssertThrowsError(try HistoryArchiveExporter.export(to: destination, forEachBatch: { visit in
            try visit([makeSession()])
            try concurrentData.write(to: destination, options: .atomic)
        }))
        XCTAssertEqual(try Data(contentsOf: destination), concurrentData)
        try assertNoTemporaryFiles(in: directory)
    }

    func testDestinationCreatedDuringExportIsNotOverwritten() throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("history.json")
        let concurrentData = Data("concurrent contents".utf8)
        XCTAssertThrowsError(try HistoryArchiveExporter.export(to: destination, forEachBatch: { visit in
            try visit([makeSession()])
            try concurrentData.write(to: destination)
        }))
        XCTAssertEqual(try Data(contentsOf: destination), concurrentData)
        try assertNoTemporaryFiles(in: directory)
    }

    func testUnavailableStoreDoesNotReplacePreviousExport() throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("history.json")
        let original = Data("previous export".utf8)
        try original.write(to: destination)
        XCTAssertThrowsError(try HistoryArchiveExporter.export(from: SessionPersistenceManager(), to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), original)
        try assertNoTemporaryFiles(in: directory)
    }

    private enum TestFailure: Error { case source }

    private func makeManager() throws -> SessionPersistenceManager {
        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self, StoredKimiCodeApprovalOrphan.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let manager = SessionPersistenceManager()
        manager.modelContainer = container
        return manager
    }

    private func makeSession(id: String = "session", date: Date = Date()) -> StoredSession {
        StoredSession(sessionId: id, agentTypeRaw: "future-agent", startTime: date,
                      prompt: "中文请求\n保留第二行 👋", workingDirectory: "/tmp/中文项目", terminal: "ttys001", statusRaw: "future-status")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func archive(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func assertNoTemporaryFiles(in directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(files.contains { $0.hasPrefix(".xisland-history-") }, file: file, line: line)
    }
}
