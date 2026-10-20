import Foundation
import SwiftData
import XCTest
@testable import XIsland

@MainActor
final class HistoryBackgroundStoreTests: XCTestCase {
    func testPageReturnsValueSnapshotsAndSearchesBeyondCurrentPage() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        for index in 0..<501 {
            context.insert(session("session-\(index)", prompt: index == 500 ? "中文 Target" : "task"))
        }
        try context.save()
        let store = HistoryBackgroundStore(container: container)
        let page = try await store.page(limit: 2, offset: 0, search: "", matchingAgents: [], token: HistoryJobToken())
        XCTAssertEqual(page.totalCount, 501)
        XCTAssertEqual(page.sessions.map(\.sessionId), ["session-0", "session-1"])
        let result = try await store.page(limit: 1, offset: 0, search: "target", matchingAgents: [], token: HistoryJobToken())
        XCTAssertEqual(result.totalCount, 1)
        XCTAssertEqual(result.sessions.first?.displayTitle, "中文 Target")
        XCTAssertEqual(result.sessions.first?.formattedDuration, "1m")
        let agentResult = try await store.page(limit: 1, offset: 0, search: "display name", matchingAgents: ["codex"], token: HistoryJobToken())
        XCTAssertEqual(agentResult.totalCount, 501)
        let first = try XCTUnwrap(try context.fetch(FetchDescriptor<StoredSession>()).first { $0.sessionId == "session-500" })
        first.prompt = "Changed after snapshot"
        try context.save()
        XCTAssertEqual(result.sessions.first?.prompt, "中文 Target")
    }

    func testStatisticsMergeNativeMirrorsAcrossLexicalBatches() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let first = session("a-mirror", tokens: 100)
        let second = session("z-mirror", tokens: 200)
        first.completedAt = first.startTime.addingTimeInterval(120)
        second.startTime = first.startTime.addingTimeInterval(60)
        second.completedAt = first.startTime.addingTimeInterval(180)
        for record in [first, second] {
            record.sourceNamespace = "native"
            record.sourceInstanceId = record.sessionId
            record.nativeTaskId = "same-task"
            record.toolEvents = [StoredToolEvent(tool: "read", isComplete: true, toolCallId: "same-call")]
            context.insert(record)
        }
        for index in 0..<501 { context.insert(session("middle-\(index)", tokens: 1)) }
        try context.save()
        let statistics = try await HistoryBackgroundStore(container: container).statistics(
            timeRange: .all, now: Date(timeIntervalSince1970: 1_000), calendar: Calendar(identifier: .gregorian),
            token: HistoryJobToken())
        XCTAssertEqual(statistics.totalCount, 502)
        XCTAssertEqual(statistics.totalDuration, 501 * 60 + 180)
        XCTAssertEqual(statistics.totalTokens, 701)
        XCTAssertEqual(statistics.toolFrequencies.first?.callCount, 1)
    }

    func testExportRetainsArchiveSchemaAndAll10001LexicallyOrderedRecords() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        for index in 0..<10_000 { context.insert(session("session-\(index)")) }
        let rich = session("rich")
        rich.toolEvents = [StoredToolEvent(tool: "read", input: "中文", result: "all bytes", isComplete: true)]
        rich.chatMessages = [StoredChatMessage(content: "完整消息")]
        context.insert(rich)
        try context.save()
        let destination = try directory().appendingPathComponent("history.json")
        let count = try await HistoryBackgroundStore(container: container).export(to: destination, token: HistoryJobToken())
        XCTAssertEqual(count, 10_001)
        let archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
        XCTAssertEqual(archive["schemaVersion"] as? Int, 1)
        XCTAssertEqual(archive["format"] as? String, "xisland.history")
        let sessions = try XCTUnwrap(archive["sessions"] as? [[String: Any]])
        XCTAssertEqual(Set(sessions.compactMap { $0["sessionId"] as? String }).count, 10_001)
        let record = try XCTUnwrap(sessions.first { $0["sessionId"] as? String == "rich" })
        XCTAssertEqual((record["toolEvents"] as? [[String: Any]])?.first?["input"] as? String, "中文")
        XCTAssertEqual((record["chatMessages"] as? [[String: Any]])?.first?["content"] as? String, "完整消息")
    }

    func testCleanupUsesLexicalCursorAndKeepsUnfinishedParentOrphans() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        for index in 0..<1_201 { context.insert(session("session-\(index)")) }
        let active = session("active")
        active.statusRaw = "active"
        context.insert(active)
        let missingEnd = session("missing-end")
        missingEnd.completedAt = nil
        context.insert(missingEnd)
        for id in ["active", "session-1", "unbound"] {
            context.insert(StoredKimiCodeApprovalOrphan(sessionId: id, observationData: Data(), updatedAt: .distantPast))
        }
        try context.save()
        let store = HistoryBackgroundStore(container: container)
        let changed = try await store.cleanup(olderThanDays: 0, token: HistoryJobToken())
        XCTAssertTrue(changed)
        let fresh = ModelContext(container)
        XCTAssertEqual(Set(try fresh.fetch(FetchDescriptor<StoredSession>()).map(\.sessionId)), ["active", "missing-end"])
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<StoredKimiCodeApprovalOrphan>()).map(\.sessionId), ["active"])
        let unchanged = try await store.cleanup(olderThanDays: .max, token: HistoryJobToken())
        XCTAssertFalse(unchanged)
    }

    func testInvalidatedTokenRejectsEveryOperationAndPreservesExport() async throws {
        let container = try makeContainer()
        container.mainContext.insert(session("keep"))
        try container.mainContext.save()
        let store = HistoryBackgroundStore(container: container)
        let token = HistoryJobToken()
        token.invalidate()
        let destination = try directory().appendingPathComponent("history.json")
        let original = Data("previous archive".utf8)
        try original.write(to: destination)
        do { _ = try await store.page(limit: 1, offset: 0, search: "", matchingAgents: [], token: token); XCTFail() }
        catch { assertHistoryChanged(error) }
        do { _ = try await store.statistics(timeRange: .all, now: Date(), calendar: .current, token: token); XCTFail() }
        catch { assertHistoryChanged(error) }
        do { _ = try await store.export(to: destination, token: token); XCTFail() }
        catch { assertHistoryChanged(error) }
        do { _ = try await store.cleanup(olderThanDays: 0, token: token); XCTFail() }
        catch { assertHistoryChanged(error) }
        do { _ = try await store.delete(sessionID: "keep", token: token); XCTFail() }
        catch { assertHistoryChanged(error) }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<StoredSession>()), 1)
    }

    func testDeleteRemovesOnlyRequestedSessionChildrenAndOrphan() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let target = session("target")
        target.toolEvents = [StoredToolEvent(tool: "read")]
        target.chatMessages = [StoredChatMessage(content: "content")]
        context.insert(target)
        context.insert(session("keep"))
        context.insert(StoredKimiCodeApprovalOrphan(sessionId: "target", observationData: Data()))
        context.insert(StoredKimiCodeApprovalOrphan(sessionId: "keep", observationData: Data()))
        try context.save()
        let store = HistoryBackgroundStore(container: container)
        let deleted = try await store.delete(sessionID: "target", token: HistoryJobToken())
        XCTAssertTrue(deleted)
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<StoredSession>()).map(\.sessionId), ["keep"])
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<StoredKimiCodeApprovalOrphan>()).map(\.sessionId), ["keep"])
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<StoredToolEvent>()), 0)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<StoredChatMessage>()), 0)
        let missing = try await store.delete(sessionID: "target", token: HistoryJobToken())
        XCTAssertFalse(missing)
    }

    func testCancelledDeleteAndExportPreserveStoreAndOriginalFile() async throws {
        let container = try makeContainer()
        container.mainContext.insert(session("keep"))
        try container.mainContext.save()
        let store = HistoryBackgroundStore(container: container)
        let destination = try directory().appendingPathComponent("history.json")
        let original = Data("previous export".utf8)
        try original.write(to: destination)
        let deleteTask = Task { try await store.delete(sessionID: "keep", token: HistoryJobToken()) }
        deleteTask.cancel()
        do { _ = try await deleteTask.value; XCTFail("Cancelled delete succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let exportTask = Task { try await store.export(to: destination, token: HistoryJobToken()) }
        exportTask.cancel()
        do { _ = try await exportTask.value; XCTFail("Cancelled export succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<StoredSession>()), 1)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["history.json"])
    }

    func testInvalidPagesAndRetentionAreRejectedWithoutChanges() async throws {
        let container = try makeContainer()
        let store = HistoryBackgroundStore(container: container)
        do { _ = try await store.page(limit: 0, offset: 0, search: "", matchingAgents: [], token: HistoryJobToken()); XCTFail() }
        catch { XCTAssertTrue(error is HistoryReadError) }
        do { _ = try await store.page(limit: 1, offset: -1, search: "", matchingAgents: [], token: HistoryJobToken()); XCTFail() }
        catch { XCTAssertTrue(error is HistoryReadError) }
        do { _ = try await store.cleanup(olderThanDays: -1, token: HistoryJobToken()); XCTFail() }
        catch { XCTAssertTrue(error is CocoaError) }
    }

    private func assertHistoryChanged(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case HistoryReadError.historyChanged = error else { return XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self, StoredKimiCodeApprovalOrphan.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        container.mainContext.autosaveEnabled = false
        return container
    }

    private func session(_ id: String, prompt: String = "task", tokens: Int = 0) -> StoredSession {
        StoredSession(sessionId: id, agentTypeRaw: "codex", startTime: Date(timeIntervalSince1970: 100),
            completedAt: Date(timeIntervalSince1970: 160), prompt: prompt, workingDirectory: "/tmp/project",
            terminal: "", statusRaw: "completed", totalTokens: tokens)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-background-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
}
