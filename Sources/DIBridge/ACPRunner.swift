import Foundation
import Darwin
import DIShared

/// 单独进程内的 stdio 透明包装器。标准输出仅包含原 Agent 的字节。
enum ACPRunner {
    struct Options {
        let host: String
        let source: String
        let command: String
        let arguments: [String]
    }
    enum RunnerError: Error { case invalidArguments, unavailableExecutable, system(Int32) }

    static func options(_ arguments: [String], cody: Bool = false) throws -> Options {
        var host: String? = cody ? "cody" : nil
        var source: String?
        var index = 0
        while index < arguments.count && arguments[index] != "--" {
            guard index + 1 < arguments.count else { throw RunnerError.invalidArguments }
            switch arguments[index] {
            case "--host": guard host == nil else { throw RunnerError.invalidArguments }; host = arguments[index + 1]
            case "--source": guard source == nil else { throw RunnerError.invalidArguments }; source = arguments[index + 1]
            default: throw RunnerError.invalidArguments
            }
            index += 2
        }
        guard index < arguments.count, arguments[index] == "--", index + 1 < arguments.count,
              let host, let source, !arguments[index + 1].isEmpty else { throw RunnerError.invalidArguments }
        if cody { _ = try CodyEventObserver(source: source) }
        else { _ = try ACPEventObserver(host: host, source: source) }
        return Options(host: host, source: source, command: arguments[index + 1], arguments: Array(arguments.dropFirst(index + 2)))
    }

    static func run(arguments: [String], bridgePath: String, cody: Bool = false,
                    environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        guard environment["X_ISLAND_ACP_WRAPPER_ACTIVE"] == nil else { return 126 }
        do {
            let options = try options(arguments, cody: cody)
            guard let executable = AiderLauncher.executablePath(options.command, environment: environment),
                  executable != AiderLauncher.executablePath(bridgePath, environment: environment) else { throw RunnerError.unavailableExecutable }
            let observations = try Observations(host: options.host, source: options.source, cody: cody,
                                                socketPath: DIBridge.socketPath(environment: environment))
            let pipes = try StdioPipes()
            defer { pipes.closeAll() }
            let pumps = DispatchGroup(), inputPump = DispatchGroup()
            let state = PumpState()
            var originalPipeSignal = sigaction()
            _ = sigaction(SIGPIPE, nil, &originalPipeSignal)
            defer { _ = sigaction(SIGPIPE, &originalPipeSignal, nil) }
            var childEnvironment = environment
            childEnvironment["X_ISLAND_ACP_WRAPPER_ACTIVE"] = "1"
            var started = false
            defer {
                state.stop()
                if started { inputPump.wait(); pumps.wait() }
                observations.finish()
            }
            defer { pipes.restoreStandardIO() }
            try pipes.redirectForSpawn()
            let result = try TerminalProcessSupervisor.run(executable: executable, arguments: options.arguments,
                                                            environment: childEnvironment) { pid in
                started = true
                pipes.restoreStandardIO()
                pipes.closeChildEnds()
                // 子进程已经创建，保留其原 SIGPIPE 处置；只有转发器忽略管道断开信号。
                signal(SIGPIPE, SIG_IGN)
                inputPump.enter()
                DispatchQueue.global().async {
                    defer { close(pipes.agentInput); inputPump.leave() }
                    pump(from: pipes.clientInput, to: pipes.agentInput, stopped: { state.stopped },
                         chunk: { observations.enqueue($0, direction: .clientToAgent) },
                         failed: { if !state.stopped { kill(-pid, SIGTERM) } })
                }
                pumps.enter()
                DispatchQueue.global().async {
                    defer { pumps.leave() }
                    pump(from: pipes.agentOutput, to: pipes.clientOutput, stopped: { false },
                         chunk: { observations.enqueue($0, direction: .agentToClient) },
                         failed: { if !state.stopped { kill(-pid, SIGTERM) } })
                }
            }
            return result
        } catch {
            fputs(cody ? "[XIsland] Cody 包装器启动失败；用法：di-bridge cody-agent --source 名称 -- Agent命令 [参数]\n" : "[XIsland] ACP 包装器启动失败；用法：di-bridge acp --host zed|jetbrains_ai --source 名称 -- Agent命令 [参数]\n", stderr)
            return 126
        }
    }

