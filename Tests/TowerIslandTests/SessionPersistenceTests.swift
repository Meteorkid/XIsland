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

    func testResaveUpdatesToolResultsAndAppendsChildrenWithoutDuplicates() throws {
        let manager = makeManager(container: try makeContainer())
        let session = makeTestSession()
        session.events = (0..<10).map { ToolEvent(tool: "read", input: "file-\($0).swift") }
        session.chatHistory = [ChatMessage(timestamp: Date(), role: .user, content: "Inspect files")]
        manager.save(session: session)

        session.events[0].result = "File contents"
        session.events[0].isComplete = true
        session.events[0].linesRead = 42
        session.events.append(contentsOf: (10..<15).map {
            ToolEvent(tool: "read", input: "file-\($0).swift")
        })
        session.chatHistory.append(ChatMessage(timestamp: Date(), role: .assistant, content: "Done"))
        for _ in 0..<3 {
            manager.save(session: session)
        }

        let stored = try XCTUnwrap(manager.fetchHistory().first)
        XCTAssertEqual(stored.toolEvents.count, 15)
        XCTAssertEqual(stored.chatMessages.count, 2)
        let completedTool = try XCTUnwrap(stored.toolEvents.first { $0.input == "file-0.swift" })
        XCTAssertEqual(completedTool.result, "File contents")
        XCTAssertTrue(completedTool.isComplete)
        XCTAssertEqual(completedTool.linesRead, 42)
    }

    func testDistinctChildrenWithIdenticalContentKeepTheirIdentities() throws {
        let manager = makeManager(container: try makeContainer())
        let session = makeTestSession()
        let timestamp = Date()
        session.events = [ToolEvent(tool: "read", input: "same.swift"), ToolEvent(tool: "read", input: "same.swift")]
        session.chatHistory = [
            ChatMessage(timestamp: timestamp, role: .user, content: "Same text"),
            ChatMessage(timestamp: timestamp, role: .user, content: "Same text"),
        ]

        XCTAssertTrue(manager.save(session: session))
        XCTAssertTrue(manager.save(session: session))

        let stored = try XCTUnwrap(manager.fetchHistory().first)
        XCTAssertEqual(Set(stored.toolEvents.compactMap(\.eventId)), Set(session.events.map(\.id)))
        XCTAssertEqual(Set(stored.chatMessages.compactMap(\.messageId)), Set(session.chatHistory.map(\.id)))
        XCTAssertEqual(stored.toolEvents.count, 2)
        XCTAssertEqual(stored.chatMessages.count, 2)
    }

    func testSaveFailureIsReportedAndRetryClearsError() throws {
        let manager = SessionPersistenceManager()
        let session = makeTestSession()
        session.events = [ToolEvent(tool: "read", input: "important.swift")]

        XCTAssertFalse(manager.save(session: session))
        XCTAssertNotNil(manager.lastSaveError)
        XCTAssertEqual(session.events.count, 1)

        XCTAssertTrue(manager.setupContainer(isStoredInMemoryOnly: true))
        XCTAssertTrue(manager.save(session: session))
        XCTAssertNil(manager.lastSaveError)
        XCTAssertEqual(manager.fetchHistory().first?.toolEvents.count, 1)
    }

    func testReadOnlySaveFailureDoesNotPublishUnsavedHistoryAndCanRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-readonly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("history.store")
        autoreleasepool {
            let manager = SessionPersistenceManager()
            XCTAssertTrue(manager.setupContainer(storeURL: storeURL))
            XCTAssertTrue(manager.save(session: makeTestSession(id: "saved")))
        }

        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self])
        let readOnly = ModelConfiguration(schema: schema, url: storeURL, allowsSave: false)
        let manager = makeManager(container: try ModelContainer(for: schema, configurations: [readOnly]))
        let pending = makeTestSession(id: "pending")
        pending.events = [ToolEvent(tool: "read")]

        XCTAssertFalse(manager.save(session: pending))
        XCTAssertNotNil(manager.lastSaveError)
        XCTAssertEqual(manager.fetchHistory().map(\.sessionId), ["saved"])
        XCTAssertFalse(try XCTUnwrap(manager.modelContainer).mainContext.hasChanges)

        manager.modelContainer = nil
        XCTAssertTrue(manager.setupContainer(storeURL: storeURL))
        XCTAssertTrue(manager.save(session: pending))
        XCTAssertTrue(manager.save(session: pending))
        XCTAssertNil(manager.lastSaveError)
        XCTAssertEqual(manager.totalCount(), 2)
    }

    func testLegacyDiskStoreMigratesWithoutMergingChildrenAndKeepsStableIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("history.store")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        try autoreleasepool {
            let schema = Schema([
                LegacyHistorySchema.StoredSession.self,
                LegacyHistorySchema.StoredToolEvent.self,
                LegacyHistorySchema.StoredChatMessage.self,
            ])
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL)])
            let session = LegacyHistorySchema.StoredSession()
            session.toolEvents = (0..<2).map { _ in LegacyHistorySchema.StoredToolEvent(timestamp: timestamp) }
            session.chatMessages = (0..<2).map { _ in LegacyHistorySchema.StoredChatMessage(timestamp: timestamp) }
            container.mainContext.insert(session)
            try container.mainContext.save()
        }

        var eventIDs: Set<UUID> = []
        var messageIDs: Set<UUID> = []
        try autoreleasepool {
            let manager = SessionPersistenceManager()
            XCTAssertTrue(manager.setupContainer(storeURL: storeURL), manager.lastSaveError ?? "")
            let stored = try XCTUnwrap(manager.fetchHistory().first)
            XCTAssertEqual(stored.sessionId, "legacy")
            XCTAssertNil(stored.recapText)
            XCTAssertNil(stored.completedAt)
            XCTAssertEqual(stored.toolEvents.count, 2)
            XCTAssertEqual(stored.chatMessages.count, 2)
            XCTAssertTrue(stored.toolEvents.allSatisfy { $0.timestamp == timestamp && $0.tool == "read" && $0.input == nil })
            XCTAssertTrue(stored.chatMessages.allSatisfy { $0.timestamp == timestamp && $0.content == "Same content" })
            eventIDs = Set(stored.toolEvents.compactMap(\.eventId))
            messageIDs = Set(stored.chatMessages.compactMap(\.messageId))
            XCTAssertEqual(eventIDs.count, 2)
            XCTAssertEqual(messageIDs.count, 2)

            let newSession = makeTestSession(id: "legacy")
            newSession.events = [ToolEvent(tool: "read")]
            newSession.chatHistory = [ChatMessage(timestamp: timestamp, role: .user, content: "Same content")]
            XCTAssertTrue(manager.save(session: newSession))
            XCTAssertTrue(manager.save(session: newSession))
            let updated = try XCTUnwrap(manager.fetchHistory().first)
            XCTAssertEqual(updated.toolEvents.count, 3)
            XCTAssertEqual(updated.chatMessages.count, 3)
            eventIDs.insert(newSession.events[0].id)
            messageIDs.insert(newSession.chatHistory[0].id)
        }

        let backupURL = HistoryStoreBackup.backupURL(for: storeURL)
        let backupData = try Data(contentsOf: backupURL)
        let restoredURL = directory.appendingPathComponent("restored-before-migration.store")
        try FileManager.default.copyItem(at: backupURL, to: restoredURL)
        try autoreleasepool {
            let legacySchema = Schema([
                LegacyHistorySchema.StoredSession.self,
                LegacyHistorySchema.StoredToolEvent.self,
                LegacyHistorySchema.StoredChatMessage.self,
            ])
            let restored = try ModelContainer(for: legacySchema, configurations: [
                ModelConfiguration(schema: legacySchema, url: restoredURL, allowsSave: false),
            ])
            let original = try XCTUnwrap(restored.mainContext.fetch(FetchDescriptor<LegacyHistorySchema.StoredSession>()).first)
            XCTAssertEqual(original.sessionId, "legacy")
            XCTAssertEqual(original.prompt, "Legacy history")
            XCTAssertEqual(original.toolEvents.count, 2)
            XCTAssertEqual(original.chatMessages.count, 2)
            XCTAssertTrue(original.toolEvents.allSatisfy { $0.timestamp == timestamp && $0.tool == "read" })
            XCTAssertTrue(original.chatMessages.allSatisfy { $0.timestamp == timestamp && $0.content == "Same content" })
        }

        let reopened = SessionPersistenceManager()
        XCTAssertTrue(reopened.setupContainer(storeURL: storeURL), reopened.lastSaveError ?? "")
        let stored = try XCTUnwrap(reopened.fetchHistory().first)
        XCTAssertEqual(Set(stored.toolEvents.compactMap(\.eventId)), eventIDs)
        XCTAssertEqual(Set(stored.chatMessages.compactMap(\.messageId)), messageIDs)
        XCTAssertEqual(stored.toolEvents.count, 3)
        XCTAssertEqual(stored.chatMessages.count, 3)
        XCTAssertEqual(try Data(contentsOf: backupURL), backupData)
    }

    func testBackupFailurePreventsOpeningAndMigratingLegacyStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-blocked-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("history.store")
        try autoreleasepool {
            let schema = Schema([
                LegacyHistorySchema.StoredSession.self,
                LegacyHistorySchema.StoredToolEvent.self,
                LegacyHistorySchema.StoredChatMessage.self,
            ])
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL)])
            container.mainContext.insert(LegacyHistorySchema.StoredSession())
            try container.mainContext.save()
        }
        let sourceData = try Data(contentsOf: storeURL)
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let walData = FileManager.default.fileExists(atPath: walURL.path) ? try Data(contentsOf: walURL) : nil
        try Data("blocks directory creation".utf8).write(to: directory.appendingPathComponent("HistoryBackups"))

        let manager = SessionPersistenceManager()
        XCTAssertFalse(manager.setupContainer(storeURL: storeURL))
        XCTAssertNil(manager.modelContainer)
        XCTAssertTrue(manager.lastSaveError?.contains("backup") == true)
        XCTAssertEqual(try Data(contentsOf: storeURL), sourceData)
        if let walData { XCTAssertEqual(try Data(contentsOf: walURL), walData) }
    }

    func testCorruptSourcePreventsMigrationAndInMemoryStoreSkipsBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-corrupt-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("history.store")
        let corruptData = Data("not a sqlite database".utf8)
        try corruptData.write(to: storeURL)

        let manager = SessionPersistenceManager()
        XCTAssertFalse(manager.setupContainer(storeURL: storeURL))
        XCTAssertNil(manager.modelContainer)
        XCTAssertTrue(manager.lastSaveError?.contains("backup") == true)
        XCTAssertEqual(try Data(contentsOf: storeURL), corruptData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: HistoryStoreBackup.backupURL(for: storeURL).path))

        XCTAssertTrue(manager.setupContainer(isStoredInMemoryOnly: true, storeURL: storeURL))
        XCTAssertNil(manager.lastSaveError)
        XCTAssertEqual(try Data(contentsOf: storeURL), corruptData)
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
        XCTAssertNil(manager.lastSaveError)

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

