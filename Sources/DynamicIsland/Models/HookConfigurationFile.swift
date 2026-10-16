import Darwin
import Foundation

/// 配置变换先在内存完成，只有完整成功才替换原文件，避免损坏配置被当作空对象覆盖。
enum HookConfigurationFile {
    enum ConfigurationError: Error {
        case rootMustBeObject
        case cannotCreateTemporaryFile
    }

    static func read(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let configuration = object as? [String: Any] else { throw ConfigurationError.rootMustBeObject }
        return configuration
    }

    @discardableResult
    static func update(at url: URL, transform: ([String: Any]) throws -> [String: Any]) throws -> Bool {
        // dotfiles 常由符号链接管理；原子替换目标文件，保留用户的链接本身。
        let url = url.resolvingSymlinksInPath()
        let original = try read(at: url)
        let updated = try transform(original)
        guard !NSDictionary(dictionary: original).isEqual(to: updated) else { return false }
        let data = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
        try replace(at: url, with: data)
        return true
    }

    @discardableResult
    static func updateText(at url: URL, transform: (String) throws -> String) throws -> Bool {
        let url = url.resolvingSymlinksInPath()
        let original: String
        if FileManager.default.fileExists(atPath: url.path) { original = try String(contentsOf: url, encoding: .utf8) }
        else { original = "" }
        let updated = try transform(original)
        guard updated != original else { return false }
        try replace(at: url, with: Data(updated.utf8))
        return true
    }

    private static func replace(at url: URL, with data: Data) throws {
        let files = FileManager.default
        let directory = url.deletingLastPathComponent()
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".xisland-\(UUID().uuidString).tmp")
        defer { try? files.removeItem(at: temporary) }
        let permissions = (try? files.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o600
        guard files.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: permissions]) else {
            throw ConfigurationError.cannotCreateTemporaryFile
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
