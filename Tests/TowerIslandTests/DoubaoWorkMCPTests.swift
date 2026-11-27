import Darwin
import DIShared
import XCTest
@testable import DIBridge
@testable import XIsland

/// 用真实桥接进程验证 `doubao-work-mcp` 的 MCP 表面：
/// 只暴露活动上报工具，不暴露审批图工具，也不向真实运行中的 App 注入测试事件。
final class DoubaoWorkMCPTests: XCTestCase {
    private var bridgeURL: URL? {
        // 源码目录 → 仓库根 → .build/debug/di-bridge；CI 未构建桥接时跳过。
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/DIBridge")
    }

    func testConnectorExposesOnlyActivityToolAndReportsSuccess() throws {
        guard let bridgeURL, FileManager.default.isExecutableFile(atPath: bridgeURL.path) else {
            throw XCTSkip("di-bridge 尚未构建")
        }
        let socket = FileManager.default.temporaryDirectory
            .appendingPathComponent("xisland-mcp-\(UUID().uuidString).sock")

        let process = Process()
        process.executableURL = bridgeURL
        process.arguments = ["doubao-work-mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment["DI_SOCKET_PATH"] = socket.path // 不存在的 socket = 单向发送静默失败
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"xisland_activity","arguments":{"summary":"测试活动","detail":"npm test"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"approval_graph_get","arguments":{}}}"#,
        ]
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let responses = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
        XCTAssertGreaterThanOrEqual(responses.count, 4, "每个请求都应有 JSON-RPC 响应")

        let initialize = try response(id: 1, in: responses)
        let serverInfo = try XCTUnwrap(initialize["result"] as? [String: Any])["serverInfo"] as? [String: Any]
        XCTAssertEqual(serverInfo?["name"] as? String, "xisland-activity")

        let list = try response(id: 2, in: responses)
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["xisland_activity"])
        let schema = try XCTUnwrap(tools.first?["inputSchema"] as? [String: Any])
        XCTAssertEqual((schema["required"] as? [String]) ?? [], ["summary"])

        let call = try response(id: 3, in: responses)
        let result = try XCTUnwrap(call["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertTrue((content.first?["text"] as? String)?.contains("活动上报") ?? false)

        // 观察模式不允许调用审批图工具，避免让人以为豆包工作能接管审批。
        let rejected = try response(id: 4, in: responses)
        let error = try XCTUnwrap(rejected["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    private static func readFrame(_ fd: Int32) -> Data? {
        var data = Data()
        var pending = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pending, 1, 1000) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { return data.isEmpty ? nil : data }
            data.append(contentsOf: buffer[0..<n])
            if data.contains(0x0A) { return data }
            if data.count > 256 * 1024 { return nil }
        }
    }

    private func response(id: Int, in responses: [[String: Any]]) throws -> [String: Any] {
        try XCTUnwrap(responses.first { ($0["id"] as? NSNumber)?.intValue == id }, "缺少 id=\(id) 的响应")
    }

    func testActivityMessagesReachTheAppSocketAndCloseWithTheConnector() throws {
        guard let bridgeURL, FileManager.default.isExecutableFile(atPath: bridgeURL.path) else {
            throw XCTSkip("di-bridge 尚未构建")
        }
        // UNIX socket 路径上限 104 字节；临时目录太深，直接用 /tmp 下的短名。
        let socketPath = "/tmp/xis-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let listener = try ListeningSocket(path: socketPath)
        defer { listener.close() }
        let received = ReceivedMessages()
        DispatchQueue.global(qos: .userInitiated).async {
            // 每条消息一个连接；accept 超时不能结束循环，否则只收到第一条。
            let stopAt = Date().addingTimeInterval(8)
            while Date() < stopAt {
                guard let fd = listener.accept(timeout: 0.2) else { continue }

                defer { Darwin.close(fd) }
                guard let data = Self.readFrame(fd), let message = try? DIProtocol.decode(data) else { continue }
                received.append(message)
            }
        }

        let process = Process()
        process.executableURL = bridgeURL
        process.arguments = ["doubao-work-mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment["DI_SOCKET_PATH"] = socketPath
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"xisland_activity","arguments":{"summary":"扫描依赖","detail":"swift build"}}}

        """.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, received.snapshot().count < 4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let activity = received.snapshot().filter { $0.type != .mcpHandshake }
        XCTAssertGreaterThanOrEqual(activity.count, 4, "应收到 sessionStart / toolStart / toolComplete / sessionEnd")
        XCTAssertEqual(Set(activity.map(\.agentType)), ["doubao_work"])
        XCTAssertEqual(Set(activity.map(\.type.rawValue)), ["session_start", "tool_start", "tool_complete", "session_end"])
        XCTAssertEqual(activity.first?.sessionId, activity.last?.sessionId)
        XCTAssertTrue(activity.contains { $0.prompt == "扫描依赖" })
        XCTAssertTrue(activity.contains { $0.tool == "xisland_activity" && $0.toolResult == "扫描依赖" })
    }
}

/// 极简 UNIX socket 监听器：只用测试内需要的 bind / listen / accept。
private struct ListeningSocket {
    let fd: Int32
    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            bytes.withUnsafeBufferPointer { source in
                UnsafeMutableRawPointer(destination).copyMemory(from: source.baseAddress!, byteCount: bytes.count)
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
    }
    func accept(timeout: TimeInterval) -> Int32? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return nil }
        return Darwin.accept(fd, nil, nil)
    }
    func close() { Darwin.close(fd) }
}

private final class ReceivedMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [DIMessage] = []
    func append(_ message: DIMessage) { lock.withLock { messages.append(message) } }
    func snapshot() -> [DIMessage] { lock.withLock { messages } }
}