// 固定升级前的真实字段和关系，确保测试的是磁盘 schema 迁移，而非新模型的 nil 字段。
private enum LegacyHistorySchema {
    @Model
    final class StoredSession {
        @Attribute(.unique) var sessionId: String
        var agentTypeRaw: String
        var startTime: Date
        var completedAt: Date?
        var prompt: String
        var workingDirectory: String
        var terminal: String
        var statusRaw: String
        var recapText: String?
        var inputTokens: Int
        var outputTokens: Int
        var totalTokens: Int
        var estimatedCostUSD: Double
        var model: String
        @Relationship(deleteRule: .cascade) var toolEvents: [StoredToolEvent] = []
        @Relationship(deleteRule: .cascade) var chatMessages: [StoredChatMessage] = []

        init() {
            sessionId = "legacy"
            agentTypeRaw = AgentType.claudeCode.rawValue
            startTime = Date(timeIntervalSince1970: 1_700_000_000)
            prompt = "Legacy history"
            workingDirectory = "/tmp/project"
            terminal = "ttys001"
            statusRaw = SessionStatus.active.rawValue
            inputTokens = 10
            outputTokens = 20
            totalTokens = 30
            estimatedCostUSD = 0
            model = ""
        }
    }

    @Model
    final class StoredToolEvent {
        var tool: String
        var input: String?
        var result: String?
        var timestamp: Date
        var linesAdded: Int?
        var linesRemoved: Int?
        var isComplete: Bool
        var linesRead: Int?
        var testPassed: Int
        var testFailed: Int
        var testSkipped: Int
        var session: StoredSession?

        init(timestamp: Date) {
            tool = "read"
            self.timestamp = timestamp
            isComplete = false
            testPassed = 0
            testFailed = 0
            testSkipped = 0
        }
    }

    @Model
    final class StoredChatMessage {
        var timestamp: Date
        var role: String
        var content: String
        var session: StoredSession?

        init(timestamp: Date) {
            self.timestamp = timestamp
            role = "user"
            content = "Same content"
        }
    }
}
