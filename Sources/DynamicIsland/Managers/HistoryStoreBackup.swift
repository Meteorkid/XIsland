import Darwin
import Foundation
import SQLite3

enum HistoryStoreBackup {
    private static let migrationIdentifier = "completion-review-v6"

    static func backupURL(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent()
            .appendingPathComponent("HistoryBackups", isDirectory: true)
            .appendingPathComponent("\(storeURL.lastPathComponent).pre-\(migrationIdentifier).sqlite")
    }

    @discardableResult
    static func prepareBackupIfNeeded(storeURL: URL) throws -> URL? {
        let files = FileManager.default
        guard files.fileExists(atPath: storeURL.path) else { return nil }
        let backupURL = backupURL(for: storeURL)
        do {
            if files.fileExists(atPath: backupURL.path) {
                try validate(at: backupURL)
                return backupURL
            }

            let directory = backupURL.deletingLastPathComponent()
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let temporaryURL = directory.appendingPathComponent(".\(UUID().uuidString).sqlite")
            defer {
                for suffix in ["", "-wal", "-shm", "-journal"] {
                    try? files.removeItem(atPath: temporaryURL.path + suffix)
                }
            }
            guard files.createFile(atPath: temporaryURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }

            // SQLite 在线备份会读入已提交的 WAL，直接复制主文件会漏掉这部分历史。
            try makeSnapshot(from: storeURL, to: temporaryURL)
            try validate(at: temporaryURL)
            // 同目录原子发布，排他重命名避免并发启动覆盖第一次升级前的恢复点。
            if renamex_np(temporaryURL.path, backupURL.path, UInt32(RENAME_EXCL)) != 0 {
                let code = errno
                guard code == EEXIST else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
                try validate(at: backupURL)
            }
            return backupURL
        } catch {
            throw NSError(domain: "XIsland.HistoryStoreBackup", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "History migration was stopped because its backup could not be prepared at \(backupURL.path): \(error.localizedDescription)",
                NSUnderlyingErrorKey: error,
            ])
        }
    }

    private static func makeSnapshot(from sourceURL: URL, to destinationURL: URL) throws {
        let source = try open(sourceURL, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(source) }
        let destination = try open(destinationURL, flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(destination) }
        sqlite3_busy_timeout(source, 1_000)
        sqlite3_busy_timeout(destination, 1_000)

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw sqliteError(destination, operation: "Initialize backup")
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw sqliteError(destination, operation: "Copy history", code: stepResult == SQLITE_DONE ? finishResult : stepResult)
        }
        // 备份必须是可单独恢复的文件，不依赖临时路径下的 WAL 或 SHM。
        guard sqlite3_exec(destination, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(destination, operation: "Finalize backup")
        }
    }

    private static func validate(at url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size >= 100 else { throw CocoaError(.fileReadCorruptFile) }
        let database = try open(url, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(database, operation: "Check backup")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let result = sqlite3_column_text(statement, 0),
              String(cString: result) == "ok",
              sqlite3_step(statement) == SQLITE_DONE else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private static func open(_ url: URL, flags: Int32) throws -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let error = sqliteError(database, operation: "Open history", code: result)
            if let database { sqlite3_close(database) }
            throw error
        }
        return database
    }

    private static func sqliteError(_ database: OpaquePointer?, operation: String, code: Int32? = nil) -> NSError {
        NSError(domain: "SQLite", code: Int(code ?? sqlite3_errcode(database)), userInfo: [
            NSLocalizedDescriptionKey: "\(operation): \(String(cString: sqlite3_errmsg(database)))",
        ])
    }
}
