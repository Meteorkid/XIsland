import Foundation
import Darwin

enum AmazonQVersionProbe {
    static func supports(_ output: String) -> Bool {
        output.trimmingCharacters(in: .whitespacesAndNewlines) == "qchat 1.19.7"
    }

    /// 固定源码中 --version 在 clap 解析阶段退出，不进入聊天初始化。
    static func verify(executable: String, environment: [String: String], timeout: TimeInterval = 1) -> Bool {
        guard timeout.isFinite, timeout > 0 else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return false }
        if finished.wait(timeout: .now() + timeout) != .success {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 0.1) != .success, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.1)
            }
            return false
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return false }
        let fd = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return false }
        var bytes = [UInt8](repeating: 0, count: 257)
        let count = read(fd, &bytes, bytes.count)
        guard count > 0, count <= 256, let text = String(bytes: bytes.prefix(count), encoding: .utf8) else { return false }
        return supports(text)
    }
}
