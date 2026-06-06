import Foundation
import SwiftData

@Model
final class StoredSession {
    @Attribute(.unique) var sessionId: String
    var agentTypeRaw: String
    var startTime: Date
    var completedAt: Date?
    var prompt: String
    var workingDirectory: String
    var terminal: String
    var statusRaw: String
    var recapText: String?
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int
    var estimatedCostUSD: Double
    var model: String

    @Relationship(deleteRule: .cascade) var toolEvents: [StoredToolEvent] = []
    @Relationship(deleteRule: .cascade) var chatMessages: [StoredChatMessage] = []

    // MARK: - Computed properties

    var agentType: AgentType {
        AgentType(rawValue: agentTypeRaw) ?? .claudeCode
    }

    var status: SessionStatus {
        SessionStatus(rawValue: statusRaw) ?? .completed
    }

    var duration: TimeInterval {
        (completedAt ?? Date()).timeIntervalSince(startTime)
    }

    var workspaceName: String {
        if workingDirectory.isEmpty { return agentType.shortName }
        var name = (workingDirectory as NSString).lastPathComponent
        if name.hasPrefix(".") { name = String(name.dropFirst()) }
        if name.isEmpty { return agentType.shortName }
        return name
    }

    var displayTitle: String {
        if !prompt.isEmpty {
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
            if firstLine.count > 40 {
                return String(firstLine.prefix(38)) + "..."
            }
            return firstLine
        }
        return workspaceName
    }

    var formattedDuration: String {
        let mins = Int(duration) / 60
        if mins < 1 { return "<1m" }
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h\(mins % 60)m"
    }

    // MARK: - Init

    init(from session: AgentSession) {
        self.sessionId = session.id
        self.agentTypeRaw = session.agentType.rawValue
        self.startTime = session.startTime
        self.completedAt = session.completedAt
        self.prompt = session.prompt
        self.workingDirectory = session.workingDirectory
        self.terminal = session.terminal
        self.statusRaw = session.status.rawValue
        self.recapText = session.recapText
        self.inputTokens = session.tokenUsage.inputTokens
        self.outputTokens = session.tokenUsage.outputTokens
        self.totalTokens = session.tokenUsage.totalTokens
        self.estimatedCostUSD = session.tokenUsage.estimatedCostUSD
        self.model = session.tokenUsage.model
        self.toolEvents = session.events.map { StoredToolEvent(from: $0) }
        self.chatMessages = session.chatHistory.map { StoredChatMessage(from: $0) }
    }

    /// Internal initializer for SwiftData (all stored properties).
    init(
        sessionId: String,
        agentTypeRaw: String,
        startTime: Date,
        completedAt: Date? = nil,
        prompt: String,
        workingDirectory: String,
        terminal: String,
        statusRaw: String,
        recapText: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        totalTokens: Int = 0,
        estimatedCostUSD: Double = 0.0,
        model: String = ""
    ) {
        self.sessionId = sessionId
        self.agentTypeRaw = agentTypeRaw
        self.startTime = startTime
        self.completedAt = completedAt
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.terminal = terminal
        self.statusRaw = statusRaw
        self.recapText = recapText
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.model = model
    }
}
