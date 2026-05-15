import Foundation

public enum DISocketConfig {
    public static var socketDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.xisland"
    }

    public static var socketPath: String {
        "\(socketDir)/di.sock"
    }
}

public enum DIMessageType: String, Codable, Sendable {
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case toolStart = "tool_start"
    case toolComplete = "tool_complete"
    case permissionRequest = "permission_request"
    case permissionResponse = "permission_response"
    case question = "question"
    case questionResponse = "question_response"
    case planReview = "plan_review"
    case planResponse = "plan_response"
    case statusUpdate = "status_update"
    case progress = "progress"
    case subagentStart = "subagent_start"
    case subagentEnd = "subagent_end"
    case contextCompact = "context_compact"
    case recap = "recap"
}

public struct DIMessage: Codable, Sendable {
    public var type: DIMessageType
    public var sessionId: String
    public var agentType: String?
    public var timestamp: Date

    public var terminal: String?
    public var termSessionId: String?
    public var workingDir: String?
    public var prompt: String?

    public var tool: String?
    public var toolInput: String?
    public var toolResult: String?
    public var linesAdded: Int?
    public var linesRemoved: Int?

    public var permDescription: String?
    public var diff: String?
    public var filePath: String?
    public var approved: Bool?

    public var questionText: String?
    public var options: [String]?
    public var answer: String?

    public var planMarkdown: String?
    public var planApproved: Bool?
    public var feedback: String?

    public var status: String?

    // Token/Cost tracking
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var totalTokens: Int?
    public var costUSD: Double?
    public var model: String?

    // Session recap
    public var recapText: String?

    // Subagent tracking
    public var parentSessionId: String?
    public var subagentId: String?

    public init(type: DIMessageType, sessionId: String) {
        self.type = type
        self.sessionId = sessionId
        self.timestamp = Date()
    }
}

public enum DIProtocol {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func encode(_ message: DIMessage) throws -> Data {
        var data = try encoder.encode(message)
        data.append(0x0A)
        return data
    }

    public static func decode(_ data: Data) throws -> DIMessage {
        let trimmed = data.filter { $0 != 0x0A && $0 != 0x0D }
        return try decoder.decode(DIMessage.self, from: Data(trimmed))
    }
}