    private static func pump(from input: Int32, to output: Int32, stopped: () -> Bool,
                             chunk: (Data) -> Void, failed: () -> Void) {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while !stopped() {
            var descriptor = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 50)
            if ready < 0 { if errno == EINTR { continue }; failed(); return }
            if ready == 0 { continue }
            let count = read(input, &buffer, buffer.count)
            if count == 0 { return }
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; failed(); return }
            let data = Data(buffer.prefix(count))
            // 排队在写出之前：快速 Agent 的响应不能越过本端尚未登记的请求。
            chunk(data)
            let success = data.withUnsafeBytes { bytes -> Bool in
                guard let base = bytes.baseAddress else { return true }
                var offset = 0
                while offset < count && !stopped() {
                    var destination = pollfd(fd: output, events: Int16(POLLOUT), revents: 0)
                    let available = poll(&destination, 1, 50)
                    if available < 0 { if errno == EINTR { continue }; return false }
                    if available == 0 { continue }
                    let written = write(output, base.advanced(by: offset), count - offset)
                    if written < 0 { if errno == EINTR || errno == EAGAIN { continue }; return false }
                    if written == 0 { return false }
                    offset += written
                }
                return offset == count || stopped()
            }
            if !success { failed(); return }
        }
    }

    private final class PumpState: @unchecked Sendable {
        private let lock = NSLock()
        private var ended = false
        var stopped: Bool { lock.lock(); defer { lock.unlock() }; return ended }
        func stop() { lock.lock(); ended = true; lock.unlock() }
    }

    private final class StdioPipes: @unchecked Sendable {
        let clientInput: Int32
        let clientOutput: Int32
        let agentInput: Int32
        let agentOutput: Int32
        private let childInput: Int32
        private let childOutput: Int32
        private var childEndsClosed = false
        private var redirected = false
        private var originalInputFlags: Int32 = 0
        private var originalOutputFlags: Int32 = 0

        init() throws {
            var descriptors: [Int32] = []
            var flagsToRestore: [(Int32, Int32)] = []
            func duplicate(_ fd: Int32) throws -> Int32 {
                let copy = dup(fd)
                guard copy >= 0 else { throw RunnerError.system(errno) }
                descriptors.append(copy)
                guard fcntl(copy, F_SETFD, FD_CLOEXEC) == 0 else { throw RunnerError.system(errno) }
                return copy
            }
            func pipePair() throws -> [Int32] {
                var pair: [Int32] = [-1, -1]
                guard pipe(&pair) == 0 else { throw RunnerError.system(errno) }
                descriptors += pair
                for fd in pair { guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw RunnerError.system(errno) } }
                return pair
            }
            do {
                clientInput = try duplicate(STDIN_FILENO); clientOutput = try duplicate(STDOUT_FILENO)
                let input = try pipePair(), output = try pipePair()
                childInput = input[0]; agentInput = input[1]
                agentOutput = output[0]; childOutput = output[1]
                originalInputFlags = fcntl(clientInput, F_GETFL)
                originalOutputFlags = fcntl(clientOutput, F_GETFL)
                for fd in [clientInput, clientOutput, agentInput, agentOutput] {
                    let flags = fcntl(fd, F_GETFL)
                    if flags >= 0 { flagsToRestore.append((fd, flags)) }
                    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw RunnerError.system(errno) }
                }
            } catch {
                for (fd, flags) in flagsToRestore { _ = fcntl(fd, F_SETFL, flags) }
                for fd in descriptors { close(fd) }
                throw error
            }
        }
        func redirectForSpawn() throws {
            redirected = true
            guard dup2(childInput, STDIN_FILENO) >= 0, dup2(childOutput, STDOUT_FILENO) >= 0 else { throw RunnerError.system(errno) }
        }
        func restoreStandardIO() {
            guard redirected else { return }
            _ = dup2(clientInput, STDIN_FILENO); _ = dup2(clientOutput, STDOUT_FILENO)
            redirected = false
        }
        func closeChildEnds() { close(childInput); close(childOutput); childEndsClosed = true }
        func closeAll() {
            restoreStandardIO()
            _ = fcntl(clientInput, F_SETFL, originalInputFlags); _ = fcntl(clientOutput, F_SETFL, originalOutputFlags)
            close(clientInput); close(clientOutput); close(agentOutput)
            if !childEndsClosed { close(childInput); close(childOutput); close(agentInput) }
        }
    }

    private final class Observations: @unchecked Sendable {
        let queue = DispatchQueue(label: "xisland.acp.observation")
        let observer: ACPEventObserver?
        let codyObserver: CodyEventObserver?
        let codyFramer = CodyMessageFramer()
        var codyStopped = false
        let socketPath: String
        let lock = NSLock()
        var pendingBytes = 0
        var paused = false
        var client = Data(), agent = Data()
        init(host: String, source: String, cody: Bool, socketPath: String) throws {
            observer = cody ? nil : try ACPEventObserver(host: host, source: source)
            codyObserver = cody ? try CodyEventObserver(source: source) : nil
            self.socketPath = socketPath
        }
        func enqueue(_ data: Data, direction: ACPEventObserver.Direction) {
            lock.lock()
            if paused { lock.unlock(); return }
            if pendingBytes + data.count > 2_097_152 {
                paused = true; lock.unlock()
                queue.async {
                    self.send(self.observer?.suspend() ?? self.codyObserver?.finish(interrupted: true) ?? [])
                }
                return
            }
            pendingBytes += data.count
            queue.async {
                defer { self.lock.lock(); self.pendingBytes -= data.count; self.lock.unlock() }
                if let cody = self.codyObserver {
                    guard direction == .agentToClient, !self.codyStopped else { return }
                    self.codyFramer.consume(data) { frame in
                        guard !self.codyStopped else { return }
                        do { self.send(try cody.consumeAgentFrame(frame)) }
                        catch {
                            self.codyStopped = true
                            self.send(cody.finish(interrupted: true))
                        }
                    }
                    if self.codyFramer.stopped { self.send(cody.finish(interrupted: true)) }
                    return
                }
                var accumulated = direction == .clientToAgent ? self.client : self.agent
                accumulated.append(data)
                while let newline = accumulated.firstIndex(of: 10) {
                    self.send(self.observer?.consume(Data(accumulated[..<newline]), direction: direction) ?? [])
                    accumulated.removeSubrange(...newline)
                }
                if accumulated.count > 1_048_576 {
                    self.send(self.observer?.suspend() ?? []); accumulated.removeAll()
                }
                if direction == .clientToAgent { self.client = accumulated } else { self.agent = accumulated }
            }
            lock.unlock()
        }
        func send(_ messages: [DIMessage]) {
            for message in messages { ObservationSender.send(message, socketPath: socketPath) }
        }
        func finish() {
            let finished = DispatchSemaphore(value: 0)
            queue.async {
                self.codyFramer.finish()
                self.send(self.codyObserver?.finish(interrupted: self.codyFramer.stopped || self.codyStopped) ?? [])
                finished.signal()
            }
            _ = finished.wait(timeout: .now() + 0.25)
        }
    }
}
