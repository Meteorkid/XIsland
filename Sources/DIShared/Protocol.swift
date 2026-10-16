import Foundation

// MARK: - Socket 路径约定

/// `DIBridge`（各 AI 工具的 hook 子进程）与 `DynamicIsland`（常驻服务端）
/// 共享的 Unix domain socket 路径约定。路径必须两端一致，否则事件无法投递。
public enum DISocketConfig {
    public enum ConfigurationError: LocalizedError {
        case invalidTestRuntimeDirectory(String)

        public var errorDescription: String? {
            switch self {
            case .invalidTestRuntimeDirectory(let directory):
                return "Test runtime directory must be a short absolute path inside a temporary directory: \(directory)"
            }
        }
    }

    /// 运行时目录：生产使用用户目录，测试必须使用独立临时目录。
    public static var socketDir: String {
        do {
            return try resolvedSocketDirectory(
                arguments: ProcessInfo.processInfo.arguments,
                environment: ProcessInfo.processInfo.environment
            )
        } catch {
            preconditionFailure(error.localizedDescription)
        }
    }

    public static func resolvedSocketDirectory(
        arguments: [String],
        environment: [String: String],
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) throws -> String {
        guard arguments.contains("--ui-test-mode") || environment["X_ISLAND_TEST_MODE"] == "1" else {
            return homeDirectory + "/.xisland"
        }

        let directory = environment["X_ISLAND_TEST_RUNTIME_DIR"] ?? defaultTestRuntimeDirectory
        try validateTestRuntimeDirectory(directory)
        return directory
    }

    public static var defaultTestRuntimeDirectory: String {
        "/tmp/xi-test-\(ProcessInfo.processInfo.processIdentifier)"
    }

    public static func validateTestRuntimeDirectory(_ directory: String) throws {
        let path = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath().path
        let temporaryRoots = [URL(fileURLWithPath: "/tmp"), FileManager.default.temporaryDirectory]
            .map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        // Darwin 的 sockaddr_un.sun_path 只有 104 字节，末尾还需保留 NUL。
        guard directory.hasPrefix("/"), !directory.contains("\0"),
              (directory + "/di.sock").utf8.count < 104,
              temporaryRoots.contains(where: { path.hasPrefix($0 + "/") }) else {
            throw ConfigurationError.invalidTestRuntimeDirectory(directory)
        }
    }

    /// 服务端监听的 Unix domain socket 绝对路径。
    public static var socketPath: String {
        socketDir + "/di.sock"
    }
}

// MARK: - 消息类型

/// 跨进程消息的类型标签。`rawValue` 是线上的 JSON 标识，两端必须严格一致，
/// 因此修改任何取值都意味着协议不兼容。
public enum DIMessageType: String, Codable, Sendable {
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case toolStart = "tool_start"
    case toolComplete = "tool_complete"
    case permissionRequest = "permission_request"
    case permissionResponse = "permission_response"
    case question = "question"
    case questionResponse = "question_response"
    case interactionResolved = "interaction_resolved"
    case planReview = "plan_review"
    case planResponse = "plan_response"
    case statusUpdate = "status_update"
    case progress = "progress"
    case subagentStart = "subagent_start"
    case subagentEnd = "subagent_end"
    case contextCompact = "context_compact"
    case recap = "recap"
    case observationHeartbeat = "observation_heartbeat"
    case observationEnded = "observation_ended"
}

// MARK: - 消息载体

/// 原生后台任务事实；独立于会话的观察租约 nativeTaskId 和模型工具调用 ID。
public struct DINativeBackgroundTask: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String?
    public var status: String
    public var description: String?
    public var startedAtMilliseconds: Int64?
    public var result: String?

    public init(id: String, kind: String? = nil, status: String, description: String? = nil,
                startedAtMilliseconds: Int64? = nil, result: String? = nil) {
        self.id = id
        self.kind = kind
        self.status = status
        self.description = description
        self.startedAtMilliseconds = startedAtMilliseconds
        self.result = result
    }
}

