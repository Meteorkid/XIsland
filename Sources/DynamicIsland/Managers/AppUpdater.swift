import AppKit
import CryptoKit
import Dispatch
import Foundation
import UpdateSecurity

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
    case updateSignatureFailed
    case terminationCancelled

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
        case .updateSignatureFailed:
            return "The update manifest signature did not verify."
        case .terminationCancelled:
            return "History was not saved. The update was cancelled."
        }
    }
}

// MARK: - 更新器

struct AppUpdater {

    /// Info.plist 中可选的 Developer ID Team ID。发布构建由
    /// `X_ISLAND_UPDATE_TEAM_ID` 写入；未配置时回退到当前运行 App 的 Team ID。
    static let teamIdentifierInfoKey = "XIslandUpdateTeamIdentifier"

    /// Info.plist 中的 Ed25519 更新公钥（base64 原始 32 字节）。
    /// 私钥不进入仓库，只用于发布机签名 manifest。
    static let updatePublicKeyInfoKey = "XIslandUpdatePublicKey"
    static let updateKeyIDInfoKey = "XIslandUpdateKeyID"

    static var expectedTeamIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: teamIdentifierInfoKey) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var expectedUpdatePublicKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: updatePublicKeyInfoKey) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var expectedUpdateKeyID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: updateKeyIDInfoKey) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var updateVerifierPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/xisland-update-verify")
            .path
    }

    /// 代码签名校验结果。
    enum SignatureVerification {
        /// 校验通过。`teamIdentifier` 为 nil 表示只验证了签名自洽，未验证签名者身份。
        case accepted(teamIdentifier: String?)
        case rejected(reason: String)
    }

    // 依赖注入所用的类型别名，便于测试中替换实现
    typealias CommandRunner = @Sendable (_ launchPath: String, _ arguments: [String]) throws -> String
    typealias Downloader = @Sendable (_ sourceURL: URL, _ destinationURL: URL) async throws -> Void
    typealias RelaunchHook = @Sendable (_ appPath: String) throws -> Void
    typealias HelperLauncher = @Sendable (_ scriptPath: String) throws -> Void
    typealias TerminationHook = @Sendable () -> Void
    typealias TerminationPreparation = @Sendable () async -> Bool
    typealias TerminationCancellation = @Sendable () async -> Void
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
    let prepareTermination: TerminationPreparation
    let cancelTermination: TerminationCancellation
    let temporaryDirectoryProvider: TemporaryDirectoryProvider
    let fileExists: FileExistenceChecker
    let installImpl: InstallHandler?

    init(
        runCommand: @escaping CommandRunner = Self.defaultRunCommand,
        downloadFile: @escaping Downloader = Self.defaultDownloadFile,
        relaunchApp: @escaping RelaunchHook = Self.defaultRelaunchApp,
        launchInstallerHelper: @escaping HelperLauncher = Self.defaultLaunchInstallerHelper,
        terminateApp: @escaping TerminationHook = Self.defaultTerminateApp,
        prepareTermination: @escaping TerminationPreparation = Self.defaultPrepareTermination,
        cancelTermination: @escaping TerminationCancellation = Self.defaultCancelTermination,
        temporaryDirectoryProvider: @escaping TemporaryDirectoryProvider = Self.defaultTemporaryDirectoryProvider,
        fileExists: @escaping FileExistenceChecker = Self.defaultFileExists,
        installImpl: InstallHandler? = nil
    ) {
        self.runCommand = runCommand
        self.downloadFile = downloadFile
        self.relaunchApp = relaunchApp
        self.launchInstallerHelper = launchInstallerHelper
        self.terminateApp = terminateApp
        self.prepareTermination = prepareTermination
        self.cancelTermination = cancelTermination
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
            guard AppDelegate.shared?.commitUpdateTermination() == true else { return }
            NSApp.terminate(nil)
        }
    }

    private static let defaultPrepareTermination: TerminationPreparation = {
        await AppDelegate.shared?.prepareForUpdateTermination() ?? false
    }

    private static let defaultCancelTermination: TerminationCancellation = {
        await AppDelegate.shared?.cancelUpdateTermination()
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

    // MARK: - 代码签名身份校验

    /// 从 `codesign -dv --verbose=4` 的输出中解析 `TeamIdentifier`。
    ///
    /// ad-hoc 签名输出 `TeamIdentifier=not set`，此时返回 nil —— 该情况不代表签名有效，
    /// 只表示没有可用身份信息。
    static func parseTeamIdentifier(from output: String) -> String? {
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("TeamIdentifier=") else { continue }
            let value = String(line.dropFirst("TeamIdentifier=".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || value == "not set" { return nil }
            return value
        }
        return nil
    }

    /// 校验待安装应用的代码签名完整性；若配置了 Team ID，同时校验签名者身份。
    ///
    /// `codesign --verify` 只验证签名自洽（资源封印与签名匹配），ad-hoc 自签名同样能通过。
    /// 因此当 `allowSignedManifest` 为 true 时，调用方必须已经验证过独立的更新清单签名，
    /// 并用该清单的 SHA256 覆盖实际 DMG；否则 ad-hoc 包一律拒绝（fail closed）。
    func verifySignature(
        at path: String,
        expectedTeamIdentifier: String? = nil,
        allowSignedManifest: Bool = false
    ) -> SignatureVerification {
        do {
            _ = try runCommand("/usr/bin/codesign", ["--verify", "--deep", "--strict", path])
        } catch {
            return .rejected(reason: "codesign --verify failed for \(path)")
        }

        let configuredTeam = expectedTeamIdentifier ?? Self.expectedTeamIdentifier
        if let configuredTeam, !configuredTeam.isEmpty {
            guard let output = try? runCommand("/usr/bin/codesign", ["-dv", "--verbose=4", path]),
                  let actual = Self.parseTeamIdentifier(from: output) else {
                return .rejected(reason: "downloaded app carries no TeamIdentifier; expected \(configuredTeam)")
            }
            guard actual == configuredTeam else {
                return .rejected(reason: "TeamIdentifier mismatch: expected \(configuredTeam), got \(actual)")
            }
            return .accepted(teamIdentifier: actual)
        }

        if allowSignedManifest {
            return .accepted(teamIdentifier: nil)
        }

        guard let trustedTeam = currentApplicationTeamIdentifier(), !trustedTeam.isEmpty else {
            return .rejected(reason: "no trusted TeamIdentifier configured or present on the running app; refusing ad-hoc update")
        }

        guard let output = try? runCommand("/usr/bin/codesign", ["-dv", "--verbose=4", path]),
              let actual = Self.parseTeamIdentifier(from: output) else {
            return .rejected(reason: "downloaded app carries no TeamIdentifier; expected \(trustedTeam)")
        }
        guard actual == trustedTeam else {
            return .rejected(reason: "TeamIdentifier mismatch: expected \(trustedTeam), got \(actual)")
        }
        return .accepted(teamIdentifier: actual)
    }

    /// 读取待安装 App 的 CFBundleShortVersionString。
    static func appVersion(at path: String) -> String? {
        let infoPlist = URL(fileURLWithPath: path)
            .appendingPathComponent("Contents/Info.plist")
            .path
        guard let output = try? Self.executeCommand(
            launchPath: "/usr/libexec/PlistBuddy",
            arguments: ["-c", "Print :CFBundleShortVersionString", infoPlist]
        ) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 读取当前运行 App 的 Team ID；ad-hoc 包返回 nil。
    func currentApplicationTeamIdentifier() -> String? {
        let bundlePath = Bundle.main.bundleURL.path
        guard let output = try? runCommand("/usr/bin/codesign", ["-dv", "--verbose=4", bundlePath]) else {
            return nil
        }
        return Self.parseTeamIdentifier(from: output)
    }
}

// MARK: - 安装流程

extension AppUpdater {
    func install(
        version: String,
        releaseURL: URL,
        appPath: String,
        expectedSHA256: String? = nil,
        manifestURL: URL? = nil,
        signatureURL: URL? = nil,
        expectedPublicKey: String? = nil,
        expectedKeyID: String? = nil,
        onStage: @escaping @MainActor (AppUpdaterStage) -> Void
    ) async throws {
        if let installImpl {
            try await installImpl(version, releaseURL, appPath, expectedSHA256, onStage)
            return
        }

        let trustedPublicKey = expectedPublicKey ?? Self.expectedUpdatePublicKey
        let trustedKeyID = expectedKeyID ?? Self.expectedUpdateKeyID
        let requiresSignedManifest = trustedPublicKey != nil
        if requiresSignedManifest, (manifestURL == nil || signatureURL == nil) {
            throw AppUpdaterError.updateSignatureFailed
        }

        let tempDirectory = try temporaryDirectoryProvider()
        let dmgURL = tempDirectory.appendingPathComponent(Self.dmgFilename(for: version))
        let manifestPath = tempDirectory.appendingPathComponent("XIsland-\(version).manifest.json")
        let signaturePath = tempDirectory.appendingPathComponent("XIsland-\(version).manifest.sig")
        var mountedDirectory: String?
        var helperOwnsCleanup = false
        defer {
            // helper 成功启动后才接管挂载与下载目录，之前的任何失败由当前进程清理。
            if !helperOwnsCleanup {
                var canRemoveDownload = true
                if let mountedDirectory {
                    do { _ = try runCommand("/usr/bin/hdiutil", ["detach", mountedDirectory, "-quiet"]) }
                    catch {
                        canRemoveDownload = false
                        NSLog("XIsland update: detach failed; temporary update files retained.")
                    }
                }
                if canRemoveDownload {
                    do { try FileManager.default.removeItem(at: tempDirectory) }
                    catch { NSLog("XIsland update: unable to clean temporary update files.") }
                }
            }
        }

        await MainActor.run { onStage(.downloading) }

        if let trustedPublicKey, let manifestURL, let signatureURL {
            do {
                try await downloadFile(manifestURL, manifestPath)
                try await downloadFile(signatureURL, signaturePath)
            } catch {
                throw AppUpdaterError.downloadFailed
            }

            let manifestData: Data
            let signature: String
            do {
                manifestData = try Data(contentsOf: manifestPath)
                signature = try String(contentsOf: signaturePath, encoding: .utf8)
            } catch {
                throw AppUpdaterError.updateSignatureFailed
            }

            // 先验签清单，再下载 DMG。清单签名是后续 SHA256 和版本号的信任锚。
            do {
                try UpdateSignatureVerifier.verifySignature(
                    manifestData: manifestData,
                    signatureBase64: signature,
                    publicKeyBase64: trustedPublicKey
                )
            } catch {
                NSLog("XIsland update: manifest signature rejected — %@", error.localizedDescription)
                throw AppUpdaterError.updateSignatureFailed
            }
        }

        do {
            try await downloadFile(releaseURL, dmgURL)
        } catch {
            throw AppUpdaterError.downloadFailed
        }

        let actualHash = Self.computeSHA256(of: dmgURL)
        guard let actualHash else {
            throw AppUpdaterError.integrityCheckFailed
        }

        if let trustedPublicKey {
            let expectedDMG = Self.dmgFilename(for: version)
            let manifestData: Data
            let signature: String
            do {
                manifestData = try Data(contentsOf: manifestPath)
                signature = try String(contentsOf: signaturePath, encoding: .utf8)
            } catch {
                throw AppUpdaterError.updateSignatureFailed
            }

            do {
                let manifest = try UpdateSignatureVerifier.verify(
                    manifestData: manifestData,
                    signatureBase64: signature,
                    publicKeyBase64: trustedPublicKey,
                    expectedVersion: version,
                    expectedDMGFilename: expectedDMG,
                    expectedKeyID: trustedKeyID,
                    actualDMGSHA256: actualHash
                )
                if let expectedSHA256, expectedSHA256.lowercased() != manifest.sha256.lowercased() {
                    throw AppUpdaterError.integrityCheckFailed
                }
                NSLog("XIsland update: signed manifest verified; key=%@", manifest.keyID)
            } catch let error as AppUpdaterError {
                throw error
            } catch {
                NSLog("XIsland update: signed manifest rejected — %@", error.localizedDescription)
                throw AppUpdaterError.updateSignatureFailed
            }
        } else if let expectedHash = expectedSHA256 {
            guard actualHash.lowercased() == expectedHash.lowercased() else {
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
        mountedDirectory = mountDirectory

        let mountedAppPath = URL(fileURLWithPath: mountDirectory)
            .appendingPathComponent("X Island.app")
            .path
        guard fileExists(mountedAppPath) else {
            throw AppUpdaterError.appNotFound
        }

        if requiresSignedManifest {
            guard let actualVersion = Self.appVersion(at: mountedAppPath),
                  Self.updateVersion(actualVersion, matches: version) else {
                throw AppUpdaterError.updateSignatureFailed
            }
        }

        // 校验挂载应用的代码签名完整性；独立清单已经提供发布者身份时，
        // 不再要求 ad-hoc 包必须有 Team ID。
        switch verifySignature(at: mountedAppPath, allowSignedManifest: requiresSignedManifest) {
        case .accepted(let teamIdentifier):
            NSLog("XIsland update: signature verified, TeamIdentifier=%@", teamIdentifier ?? "signed-manifest")
        case .rejected(let reason):
            NSLog("XIsland update: signature rejected — %@", reason)
            throw AppUpdaterError.codeSigningFailed
        }

        if requiresSignedManifest, !fileExists(Self.updateVerifierPath) {
            throw AppUpdaterError.installFailed
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
                tempDirectory: tempDirectory.path,
                expectedTeamIdentifier: Self.expectedTeamIdentifier ?? currentApplicationTeamIdentifier(),
                expectedVersion: requiresSignedManifest ? version : nil,
                manifestPath: requiresSignedManifest ? manifestPath.path : nil,
                signaturePath: requiresSignedManifest ? signaturePath.path : nil,
                dmgPath: requiresSignedManifest ? dmgURL.path : nil,
                expectedPublicKey: requiresSignedManifest ? trustedPublicKey : nil,
                expectedKeyID: requiresSignedManifest ? trustedKeyID : nil,
                verifierPath: requiresSignedManifest ? Self.updateVerifierPath : nil
            )
        } catch {
            throw AppUpdaterError.installFailed
        }

        try Task.checkCancellation()
        guard await prepareTermination() else { throw AppUpdaterError.terminationCancelled }
        do {
            try Task.checkCancellation()
            await MainActor.run { onStage(.relaunching) }
            try Task.checkCancellation()
            do { try launchInstallerHelper(installerScript.path) }
            catch { throw AppUpdaterError.relaunchFailed }
        } catch {
            // 只有取得退出准备权的本次安装失败，才能恢复事件接收。
            await cancelTermination()
            throw error
        }
        helperOwnsCleanup = true

        terminateApp()
    }

    private static func updateVersion(_ actual: String, matches expected: String) -> Bool {
        UpdateSignatureVerifier.normalize(version: actual)
            == UpdateSignatureVerifier.normalize(version: expected)
    }
}

// MARK: - 安装脚本生成

extension AppUpdater {
    private static func writeInstallerScript(
        to scriptURL: URL,
        currentPID: Int32,
        mountedAppPath: String,
        appPath: String,
        mountDirectory: String,
        tempDirectory: String,
        expectedTeamIdentifier: String? = nil,
        expectedVersion: String? = nil,
        manifestPath: String? = nil,
        signaturePath: String? = nil,
        dmgPath: String? = nil,
        expectedPublicKey: String? = nil,
        expectedKeyID: String? = nil,
        verifierPath: String? = nil
    ) throws {
        let script = makeInstallerScript(
            currentPID: currentPID,
            mountedAppPath: mountedAppPath,
            appPath: appPath,
            mountDirectory: mountDirectory,
            tempDirectory: tempDirectory,
            expectedTeamIdentifier: expectedTeamIdentifier,
            expectedVersion: expectedVersion,
            manifestPath: manifestPath,
            signaturePath: signaturePath,
            dmgPath: dmgPath,
            expectedPublicKey: expectedPublicKey,
            expectedKeyID: expectedKeyID,
            verifierPath: verifierPath
        )

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    static func makeInstallerScript(
        currentPID: Int32,
        mountedAppPath: String,
        appPath: String,
        mountDirectory: String,
        tempDirectory: String,
        expectedTeamIdentifier: String? = nil,
        expectedVersion: String? = nil,
        manifestPath: String? = nil,
        signaturePath: String? = nil,
        dmgPath: String? = nil,
        expectedPublicKey: String? = nil,
        expectedKeyID: String? = nil,
        verifierPath: String? = nil
    ) -> String {
        """
        #!/bin/sh
        set -eu

        TEMP_DIR=\(shellQuoted(tempDirectory))
        APP_PATH=\(shellQuoted(appPath))
        MOUNT_DIR=\(shellQuoted(mountDirectory))
        EXPECTED_TEAM=\(shellQuoted(expectedTeamIdentifier ?? ""))
        EXPECTED_VERSION=\(shellQuoted(expectedVersion ?? ""))
        MANIFEST_PATH=\(shellQuoted(manifestPath ?? ""))
        SIGNATURE_PATH=\(shellQuoted(signaturePath ?? ""))
        DMG_PATH=\(shellQuoted(dmgPath ?? ""))
        EXPECTED_PUBLIC_KEY=\(shellQuoted(expectedPublicKey ?? ""))
        EXPECTED_KEY_ID=\(shellQuoted(expectedKeyID ?? ""))
        VERIFIER_PATH=\(shellQuoted(verifierPath ?? ""))
        HAS_SIGNED_MANIFEST=0
        if [ -n "$EXPECTED_PUBLIC_KEY" ]; then
          HAS_SIGNED_MANIFEST=1
        fi
        TRANSACTION_DIR=""
        REPLACEMENT_STARTED=0
        SUCCEEDED=0

        finish_install() {
          status=$?
          trap - EXIT
          trap '' HUP INT TERM
          rollback_ok=1
          if [ "$SUCCEEDED" != 1 ] && [ -n "$TRANSACTION_DIR" ]; then
            if [ -e "$TRANSACTION_DIR/previous.app" ] || [ -L "$TRANSACTION_DIR/previous.app" ]; then
              if [ -e "$APP_PATH" ] || [ -L "$APP_PATH" ]; then
                mv "$APP_PATH" "$TRANSACTION_DIR/failed.app" || rollback_ok=0
              fi
              if [ "$rollback_ok" = 1 ]; then
                mv "$TRANSACTION_DIR/previous.app" "$APP_PATH" || rollback_ok=0
              fi
              if [ "$rollback_ok" != 1 ]; then
                echo "Automatic rollback failed; previous app retained at $TRANSACTION_DIR/previous.app" >&2
              fi
            elif [ "$REPLACEMENT_STARTED" = 1 ] && { [ -e "$APP_PATH" ] || [ -L "$APP_PATH" ]; }; then
              mv "$APP_PATH" "$TRANSACTION_DIR/failed.app" || rollback_ok=0
            fi
          fi
          if [ "$SUCCEEDED" != 1 ] && [ "$rollback_ok" = 1 ] && [ -d "$APP_PATH" ]; then
            open "$APP_PATH" >/dev/null 2>&1 || true
          fi
          # 回滚失败时保留整个事务目录，避免删除唯一可恢复的旧包。
          if [ "$rollback_ok" = 1 ] && [ -n "$TRANSACTION_DIR" ]; then
            rm -rf -- "$TRANSACTION_DIR" || true
          fi
          if hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1; then
            rm -rf -- "$TEMP_DIR" || true
          else
            echo "Unable to detach update volume; temporary files retained at $TEMP_DIR" >&2
          fi
          exit "$status"
        }
        trap finish_install EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM

        while kill -0 \(currentPID) 2>/dev/null; do
          sleep 0.2
        done

        # 同父目录保证切换使用同文件系统的 rename；旧包直到验证通过才移动。
        APP_PARENT=\(shellQuoted(URL(fileURLWithPath: appPath).deletingLastPathComponent().path))
        TRANSACTION_DIR=$(mktemp -d "$APP_PARENT/.xisland-upgrade.XXXXXX")
        STAGED_APP="$TRANSACTION_DIR/X Island.app"
        cp -R \(shellQuoted(mountedAppPath)) "$STAGED_APP"
        xattr -cr "$STAGED_APP" || true
        codesign --verify --deep --strict "$STAGED_APP"

        # 独立清单验签 + DMG 实际 SHA256 复验。安装脚本在 App 退出后再次执行，
        # 防止下载完成到替换之间的文件替换或 TOCTOU。
        if [ "$HAS_SIGNED_MANIFEST" = 1 ]; then
          if [ -z "$EXPECTED_VERSION" ] || [ -z "$MANIFEST_PATH" ] || [ -z "$SIGNATURE_PATH" ] || [ -z "$DMG_PATH" ]; then
            echo "Update rejected: signed update manifest metadata is incomplete" >&2
            exit 1
          fi
          if [ ! -x "$VERIFIER_PATH" ]; then
            echo "Update rejected: update verifier is missing at $VERIFIER_PATH" >&2
            exit 1
          fi
          if [ ! -f "$MANIFEST_PATH" ] || [ ! -f "$SIGNATURE_PATH" ] || [ ! -f "$DMG_PATH" ]; then
            echo "Update rejected: signed update files are missing" >&2
            exit 1
          fi
          "$VERIFIER_PATH" "$MANIFEST_PATH" "$SIGNATURE_PATH" "$DMG_PATH" "$EXPECTED_VERSION" "$EXPECTED_PUBLIC_KEY" "$EXPECTED_KEY_ID"
          ACTUAL_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$STAGED_APP/Contents/Info.plist" 2>/dev/null || true)
          if [ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]; then
            echo "Update rejected: app version mismatch (expected $EXPECTED_VERSION, got ${ACTUAL_VERSION:-unknown})" >&2
            exit 1
          fi
        fi

        # 签名者身份校验：配置了 Team ID 时必须匹配；未配置时只允许已经通过
        # 独立清单验签的更新，纯 ad-hoc 且无清单签名的包一律拒绝。
        if [ -n "$EXPECTED_TEAM" ]; then
          ACTUAL_TEAM=$(codesign -dv --verbose=4 "$STAGED_APP" 2>&1 | awk -F= '$1 ~ /TeamIdentifier/ {print $2; exit}')
          if [ -z "$ACTUAL_TEAM" ] || [ "$ACTUAL_TEAM" = "not set" ]; then
            echo "Update rejected: downloaded app carries no TeamIdentifier (expected ${EXPECTED_TEAM:-a Developer ID})" >&2
            exit 1
          fi
          if [ "$ACTUAL_TEAM" != "$EXPECTED_TEAM" ]; then
            echo "Update rejected: TeamIdentifier mismatch (expected $EXPECTED_TEAM, got $ACTUAL_TEAM)" >&2
            exit 1
          fi
        elif [ "$HAS_SIGNED_MANIFEST" != 1 ]; then
          echo "Update rejected: no trusted TeamIdentifier configured" >&2
          exit 1
        fi

        if [ -e "$APP_PATH" ] || [ -L "$APP_PATH" ]; then
          mv "$APP_PATH" "$TRANSACTION_DIR/previous.app"
        fi
        REPLACEMENT_STARTED=1
        mv "$STAGED_APP" "$APP_PATH"
        open "$APP_PATH"
        SUCCEEDED=1
        """
    }

    /// 用单引号包裹并转义，防止路径中的特殊字符破坏 shell 命令。
    private static func shellQuoted(_ value: String) -> String {
        // POSIX 单引号转义：把每个 ' 替换为 '\''
        let escaped = value.replacingOccurrences(of: "'", with: #"'\''"#)
        return "'\(escaped)'"
    }
}
