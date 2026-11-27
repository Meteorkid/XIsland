import XCTest
import SQLite3
@testable import XIsland

final class HistoryStoreLocationTests: XCTestCase {
    private var baseDirectory: URL!

    override func setUpWithError() throws {
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xisland-store-location-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let baseDirectory {
            try? FileManager.default.removeItem(at: baseDirectory)
        }
    }

    func testMigratesLegacyStoreAndBackupsIntoApplicationDirectory() throws {
        let legacy = HistoryStoreLocation.legacyStoreURL(in: baseDirectory)
        let database = try open(legacy, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try execute("CREATE TABLE history (content TEXT); INSERT INTO history VALUES ('legacy row');", on: database)
        sqlite3_close(database)

        let legacyBackups = baseDirectory.appendingPathComponent("HistoryBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyBackups, withIntermediateDirectories: true)
        try Data("backup".utf8).write(to: legacyBackups.appendingPathComponent("default.store.pre-v6.sqlite"))

        let migrated = try HistoryStoreLocation.migrateLegacyStoreIfNeeded(in: baseDirectory)

        XCTAssertEqual(migrated.lastPathComponent, "XIsland.store")
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrated.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try scalar("SELECT content FROM history", at: migrated), "legacy row")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: baseDirectory.appendingPathComponent("XIsland/HistoryBackups/XIsland.store.pre-v6.sqlite").path
        ))
    }

    func testCorruptLegacyStoreFailsWithoutCreatingEmptyDestination() throws {
        let legacy = HistoryStoreLocation.legacyStoreURL(in: baseDirectory)
        try Data("not a sqlite database".utf8).write(to: legacy)
        let destination = HistoryStoreLocation.productionStoreURL(in: baseDirectory)

        XCTAssertThrowsError(try HistoryStoreLocation.migrateLegacyStoreIfNeeded(in: baseDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testStoredToolEventTruncatesLargeInputAndResult() {
        let event = ToolEvent(
            tool: "Bash",
            input: String(repeating: "i", count: 20_000),
            result: String(repeating: "r", count: 100_000)
        )
        let stored = StoredToolEvent(from: event)

        XCTAssertLessThanOrEqual(stored.result?.utf8.count ?? 0, ToolEventPersistencePolicy.maxResultUTF8Bytes + 64)
        XCTAssertLessThanOrEqual(stored.input?.utf8.count ?? 0, ToolEventPersistencePolicy.maxInputUTF8Bytes + 64)
        XCTAssertTrue(stored.result?.contains("[truncated; original") == true)
        XCTAssertTrue(stored.input?.contains("[truncated; original") == true)
        XCTAssertTrue(stored.result?.hasPrefix("rrrr") == true)
    }

    func testMaintenanceVacuumsFreedPages() throws {
        let store = baseDirectory.appendingPathComponent("vacuum.sqlite")
        let database = try open(store, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", on: database)
        try execute("CREATE TABLE payload (body TEXT);", on: database)
        for index in 0..<256 {
            try execute("INSERT INTO payload VALUES ('\(String(repeating: "x", count: 8_000))');", on: database)
        }
        try execute("DELETE FROM payload; PRAGMA wal_checkpoint(TRUNCATE);", on: database)
        let before = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: store.path)[.size] as? NSNumber).int64Value
        sqlite3_close(database)

        XCTAssertTrue(HistoryStoreMaintenance.vacuumIfNeeded(
            storeURL: store,
            minimumFreePages: 1,
            minimumFileSize: 1
        ))
        XCTAssertEqual(try scalar("PRAGMA freelist_count", at: store), "0")
        let after = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: store.path)[.size] as? NSNumber).int64Value
        XCTAssertGreaterThan(before, 0)
        XCTAssertGreaterThan(after, 0)
    }

    private func open(_ url: URL, flags: Int32 = SQLITE_OPEN_READONLY) throws -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw NSError(domain: "HistoryStoreLocationTests", code: Int(result))
        }
        return database
    }

    private func execute(_ sql: String, on database: OpaquePointer) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw NSError(domain: "HistoryStoreLocationTests", code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database)),
            ])
        }
    }

    private func scalar(_ sql: String, at url: URL) throws -> String? {
        let database = try open(url)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "HistoryStoreLocationTests", code: Int(sqlite3_errcode(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let result = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: result)
    }
}
