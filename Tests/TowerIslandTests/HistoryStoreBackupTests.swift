import XCTest
import SQLite3
@testable import XIsland

final class HistoryStoreBackupTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testMissingStoreDoesNotCreateBackupDirectory() throws {
        let storeURL = directory.appendingPathComponent("history.store")
        XCTAssertNil(try HistoryStoreBackup.prepareBackupIfNeeded(storeURL: storeURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("HistoryBackups").path))
    }

    func testBackupIncludesCommittedWALWithoutCheckpointingSource() throws {
        let storeURL = directory.appendingPathComponent("history.store")
        let source = try open(storeURL)
        defer { sqlite3_close(source) }
        try execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE history (content TEXT);", on: source)
        try execute("PRAGMA wal_checkpoint(TRUNCATE); INSERT INTO history VALUES ('committed in WAL');", on: source)
        let sourceData = try Data(contentsOf: storeURL)
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let walData = try Data(contentsOf: walURL)
        XCTAssertGreaterThan(walData.count, 32)

        let backupURL = try XCTUnwrap(HistoryStoreBackup.prepareBackupIfNeeded(storeURL: storeURL))

        XCTAssertEqual(backupURL.lastPathComponent, "history.store.pre-stable-record-ids-v1.sqlite")
        XCTAssertEqual(try Data(contentsOf: storeURL), sourceData)
        XCTAssertEqual(try Data(contentsOf: walURL), walData)
        XCTAssertEqual(try scalar("SELECT content FROM history", at: backupURL), "committed in WAL")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path + "-shm"))
    }

    func testExistingBackupRemainsUnchangedWhenSourceChanges() throws {
        let storeURL = directory.appendingPathComponent("history.store")
        let source = try open(storeURL)
        defer { sqlite3_close(source) }
        try execute("CREATE TABLE history (content TEXT); INSERT INTO history VALUES ('original');", on: source)
        let backupURL = try XCTUnwrap(HistoryStoreBackup.prepareBackupIfNeeded(storeURL: storeURL))
        let originalBackup = try Data(contentsOf: backupURL)
        try execute("INSERT INTO history VALUES ('new content');", on: source)

        XCTAssertEqual(try HistoryStoreBackup.prepareBackupIfNeeded(storeURL: storeURL), backupURL)
        XCTAssertEqual(try Data(contentsOf: backupURL), originalBackup)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history", at: backupURL), "1")
    }

    func testCorruptSourceFailsWithoutPublishingPartialBackup() throws {
        let storeURL = directory.appendingPathComponent("history.store")
        let corruptData = Data("not a sqlite database".utf8)
        try corruptData.write(to: storeURL)

        XCTAssertThrowsError(try HistoryStoreBackup.prepareBackupIfNeeded(storeURL: storeURL))
        XCTAssertEqual(try Data(contentsOf: storeURL), corruptData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: HistoryStoreBackup.backupURL(for: storeURL).path))
        let backupDirectory = directory.appendingPathComponent("HistoryBackups")
        if FileManager.default.fileExists(atPath: backupDirectory.path) {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: backupDirectory.path).isEmpty)
        }
    }

    func testCorruptExistingBackupFailsWithoutReplacingIt() throws {
        let storeURL = directory.appendingPathComponent("history.store")
        let source = try open(storeURL)
        defer { sqlite3_close(source) }
        try execute("CREATE TABLE history (content TEXT);", on: source)
        let backupURL = HistoryStoreBackup.backupURL(for: storeURL)
        try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corruptData = Data("corrupt recovery point".utf8)
        try corruptData.write(to: backupURL)

        XCTAssertThrowsError(try HistoryStoreBackup.prepareBackupIfNeeded(storeURL: storeURL))
        XCTAssertEqual(try Data(contentsOf: backupURL), corruptData)
    }

    func testBackupDirectoryFailureLeavesSourceUnchanged() throws {
        let storeURL = directory.appendingPathComponent("history.store")
        let source = try open(storeURL)
        defer { sqlite3_close(source) }
        try execute("CREATE TABLE history (content TEXT); INSERT INTO history VALUES ('original');", on: source)
        let sourceData = try Data(contentsOf: storeURL)
        try Data("blocks directory creation".utf8).write(to: directory.appendingPathComponent("HistoryBackups"))

        XCTAssertThrowsError(try HistoryStoreBackup.prepareBackupIfNeeded(storeURL: storeURL))
        XCTAssertEqual(try Data(contentsOf: storeURL), sourceData)
        XCTAssertEqual(try scalar("SELECT content FROM history", at: storeURL), "original")
    }

    private func open(_ url: URL, flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) throws -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw NSError(domain: "HistoryStoreBackupTests", code: Int(result))
        }
        return database
    }

    private func execute(_ sql: String, on database: OpaquePointer) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw NSError(domain: "HistoryStoreBackupTests", code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database)),
            ])
        }
    }

    private func scalar(_ sql: String, at url: URL) throws -> String? {
        let database = try open(url, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "HistoryStoreBackupTests", code: Int(sqlite3_errcode(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let result = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: result)
    }
}
