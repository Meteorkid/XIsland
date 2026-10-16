import Foundation
import Darwin
import DIShared

enum ObservationSender {
    /// 非阻塞、本地、单向发送；不等待 UI 或消费审批响应。
    static func send(_ message: DIMessage, socketPath: String) {
        guard socketPath.hasPrefix("/"), !socketPath.utf8.contains(0), socketPath.utf8.count < 104,
              let data = try? DIProtocol.encode(message) else { return }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { return }
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.utf8CString
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            path.withUnsafeBufferPointer { UnsafeMutableRawPointer(destination).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS, writable(descriptor, deadline: deadline) else { return }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return }
        }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count, ProcessInfo.processInfo.systemUptime < deadline {
                let count = Darwin.send(descriptor, base.advanced(by: offset), bytes.count - offset, 0)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK, writable(descriptor, deadline: deadline) else { return }
            }
        }
    }

    private static func writable(_ descriptor: Int32, deadline: TimeInterval) -> Bool {
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let remaining = max(1, Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1_000))
            let result = poll(&descriptor, 1, remaining)
            if result > 0 { return descriptor.revents & Int16(POLLOUT) != 0 }
            if result == 0 || errno != EINTR { return false }
        }
        return false
    }
}
