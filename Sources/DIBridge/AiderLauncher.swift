import Foundation
import Darwin
import DIShared

/// 显式启动的进程观察器。UUID 属于包装器生命周期，不冒充 Aider 原生会话。
enum AiderLauncher {
    private static let recursionKey = "X_ISLAND_AIDER_WRAPPER_ACTIVE"

    static func run(arguments: [String], bridgePath: String,
                    environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        if arguments == ["--xisland-help"] {
            print("""
            用法：xisland-aider [Aider 参数…]
            本次进程使用 XIsland 通知；原有配置文件保持不变。
            用户显式的通知选项仍可覆盖它，此时可能只观察到进程生命周期。
            通知不代表任务完成或审批请求；对话与工具内容不会被包装器读取。
            """)
            return 0
        }
        guard environment[recursionKey] == nil else {
            fputs("[XIsland] 检测到 Aider 包装器递归，未启动子进程。\n", stderr)
            return 126
        }
        guard let executable = executablePath("aider", environment: environment),
              let bridge = executablePath(bridgePath, environment: environment), executable != bridge else {
            fputs("[XIsland] 未找到可执行的 aider，或路径指向包装器自身。\n", stderr)
            return 127
        }
        var childEnvironment = environment
        childEnvironment[recursionKey] = "1"
        let lifecycle: Lifecycle?
        do { lifecycle = try Lifecycle(environment: environment) }
        catch {
            fputs("[XIsland] 无法创建本次观察状态，将使用 Aider 原有通知设置。\n", stderr)
            lifecycle = nil
        }
        defer { lifecycle?.remove() }
        let forwarded: [String]
        if let lifecycle {
            let command = shellQuote(bridge) + " aider-notify " + shellQuote(lifecycle.url.path) + " </dev/null"
            // 不解析或重新拼接用户 argv，后续显式选项按 Aider 自身语义覆盖。
            forwarded = ["--notifications", "--notifications-command", command] + arguments
            fputs("[XIsland] 本次 Aider 使用 XIsland 通知；通知仅提示查看终端，不代表任务完成。\n", stderr)
        } else { forwarded = arguments }
        do {
            let result = try TerminalProcessSupervisor.run(executable: executable, arguments: forwarded,
                                                           environment: childEnvironment) { pid in
                lifecycle?.start(childPID: pid)
            }
            lifecycle?.finish(exitCode: result)
            return result
        } catch {
            fputs("[XIsland] 无法启动或监督 Aider 进程。\n", stderr)
            lifecycle?.finish(exitCode: 126)
            return 126
        }
    }

    /// 此入口完全不读取 stdin；Aider 的通知命令默认继承交互终端输入。
    static func notify(statePath: String) {
        let descriptor = open(statePath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 16_384,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(descriptor, LOCK_UN) }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = pread(descriptor, &bytes, bytes.count, 0)
        guard count == bytes.count, let state = try? JSONDecoder().decode(State.self, from: Data(bytes)),
              state.version == 1, state.active, state.ownerPID > 1, kill(state.ownerPID, 0) == 0,
              state.id.hasPrefix("aider-wrapper-"), UUID(uuidString: String(state.id.dropFirst("aider-wrapper-".count))) != nil else { return }
        var message = state.message(type: .statusUpdate)
        message.status = "收到 Aider 通知，请查看终端"
        ObservationSender.send(message, socketPath: state.socketPath)
    }

    static func executablePath(_ command: String, environment: [String: String]) -> String? {
        guard !command.isEmpty, !command.utf8.contains(0) else { return nil }
        let candidates = command.contains("/") ? [command]
            : (environment["PATH"] ?? "/usr/bin:/bin").components(separatedBy: ":").map { ($0.isEmpty ? "." : $0) + "/" + command }
        for candidate in candidates {
            let path = URL(fileURLWithPath: candidate).standardizedFileURL.resolvingSymlinksInPath().path
            var info = stat()
            if stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(path, X_OK) == 0 { return path }
        }
        return nil
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private struct State: Codable {
        let version: Int
        let id: String
        let ownerPID: pid_t
        let workingDirectory: String
        let terminal: String?
        let terminalSession: String?
        let socketPath: String
        var active = false

        func message(type: DIMessageType) -> DIMessage {
            var message = DIMessage(type: type, sessionId: id)
            message.agentType = "aider"
            message.workingDir = workingDirectory
            message.terminal = terminal
            message.termSessionId = terminalSession
            message.statusIsAssistantReply = false
            return message
        }
    }

    private final class Lifecycle {
        let url: URL
        let descriptor: Int32
        var state: State
        var started = false

        init(environment: [String: String]) throws {
            let id = UUID().uuidString
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-aider-\(id)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            url = directory.appendingPathComponent("state.json")
            descriptor = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                try? FileManager.default.removeItem(at: directory)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            state = State(version: 1, id: "aider-wrapper-\(id)", ownerPID: getpid(), workingDirectory: FileManager.default.currentDirectoryPath,
                          terminal: environment["TERM_PROGRAM"], terminalSession: environment["TERM_SESSION_ID"],
                          socketPath: DIBridge.socketPath(environment: environment))
        }

        deinit { close(descriptor) }

        func start(childPID: pid_t) {
            guard childPID > 1, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
            defer { flock(descriptor, LOCK_UN) }
            state.active = true
            guard writeState() else { state.active = false; return }
            started = true
            var message = state.message(type: .sessionStart)
            message.status = "Aider 进程已连接；轮次状态不可用"
            ObservationSender.send(message, socketPath: state.socketPath)
        }

        func finish(exitCode: Int32) {
            guard started else { return }
            // 正常回调最多发送100ms；若外部暂停回调进程，不无限阻塞 Aider 退出。
            let deadline = ProcessInfo.processInfo.systemUptime + 0.3
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EINTR,
                      ProcessInfo.processInfo.systemUptime < deadline else { return }
                usleep(1_000)
            }
            defer { flock(descriptor, LOCK_UN) }
            state.active = false
            guard writeState() else { return }
            var message = state.message(type: .sessionEnd)
            message.observedState = "completed"
            message.status = "Aider 进程已退出（退出码 \(exitCode)）"
            ObservationSender.send(message, socketPath: state.socketPath)
            started = false
        }

        private func writeState() -> Bool {
            guard let data = try? JSONEncoder().encode(state), data.count <= 16_384 else { return false }
            let written = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
            return written == data.count && ftruncate(descriptor, off_t(data.count)) == 0
        }

        func remove() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

}
