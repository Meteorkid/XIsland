import XCTest
import SwiftData
@testable import XIsland

@MainActor
final class SessionPersistenceTests: XCTestCase {

    // MARK: - Helpers

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeTestSession(
        id: String = "test-\(UUID().uuidString)",
        agentType: AgentType = .claudeCode,
        completedAt: Date? = Date()
    ) -> AgentSession {
        let session = AgentSession(
            id: id,
            agentType: agentType,
            terminal: "ttys001",
            workingDirectory: "/Users/test/project",
            prompt: "Fix the bug in auth module"
        )
        session.status = .completed
        session.completedAt = completedAt
        session.tokenUsage.inputTokens = 1000
        session.tokenUsage.outputTokens = 500
        session.tokenUsage.totalTokens = 1500
        session.tokenUsage.estimatedCostUSD = 0.05
        session.tokenUsage.model = "claude-sonnet-4-20250514"
        return session
    }

    private func makeManager(container: ModelContainer) -> SessionPersistenceManager {
        let manager = SessionPersistenceManager()
        manager.modelContainer = container
        return manager
    }

    // MARK: - Tests

    func testSaveAndFetchSession() throws {
        let container = try makeContainer()
        let manager = makeManager(container: container)
        let session = makeTestSession()

        manager.save(session: session)

        let results = manager.fetchHistory()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.sessionId, session.id)
        XCTAssertEqual(results.first?.agentTypeRaw, AgentType.claudeCode.rawValue)
        XCTAssertEqual(results.first?.prompt, "Fix the bug in auth module")
        XCTAssertEqual(results.first?.inputTokens, 1000)
        XCTAssertEqual(results.first?.estimatedCostUSD, 0.05)
    }

    func testNoDuplicatesOnResave() throws {
        let container = try makeContainer()
        let manager = makeManager(container: container)
        let session = makeTestSession(id: "same-id")

        manager.save(session: session)
        manager.save(session: session)

        let results = manager.fetchHistory()
        XCTAssertEqual(results.count, 1)
    }

    func testToolEventsPersisted() throws {
        let container = try makeContainer()
        let manager = makeManager(container: container)
        let session = makeTestSession()

        let event1 = ToolEvent(tool: "read", input: "/path/to/file.swift", isComplete: true)
        let event2 = ToolEvent(tool: "write", input: "/path/to/output.swift", isComplete: true)
        session.events = [event1, event2]

        manager.save(session: session)

        let results = manager.fetchHistory()
        let stored = results.first!
        XCTAssertEqual(stored.toolEvents.count, 2)
        let toolNames = Set(stored.toolEvents.map(\.tool))
        XCTAssertTrue(toolNames.contains("read"))
        XCTAssertTrue(toolNames.contains("write"))
    }

    func testChatMessagesPersisted() throws {
        let container = try makeContainer()
        let manager = makeManager(container: container)
        let session = makeTestSession()

        session.chatHistory = [
            ChatMessage(timestamp: Date(), role: .user, content: "Fix the bug"),
            ChatMessage(timestamp: Date(), role: .assistant, content: "I'll fix it"),
            ChatMessage(timestamp: Date(), role: .system, content: "Session started"),
        ]

        manager.save(session: session)

        let results = manager.fetchHistory()
        let stored = results.first!
        XCTAssertEqual(stored.chatMessages.count, 3)
        let roles = Set(stored.chatMessages.map(\.role))
        XCTAssertTrue(roles.contains("user"))
        XCTAssertTrue(roles.contains("assistant"))
        XCTAssertTrue(roles.contains("system"))
        let contents = Set(stored.chatMessages.map(\.content))
        XCTAssertTrue(contents.contains("Fix the bug"))
        XCTAssertTrue(contents.contains("I'll fix it"))
        XCTAssertTrue(contents.contains("Session started"))
    }

    func testCleanupOlderThan() throws {
        let container = try makeContainer()
        let manager = makeManager(container: container)

        let oldSession = makeTestSession(id: "old", completedAt: Date().addingTimeInterval(-86400 * 10))
        let recentSession = makeTestSession(id: "recent", completedAt: Date().addingTimeInterval(-86400 * 0.5))

        manager.save(session: oldSession)
        manager.save(session: recentSession)

        manager.cleanup(olderThanDays: 1)

        let results = manager.fetchHistory()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.sessionId, "recent")
    }

    func testFetchHistoryLimit() throws {
        let container = try makeContainer()
        let manager = makeManager(container: container)

        // 使用不同的 completedAt 时间，确保排序正确
        // session-4 最新，session-0 最旧
        for i in 0..<5 {
            let completedDate = Date().addingTimeInterval(TimeInterval(-(4 - i)) * 60)
            let session = makeTestSession(id: "session-\(i)", completedAt: completedDate)
            manager.save(session: session)
        }

        let results = manager.fetchHistory(limit: 3)
        XCTAssertEqual(results.count, 3)
        // 按 completedAt 倒序，最新的在前
        XCTAssertEqual(results[0].sessionId, "session-4")
        XCTAssertEqual(results[1].sessionId, "session-3")
        XCTAssertEqual(results[2].sessionId, "session-2")
    }

    func testDeleteSession() throws {
        let container = try makeContainer()
        let manager = makeManager(container: container)
        let session = makeTestSession()

        manager.save(session: session)
        XCTAssertEqual(manager.totalCount(), 1)

        let results = manager.fetchHistory()
        manager.deleteSession(results.first!)

        XCTAssertEqual(manager.totalCount(), 0)
    }

    func testTotalCount() throws {
        let container = try makeContainer()
        let manager = makeManager(container: container)

        manager.save(session: makeTestSession(id: "s1"))
        manager.save(session: makeTestSession(id: "s2"))
        manager.save(session: makeTestSession(id: "s3"))

        XCTAssertEqual(manager.totalCount(), 3)
    }
}
