import Foundation

/// 伴端（iPhone / Apple Watch）能看到的会话阶段。
///
/// 刻意比 Mac 端的 `SessionStatus`（11 个）少：伴端只关心"要不要我出手"，
/// 把 `compacting`、`observing` 这类中间态合并掉，减少跨端语义漂移。
public enum CompanionPhase: String, Codable, Sendable, CaseIterable {
    case idle
    case processing
    case running
    case waitingApproval
    case waitingQuestion

    /// 容错解码：较新的 Mac 端可能送来这个版本没见过的值。
    ///
    /// 回退到 `idle` 而不是抛错——抛错会让整份快照解码失败，
    /// 在 watchOS 上表现为每次启动都因持久化的 application context 崩溃。
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CompanionPhase(rawValue: raw) ?? .idle
    }

    /// 展示优先级，与 Mac 端收起态一致：审批 > 提问 > 运行 > 处理 > 空闲。
    public var priority: Int {
        switch self {
        case .waitingApproval: return 4
        case .waitingQuestion: return 3
        case .running: return 2
        case .processing: return 1
        case .idle: return 0
        }
    }

    public var needsUser: Bool {
        self == .waitingApproval || self == .waitingQuestion
    }
}

/// 一个会话在伴端上的投影。字段数按"手表能一屏读完"来裁。
public struct CompanionSession: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    /// 客户端显示名，例如 "Claude Code"。
    public let agent: String
    /// 首条提问或会话标题，已截断。
    public let title: String
    public let project: String
    public let phase: CompanionPhase
    public let updatedAt: Date

    public init(id: String, agent: String, title: String, project: String,
                phase: CompanionPhase, updatedAt: Date) {
        self.id = id
        self.agent = agent
        self.title = title
        self.project = project
        self.phase = phase
        self.updatedAt = updatedAt
    }
}

/// 局域网通道使用的完整快照。
public struct CompanionSnapshot: Codable, Sendable, Equatable {
    /// 协议版本。伴端遇到高于自己的版本时只读展示，不下发命令。
    public let protocolVersion: Int
    /// 单调递增，用于丢弃迟到的旧包。
    public let sequence: UInt64
    public let generatedAt: Date
    /// Mac 端是否允许伴端执行决定类命令。
    ///
    /// 必须由 Mac 下发而不是伴端自己决定：否则任何连上来的设备都能自行放开审批权。
    /// 缺失时按 false 处理——旧版 Mac 不带这个字段，安全侧默认收紧。
    public let allowsDecisions: Bool
    public let sessions: [CompanionSession]

    public static let currentProtocolVersion = 1

    public init(sequence: UInt64, generatedAt: Date, sessions: [CompanionSession],
                allowsDecisions: Bool = false) {
        self.protocolVersion = Self.currentProtocolVersion
        self.sequence = sequence
        self.generatedAt = generatedAt
        self.allowsDecisions = allowsDecisions
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, sequence, generatedAt, allowsDecisions, sessions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        self.sequence = try container.decode(UInt64.self, forKey: .sequence)
        self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        self.sessions = try container.decode([CompanionSession].self, forKey: .sessions)
        // 旧版 Mac 不带该字段：默认不允许，避免误放开审批权。
        self.allowsDecisions = try container.decodeIfPresent(Bool.self, forKey: .allowsDecisions) ?? false
    }

    public var pendingCount: Int { sessions.filter(\.phase.needsUser).count }

    /// 按展示优先级排序，供伴端直接渲染。
    ///
    /// 用 `id` 兜底做最终比较：优先级与时间都相同时（同一秒内两条同类会话），
    /// 若不指定次序，`sorted` 的结果在两次调用间可能不同，
    /// 导致摘要内容反复变化、每次都触发一次无效发送。
    public var ordered: [CompanionSession] {
        sessions.sorted { lhs, rhs in
            if lhs.phase.priority != rhs.phase.priority {
                return lhs.phase.priority > rhs.phase.priority
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id < rhs.id
        }
    }
}

/// 蓝牙通道使用的精简摘要。
///
/// 蓝牙单包载荷有限，只送"最需要你看一眼的那一条"加上计数。
/// 完整列表仍走局域网，摘要只负责让锁屏与手表保持新鲜。
public struct CompanionDigest: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let sequence: UInt64
    /// 按优先级排列，最多 1 条；没有会话时为 nil。
    public let focus: CompanionSession?
    public let totalCount: Int
    public let pendingCount: Int
    /// 与 `CompanionSnapshot.allowsDecisions` 同义。摘要走手表通道，
    /// 手表据此决定是否显示按钮。
    public let allowsDecisions: Bool

    public init(sequence: UInt64, focus: CompanionSession?, totalCount: Int,
                pendingCount: Int, allowsDecisions: Bool = false) {
        self.protocolVersion = CompanionSnapshot.currentProtocolVersion
        self.sequence = sequence
        self.focus = focus
        self.totalCount = totalCount
        self.pendingCount = pendingCount
        self.allowsDecisions = allowsDecisions
    }

