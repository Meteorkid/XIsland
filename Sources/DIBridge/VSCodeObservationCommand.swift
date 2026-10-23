import Foundation
import DIShared

/// Companion 的单帧观察入口；不进入 hook 适配或交互响应流程。
enum VSCodeObservationCommand {
    static let maxFrameBytes = 256 * 1024
    private static let allowedTypes: Set<DIMessageType> = [
        .sessionStart, .statusUpdate, .subagentStart, .subagentEnd,
        .observationHeartbeat, .observationEnded,
    ]
    private static let allowedFields: Set<String> = [
        "type", "sessionId", "agentType", "timestamp", "nativeEvent", "nativeMessageId", "nativeMessagePartial",
        "sourceNamespace", "sourceInstanceId", "nativeTaskId", "observationSequence", "terminal", "prompt",
        "status", "observedState", "statusIsAssistantReply", "tokensIn", "tokensOut", "costUSD",
        "usageIsCumulative", "parentSessionId", "subagentId",
    ]

    static func validate(_ frame: Data) throws {
        guard frame.count <= maxFrameBytes, frame.last == 0x0A,
              !frame.dropLast().contains(0x0A), !frame.contains(0x0D),
              let fields = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
              Set(fields.keys).isSubset(of: allowedFields) else {
            throw DIBridge.NativePayloadError.invalidField("observation_frame")
        }
        let message = try DIProtocol.decode(frame)
        guard let agent = message.agentType, ["roo_code", "pearai"].contains(agent), allowedTypes.contains(message.type),
              let namespace = message.sourceNamespace, namespace.count == 24,
              namespace.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let instance = message.sourceInstanceId, UUID(uuidString: instance)?.uuidString.lowercased() == instance,
              let sequence = message.observationSequence, (1...9_007_199_254_740_991).contains(sequence) else {
            throw DIBridge.NativePayloadError.invalidField("observation_type")
        }
        // 与接收端 ObservationLeaseLedger 保持同一身份规则，禁止落入缺少 metadata 的旧会话路径。
        let source = "\(agent)-\(namespace)-\(instance)"
        if message.type == .observationHeartbeat || message.type == .observationEnded {
            guard message.nativeTaskId == nil, message.sessionId == source,
                  message.parentSessionId == nil, message.subagentId == nil else {
                throw DIBridge.NativePayloadError.invalidField("observation_control_identity")
            }
        } else {
            guard let task = message.nativeTaskId, validTaskID(task),
                  message.sessionId == sessionID(source: source, task: task) else {
                throw DIBridge.NativePayloadError.invalidField("observation_task_identity")
            }
            if message.type == .subagentStart || message.type == .subagentEnd {
                guard message.parentSessionId == message.sessionId,
                      let child = message.subagentId, child.hasPrefix(source + "-") else {
                    throw DIBridge.NativePayloadError.invalidField("observation_subagent_identity")
                }
                let encoded = String(child.dropFirst(source.count + 1))
                    .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                let padded = encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
                guard let data = Data(base64Encoded: padded), let childTask = String(data: data, encoding: .utf8),
                      validTaskID(childTask), child == sessionID(source: source, task: childTask) else {
                    throw DIBridge.NativePayloadError.invalidField("observation_subagent_identity")
                }
            } else if message.parentSessionId != nil || message.subagentId != nil {
                throw DIBridge.NativePayloadError.invalidField("observation_subagent_identity")
            }
        }
    }

    private static func validTaskID(_ task: String) -> Bool {
        !task.isEmpty && task.utf8.count <= 16_384 && !task.unicodeScalars.contains(where: { $0.value < 32 })
    }

    private static func sessionID(source: String, task: String) -> String {
        let encoded = Data(task.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return source + "-" + encoded
    }

    /// 在读取过程中执行上限和总截止时间，避免不结束 stdin 的调用长期占用服务端连接。
    static func readFrame(from input: Int32, deadline: TimeInterval) -> Data? {
        var frame = Data()
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            var descriptor = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, 2000)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let count = read(input, &bytes, min(bytes.count, maxFrameBytes + 1 - frame.count))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { return frame }
            frame.append(contentsOf: bytes.prefix(count))
            guard frame.count <= maxFrameBytes else { return nil }
        }
    }

    static func run() -> Int32 {
        let fd = DIBridge.connectSocket()
        guard fd >= 0 else { return 75 }
        defer { close(fd) }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return 74 }
        print("ready")
        fflush(stdout)
        guard let frame = readFrame(from: STDIN_FILENO, deadline: deadline),
              (try? validate(frame)) != nil else { return 65 }
        guard sendFrame(fd: fd, frame: frame, deadline: deadline) else { return 74 }
        shutdown(fd, SHUT_WR)
        // 等接收端处理完并关闭，再让队列发送下一帧；观察入口不接受任何应答内容。
        var byte: UInt8 = 0
        while setTimeout(fd, option: SO_RCVTIMEO, deadline: deadline) {
            let count = recv(fd, &byte, 1, 0)
            if count < 0, errno == EINTR { continue }
            return count == 0 ? 0 : 74
        }
        return 74
    }

    static func sendFrame(fd: Int32, frame: Data, deadline: TimeInterval) -> Bool {
        frame.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                guard setTimeout(fd, option: SO_SNDTIMEO, deadline: deadline) else { return false }
                let count = send(fd, base.advanced(by: offset), bytes.count - offset, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    private static func setTimeout(_ fd: Int32, option: Int32, deadline: TimeInterval) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        var timeout = timeval(tv_sec: Int(remaining), tv_usec: Int32(max(1, (remaining - floor(remaining)) * 1_000_000)))
        return setsockopt(fd, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
    }
}
