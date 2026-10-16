import Foundation
import Darwin

/// 仅自动配置已核实的 Codewhale 发布线；旧 DeepSeek-TUI 不因配置文件同名而被视为兼容。
enum DeepSeekHookInstallation {
    static func isSupportedVersionOutput(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "codewhale \(DeepSeekHookConfiguration.supportedVersion)"
            || value == "codewhale \(DeepSeekHookConfiguration.supportedVersion) (1be1a703b975)"
    }

    static func configURL(homeDirectory: String, environment: [String: String]) throws -> URL {
        URL(fileURLWithPath: try DeepSeekHookConfiguration.resolvedConfigPath(homeDirectory: homeDirectory,
            environment: environment, fileExists: { FileManager.default.fileExists(atPath: $0) }))
    }

    @discardableResult
    static func install(homeDirectory: String, bridgePath: String, environment: [String: String]) throws -> Bool {
        guard let executable = executable(homeDirectory: homeDirectory, environment: environment),
              let version = versionOutput(at: executable, environment: environment), isSupportedVersionOutput(version) else { return false }
        let url = try configURL(homeDirectory: homeDirectory, environment: environment)
        try HookConfigurationFile.updateText(at: url) { try DeepSeekHookConfiguration.merging(into: $0, bridgePath: bridgePath) }
        return true
    }

    static func isConfigured(homeDirectory: String, bridgePath: String, environment: [String: String]) -> Bool {
        guard let url = try? configURL(homeDirectory: homeDirectory, environment: environment),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return DeepSeekHookConfiguration.isConfigured(in: text, bridgePath: bridgePath)
    }

    static func remove(homeDirectory: String, environment: [String: String]) throws {
        let url = try configURL(homeDirectory: homeDirectory, environment: environment)
        try HookConfigurationFile.updateText(at: url) { try DeepSeekHookConfiguration.removing(from: $0) }
    }

    static func shouldRepair(homeDirectory: String, bridgePath: String, environment: [String: String]) -> Bool {
        guard let url = try? configURL(homeDirectory: homeDirectory, environment: environment),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !DeepSeekHookConfiguration.isConfigured(in: text, bridgePath: bridgePath),
              let cleaned = try? DeepSeekHookConfiguration.removing(from: text), cleaned != text,
              (try? DeepSeekHookConfiguration.merging(into: text, bridgePath: bridgePath)) != nil else { return false }
        return true
    }

    private static func executable(homeDirectory: String, environment: [String: String]) -> URL? {
        let directories = (environment["PATH"] ?? "").components(separatedBy: ":")
            + [homeDirectory + "/.cargo/bin", homeDirectory + "/.local/bin", "/opt/homebrew/bin"]
        for directory in directories where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("codewhale")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// 只运行 --version，不读取对话。状态轮询不调用此探测；超时不写任何配置。
    static func versionOutput(at executable: URL, environment: [String: String], timeout: TimeInterval = 0.5) -> String? {
        guard timeout > 0, timeout.isFinite else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) != .success {
            if process.isRunning { process.terminate() }
            if done.wait(timeout: .now() + 0.1) != .success, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 0.1)
            }
            return nil
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        // 不等待继承了 stdout 的后台后代；版本输出有严格大小上限。
        let fd = output.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 257)
        let count = read(fd, &bytes, bytes.count)
        guard count > 0, count <= 256 else { return nil }
        return String(bytes: bytes.prefix(count), encoding: .utf8)
    }
}
