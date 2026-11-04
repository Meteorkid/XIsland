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
        // 先按标准 JSON 解析；失败再剥注释重试，兼容用户手写的 JSONC。
        if let object = try? JSONSerialization.jsonObject(with: data),
           let configuration = object as? [String: Any] {
            return configuration
        }
        if let text = String(data: data, encoding: .utf8) {
            let stripped = JSONTextSurgery.strippingComments(text)
            if let object = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)),
               let configuration = object as? [String: Any] {
                return configuration
            }
        }
        // 两次都不成立：既可能是语法错误，也可能根不是对象。
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
        let data = try encode(updated, preservingCommentsOf: snapshot.file?.data)
        try replace(snapshot, with: data)
        return true
    }

    /// 优先保留原文件的注释与键序：只替换顶层 `hooks` 的值。
    ///
    /// 仅当原文件**含注释**时才走局部替换——无注释时全量重写的结果与原来一致，
    /// 保持既有行为不变。局部替换还必须通过"语义等价"校验，任何不满足都回退。
    private static func encode(_ updated: [String: Any], preservingCommentsOf originalData: Data?) throws -> Data {
        let fallback = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])

        guard let originalData,
              let originalText = String(data: originalData, encoding: .utf8),
              JSONTextSurgery.containsComments(originalText),
              let newHooks = updated["hooks"],
              JSONSerialization.isValidJSONObject(newHooks),
              let rendered = try? JSONSerialization.data(withJSONObject: newHooks, options: [.sortedKeys]),
              let renderedText = String(data: rendered, encoding: .utf8),
              let patched = JSONTextSurgery.replaceTopLevelValue(in: originalText, key: "hooks", with: renderedText)
        else { return fallback }

        // 安全网：剥掉注释后必须解析出与目标**完全一致**的文档，否则回退全量重写。
        let stripped = JSONTextSurgery.strippingComments(patched)
        guard let check = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any],
              NSDictionary(dictionary: check).isEqual(to: updated)
        else { return fallback }

        return Data(patched.utf8)
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
            // 备份名要让用户自己也能找到并恢复：明文时间戳，不用隐藏文件与 UUID。
            let recovery = freeBackupURL(for: url)
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

    /// 用户可见的备份路径：`settings.json.bak-20261103-230045`。
    ///
    /// 用明文时间戳而不是隐藏文件加 UUID——备份的价值在于程序跑不起来时用户还能自己 `mv` 回去；
    /// 同秒重名时追加序号，避免"安装后立刻卸载"覆盖掉第一份备份。
    private static func freeBackupURL(for url: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(url.lastPathComponent).bak-\(formatter.string(from: Date()))"
        let directory = url.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent(base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }
        return candidate
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
