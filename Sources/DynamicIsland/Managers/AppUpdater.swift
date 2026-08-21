import AppKit
import CryptoKit
import Dispatch
import Foundation

// MARK: - 更新阶段

enum AppUpdaterStage: Equatable {
    case downloading
    case mounting
    case installing
    case relaunching
}

// MARK: - 更新错误

enum AppUpdaterError: LocalizedError, Equatable {
    case downloadFailed
    case mountFailed
    case appNotFound
    case installFailed
    case relaunchFailed
    case integrityCheckFailed
    case codeSigningFailed

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "Unable to download the update."
        case .mountFailed:
            return "Unable to mount the downloaded update."
        case .appNotFound:
            return "The downloaded update did not contain X Island.app."
        case .installFailed:
            return "Unable to replace the installed app."
        case .relaunchFailed:
            return "The update installed, but the app could not relaunch."
        case .integrityCheckFailed:
            return "The downloaded update failed integrity verification."
        case .codeSigningFailed:
            return "The installed app failed code signing verification."
        }
    }
}

// MARK: - 更新器

struct AppUpdater {

    // 依赖注入所用的类型别名，便于测试中替换实现
    typealias CommandRunner = @Sendable (_ launchPath: String, _ arguments: [String]) throws -> String
    typealias Downloader = @Sendable (_ sourceURL: URL, _ destinationURL: URL) async throws -> Void
    typealias RelaunchHook = @Sendable (_ appPath: String) throws -> Void
    typealias HelperLauncher = @Sendable (_ scriptPath: String) throws -> Void
    typealias TerminationHook = @Sendable () -> Void
    typealias TemporaryDirectoryProvider = @Sendable () throws -> URL
    typealias FileExistenceChecker = @Sendable (_ path: String) -> Bool
    typealias InstallHandler = @Sendable (
        _ version: String,
        _ releaseURL: URL,
        _ appPath: String,
        _ expectedSHA256: String?,
        _ onStage: @escaping @MainActor (AppUpdaterStage) -> Void
    ) async throws -> Void

    /// 命令执行失败时抛出的错误，携带进程退出码与合并后的输出。
    struct CommandExecutionError: Error, Equatable {
        let launchPath: String
        let arguments: [String]
        let terminationStatus: Int32
        let output: String
    }

    // MARK: 依赖

    let runCommand: CommandRunner
    let downloadFile: Downloader
    let relaunchApp: RelaunchHook
    let launchInstallerHelper: HelperLauncher
    let terminateApp: TerminationHook
    let temporaryDirectoryProvider: TemporaryDirectoryProvider
    let fileExists: FileExistenceChecker
    let installImpl: InstallHandler?

    init(
        runCommand: @escaping CommandRunner = Self.defaultRunCommand,
        downloadFile: @escaping Downloader = Self.defaultDownloadFile,
        relaunchApp: @escaping RelaunchHook = Self.defaultRelaunchApp,
        launchInstallerHelper: @escaping HelperLauncher = Self.defaultLaunchInstallerHelper,
        terminateApp: @escaping TerminationHook = Self.defaultTerminateApp,
        temporaryDirectoryProvider: @escaping TemporaryDirectoryProvider = Self.defaultTemporaryDirectoryProvider,
        fileExists: @escaping FileExistenceChecker = Self.defaultFileExists,
        installImpl: InstallHandler? = nil
    ) {
        self.runCommand = runCommand
        self.downloadFile = downloadFile
        self.relaunchApp = relaunchApp
        self.launchInstallerHelper = launchInstallerHelper
        self.terminateApp = terminateApp
        self.temporaryDirectoryProvider = temporaryDirectoryProvider
        self.fileExists = fileExists
        self.installImpl = installImpl
    }

    // MARK: - 命令执行

    /// 跨线程安全地累积子进程的标准输出 / 错误输出。
    private final class CommandOutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var accumulated = Data()
        private var readFailure: Error?

