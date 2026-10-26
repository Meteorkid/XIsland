import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// CGImage 在捕获后保持不可变；传输线程只读取并编码它。
struct IslandPreviewSnapshot: @unchecked Sendable {
    let image: CGImage
    let frame: CGRect
    let scale: CGFloat
    let outline: IslandSwitchGeometry
}

struct LinkedIslandPreviewPeer: Sendable {
    let pid: Int32
    let executablePath: String
}

enum LinkedIslandPreviewTransport {
    static let maximumMessageBytes = 2 * 1024 * 1024
    static let maximumPixels = 4_000_000
    private static let maximumHeaderBytes = 8 * 1024

    enum PreviewError: Error, Equatable, Sendable {
        case invalidRequest, invalidSnapshot, tooLarge, peerRejected, unavailable, timeout, cancelled
        case io(Int32)
    }

    struct Request: Codable, Sendable {
        let id: UUID
        let endpoint: String
        var userInfo: [String: String] { ["id": id.uuidString, "endpoint": endpoint] }

        init(id: UUID, endpoint: String) { self.id = id; self.endpoint = endpoint }

        init?(userInfo: [AnyHashable: Any]?) {
            guard let userInfo, userInfo.count == 2,
                  let rawID = userInfo["id"] as? String, rawID.count == 36, let id = UUID(uuidString: rawID),
                  let endpoint = userInfo["endpoint"] as? String, validEndpoint(endpoint) else { return nil }
            self.init(id: id, endpoint: endpoint)
        }
    }

    final class Handle: @unchecked Sendable {
        fileprivate let control: PreviewControl
        fileprivate init(_ control: PreviewControl) { self.control = control }
        func cancel() { control.cancel() }
        var isFinished: Bool { control.isFinished }
        deinit { cancel() }
    }

    struct Pending: Sendable {
        let request: Request
        let handle: Handle
        func cancel() { handle.cancel() }
    }

    /// 返回前已完成 bind/listen；取消只置标志，fd 始终由工作线程关闭。
    @MainActor
    static func begin(expectedTarget: LinkedIslandPreviewPeer, timeout: TimeInterval = 1,
                      completion: @escaping @MainActor (Result<IslandPreviewSnapshot, PreviewError>) -> Void) throws -> Pending {
        guard validPeer(expectedTarget), validTimeout(timeout) else { throw PreviewError.invalidRequest }
        let endpoint = try OwnedEndpoint.create()
        let request = Request(id: UUID(), endpoint: endpoint.path)
        let control = PreviewControl(timeout: timeout)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<WireSnapshot, PreviewError>
            do {
                defer { endpoint.closeAndRemove() }
                let client = try acceptConnection(endpoint.listener, control: control)
                defer { Darwin.close(client) }
                try authenticate(client, expected: expectedTarget)
                try write(Message(kind: "prepare", id: request.id), to: client, control: control)
                let response = try read(from: client, control: control)
                guard response.message.id == request.id else { throw PreviewError.invalidRequest }
                if response.message.kind == "unavailable" { throw PreviewError.unavailable }
                guard response.message.kind == "snapshot", let metadata = response.message.snapshot else {
                    throw PreviewError.invalidSnapshot
                }
                try validatePNG(response.png, metadata: metadata)
                try control.check()
                result = .success(WireSnapshot(metadata: metadata, png: response.png))
            } catch {
                result = .failure(error as? PreviewError ?? .invalidSnapshot)
            }
            control.finish()
            Task { @MainActor in
                guard control.claimCompletion() else { return }
                if control.isCancelled { completion(.failure(.cancelled)); return }
                completion(result.flatMap { payload in
                    guard let source = CGImageSourceCreateWithData(payload.png as CFData, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0,
                            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                          let outline = payload.metadata.outline.value else { return .failure(.invalidSnapshot) }
                    return .success(IslandPreviewSnapshot(image: image, frame: payload.metadata.frame,
                                                         scale: payload.metadata.scale, outline: outline))
                })
            }
        }
        return Pending(request: request, handle: Handle(control))
    }

