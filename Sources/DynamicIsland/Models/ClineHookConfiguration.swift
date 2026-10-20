import Foundation
import Darwin

/// VS Code 扩展发现无扩展名的可执行事件文件；不更改启用或信任设置。
enum ClineHookConfiguration {
    static let relativeHooksDirectory = "Documents/Cline/Hooks"
    static let workspaceHooksDirectory = ".clinerules/hooks"
    // 当前扩展运行时已接线的事件；TaskResume/PreCompact 的类型定义不代表已接线。
    static let events = ["TaskStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "TaskComplete", "TaskCancel"]

    enum ConfigurationError: Error, Equatable {
        case invalidBridgePath
        case unsupportedEvent(String)
        case conflictingFiles([String])
        case unsafeDirectory
        case fileChanged(String)
    }

    enum ExistingFile: Equatable {
        case regularFile(contents: String, isExecutable: Bool)
        case symbolicLink
        case other
    }

    enum Action: Equatable {
        case create
        case replaceOwned
        case unchanged
        case conflict
    }

    struct PlannedFile: Equatable {
        let event: String
        let contents: String
        let action: Action
        let permissions: Int = 0o700
    }

    /// 调用方必须以 lstat 语义区分符号链接，并在实际写入前重新核对快照。
    static func installationPlan(existingFiles: [String: ExistingFile], bridgePath: String) throws -> [PlannedFile] {
        try events.map { event in
            let contents = try eventFileContents(event: event, bridgePath: bridgePath)
            let action: Action
            switch existingFiles[event] {
            case nil:
                action = .create
            case let .regularFile(current, executable):
                if current == contents, executable { action = .unchanged }
                else if isOwned(contents: current, event: event) { action = .replaceOwned }
                else { action = .conflict }
            case .symbolicLink, .other:
                action = .conflict
            }
            return PlannedFile(event: event, contents: contents, action: action)
        }
    }

    static func isConfigured(existingFiles: [String: ExistingFile], bridgePath: String) -> Bool {
        guard let plan = try? installationPlan(existingFiles: existingFiles, bridgePath: bridgePath) else { return false }
        return plan.allSatisfy { $0.action == .unchanged }
    }

    static func isConfigured(in directory: URL, bridgePath: String) -> Bool {
        guard (try? validateDirectory(directory)) != nil, let files = try? existingFiles(in: directory) else { return false }
        return isConfigured(existingFiles: files, bridgePath: bridgePath)
    }

    static func shouldRepair(in directory: URL, bridgePath: String) -> Bool {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              let files = try? existingFiles(in: directory),
              let plan = try? installationPlan(existingFiles: files, bridgePath: bridgePath) else { return false }
        return !plan.contains(where: { $0.action == .conflict }) && plan.contains(where: { $0.action != .unchanged })
    }

    static func install(in directory: URL, bridgePath: String) throws {
        try Task.checkCancellation()
        try validateDirectory(directory)
        let original = try existingFiles(in: directory)
        let plan = try installationPlan(existingFiles: original, bridgePath: bridgePath)
        let conflicts = plan.filter { $0.action == .conflict }.map(\.event)
        guard conflicts.isEmpty else { throw ConfigurationError.conflictingFiles(conflicts) }
        guard plan.contains(where: { $0.action != .unchanged }) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try validateDirectory(directory)
        // 全量预检后再读一次，避免冲突导致留下半套事件文件。
        guard try existingFiles(in: directory) == original else { throw ConfigurationError.fileChanged(directory.path) }
        for file in plan where file.action != .unchanged {
            try Task.checkCancellation()
            let target = directory.appendingPathComponent(file.event)
            guard try existingFile(at: target) == original[file.event] else { throw ConfigurationError.fileChanged(file.event) }
            try writeAtomically(file, to: target, expected: original[file.event])
        }
    }

    static func remove(from directory: URL) throws {
        try Task.checkCancellation()
        try validateDirectory(directory)
        for event in events {
            let target = directory.appendingPathComponent(event)
            let original = try existingFile(at: target)
            guard case let .regularFile(contents, _) = original, isOwned(contents: contents, event: event) else { continue }
            guard try existingFile(at: target) == original else { throw ConfigurationError.fileChanged(event) }
            try Task.checkCancellation()
            guard unlink(target.path) == 0 else { throw posixError() }
        }
    }

    private static func validateDirectory(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw posixError()
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw ConfigurationError.unsafeDirectory }
    }

    private static func existingFiles(in directory: URL) throws -> [String: ExistingFile] {
        var result: [String: ExistingFile] = [:]
        for event in events { result[event] = try existingFile(at: directory.appendingPathComponent(event)) }
        return result
    }

    private static func existingFile(at url: URL) throws -> ExistingFile? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        if info.st_mode & S_IFMT == S_IFLNK { return .symbolicLink }
        guard info.st_mode & S_IFMT == S_IFREG else { return .other }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw posixError() }
        guard opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else { throw ConfigurationError.fileChanged(url.lastPathComponent) }
        let data = try handle.readToEnd() ?? Data()
        guard let contents = String(data: data, encoding: .utf8) else { return .other }
        return .regularFile(contents: contents, isExecutable: access(url.path, X_OK) == 0)
    }

    private static func writeAtomically(_ file: PlannedFile, to target: URL, expected: ExistingFile?) throws {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".xisland-cline-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); unlink(temporary.path) }
        try handle.write(contentsOf: Data(file.contents.utf8))
        guard fchmod(descriptor, mode_t(file.permissions)) == 0 else { throw posixError() }
        try handle.synchronize()
        try handle.close()
        try validateDirectory(target.deletingLastPathComponent())
        guard try existingFile(at: target) == expected else { throw ConfigurationError.fileChanged(file.event) }
        // 新文件使用原子 link，竞争出现的第三方目标不能被 rename 覆盖。
        try Task.checkCancellation()
        let result = file.action == .create ? link(temporary.path, target.path) : rename(temporary.path, target.path)
        guard result == 0 else { throw posixError() }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    static func eventFileContents(event: String, bridgePath: String) throws -> String {
        guard events.contains(event) else { throw ConfigurationError.unsupportedEvent(event) }
        try validateBridgePath(bridgePath)
        // bridge 的任何输出或失败都不能改变观察 hook 的协议响应。
        return prefix(event: event) + shellQuote(bridgePath) + suffix(event: event)
    }

    static func isOwned(contents: String, event: String) -> Bool {
        guard events.contains(event), contents.hasPrefix(prefix(event: event)), contents.hasSuffix(suffix(event: event)) else {
            return false
        }
        let quoted = String(contents.dropFirst(prefix(event: event).count).dropLast(suffix(event: event).count))
        guard quoted.hasPrefix("'"), quoted.hasSuffix("'"), quoted.count >= 2 else { return false }
        let path = String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        // 标记或 di-bridge 字样不能单独证明所有权；手改文件仍归用户所有。
        return (try? eventFileContents(event: event, bridgePath: path)) == contents
    }

    private static func prefix(event: String) -> String {
        "#!/bin/sh\n# XIsland:Cline:\(event):v1\n"
    }

    private static func suffix(event: String) -> String {
        " --agent cline --hook \(event) >/dev/null 2>/dev/null || true\nprintf '%s\\n' '{\"cancel\":false}'\n"
    }

    private static func validateBridgePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ConfigurationError.invalidBridgePath
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
