import Foundation
import Darwin
import DIShared

/// 仅向调用方指定的新目录导出；不修改 WorkBuddy 插件市场、启用状态或用户 settings。
enum WorkBuddyPluginExport {
    enum ExportError: Error { case invalidPath, destinationExists }
    static let events = WorkBuddyPluginConfiguration.events

    static func files(bridgePath: String) throws -> [String: Data] {
        do { return try WorkBuddyPluginConfiguration.files(bridgePath: bridgePath) }
        catch WorkBuddyPluginConfiguration.ConfigurationError.invalidBridgePath { throw ExportError.invalidPath }
    }

    static func write(to destination: URL, bridgePath: String) throws {
        let contents = try files(bridgePath: bridgePath)
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard destination.isFileURL, manager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw ExportError.invalidPath }
        guard mkdir(destination.path, 0o700) == 0 else {
            if errno == EEXIST { throw ExportError.destinationExists }
            throw ExportError.invalidPath
        }
        var createdFiles: [URL] = [], createdDirectories: [URL] = []
        do {
            for (relativePath, data) in contents {
                let file = destination.appendingPathComponent(relativePath)
                let directory = file.deletingLastPathComponent()
                if !createdDirectories.contains(directory) {
                    guard mkdir(directory.path, 0o700) == 0 else { throw ExportError.invalidPath }
                    createdDirectories.append(directory)
                }
                try data.write(to: file, options: .withoutOverwriting)
                createdFiles.append(file)
            }
        } catch {
            for file in createdFiles { try? manager.removeItem(at: file) }
            for directory in createdDirectories.reversed() { rmdir(directory.path) }
            rmdir(destination.path)
            throw error
        }
    }

    static func run(arguments: [String], bridgePath: String) -> Int32 {
        guard arguments.count == 1, arguments[0].hasPrefix("/"), !arguments[0].utf8.contains(0),
              let bridge = AiderLauncher.executablePath(bridgePath, environment: ProcessInfo.processInfo.environment) else {
            fputs("用法：di-bridge workbuddy-plugin /绝对路径/新目录\n", stderr)
            return 64
        }
        do {
            try write(to: URL(fileURLWithPath: arguments[0], isDirectory: true), bridgePath: bridge)
            fputs("[XIsland] WorkBuddy 观察插件已导出，尚未安装或启用。\n", stderr)
            return 0
        } catch {
            fputs("[XIsland] 导出失败：需要新目录，且父目录必须存在；未修改 WorkBuddy 配置。\n", stderr)
            return 65
        }
    }
}
