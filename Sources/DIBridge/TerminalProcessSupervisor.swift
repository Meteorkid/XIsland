import Darwin

/// 同步监督一个直接继承终端的进程，不读取、转发或解析其标准输入输出。
///
/// 仅供命令行入口在主线程调用；信号处置属于整个进程，同一时刻只能运行一个实例。
/// `didStart` 在子进程恢复执行之前调用，应只做短时、不读取 stdin 的生命周期登记。
/// 无法处理 SIGKILL、监督器崩溃，或自行脱离该进程组的后代。
enum TerminalProcessSupervisor {
    struct Failure: Error, CustomStringConvertible {
        let operation: String
        let code: Int32

        var description: String { "\(operation): \(String(cString: strerror(code)))" }
    }

    private static var isRunning = false
    private static let forwardedSignals: [Int32] = [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGTSTP, SIGCONT, SIGWINCH]

    /// 返回普通退出码，或 shell 惯例的 `128 + signal`；不启动 shell，不修改工作目录。
    static func run(executable: String, arguments: [String], environment: [String: String],
                    didStart: (pid_t) -> Void) throws -> Int32 {
        guard pthread_main_np() != 0, !isRunning else {
            throw Failure(operation: "terminal supervisor requires the main thread", code: EBUSY)
        }
        guard !executable.isEmpty, !executable.utf8.contains(0),
              arguments.allSatisfy({ !$0.utf8.contains(0) }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=")
                  && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else {
            throw Failure(operation: "invalid process argument or environment", code: EINVAL)
        }
        isRunning = true
        defer { isRunning = false }

        let terminal = try TerminalOwnership()
        defer { terminal.closeDescriptor() }
        let signals = try SignalEvents(signals: forwardedSignals + [SIGCHLD])
        defer { signals.restore() }

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes), operation: "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_START_SUSPENDED
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)), operation: "posix_spawnattr_setflags")
        try check(posix_spawnattr_setpgroup(&attributes, 0), operation: "posix_spawnattr_setpgroup")
        var defaultSignals = signals.watchedMask
        try check(posix_spawnattr_setsigdefault(&attributes, &defaultSignals), operation: "posix_spawnattr_setsigdefault")
        var childMask = signals.originalMask
        try check(posix_spawnattr_setsigmask(&attributes, &childMask), operation: "posix_spawnattr_setsigmask")

        let argv = try CStringArray([executable] + arguments)
        let envp = try CStringArray(environment.map { "\($0.key)=\($0.value)" })
        var child: pid_t = 0
        let spawnResult = executable.withCString { path in
            posix_spawn(&child, path, nil, &attributes, argv.pointers, envp.pointers)
        }
        try check(spawnResult, operation: "posix_spawn")
        var reaped = false
        defer {
            // 若交接终端或等待发生错误，不能留下一个暂停的、无人监督的子进程。
            if !reaped {
                kill(-child, SIGKILL)
                kill(child, SIGKILL)
                var status: Int32 = 0
                while waitpid(child, &status, 0) == -1 && errno == EINTR {}
            }
            terminal.restore(parentOf: child)
        }

        // START_SUSPENDED 同时防止子进程抢读前台交接前的 tty 和回调早于 session_start。
        didStart(child)
        try terminal.give(to: child)
        guard kill(-child, SIGCONT) == 0 else {
            throw Failure(operation: "resume child", code: errno)
        }

        while true {
            var status: Int32 = 0
            let result = waitpid(child, &status, WNOHANG | WUNTRACED)
            if result == child {
                if status & 0xff == 0x7f {
                    terminal.restore(parentOf: child)
                    // SIGSTOP 也适用于会话首进程；SIGTSTP 在孤儿进程组中会被忽略。
                    // fg 发来的 SIGCONT 由 kqueue 处理，交回前台后只继续子进程一次。
                    kill(getpid(), SIGSTOP)
                } else {
                    reaped = true
                    return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                }
            } else if result == -1 && errno != EINTR {
                throw Failure(operation: "waitpid", code: errno)
            }

            for event in try signals.next() {
                let signalNumber = Int32(event.ident)
                if signalNumber == SIGCHLD { continue }
                if signalNumber == SIGCONT { try terminal.give(to: child) }
                // 父进程不在子进程前台组中；终端 Ctrl-C 不会在这里再转发一次。
                // kqueue 保留生成次数；标准信号在接收端仍具有 POSIX 的合并语义。
                for _ in 0..<max(1, event.data) {
                    if kill(-child, signalNumber) == -1 && errno != ESRCH {
                        throw Failure(operation: "forward signal", code: errno)
                    }
                }
            }
        }
    }

    private static func check(_ result: Int32, operation: String) throws {
        if result != 0 { throw Failure(operation: operation, code: result) }
    }

    private final class CStringArray {
        let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        private let count: Int

        init(_ strings: [String]) throws {
            count = strings.count
            pointers = .allocate(capacity: count + 1)
            pointers.initialize(repeating: nil, count: count + 1)
            for (index, value) in strings.enumerated() {
                pointers[index] = strdup(value)
                if pointers[index] == nil {
                    throw Failure(operation: "allocate process arguments", code: ENOMEM)
                }
            }
        }

        deinit {
            for index in 0..<count { free(pointers[index]) }
            pointers.deallocate()
        }
    }

    private final class TerminalOwnership {
        private let descriptor: Int32
        private let parentGroup = getpgrp()

        init() throws {
            // tcgetpgrp 同时要求 stdin 是当前会话的控制终端；pipe 和普通文件不会交接。
            guard isatty(STDIN_FILENO) == 1, tcgetpgrp(STDIN_FILENO) >= 0 else {
                descriptor = -1
                return
            }
            descriptor = dup(STDIN_FILENO)
            guard descriptor >= 0 else { throw Failure(operation: "dup terminal", code: errno) }
            if fcntl(descriptor, F_SETFD, FD_CLOEXEC) == -1 {
                let code = errno
                Darwin.close(descriptor)
                throw Failure(operation: "protect terminal descriptor", code: code)
            }
        }

        func give(to child: pid_t) throws {
            guard descriptor >= 0, tcgetpgrp(descriptor) == parentGroup else { return }
            if setForeground(child) == -1 {
                throw Failure(operation: "give terminal to child", code: errno)
            }
        }

        func restore(parentOf child: pid_t) {
            guard descriptor >= 0, tcgetpgrp(descriptor) == child else { return }
            // tty 关闭后无法恢复；也不能夺回已由 shell 或其他作业取得的前台。
            _ = setForeground(parentGroup)
        }

        func closeDescriptor() { if descriptor >= 0 { Darwin.close(descriptor) } }

        private func setForeground(_ group: pid_t) -> Int32 {
            var mask: sigset_t = 0
            sigemptyset(&mask)
            sigaddset(&mask, SIGTTOU)
            var previous: sigset_t = 0
            let maskResult = pthread_sigmask(SIG_BLOCK, &mask, &previous)
            if maskResult != 0 { errno = maskResult; return -1 }
            let result = tcsetpgrp(descriptor, group)
            let code = errno
            pthread_sigmask(SIG_SETMASK, &previous, nil)
            errno = code
            return result
        }
    }

    private final class SignalEvents {
        let descriptor: Int32
        let watchedMask: sigset_t
        let originalMask: sigset_t
        private var previousActions: [(Int32, sigaction)] = []

        init(signals: [Int32]) throws {
            var mask: sigset_t = 0
            sigemptyset(&mask)
            for signalNumber in signals { sigaddset(&mask, signalNumber) }
            watchedMask = mask
            var previousMask: sigset_t = 0
            try check(pthread_sigmask(SIG_BLOCK, &mask, &previousMask), operation: "block setup signals")
            originalMask = previousMask
            descriptor = kqueue()
            guard descriptor >= 0 else {
                let code = errno
                pthread_sigmask(SIG_SETMASK, &previousMask, nil)
                throw Failure(operation: "kqueue", code: code)
            }
            do {
                guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else {
                    throw Failure(operation: "protect signal descriptor", code: errno)
                }
                for signalNumber in signals {
                    var change = kevent64_s()
                    change.ident = UInt64(signalNumber)
                    change.filter = Int16(EVFILT_SIGNAL)
                    change.flags = UInt16(EV_ADD | EV_CLEAR)
                    if kevent64(descriptor, &change, 1, nil, 0, 0, nil) == -1 {
                        throw Failure(operation: "watch signal", code: errno)
                    }
                    var previous = sigaction()
                    var action = sigaction()
                    sigemptyset(&action.sa_mask)
                    // EVFILT_SIGNAL 记录被忽略的信号；无需在异步信号处理器里执行 Swift。
                    // SIGCHLD 必须为默认处置，否则子进程会被内核自动回收。
                    action.__sigaction_u.__sa_handler = signalNumber == SIGCHLD ? SIG_DFL : SIG_IGN
                    if sigaction(signalNumber, &action, &previous) == -1 {
                        throw Failure(operation: "install signal disposition", code: errno)
                    }
                    previousActions.append((signalNumber, previous))
                }
                try check(pthread_sigmask(SIG_SETMASK, &previousMask, nil), operation: "restore setup signal mask")
            } catch {
                restore()
                throw error
            }
        }

        func next() throws -> [kevent64_s] {
            var events = [kevent64_s](repeating: kevent64_s(), count: 8)
            let count = events.withUnsafeMutableBufferPointer {
                kevent64(descriptor, nil, 0, $0.baseAddress, Int32($0.count), 0, nil)
            }
            if count == -1 {
                if errno == EINTR { return [] }
                throw Failure(operation: "wait for signal", code: errno)
            }
            return Array(events.prefix(Int(count)))
        }

        func restore() {
            var mask = watchedMask
            pthread_sigmask(SIG_BLOCK, &mask, nil)
            for (signalNumber, saved) in previousActions.reversed() {
                var action = saved
                sigaction(signalNumber, &action, nil)
            }
            Darwin.close(descriptor)
            var original = originalMask
            pthread_sigmask(SIG_SETMASK, &original, nil)
        }
    }
}