    /// 目标只在双向身份核验和 prepare 校验后捕获本应用内容。
    @MainActor
    static func respond(to request: Request, expectedSource: LinkedIslandPreviewPeer,
                        timeout: TimeInterval = 1,
                        capture: @escaping @MainActor () -> IslandPreviewSnapshot?) -> Handle {
        let control = PreviewControl(timeout: validTimeout(timeout) ? timeout : 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { control.finish() }
            guard validPeer(expectedSource), validTimeout(timeout), validEndpoint(request.endpoint) else { return }
            do {
                let socket = try connectedSocket(request.endpoint, control: control)
                defer { Darwin.close(socket) }
                try authenticate(socket, expected: expectedSource)
                let incoming = try read(from: socket, control: control)
                guard incoming.message.kind == "prepare", incoming.message.id == request.id,
                      incoming.message.snapshot == nil, incoming.png.isEmpty else { throw PreviewError.invalidRequest }
                let box = PreviewCaptureBox()
                Task { @MainActor in
                    guard control.canCapture else { box.complete(nil); return }
                    box.complete(capture())
                }
                while !box.isComplete {
                    try control.check()
                    _ = box.ready.wait(timeout: .now() + 0.02)
                }
                try control.check()
                guard let snapshot = box.snapshot else {
                    try write(Message(kind: "unavailable", id: request.id), to: socket, control: control)
                    return
                }
                let metadata = SnapshotMetadata(snapshot)
                try validate(metadata)
                let png = try encodePNG(snapshot.image)
                try control.check()
                try write(Message(kind: "snapshot", id: request.id, snapshot: metadata), png: png,
                          to: socket, control: control)
            } catch {
                // 失败由来源的连接结果处理，不记录截图、路径或请求载荷。
            }
        }
        return Handle(control)
    }

    private struct Message: Codable {
        var version = 1
        let kind: String
        let id: UUID
        var snapshot: SnapshotMetadata?
    }

    private struct WireSnapshot: Sendable {
        let metadata: SnapshotMetadata
        let png: Data
    }

    private struct SnapshotMetadata: Codable, Sendable {
        let frame: CGRect
        let scale: CGFloat
        let width: Int
        let height: Int
        let outline: Outline
        init(_ snapshot: IslandPreviewSnapshot) {
            frame = snapshot.frame; scale = snapshot.scale
            width = snapshot.image.width; height = snapshot.image.height
            outline = Outline(snapshot.outline)
        }
    }

    private struct Outline: Codable, Sendable {
        let frame: CGRect
        let displayID: UInt32
        let top: CGFloat
        let bottom: CGFloat
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        init(_ geometry: IslandSwitchGeometry) {
            frame = geometry.frame; displayID = geometry.displayID
            top = geometry.topRadius; bottom = geometry.bottomRadius
            red = geometry.fill.red; green = geometry.fill.green
            blue = geometry.fill.blue; alpha = geometry.fill.alpha
        }
        var value: IslandSwitchGeometry? {
            guard validRect(frame) else { return nil }
            return IslandSwitchGeometry(frame: frame, displayID: displayID, topRadius: top, bottomRadius: bottom,
                fill: IslandSwitchColor(red: red, green: green, blue: blue, alpha: alpha))
        }
    }

    private static func validate(_ metadata: SnapshotMetadata) throws {
        guard validRect(metadata.frame), metadata.scale.isFinite, metadata.scale > 0, metadata.scale <= 8,
              metadata.width > 0, metadata.height > 0,
              metadata.width <= maximumPixels, metadata.height <= maximumPixels,
              metadata.width <= maximumPixels / metadata.height else { throw PreviewError.invalidSnapshot }
        guard abs(CGFloat(metadata.width) - metadata.frame.size.width * metadata.scale) <= 1,
              abs(CGFloat(metadata.height) - metadata.frame.size.height * metadata.scale) <= 1,
              let outline = metadata.outline.value,
              metadata.frame.insetBy(dx: -1 / metadata.scale, dy: -1 / metadata.scale).contains(outline.frame)
        else { throw PreviewError.invalidSnapshot }
    }

