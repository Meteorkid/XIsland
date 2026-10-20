import Darwin
import Foundation

/// 配置变换先在内存完成，只有完整成功才替换原文件，避免损坏配置被当作空对象覆盖。
enum HookConfigurationFile {
    enum ConfigurationError: LocalizedError, Equatable {
        case rootMustBeObject
        case cannotCreateTemporaryFile
        case configurationChanged(String)
        case unsafeFile(String)

        var errorDescription: String? {
            switch self {
            case .rootMustBeObject: return "Configuration root must be an object."
            case .cannotCreateTemporaryFile: return "Cannot create a temporary configuration file."
            case let .configurationChanged(path): return "Configuration changed during update; no replacement was made: \(path)"
            case let .unsafeFile(path): return "Configuration is not a regular file: \(path)"
            }
        }
    }

    static func read(at url: URL) throws -> [String: Any] {
        try configuration(from: Snapshot.read(at: url).file?.data)
    }

    private static func configuration(from data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let configuration = object as? [String: Any] else { throw ConfigurationError.rootMustBeObject }
        return configuration
    }

    @discardableResult
    static func update(at url: URL, transform: ([String: Any]) throws -> [String: Any]) throws -> Bool {
        try Task.checkCancellation()
        let snapshot = try Snapshot.read(at: url)
        let original = try configuration(from: snapshot.file?.data)
        let updated = try transform(original)
        guard !NSDictionary(dictionary: original).isEqual(to: updated) else { return false }
        let data = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
        try replace(snapshot, with: data)
        return true
    }

    @discardableResult
    static func updateText(at url: URL, transform: (String) throws -> String) throws -> Bool {
        try Task.checkCancellation()
        let snapshot = try Snapshot.read(at: url)
        let original: String
        if let data = snapshot.file?.data {
            guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            original = text
        } else { original = "" }
        let updated = try transform(original)
        guard updated != original else { return false }
        try replace(snapshot, with: Data(updated.utf8))
        return true
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            mode = info.st_mode
        }
    }

    private struct SymbolicLink: Equatable {
        let identity: FileIdentity
        let destination: String

        static func read(at url: URL) throws -> SymbolicLink? {
            guard let info = try metadata(at: url), info.st_mode & S_IFMT == S_IFLNK else { return nil }
            return SymbolicLink(identity: FileIdentity(info),
                                destination: try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        }
    }

    private struct RegularFile: Equatable {
        let identity: FileIdentity
        let data: Data

        static func read(at url: URL) throws -> RegularFile? {
            guard let info = try metadata(at: url) else { return nil }
            guard info.st_mode & S_IFMT == S_IFREG else { throw ConfigurationError.unsafeFile(url.path) }
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw posixError() }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0 else { throw posixError() }
            guard FileIdentity(info) == FileIdentity(opened) else { throw ConfigurationError.configurationChanged(url.path) }
            let data = try handle.readToEnd() ?? Data()
            var after = stat()
            guard fstat(descriptor, &after) == 0 else { throw posixError() }
            guard FileIdentity(opened) == FileIdentity(after), opened.st_size == after.st_size,
                  opened.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  opened.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  opened.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  opened.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                  try metadata(at: url).map(FileIdentity.init) == FileIdentity(after) else {
                throw ConfigurationError.configurationChanged(url.path)
            }
            return RegularFile(identity: FileIdentity(after), data: data)
        }
    }

    private struct Snapshot: Equatable {
        let source: URL
        let target: URL
        let symbolicLink: SymbolicLink?
        let file: RegularFile?

        static func read(at url: URL) throws -> Snapshot {
            let symbolicLink = try SymbolicLink.read(at: url)
            // dotfiles 常由符号链接管理；保留原路径绑定，替换的仍是实际目标。
            let target = url.resolvingSymlinksInPath()
            let file = try RegularFile.read(at: target)
            guard try SymbolicLink.read(at: url) == symbolicLink, url.resolvingSymlinksInPath() == target else {
                throw ConfigurationError.configurationChanged(url.path)
            }
            guard symbolicLink == nil || file != nil else { throw ConfigurationError.unsafeFile(url.path) }
            return Snapshot(source: url, target: target, symbolicLink: symbolicLink, file: file)
        }

        func validate() throws {
            guard let current = try? Snapshot.read(at: source), current == self else {
                throw ConfigurationError.configurationChanged(source.path)
            }
        }
    }

    private static func replace(_ snapshot: Snapshot, with data: Data) throws {
        try Task.checkCancellation()
        try snapshot.validate()
        let files = FileManager.default
        let url = snapshot.target
        let directory = url.deletingLastPathComponent()
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".xisland-\(UUID().uuidString).tmp")
        defer { try? files.removeItem(at: temporary) }
        let staged = try writeExclusive(data, to: temporary, permissions: snapshot.file.map { $0.identity.mode & 0o777 } ?? 0o600)
        var backup: URL?
        var committed = false
        defer {
            if !committed, let backup { try? files.removeItem(at: backup) }
        }
        if let original = snapshot.file {
            let recovery = directory.appendingPathComponent(".\(url.lastPathComponent).xisland-\(UUID().uuidString).bak")
            _ = try writeExclusive(original.data, to: recovery, permissions: 0o600)
            backup = recovery
        }
        guard try RegularFile.read(at: temporary) == staged else { throw ConfigurationError.configurationChanged(temporary.path) }
        // 缩小读取到替换的窗口；非合作写者仍可在最后一次核对与 rename 之间写入。
        try snapshot.validate()
        try Task.checkCancellation()
        let result = snapshot.file == nil ? link(temporary.path, url.path) : rename(temporary.path, url.path)
        guard result == 0 else {
            if errno == EEXIST { throw ConfigurationError.configurationChanged(snapshot.source.path) }
            throw posixError()
        }
        committed = true
    }

    private static func writeExclusive(_ data: Data, to url: URL, permissions: mode_t) throws -> RegularFile {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var completed = false
        defer {
            try? handle.close()
            if !completed { unlink(url.path) }
        }
        try handle.write(contentsOf: data)
        guard fchmod(descriptor, permissions) == 0 else { throw posixError() }
        try handle.synchronize()
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        try handle.close()
        completed = true
        return RegularFile(identity: FileIdentity(info), data: data)
    }

    private static func metadata(at url: URL) throws -> stat? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        return info
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