    /// 从完整快照降维。
    public init(snapshot: CompanionSnapshot) {
        self.init(
            sequence: snapshot.sequence,
            focus: snapshot.ordered.first,
            totalCount: snapshot.sessions.count,
            pendingCount: snapshot.pendingCount,
            allowsDecisions: snapshot.allowsDecisions
        )
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, sequence, focus, totalCount, pendingCount, allowsDecisions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        self.sequence = try container.decode(UInt64.self, forKey: .sequence)
        self.focus = try container.decodeIfPresent(CompanionSession.self, forKey: .focus)
        self.totalCount = try container.decode(Int.self, forKey: .totalCount)
        self.pendingCount = try container.decode(Int.self, forKey: .pendingCount)
        self.allowsDecisions = try container.decodeIfPresent(Bool.self, forKey: .allowsDecisions) ?? false
    }
}

/// 伴端可以下发的操作。
///
/// 每条都带 `sessionId`：用户点的是他**当时看到的那一条**，
/// 而不是"此刻排在队首的那一条"。缺了它就可能在队列变动时批准错对象。
public enum CompanionCommand: Codable, Sendable, Equatable {
    case requestState
    case approve(sessionId: String)
    case deny(sessionId: String)
    case answer(sessionId: String, text: String)

    private enum CodingKeys: String, CodingKey {
        case kind, sessionId, text
    }

    private enum Kind: String, Codable {
        case requestState, approve, deny, answer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .requestState:
            self = .requestState
        case .approve:
            self = .approve(sessionId: try container.decode(String.self, forKey: .sessionId))
        case .deny:
            self = .deny(sessionId: try container.decode(String.self, forKey: .sessionId))
        case .answer:
            self = .answer(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                text: try container.decode(String.self, forKey: .text)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .requestState:
            try container.encode(Kind.requestState, forKey: .kind)
        case .approve(let id):
            try container.encode(Kind.approve, forKey: .kind)
            try container.encode(id, forKey: .sessionId)
        case .deny(let id):
            try container.encode(Kind.deny, forKey: .kind)
            try container.encode(id, forKey: .sessionId)
        case .answer(let id, let text):
            try container.encode(Kind.answer, forKey: .kind)
            try container.encode(id, forKey: .sessionId)
            try container.encode(text, forKey: .text)
        }
    }

    /// 是否会替用户做决定。伴端尚未完成配对确认时，这类命令不应执行。
    public var decidesForTheUser: Bool {
        switch self {
        case .requestState: return false
        case .approve, .deny, .answer: return true
        }
    }

    public var sessionId: String? {
        switch self {
        case .requestState: return nil
        case .approve(let id), .deny(let id), .answer(let id, _): return id
        }
    }
}

// MARK: - 编解码

public enum CompanionCodec {
    /// 蓝牙摘要的目标上限。超过就说明字段被加多了，应当重新审视裁剪。
    public static let digestByteBudget = 512

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ snapshot: CompanionSnapshot) throws -> Data {
        try encoder().encode(snapshot)
    }

    public static func decodeSnapshot(_ data: Data) throws -> CompanionSnapshot {
        try decoder().decode(CompanionSnapshot.self, from: data)
    }

    public static func encode(_ digest: CompanionDigest) throws -> Data {
        try encoder().encode(digest)
    }

    public static func decodeDigest(_ data: Data) throws -> CompanionDigest {
        try decoder().decode(CompanionDigest.self, from: data)
    }

    public static func encode(_ command: CompanionCommand) throws -> Data {
        try encoder().encode(command)
    }

    public static func decodeCommand(_ data: Data) throws -> CompanionCommand {
        try decoder().decode(CompanionCommand.self, from: data)
    }
}

// MARK: - 序列号

/// 单调递增的包序号。伴端据此丢弃迟到的旧包，避免界面回跳。
public struct CompanionSequence: Sendable {
    private var value: UInt64 = 0
    public init() {}
    public mutating func next() -> UInt64 {
        value &+= 1
        return value
    }
    public var current: UInt64 { value }
}

// MARK: - 对端名

public enum CompanionPeerName {
    /// `MCPeerID` 的 displayName 上限，单位是 **UTF-8 字节**。
    public static let maximumBytes = 63

    /// 把设备名截断到合法长度。
    ///
    /// 必须按字节而不是字符截断：`MCPeerID(displayName:)` 在超过 63 **字节** 时
    /// 抛出 `NSInvalidArgumentException`，在 Swift 里不可捕获，直接崩溃。
    /// 一个中文字符占 3 字节，所以 22 个汉字就会越界——
    /// 用 `prefix(63)`（按字符）拦不住。
    ///
    /// 截断点落在字素簇边界上，不会切出半个字符。
    public static func sanitized(_ raw: String, fallback: String = "XIsland") -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        guard trimmed.utf8.count > maximumBytes else { return trimmed }

        // 逐字符累加，直到再加一个就会越界。
        var result = ""
        var used = 0
        for character in trimmed {
            let size = String(character).utf8.count
            if used + size > maximumBytes { break }
            result.append(character)
            used += size
        }
        return result.isEmpty ? fallback : result
    }
}
