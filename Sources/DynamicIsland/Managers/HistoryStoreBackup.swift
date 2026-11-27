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

    /// 把旧版根目录下的 `HistoryBackups` 合并到应用目录；已存在的同名文件不覆盖。
    /// 旧文件名 `default.store.pre-*` 同步改为 `XIsland.store.pre-*`。
    static func migrateLegacyBackupsIfNeeded(
        in baseDirectory: URL = HistoryStoreLocation.applicationSupportDirectory(),
        fileManager: FileManager = .default
    ) {
        let legacyBackups = baseDirectory.appendingPathComponent(HistoryStoreLocation.backupDirectoryName, isDirectory: true)
        let destinationBackups = HistoryStoreLocation.applicationDirectory(in: baseDirectory, fileManager: fileManager)
            .appendingPathComponent(HistoryStoreLocation.backupDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: legacyBackups.path) else { return }

        try? fileManager.createDirectory(at: destinationBackups, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        if let names = try? fileManager.contentsOfDirectory(atPath: legacyBackups.path) {
            for name in names {
                let source = legacyBackups.appendingPathComponent(name)
                let target = destinationBackups.appendingPathComponent(name)
                guard !fileManager.fileExists(atPath: target.path) else { continue }
                try? fileManager.moveItem(at: source, to: target)
            }
        }
        // 只有所有文件都成功移走（或目标已存在）才删除旧目录，避免移动失败丢备份。
        if let remaining = try? fileManager.contentsOfDirectory(atPath: legacyBackups.path), remaining.isEmpty {
            try? fileManager.removeItem(at: legacyBackups)
        }

        if let names = try? fileManager.contentsOfDirectory(atPath: destinationBackups.path) {
            for name in names where name.hasPrefix("\(HistoryStoreLocation.legacyStoreFileName).pre-") {
                let targetName = name.replacingOccurrences(
                    of: "\(HistoryStoreLocation.legacyStoreFileName).pre-",
                    with: "\(HistoryStoreLocation.storeFileName).pre-"
                )
                let source = destinationBackups.appendingPathComponent(name)
                let target = destinationBackups.appendingPathComponent(targetName)
                if !fileManager.fileExists(atPath: target.path) {
                    try? fileManager.moveItem(at: source, to: target)
                }
            }
        }
    }

    /// 按总大小保留最近的历史恢复点，避免多个 1.9GB 级快照无限堆积。
    /// 最新一份无论多大都会保留；其余按修改时间从旧到新删除，直到低于预算。
    static func pruneBackups(
        storeURL: URL,
        maxTotalBytes: Int64 = 2 * 1024 * 1024 * 1024,
        fileManager: FileManager = .default
    ) {
        let directory = backupURL(for: storeURL).deletingLastPathComponent()
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        let backups = names
            .filter { $0.hasSuffix(".sqlite") }
            .compactMap { name -> (URL, Int64, Date)? in
                let url = directory.appendingPathComponent(name)
                guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                      let size = attributes[.size] as? NSNumber else { return nil }
                let date = attributes[.modificationDate] as? Date ?? .distantPast
                return (url, size.int64Value, date)
            }
            .sorted { $0.2 > $1.2 }

        var total = backups.reduce(Int64(0)) { $0 + $1.1 }
        guard total > maxTotalBytes else { return }
        for backup in backups.reversed().dropLast(1) {
            try? fileManager.removeItem(at: backup.0)
            total -= backup.1
            if total <= maxTotalBytes { break }
        }
    }

    static func makeSnapshot(from sourceURL: URL, to destinationURL: URL) throws {
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

    static func validate(at url: URL) throws {
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