/// 桥接层与服务端之间传递的通用消息结构。
///
/// 一种结构承载全部事件类型：不同 `DIMessageType` 只使用其中一部分字段，
/// 其余保持 `nil`。所有负载字段均为可选，便于单一类型覆盖所有场景。
public struct DIMessage: Codable, Sendable {
    public var type: DIMessageType
    public var sessionId: String
    public var agentType: String?
    public var timestamp: Date
    /// 原生 hook 名称，用于区分真正的会话开始与同样映射为 sessionStart 的消息提交。
    public var nativeEvent: String?
    /// 原生代理与轮次身份；不等同观察租约的 nativeTaskId。
    public var nativeAgentId: String?
    public var nativeTurnId: String?
    public var nativeBackgroundTask: DINativeBackgroundTask?
    public var nativeMessageId: String?
    public var nativeMessagePartial: Bool?
    public var nativeMessageReplay: Bool?
    public var sourceNamespace: String?
    public var sourceInstanceId: String?
    public var nativeTaskId: String?
    public var observationSequence: Int?

    public var hasObservationMetadata: Bool {
        sourceNamespace != nil || sourceInstanceId != nil || nativeTaskId != nil || observationSequence != nil
            || type == .observationHeartbeat || type == .observationEnded
    }

    // 会话 / 终端上下文
    public var terminal: String?
    public var termSessionId: String?
    public var workingDir: String?
    public var prompt: String?

    // 工具调用
    public var toolCallId: String?
    public var tool: String?
    public var toolInput: String?
    public var toolResult: String?
    public var linesAdded: Int?
    public var linesRemoved: Int?

    // 原生交互关联：请求 ID 与类型共同区分权限和问题的生命周期。
    public var nativeRequestId: String?
    public var nativeRequestKind: String?

    // 权限申请
    public var permDescription: String?
    public var diff: String?
    public var filePath: String?
    public var approved: Bool?

    // 问答
    public var questionText: String?
    public var options: [String]?
    public var allowsCustomAnswer: Bool?
    public var allowsMultipleAnswers: Bool?
    public var answer: String?
    public var selectedAnswers: [String]?

    // 计划评审
    public var planMarkdown: String?
    public var planApproved: Bool?
    public var feedback: String?

    public var status: String?
    /// 适配器从原生事件确认的状态；未知值由客户端忽略，旧客户端也可忽略这两个可选字段。
    public var observedState: String?
    public var statusIsAssistantReply: Bool?

    // Token / 成本统计
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var totalTokens: Int?
    public var costUSD: Double?
    /// true 表示会话累计快照；缺省或 false 保留增量统计语义。
    public var usageIsCumulative: Bool?
    public var model: String?

    // 会话回顾
    public var recapText: String?

    // 子代理追踪
    public var parentSessionId: String?
    public var subagentId: String?
    /// true 表示仅收到子代理准备结束的通知，尚无最终完成回执。
    public var subagentEndIsProvisional: Bool?

    public init(type: DIMessageType, sessionId: String) {
        self.type = type
        self.sessionId = sessionId
        self.timestamp = Date()
    }
}

// MARK: - 编解码

/// `DIMessage` 与线路字节流之间的编解码约定。
public enum DIProtocol {
    /// 每条消息以换行符（0x0A）作为帧边界，发送方追加、接收方据此切分。
    private static let frameDelimiter: UInt8 = 0x0A

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// 编码并在末尾追加换行帧边界。
    public static func encode(_ message: DIMessage) throws -> Data {
        var payload = try encoder.encode(message)
        payload.append(frameDelimiter)
        return payload
    }

    /// 剔除帧边界（`\n` / `\r`）后解码为 `DIMessage`。
    public static func decode(_ data: Data) throws -> DIMessage {
        let payload = data.filter { $0 != 0x0A && $0 != 0x0D }
        return try decoder.decode(DIMessage.self, from: Data(payload))
    }
}
