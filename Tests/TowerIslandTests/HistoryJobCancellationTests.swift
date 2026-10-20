import Foundation
import XCTest
@testable import XIsland

final class HistoryJobCancellationTests: XCTestCase {
    func testInvalidatedTokenDoesNotEnterCommit() throws {
        let token = HistoryJobToken()
        XCTAssertEqual(try token.withCommit { 42 }, 42)
        token.invalidate()
        XCTAssertThrowsError(try token.check()) { assertHistoryChanged($0) }
        XCTAssertThrowsError(try token.withCommit { XCTFail("Invalidated job must not commit") }) {
            assertHistoryChanged($0)
        }
    }

    func testTaskCancellationTakesPrecedenceAndBlocksCommit() async {
        let result = await Task.detached { () -> Bool in
            let token = HistoryJobToken()
            token.invalidate()
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try token.withCommit { XCTFail("Cancelled job must not commit") }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value
        XCTAssertTrue(result)
    }

    func testCancellationBetweenBatchesPreservesExistingArchiveAndCleansTemporaryFile() throws {
        let (directory, destination, original) = try archiveDestination()
        let token = HistoryJobToken()
        XCTAssertThrowsError(try HistoryArchiveExporter.export(to: destination, forEachBatch: { visit in
            try visit([session("first")])
            token.invalidate()
            try visit([session("second")])
        }, checkCancellation: token.check)) { assertHistoryChanged($0) }
        try assertPreserved(directory: directory, destination: destination, original: original)
    }

    func testInvalidationAfterWritingFinalBytesStillPreventsPublication() throws {
        let (directory, destination, original) = try archiveDestination()
        let token = HistoryJobToken()
        XCTAssertThrowsError(try HistoryArchiveExporter.export(to: destination, forEachBatch: { try $0([session("all")]) },
            write: { handle, data in
                try handle.write(contentsOf: data)
                if data.starts(with: Data("],\"sessionCount\":".utf8)) { token.invalidate() }
            }, checkCancellation: token.check)) { assertHistoryChanged($0) }
        try assertPreserved(directory: directory, destination: destination, original: original)
    }

    func testCommitGateRejectsMutationAfterTheLastCancellationCheck() throws {
        let (directory, destination, original) = try archiveDestination()
        let token = HistoryJobToken()
        var reachedCommit = false
        XCTAssertThrowsError(try HistoryArchiveExporter.export(to: destination, forEachBatch: { try $0([session("all")]) },
            checkCancellation: token.check, commit: { temporary, final in
                reachedCommit = true
                token.invalidate()
                try token.withCommit { try HistoryArchiveExporter.publish(temporary, to: final) }
            })) { assertHistoryChanged($0) }
        XCTAssertTrue(reachedCommit)
        try assertPreserved(directory: directory, destination: destination, original: original)
    }

    func testUnderlyingStatisticsEntryCanAggregateOffMainThread() async throws {
        let result = try await Task.detached { () -> HistoryStatistics in
            try HistoryStatistics.load(timeRange: .all) { visit in
                XCTAssertFalse(Thread.isMainThread)
                let record = StoredSession(sessionId: "background", agentTypeRaw: "codex",
                    startTime: Date(timeIntervalSince1970: 100), completedAt: Date(timeIntervalSince1970: 160),
                    prompt: "task", workingDirectory: "", terminal: "", statusRaw: "completed", totalTokens: 9)
                try visit([record])
            }
        }.value
        XCTAssertEqual(result.totalCount, 1)
        XCTAssertEqual(result.totalTokens, 9)
        XCTAssertEqual(result.totalDuration, 60)
    }

    private func assertHistoryChanged(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case HistoryReadError.historyChanged = error else { return XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }

    private func session(_ id: String) -> StoredSession {
        StoredSession(sessionId: id, agentTypeRaw: "codex", startTime: Date(), prompt: "完整记录",
            workingDirectory: "/tmp/project", terminal: "", statusRaw: "completed")
    }

    private func archiveDestination() throws -> (URL, URL, Data) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-cancel-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("history.json")
        let original = Data("previous complete export".utf8)
        try original.write(to: destination)
        return (directory, destination, original)
    }

    private func assertPreserved(directory: URL, destination: URL, original: Data,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: destination), original, file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [destination.lastPathComponent],
                       file: file, line: line)
    }
}
