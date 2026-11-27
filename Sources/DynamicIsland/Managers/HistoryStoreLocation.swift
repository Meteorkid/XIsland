import Foundation

/// 历史库在磁盘上的唯一位置。
///
/// 生产环境不再使用 SwiftData 的通用 `default.store`：该文件位于 Application Support
/// 根目录，容易与其他非 sandbox 的 SwiftData 应用重名，也会让卸载清理无法定位。
enum HistoryStoreLocation {
    static let applicationDirectoryName = "XIsland"
    static let storeFileName = "XIsland.store"
    static let legacyStoreFileName = "default.store"
    static let backupDirectoryName = "HistoryBackups"

    /// 默认的 Application Support 根目录。
    static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// 应用专属目录。
    static func applicationDirectory(
        in baseDirectory: URL = applicationSupportDirectory(),
        fileManager: FileManager = .default
    ) -> URL {
        baseDirectory.appendingPathComponent(applicationDirectoryName, isDirectory: true)
    }

    /// 新的生产历史库路径。
    static func productionStoreURL(
        in baseDirectory: URL = applicationSupportDirectory(),
        fileManager: FileManager = .default
    ) -> URL {
        applicationDirectory(in: baseDirectory, fileManager: fileManager)
            .appendingPathComponent(storeFileName, isDirectory: false)
    }

    /// 2.2.0 及更早版本使用的通用 SwiftData 路径。
    static func legacyStoreURL(
        in baseDirectory: URL = applicationSupportDirectory(),
        fileManager: FileManager = .default
    ) -> URL {
        baseDirectory.appendingPathComponent(legacyStoreFileName, isDirectory: false)
    }

    /// 把旧版 `default.store` 迁移到应用专属目录。
    ///
    /// 使用 SQLite 在线备份生成一个包含 WAL 的独立文件，校验通过后再原子发布；
    /// 旧库直到新库验证成功后才删除。迁移在 ModelContainer 打开前执行。
    @discardableResult
    static func migrateLegacyStoreIfNeeded(
        in baseDirectory: URL = applicationSupportDirectory(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = applicationDirectory(in: baseDirectory, fileManager: fileManager)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = productionStoreURL(in: baseDirectory, fileManager: fileManager)
        guard !fileManager.fileExists(atPath: destination.path) else {
            HistoryStoreBackup.migrateLegacyBackupsIfNeeded(in: baseDirectory, fileManager: fileManager)
            return destination
        }

        let legacy = legacyStoreURL(in: baseDirectory, fileManager: fileManager)
        guard fileManager.fileExists(atPath: legacy.path) else { return destination }

        let temporary = directory.appendingPathComponent(".migration-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? fileManager.removeItem(atPath: temporary.path + suffix)
            }
        }

        // 在线备份会读入已提交的 WAL，避免直接复制主文件漏数据。
        guard fileManager.createFile(atPath: temporary.path, contents: nil,
                                    attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try HistoryStoreBackup.makeSnapshot(from: legacy, to: temporary)
        try HistoryStoreBackup.validate(at: temporary)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: temporary)
            return destination
        }
        try fileManager.moveItem(at: temporary, to: destination)

        // 新库已校验成功。旧库删除失败只会留下可清理的重复文件，不影响新库使用。
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? fileManager.removeItem(atPath: legacy.path + suffix)
        }

        // 旧迁移备份也跟随库目录，避免 400MB 级备份永久留在 Application Support 根目录。
        HistoryStoreBackup.migrateLegacyBackupsIfNeeded(in: baseDirectory, fileManager: fileManager)
        return destination
    }

    /// 迁移失败时选择仍然存在的库；两者都不存在时返回新路径（由 SwiftData 新建空库）。
    static func existingStoreAfterFailedMigration(
        in baseDirectory: URL = applicationSupportDirectory(),
        fileManager: FileManager = .default
    ) -> URL {
        let production = productionStoreURL(in: baseDirectory, fileManager: fileManager)
        if fileManager.fileExists(atPath: production.path) { return production }
        let legacy = legacyStoreURL(in: baseDirectory, fileManager: fileManager)
        if fileManager.fileExists(atPath: legacy.path) { return legacy }
        return production
    }
}
