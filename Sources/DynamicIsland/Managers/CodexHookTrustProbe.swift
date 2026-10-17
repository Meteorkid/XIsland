import CoreFoundation
import CryptoKit
import Darwin
import Foundation

struct CodexHookTrustSnapshot: Sendable {
    enum State: Sendable { case granted, required, unavailable }

    let state: State
    let fingerprint: String?
    let configuredCount: Int
    let trustedCount: Int
    let reason: String?
}

enum CodexHookTrustProbe {
    private static let outputLimit = 4 * 1_024 * 1_024
    private static let responseTimeout: TimeInterval = 7

    static func inspect(binary: URL, cwd: URL, expectedCommands: Set<String>) async -> CodexHookTrustSnapshot {
        guard !expectedCommands.isEmpty, expectedCommands.allSatisfy({ !$0.isEmpty }) else {
            return unavailable("没有可核对的 XIsland hook 命令。")
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let response = try readHooks(binary: binary, cwd: cwd)
                    continuation.resume(returning: try parse(response: response, expectedCommands: expectedCommands))
                } catch {
                    // 不回传服务端正文、stderr 或第三方 hook 定义。
                    let reason = (error as? ProbeError)?.errorDescription ?? "无法读取 Codex hook 授权状态。"
                    continuation.resume(returning: unavailable(reason))
                }
            }
        }
    }

    static func parse(response: [String: Any], expectedCommands: Set<String>) throws -> CodexHookTrustSnapshot {
        guard !expectedCommands.isEmpty, expectedCommands.allSatisfy({ !$0.isEmpty }) else {
            return unavailable("没有可核对的 XIsland hook 命令。")
        }
        guard let entries = response["data"] as? [[String: Any]], entries.count == 1,
              let entry = entries.first, entry["cwd"] is String,
              let hooks = entry["hooks"] as? [[String: Any]],
              let errors = entry["errors"] as? [Any],
              entry["warnings"] is [String] else { throw ProbeError.invalidResponse }
        guard errors.isEmpty else { return unavailable("Codex 报告 hook 配置读取错误。") }

        var commands = Set<String>()
        var trustedCount = 0
        var definitions: [[String: String]] = []
        var problem: String?
        for hook in hooks {
            guard let command = hook["command"] as? String, expectedCommands.contains(command) else { continue }
            guard commands.insert(command).inserted else {
                problem = "Codex 返回了重复的 XIsland hook 命令。"
                continue
            }
            guard hook["handlerType"] as? String == "command",
                  let enabled = boolean(hook["enabled"]),
                  let managed = boolean(hook["isManaged"]),
                  let status = hook["trustStatus"] as? String,
                  ["trusted", "untrusted", "modified", "managed"].contains(status),
                  let currentHash = hook["currentHash"] as? String, !currentHash.isEmpty else {
                problem = "Codex 返回的 XIsland hook 授权信息不完整。"
                continue
            }
            definitions.append(["command": command, "currentHash": currentHash])
            if managed || status == "managed" {
                problem = "XIsland hook 由管理策略控制，无法确认用户授权。"
            } else if !enabled {
                problem = "XIsland hook 尚未启用。"
            } else if status == "trusted" {
                trustedCount += 1
            }
        }
        if commands != expectedCommands { problem = "Codex 尚未读取全部 XIsland hook 配置。" }
        guard problem == nil else {
            return unavailable(problem!, configuredCount: commands.count, trustedCount: trustedCount)
        }

        // 只使用精确匹配的自有定义；授权状态变化不改变提醒去重指纹。
        definitions.sort { $0["command"]! < $1["command"]! }
        let data = try JSONSerialization.data(withJSONObject: definitions, options: [.sortedKeys])
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return CodexHookTrustSnapshot(
            state: trustedCount == expectedCommands.count ? .granted : .required,
            fingerprint: fingerprint,
            configuredCount: commands.count,
            trustedCount: trustedCount,
            reason: trustedCount == expectedCommands.count ? nil : "请在 Codex 中确认 XIsland hook 授权。"
        )
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func unavailable(_ reason: String, configuredCount: Int = 0, trustedCount: Int = 0) -> CodexHookTrustSnapshot {
        CodexHookTrustSnapshot(state: .unavailable, fingerprint: nil, configuredCount: configuredCount,
                               trustedCount: trustedCount, reason: reason)
    }

    private enum ProbeError: LocalizedError {
        case invalidResponse, rejected, closed, timeout, outputLimit, io

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Codex 返回了无法识别的授权状态。"
            case .rejected: return "当前 Codex 不支持读取 hook 授权状态。"
            case .closed: return "Codex 在返回授权状态前已退出。"
            case .timeout: return "读取 Codex hook 授权状态超时。"
            case .outputLimit: return "Codex 授权状态响应超过大小限制。"
            case .io: return "无法读取 Codex hook 授权状态。"
            }
        }
    }

    private static func readHooks(binary: URL, cwd: URL) throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + responseTimeout
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let terminated = DispatchSemaphore(value: 0)
        process.executableURL = binary
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = cwd
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in terminated.signal() }
        var launched = false
        defer {
            try? input.fileHandleForWriting.close()
            if launched && process.isRunning {
                process.terminate()
                if terminated.wait(timeout: .now() + 0.15) == .timedOut {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    _ = terminated.wait(timeout: .now() + 0.35)
                }
            }
            try? input.fileHandleForReading.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        try process.run()
        launched = true
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        let readFD = output.fileHandleForReading.fileDescriptor
        let writeFD = input.fileHandleForWriting.fileDescriptor
        guard fcntl(readFD, F_SETFL, O_NONBLOCK) != -1,
              fcntl(writeFD, F_SETFL, O_NONBLOCK) != -1,
              fcntl(writeFD, F_SETNOSIGPIPE, 1) != -1 else { throw ProbeError.io }

        var outgoing = try packet([
            "id": 1, "method": "initialize",
            "params": ["clientInfo": ["name": "xisland-hook-trust", "version": "1"],
                       "capabilities": ["experimentalApi": true]]
        ])
        var incoming = Data()
        var totalBytes = 0
        var requestID = 1
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ProbeError.timeout }
            // 同时轮询输入和输出，避免对方输出管道已满时继续阻塞写入。
            var descriptors = [pollfd(fd: readFD, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: writeFD, events: outgoing.isEmpty ? 0 : Int16(POLLOUT), revents: 0)]
            let ready = poll(&descriptors, nfds_t(descriptors.count), Int32(min(remaining * 1_000, 100)))
            if ready < 0 {
                if errno == EINTR { continue }
                throw ProbeError.io
            }
            if descriptors[0].revents & Int16(POLLIN | POLLHUP) != 0 {
                let count = Darwin.read(readFD, &buffer, buffer.count)
                if count == 0 { throw ProbeError.closed }
                if count < 0 {
                    if errno != EAGAIN && errno != EINTR { throw ProbeError.io }
                } else {
                    totalBytes += count
                    guard totalBytes <= outputLimit else { throw ProbeError.outputLimit }
                    var scanOffset = incoming.count
                    incoming.append(contentsOf: buffer.prefix(count))
                    while let newline = incoming[incoming.index(incoming.startIndex, offsetBy: scanOffset)...].firstIndex(of: 10) {
                        let line = incoming.prefix(upTo: newline)
                        let value = try? JSONSerialization.jsonObject(with: line)
                        incoming.removeSubrange(...newline)
                        scanOffset = 0
                        guard let reply = value as? [String: Any] else { throw ProbeError.invalidResponse }
                        guard let identifier = reply["id"] as? NSNumber,
                              CFGetTypeID(identifier) != CFBooleanGetTypeID(),
                              identifier == NSNumber(value: requestID) else { continue }
                        guard outgoing.isEmpty else { throw ProbeError.invalidResponse }
                        guard reply["error"] == nil else { throw ProbeError.rejected }
                        guard let result = reply["result"] as? [String: Any] else { throw ProbeError.invalidResponse }
                        if requestID == 2 {
                            guard let entries = result["data"] as? [[String: Any]], entries.count == 1,
                                  let responseCWD = entries[0]["cwd"] as? String,
                                  URL(fileURLWithPath: responseCWD).resolvingSymlinksInPath().standardizedFileURL ==
                                    cwd.resolvingSymlinksInPath().standardizedFileURL else { throw ProbeError.invalidResponse }
                            return result
                        }
                        requestID = 2
                        outgoing.append(try packet(["method": "initialized", "params": [:]]))
                        outgoing.append(try packet(["id": 2, "method": "hooks/list", "params": ["cwds": [cwd.path]]]))
                    }
                }
            }
            if !outgoing.isEmpty && descriptors[1].revents & Int16(POLLOUT) != 0 {
                let written = outgoing.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }
                if written > 0 { outgoing.removeFirst(written) }
                else if written < 0 && errno != EAGAIN && errno != EINTR { throw ProbeError.io }
            }
            if descriptors.contains(where: { $0.revents & Int16(POLLERR | POLLNVAL) != 0 }) { throw ProbeError.io }
        }
    }

    private static func packet(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        return data
    }
}
