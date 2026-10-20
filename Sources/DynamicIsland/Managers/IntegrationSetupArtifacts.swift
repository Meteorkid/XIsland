import CryptoKit
import Darwin
import DIShared
import Foundation

enum IntegrationSetupArtifacts {
    enum PreparationError: LocalizedError, Equatable {
        case unsupportedAgent
        case invalidPath
        case unsafePath
        case modifiedArtifact
        case ioFailure

        var errorDescription: String? {
            switch self {
            case .unsupportedAgent: return "此来源没有可自动准备的接入文件，请查看接入说明。"
            case .invalidPath: return "接入文件需要有效的本地目录和桥接程序路径。"
            case .unsafePath: return "接入文件路径包含符号链接或非普通文件，已停止准备。"
            case .modifiedArtifact: return "已有接入文件被修改，已保留原文件。请审阅后选择另一个准备目录。"
            case .ioFailure: return "无法准备接入文件，请检查目标目录是否可写后重试。"
            }
        }
    }

    /// Kiro 版本是文档模板基线；生成文件不代表检测到该版本或客户端已经加载。
    static func prepare(for agent: AgentType, directory: URL, bridgeURL: URL) throws -> URL {
        try Task.checkCancellation()
        guard directory.isFileURL, bridgeURL.isFileURL,
              [directory.path, bridgeURL.path].allSatisfy({ $0.hasPrefix("/")
                  && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw PreparationError.invalidPath
        }
        let files: [String: Data]
        switch agent {
        case .workBuddy:
            files = try WorkBuddyPluginConfiguration.files(bridgePath: bridgeURL.path)
        case .kiro:
            let document = try KiroHookConfiguration.merging(into: [:], bridgePath: bridgeURL.path,
                cliVersion: KiroHookConfiguration.documentedCLIVersion, engine: "v3")
            var data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            data.append(10)
            files = [KiroHookConfiguration.fileName: data]
        default:
            throw PreparationError.unsupportedAgent
        }

        var hash = SHA256()
        for path in files.keys.sorted() {
            hash.update(data: Data(path.utf8))
            hash.update(data: Data([0]))
            hash.update(data: files[path]!)
            hash.update(data: Data([0]))
        }
        let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let root = directory
        let destination = root.appendingPathComponent("\(agent.rawValue)-\(fingerprint)", isDirectory: true)
        do {
            try ensureDirectory(root)
            if try kind(at: destination) != nil {
                try verify(files, in: destination)
            } else {
                let staging = root.appendingPathComponent(".preparing-\(UUID().uuidString)", isDirectory: true)
                try Task.checkCancellation()
                guard mkdir(staging.path, 0o700) == 0 else { throw PreparationError.ioFailure }
                defer { try? FileManager.default.removeItem(at: staging) }
                for path in files.keys.sorted() {
                    try Task.checkCancellation()
                    let file = staging.appendingPathComponent(path)
                    try ensureDirectory(file.deletingLastPathComponent())
                    try files[path]!.write(to: file, options: .withoutOverwriting)
                }
                try verify(files, in: staging)
                // 目标由内容决定；永不替换已有目录，包括用户修改过的同名目录。
                try Task.checkCancellation()
                guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                    if errno == EEXIST { try verify(files, in: destination) }
                    else { throw PreparationError.ioFailure }
                    return resultURL(for: agent, directory: destination)
                }
            }
        } catch let error as CancellationError {
            throw error
        } catch let error as PreparationError {
            throw error
        } catch {
            // 系统错误可能携带完整路径；对外只显示不包含文件内容的固定说明。
            throw PreparationError.ioFailure
        }
        return resultURL(for: agent, directory: destination)
    }

    private static func resultURL(for agent: AgentType, directory: URL) -> URL {
        agent == .kiro ? directory.appendingPathComponent(KiroHookConfiguration.fileName) : directory
    }

    private static func kind(at url: URL) throws -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw PreparationError.ioFailure
        }
        let kind = info.st_mode & S_IFMT
        guard kind != S_IFLNK else { throw PreparationError.unsafePath }
        return kind
    }

    private static func ensureDirectory(_ directory: URL) throws {
        // 部分 Foundation URL 在根目录继续删除末段会生成 /..，不能靠递归比较父路径终止。
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in directory.pathComponents {
            try Task.checkCancellation()
            guard component != ".", component != ".." else { throw PreparationError.invalidPath }
            if component != "/" { current.appendPathComponent(component, isDirectory: true) }
            if let kind = try kind(at: current) {
                guard kind == S_IFDIR else { throw PreparationError.unsafePath }
            } else {
                guard mkdir(current.path, 0o700) == 0 else { throw PreparationError.ioFailure }
            }
        }
    }

    private static func verify(_ files: [String: Data], in directory: URL) throws {
        guard try kind(at: directory) == S_IFDIR else { throw PreparationError.unsafePath }
        var expected = Set(files.keys)
        for path in files.keys {
            let components = path.split(separator: "/")
            for count in 1..<components.count { expected.insert(components.prefix(count).joined(separator: "/")) }
        }
        var actual: Set<String> = []
        func inspect(_ folder: URL, prefix: String) throws {
            for item in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                try Task.checkCancellation()
                let relative = prefix + item.lastPathComponent
                let type = try kind(at: item)
                guard expected.contains(relative) else { throw PreparationError.modifiedArtifact }
                actual.insert(relative)
                if type == S_IFDIR {
                    guard files[relative] == nil else { throw PreparationError.unsafePath }
                    try inspect(item, prefix: relative + "/")
                } else {
                    guard type == S_IFREG, let expectedData = files[relative] else { throw PreparationError.unsafePath }
                    let descriptor = open(item.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard descriptor >= 0 else { throw PreparationError.unsafePath }
                    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    guard try handle.read(upToCount: expectedData.count + 1) == expectedData else {
                        throw PreparationError.modifiedArtifact
                    }
                }
            }
        }
        try inspect(directory, prefix: "")
        guard actual == expected else { throw PreparationError.modifiedArtifact }
    }
}
