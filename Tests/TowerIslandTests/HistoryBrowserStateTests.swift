import XCTest
import SwiftData
@testable import XIsland

@MainActor
final class HistoryBrowserStateTests: XCTestCase {
    private func manager(count: Int = 0) throws -> SessionPersistenceManager {
        let manager = SessionPersistenceManager()
        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self, StoredKimiCodeApprovalOrphan.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        manager.modelContainer = container
        let context = container.mainContext
        context.autosaveEnabled = false
        for index in 0..<count {
            context.insert(StoredSession(sessionId: String(format: "session-%05d", index), agentTypeRaw: "claude_code",
                startTime: Date(timeIntervalSince1970: 100), completedAt: Date(timeIntervalSince1970: 200),
                prompt: "普通任务", workingDirectory: "/tmp/project", terminal: "Terminal", statusRaw: "completed"))
        }
        try context.save()
        return manager
    }

    func testAllTenThousandAndOneSessionsAreReachableExactlyOnceAcrossPagesAndBatches() throws {
        let manager = try manager(count: 10_001)
        let browser = HistoryBrowserState()
        browser.reload(from: manager)
        XCTAssertEqual(browser.totalCount, 10_001)
        XCTAssertEqual(browser.pageCount, 101)
        var ids: [String] = []
        repeat {
            ids += browser.sessions.map(\.sessionId)
            guard browser.canGoForward else { break }
            browser.nextPage(in: manager)
        } while true
        XCTAssertEqual(ids.count, 10_001)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.first, "session-00000")
        XCTAssertEqual(ids.last, "session-10000")
        XCTAssertEqual(browser.pageIndex, 100)
        var batchIDs: [String] = []
        try manager.forEachHistoryBatch(batchSize: 137) { batch in
            XCTAssertLessThanOrEqual(batch.count, 137)
            batchIDs += batch.map(\.sessionId)
        }
        XCTAssertEqual(batchIDs, ids)
        browser.search("session-10000", in: manager)
        XCTAssertEqual(browser.sessions.map(\.sessionId), ["session-10000"])
        XCTAssertEqual(browser.pageIndex, 0)
        XCTAssertEqual(browser.totalCount, 1)
    }

    func testSearchMatchesEntireDatabasePromptPathAgentAndModelWithoutCaseSensitivity() throws {
        let manager = try manager()
        let context = try XCTUnwrap(manager.modelContainer).mainContext
        context.insert(StoredSession(sessionId: "target", agentTypeRaw: "claude_code", startTime: Date(),
            prompt: "修复中文 Alpha 日志", workingDirectory: "/tmp/Notebook", terminal: "Terminal", statusRaw: "completed", model: "GLM-4.5"))
        try context.save()
        for query in ["中文", "alpha", "notebook", "Claude Code", "glm-4.5", "target", "  Alpha  "] {
            let result = try manager.readHistoryPage(limit: 1, search: query)
            XCTAssertEqual(result.totalCount, 1, query)
            XCTAssertEqual(result.sessions.first?.sessionId, "target", query)
        }
        XCTAssertEqual(try manager.readHistoryPage(search: "not-found").totalCount, 0)
    }

    func testDeletingTheLastPageClampsToTheRemainingPage() throws {
        let manager = try manager(count: 3)
        let browser = HistoryBrowserState(pageSize: 2)
        browser.reload(from: manager)
        browser.nextPage(in: manager)
        manager.deleteSession(try XCTUnwrap(browser.sessions.first))
        browser.reload(from: manager)
        XCTAssertEqual(browser.pageIndex, 0)
        XCTAssertEqual(browser.totalCount, 2)
        XCTAssertEqual(browser.sessions.count, 2)
        XCTAssertFalse(browser.canGoBack)
        XCTAssertFalse(browser.canGoForward)
    }

    func testClientDisplayNamesMatchTheirDifferentStoredIdentifiers() throws {
        for agent in [AgentType.codeBuddy, .deepseek, .jetbrainsAi, .qwen, .kimi] {
            let manager = try manager()
            let context = try XCTUnwrap(manager.modelContainer).mainContext
            context.insert(StoredSession(sessionId: "fixture", agentTypeRaw: agent.rawValue, startTime: Date(),
                prompt: "内容", workingDirectory: "/tmp/project", terminal: "Terminal", statusRaw: "completed"))
            try context.save()
            for query in [agent.displayName, agent.shortName] {
                XCTAssertEqual(try manager.readHistoryPage(search: query).sessions.map(\.sessionId), ["fixture"], query)
            }
        }
    }

    func testBatchCursorUsesTheSameOrderingAsItsPredicateForMixedIdentifiers() throws {
        let manager = try manager()
        let context = try XCTUnwrap(manager.modelContainer).mainContext
        let ids = ["e\u{301}", "é", "x1", "x01", "X1", "x2", "x10", "中", "😀", "\u{E000}"]
        for id in ids {
            context.insert(StoredSession(sessionId: id, agentTypeRaw: "claude_code", startTime: Date(),
                prompt: "fixture", workingDirectory: "", terminal: "", statusRaw: "completed"))
        }
        try context.save()
        for batchSize in [1, 2, 3] {
            var actual: [Data] = []
            try manager.forEachHistoryBatch(batchSize: batchSize) { batch in actual += batch.map { Data($0.sessionId.utf8) } }
            XCTAssertEqual(actual.count, ids.count)
            XCTAssertEqual(Set(actual), Set(ids.map { Data($0.utf8) }))
        }
    }

    func testCleanupDoesNotSkipUnpaddedNumericIdentifiersAtBatchBoundaries() throws {
        let manager = try manager()
        let context = try XCTUnwrap(manager.modelContainer).mainContext
        context.autosaveEnabled = false
        for index in 0..<1201 {
            context.insert(StoredSession(sessionId: "session-\(index)", agentTypeRaw: "claude_code",
                startTime: Date(timeIntervalSince1970: 10), completedAt: Date(timeIntervalSince1970: 20),
                prompt: "fixture", workingDirectory: "", terminal: "", statusRaw: "completed"))
        }
        try context.save()
        manager.cleanup(olderThanDays: 30)
        XCTAssertEqual(manager.totalCount(), 0)
        XCTAssertNil(manager.lastSaveError)
    }

    func testReadFailureIsNotAnEmptyHistoryAndRetryRecovers() throws {
        let manager = try manager(count: 2)
        let browser = HistoryBrowserState(pageSize: 1)
        browser.search("session", in: manager)
        let container = manager.modelContainer
        manager.modelContainer = nil
        browser.reload(from: manager)
        XCTAssertTrue(browser.hasLoaded)
        XCTAssertNotNil(browser.error)
        XCTAssertNotNil(manager.lastReadError)
        XCTAssertTrue(browser.sessions.isEmpty)
        XCTAssertFalse(browser.canGoForward)
        XCTAssertEqual(browser.query, "session")
        manager.modelContainer = container
        browser.reload(from: manager)
        XCTAssertNil(browser.error)
        XCTAssertNil(manager.lastReadError)
        XCTAssertEqual(browser.totalCount, 2)
    }

    func testConsumerFailureDoesNotMasqueradeAsAReadFailure() throws {
        enum SinkError: Error { case full }
        let manager = try manager(count: 1)
        XCTAssertThrowsError(try manager.forEachHistoryBatch { _ in throw SinkError.full }) {
            XCTAssertTrue($0 is SinkError)
        }
        XCTAssertNil(manager.lastReadError)
        XCTAssertEqual(manager.totalCount(), 1)
    }

    func testInvalidPageAndMissingStoreAreExplicitErrors() throws {
        let manager = try manager()
        XCTAssertThrowsError(try manager.readHistoryPage(limit: 0))
        XCTAssertThrowsError(try manager.readHistoryPage(offset: -1))
        XCTAssertThrowsError(try manager.forEachHistoryBatch(batchSize: 0) { _ in XCTFail() })
        manager.modelContainer = nil
        XCTAssertThrowsError(try manager.readHistoryPage())
        XCTAssertThrowsError(try manager.forEachHistoryBatch { _ in XCTFail() })
        XCTAssertNotNil(manager.lastReadError)
    }

    func testMutationDuringBatchReadIsRejected() throws {
        let manager = try manager(count: 2)
        XCTAssertThrowsError(try manager.forEachHistoryBatch(batchSize: 1) { batch in manager.deleteSession(batch[0]) }) {
            guard case HistoryReadError.historyChanged = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }
}
