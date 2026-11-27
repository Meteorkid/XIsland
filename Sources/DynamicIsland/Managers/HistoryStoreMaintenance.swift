import Foundation
import SQLite3

/// 历史库在启动阶段的轻量维护。
///
/// SwiftData 删除记录后不会自动缩小 SQLite 文件；这里在 ModelContainer 打开之前检查
/// freelist，只有确实存在大量空闲页时才执行 VACUUM，避免每次启动都做全库重写。
enum HistoryStoreMaintenance {
    static let defaultMinimumFreePages = 256
    static let defaultMinimumFileSize: Int64 = 50 * 1024 * 1024

    @discardableResult
    static func vacuumIfNeeded(
        storeURL: URL,
        minimumFreePages: Int = defaultMinimumFreePages,
        minimumFileSize: Int64 = defaultMinimumFileSize
    ) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storeURL.path),
              let attributes = try? fileManager.attributesOfItem(atPath: storeURL.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value >= minimumFileSize else { return false }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE
        let openResult = sqlite3_open_v2(storeURL.path, &database, flags, nil)
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return false
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)

        guard let freePages = integerPragma("freelist_count", database: database),
              freePages >= minimumFreePages else { return false }

        // VACUUM 需要独占锁；如果另一个实例正在写入则直接跳过，等下次启动再处理。
        let result = sqlite3_exec(database, "VACUUM", nil, nil, nil)
        if result == SQLITE_OK {
            NSLog("XIsland history: VACUUM reclaimed %d free pages", freePages)
            return true
        }
        return false
    }

    private static func integerPragma(_ name: String, database: OpaquePointer) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA \(name)", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