        func append(_ chunk: Data) {
            lock.lock()
            accumulated.append(chunk)
            lock.unlock()
        }

        func recordReadFailure(_ error: Error) {
            lock.lock()
            readFailure = error
            lock.unlock()
        }

        func snapshot() -> (data: Data, readError: Error?) {
            lock.lock()
            defer { lock.unlock() }
            return (accumulated, readFailure)
        }
    }

    /// 同步执行外部命令，合并标准输出与错误输出。
    private static func executeCommand(launchPath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // 后台线程持续排空管道，避免子进程输出超过管道缓冲时发生死锁
        let collector = CommandOutputCollector()
        let drainer = DispatchGroup()
        drainer.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { drainer.leave() }
            let handle = pipe.fileHandleForReading
            do {
                while let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
                    collector.append(chunk)
                }
            } catch {
                collector.recordReadFailure(error)
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // 启动失败时关闭写端，让读取线程自然结束
            pipe.fileHandleForWriting.closeFile()
            drainer.wait()
            throw error
        }

        drainer.wait()

        let snapshot = collector.snapshot()
        if let readFailure = snapshot.readError {
            throw readFailure
        }

        let output = String(decoding: snapshot.data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CommandExecutionError(
                launchPath: launchPath,
                arguments: arguments,
                terminationStatus: process.terminationStatus,
                output: output
            )
        }

        return output
    }

    // MARK: - 默认实现

    static let defaultRunCommand: CommandRunner = { launchPath, arguments in
        try Self.executeCommand(launchPath: launchPath, arguments: arguments)
    }

    private static let defaultDownloadFile: Downloader = { sourceURL, destinationURL in
        let (temporaryURL, _) = try await URLSession.shared.download(from: sourceURL)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    }

    private static let defaultRelaunchApp: RelaunchHook = { appPath in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [appPath]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw AppUpdaterError.relaunchFailed
        }
    }

    private static let defaultLaunchInstallerHelper: HelperLauncher = { scriptPath in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: scriptPath)
        try process.run()
    }

    private static let defaultTerminateApp: TerminationHook = {
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    private static let defaultTemporaryDirectoryProvider: TemporaryDirectoryProvider = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static let defaultFileExists: FileExistenceChecker = { path in
        FileManager.default.fileExists(atPath: path)
    }

    // MARK: - 静态辅助

    static func dmgFilename(for version: String) -> String {
        let normalizedVersion = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return "XIsland-\(normalizedVersion).dmg"
    }

    /// 从 `hdiutil attach` 的输出中解析挂载点。
    static func mountDirectory(from output: String) -> String? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.reversed() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let candidate = columns.last?.trimmingCharacters(in: .whitespacesAndNewlines),
                  candidate.hasPrefix("/Volumes/"),
                  !candidate.isEmpty else {
                continue
            }
            return candidate
        }
        return nil
    }

    /// 分块计算文件的 SHA256，避免一次性读入整个 DMG。
    static func computeSHA256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { handle.closeFile() }

        var hasher = SHA256()
        let chunkSize = 64 * 1024
        while true {
            let chunk = autoreleasepool { handle.readData(ofLength: chunkSize) }
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 安装流程

extension AppUpdater {
    func install(
        version: String,
        releaseURL: URL,
        appPath: String,
        expectedSHA256: String? = nil,
        onStage: @escaping @MainActor (AppUpdaterStage) -> Void
    ) async throws {
        if let installImpl {
            try await installImpl(version, releaseURL, appPath, expectedSHA256, onStage)
            return
        }

        let tempDirectory = try temporaryDirectoryProvider()
        let dmgURL = tempDirectory.appendingPathComponent(Self.dmgFilename(for: version))

        await MainActor.run { onStage(.downloading) }
        do {
            try await downloadFile(releaseURL, dmgURL)
        } catch {
            throw AppUpdaterError.downloadFailed
        }

        // SHA256 完整性校验
        if let expectedHash = expectedSHA256 {
            guard let actualHash = Self.computeSHA256(of: dmgURL), actualHash == expectedHash else {
                try? FileManager.default.removeItem(at: dmgURL)
                throw AppUpdaterError.integrityCheckFailed
            }
        }

        await MainActor.run { onStage(.mounting) }
        let attachOutput: String
        do {
            attachOutput = try runCommand("/usr/bin/hdiutil", ["attach", dmgURL.path, "-nobrowse"])
        } catch {
            throw AppUpdaterError.mountFailed
        }

        guard let mountDirectory = Self.mountDirectory(from: attachOutput) else {
            throw AppUpdaterError.mountFailed
        }

        let mountedAppPath = URL(fileURLWithPath: mountDirectory)
            .appendingPathComponent("X Island.app")
            .path
        guard fileExists(mountedAppPath) else {
            throw AppUpdaterError.appNotFound
        }

        // 校验挂载应用的代码签名
        do {
            _ = try runCommand("/usr/bin/codesign", ["--verify", "--deep", "--strict", mountedAppPath])
        } catch {
            throw AppUpdaterError.codeSigningFailed
        }

        await MainActor.run { onStage(.installing) }
        let installerScript = tempDirectory.appendingPathComponent("install-update.sh")
        do {
            try Self.writeInstallerScript(
                to: installerScript,
                currentPID: ProcessInfo.processInfo.processIdentifier,
                mountedAppPath: mountedAppPath,
                appPath: appPath,
                mountDirectory: mountDirectory,
                tempDirectory: tempDirectory.path
            )
        } catch {
            throw AppUpdaterError.installFailed
        }

        await MainActor.run { onStage(.relaunching) }
        do {
            try launchInstallerHelper(installerScript.path)
        } catch {
            throw AppUpdaterError.relaunchFailed
        }

        terminateApp()
    }
}

// MARK: - 安装脚本生成

private extension AppUpdater {
    static func writeInstallerScript(
        to scriptURL: URL,
        currentPID: Int32,
        mountedAppPath: String,
        appPath: String,
        mountDirectory: String,
        tempDirectory: String
    ) throws {
        let script = makeInstallerScript(
            currentPID: currentPID,
            mountedAppPath: mountedAppPath,
            appPath: appPath,
            mountDirectory: mountDirectory,
            tempDirectory: tempDirectory
        )

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    private static func makeInstallerScript(
        currentPID: Int32,
        mountedAppPath: String,
        appPath: String,
        mountDirectory: String,
        tempDirectory: String
    ) -> String {
        let lines = [
            "#!/bin/sh",
            "set -eu",
            "",
            "TEMP_DIR=\(shellQuoted(tempDirectory))",
            "trap 'rm -rf \"$TEMP_DIR\"' EXIT",
            "",
            "while kill -0 \(currentPID) 2>/dev/null; do",
            "  sleep 0.2",
            "done",
            "",
            "rm -rf \(shellQuoted(appPath))",
            "cp -R \(shellQuoted(mountedAppPath)) \(shellQuoted(appPath))",
            "xattr -cr \(shellQuoted(appPath)) || true",
            "",
            "codesign --verify --deep --strict \(shellQuoted(appPath))",
            "",
            "hdiutil detach \(shellQuoted(mountDirectory)) -quiet >/dev/null 2>&1 || true",
            "open \(shellQuoted(appPath))",
        ]
        return lines.joined(separator: "\n")
    }

    /// 用单引号包裹并转义，防止路径中的特殊字符破坏 shell 命令。
    static func shellQuoted(_ value: String) -> String {
        // POSIX 单引号转义：把每个 ' 替换为 '\''
        let escaped = value.replacingOccurrences(of: "'", with: #"'\''"#)
        return "'\(escaped)'"
    }
}
