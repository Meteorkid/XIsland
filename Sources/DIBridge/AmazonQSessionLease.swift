import Foundation
import Darwin

/// 包装进程持有的临时身份。回调在同一把锁内验证并发送，退出后不能重用身份。
final class AmazonQSessionLease {
    struct State: Codable {
        let version: Int
        let id: String
        let ownerPID: Int32
        let ownerStart: String
        let socketPath: String
        var active: Bool
    }
    enum LeaseError: Error { case filesystem, invalidState, busy }
    let path: String
    private let directory: URL
    private let descriptor: Int32
    private var state: State

    init(socketPath: String) throws {
        guard let ownerStart = Self.processStart(getpid()) else { throw LeaseError.invalidState }
        let id = UUID().uuidString
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-amazonq-" + id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        path = directory.appendingPathComponent("lease.json").path
        descriptor = open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw LeaseError.filesystem
        }
        state = State(version: 1, id: id, ownerPID: getpid(), ownerStart: ownerStart, socketPath: socketPath, active: false)
        try writeState()
    }

    deinit {
        close(descriptor)
        try? FileManager.default.removeItem(at: directory)
    }

    func activate() throws {
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw LeaseError.busy }
        defer { flock(descriptor, LOCK_UN) }
        state.active = true
        try writeState()
    }

    func end() throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard (errno == EWOULDBLOCK || errno == EINTR), ProcessInfo.processInfo.systemUptime < deadline else {
                // 无法获取锁时撤销路径，使后续回调无法取得身份。
                unlink(path)
                throw LeaseError.busy
            }
            usleep(1_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        state.active = false
        try writeState()
    }

    static func withActiveState(at path: String, perform: (State) throws -> Void) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw LeaseError.invalidState }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw LeaseError.filesystem }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 16_384 else { throw LeaseError.invalidState }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw LeaseError.busy }
        defer { flock(fd, LOCK_UN) }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard pread(fd, &bytes, bytes.count, 0) == bytes.count,
              let state = try? JSONDecoder().decode(State.self, from: Data(bytes)),
              state.version == 1, state.active, UUID(uuidString: state.id) != nil,
              state.ownerPID > 1, Self.processStart(state.ownerPID) == state.ownerStart else { throw LeaseError.invalidState }
        try perform(state)
    }

    private static func processStart(_ pid: Int32) -> String? {
        var keys: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&keys, u_int(keys.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid,
              info.kp_proc.p_stat != SZOMB else { return nil }
        return "\(info.kp_proc.p_starttime.tv_sec):\(info.kp_proc.p_starttime.tv_usec)"
    }

    private func writeState() throws {
        let data = try JSONEncoder().encode(state)
        guard data.count <= 16_384 else { throw LeaseError.invalidState }
        let count = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == data.count, ftruncate(descriptor, off_t(data.count)) == 0 else { throw LeaseError.filesystem }
    }
}