    private static func validRect(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite)
            && abs(frame.origin.x) <= 100_000 && abs(frame.origin.y) <= 100_000
            && frame.size.width > 0 && frame.size.width <= 4096
            && frame.size.height > 0 && frame.size.height <= 2048
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw PreviewError.invalidSnapshot
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PreviewError.invalidSnapshot }
        guard data.length <= maximumMessageBytes else { throw PreviewError.tooLarge }
        return data as Data
    }

    private static func validatePNG(_ data: Data, metadata: SnapshotMetadata) throws {
        try validate(metadata)
        guard !data.isEmpty, data.count <= maximumMessageBytes,
              let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.png", CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == metadata.width,
              properties[kCGImagePropertyPixelHeight] as? Int == metadata.height else {
            throw PreviewError.invalidSnapshot
        }
    }

    private static func write(_ message: Message, png: Data = Data(), to fd: Int32, control: PreviewControl) throws {
        let header = try JSONEncoder().encode(message)
        guard header.count <= maximumHeaderBytes, header.count + png.count + 8 <= maximumMessageBytes else {
            throw PreviewError.tooLarge
        }
        var data = Data()
        for length in [header.count, png.count] {
            var value = UInt32(length).bigEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(header); data.append(png)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(fd, events: Int16(POLLOUT), control: control)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard count > 0 else { throw PreviewError.io(errno) }
                offset += count
            }
        }
    }

    private static func read(from fd: Int32, control: PreviewControl) throws -> (message: Message, png: Data) {
        let prefix = try readBytes(8, from: fd, control: control)
        func length(_ offset: Int) -> Int {
            prefix[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        }
        let headerCount = length(0), imageCount = length(4)
        guard headerCount > 0, headerCount <= maximumHeaderBytes,
              imageCount <= maximumMessageBytes, headerCount + imageCount + 8 <= maximumMessageBytes
        else { throw PreviewError.tooLarge }
        let message = try JSONDecoder().decode(Message.self, from: readBytes(headerCount, from: fd, control: control))
        guard message.version == 1 else { throw PreviewError.invalidRequest }
        return (message, try readBytes(imageCount, from: fd, control: control))
    }

    private static func readBytes(_ count: Int, from fd: Int32, control: PreviewControl) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                try wait(fd, events: Int16(POLLIN), control: control)
                let received = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if received < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard received > 0 else { throw PreviewError.unavailable }
                offset += received
            }
        }
        return data
    }

    private static func wait(_ fd: Int32, events: Int16, control: PreviewControl) throws {
        while true {
            try control.check()
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, 20)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw PreviewError.io(errno) }
            try control.check()
            if descriptor.revents & events != 0 { return }
            if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw PreviewError.unavailable }
        }
    }

    private static func acceptConnection(_ listener: Int32, control: PreviewControl) throws -> Int32 {
        while true {
            try wait(listener, events: Int16(POLLIN), control: control)
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard client >= 0 else { throw PreviewError.io(errno) }
            do { try configure(client); return client } catch { Darwin.close(client); throw error }
        }
    }

    private static func connectedSocket(_ path: String, control: PreviewControl) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PreviewError.io(errno) }
        do {
            try configure(fd)
            let result = withAddress(path) { Darwin.connect(fd, $0, $1) }
            if result < 0 {
                guard errno == EINPROGRESS || errno == EAGAIN else { throw PreviewError.io(errno) }
                try wait(fd, events: Int16(POLLOUT), control: control)
                var error: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                    throw PreviewError.io(error == 0 ? errno : error)
                }
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    private static func configure(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        let descriptorFlags = fcntl(fd, F_GETFD)
        guard flags >= 0, descriptorFlags >= 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else { throw PreviewError.io(errno) }
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw PreviewError.io(errno)
        }
    }

    private static func authenticate(_ fd: Int32, expected: LinkedIslandPreviewPeer) throws {
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              length == MemoryLayout<pid_t>.size, pid == expected.pid else { throw PreviewError.peerRejected }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
              String(cString: buffer) == expected.executablePath else { throw PreviewError.peerRejected }
    }

    private static func validPeer(_ peer: LinkedIslandPreviewPeer) -> Bool {
        peer.pid > 0 && peer.executablePath.hasPrefix("/") && !peer.executablePath.contains("\0")
    }
    private static func validTimeout(_ timeout: TimeInterval) -> Bool { timeout.isFinite && timeout > 0 && timeout <= 10 }
    private static var temporaryRoot: String {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func validEndpoint(_ path: String) -> Bool {
        guard !path.contains("\0"), path.utf8.count < 104 else { return false }
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        let name = directory.lastPathComponent
        guard url.standardizedFileURL.path == path, url.lastPathComponent == "s",
              directory.deletingLastPathComponent().path == temporaryRoot,
              name.hasPrefix("xip-"), name.count == 10,
              name.dropFirst(4).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        var parent = stat(), socket = stat()
        guard lstat(directory.path, &parent) == 0, lstat(path, &socket) == 0,
              parent.st_uid == getuid(), parent.st_mode & S_IFMT == S_IFDIR, parent.st_mode & 0o7777 == 0o700,
              socket.st_uid == getuid(), socket.st_mode & S_IFMT == S_IFSOCK, socket.st_mode & 0o7777 == 0o600
        else { return false }
        return true
    }

    private static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    private final class OwnedEndpoint: @unchecked Sendable {
        let path: String
        let directory: String
        let listener: Int32
        let directoryFD: Int32
        private init(path: String, directory: String, listener: Int32, directoryFD: Int32) {
            self.path = path; self.directory = directory; self.listener = listener; self.directoryFD = directoryFD
        }
        static func create() throws -> OwnedEndpoint {
            var template = Array((temporaryRoot + "/xip-XXXXXX").utf8CString)
            guard mkdtemp(&template) != nil else { throw PreviewError.io(errno) }
            let directory = String(cString: template), path = directory + "/s"
            var fd: Int32 = -1, directoryFD: Int32 = -1
            do {
                guard path.utf8.count < 104, chmod(directory, 0o700) == 0 else { throw PreviewError.invalidRequest }
                directoryFD = Darwin.open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard directoryFD >= 0 else { throw PreviewError.io(errno) }
                fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { throw PreviewError.io(errno) }
                try configure(fd)
                guard withAddress(path, { Darwin.bind(fd, $0, $1) }) == 0,
                      chmod(path, 0o600) == 0, Darwin.listen(fd, 1) == 0 else { throw PreviewError.io(errno) }
                return OwnedEndpoint(path: path, directory: directory, listener: fd, directoryFD: directoryFD)
            } catch {
                if fd >= 0 { Darwin.close(fd) }
                if directoryFD >= 0 { unlinkat(directoryFD, "s", 0); Darwin.close(directoryFD) }
                rmdir(directory)
                throw error
            }
        }
        func closeAndRemove() {
            Darwin.close(listener)
            unlinkat(directoryFD, "s", 0)
            var owned = stat(), current = stat()
            if fstat(directoryFD, &owned) == 0, lstat(directory, &current) == 0,
               owned.st_dev == current.st_dev, owned.st_ino == current.st_ino { rmdir(directory) }
            Darwin.close(directoryFD)
        }
    }
}

fileprivate final class PreviewControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var delivered = false
    private let deadline: TimeInterval
    init(timeout: TimeInterval) { deadline = ProcessInfo.processInfo.systemUptime + timeout }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func finish() { lock.lock(); finished = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var canCapture: Bool { !isCancelled && !isFinished && ProcessInfo.processInfo.systemUptime < deadline }
    func check() throws {
        if isCancelled { throw LinkedIslandPreviewTransport.PreviewError.cancelled }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw LinkedIslandPreviewTransport.PreviewError.timeout }
    }
    func claimCompletion() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !delivered else { return false }
        delivered = true
        return true
    }
}

fileprivate final class PreviewCaptureBox: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var completed = false
    private var value: IslandPreviewSnapshot?
    var isComplete: Bool { lock.lock(); defer { lock.unlock() }; return completed }
    var snapshot: IslandPreviewSnapshot? { lock.lock(); defer { lock.unlock() }; return value }
    func complete(_ snapshot: IslandPreviewSnapshot?) {
        lock.lock(); value = snapshot; completed = true; lock.unlock()
        ready.signal()
    }
}
