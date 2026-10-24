import Foundation
import SwiftData
import DIShared

@Model
final class StoredSession {
    @Attribute(.unique) var sessionId: String
    var agentTypeRaw: String
    var startTime: Date
    var completedAt: Date?
    /// nil 表示旧记录没有查看状态，不据此推断用户已经查看。
    var completionNeedsReview: Bool? = nil
    var sourceNamespace: String?
    var sourceInstanceId: String?
    var nativeTaskId: String?
    var observationEndedAt: Date?
    var kimiCodeApprovalObservationData: Data? = nil
    var historyDate: Date?
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
        (completedAt ?? observationEndedAt ?? Date()).timeIntervalSince(startTime)
    }

    var workspaceName: String {
        if workingDirectory.isEmpty { return agentType.shortName }
        var name = (workingDirectory as NSString).lastPathComponent
        if name.hasPrefix(".") { name = String(name.dropFirst()) }
        if name.isEmpty { return agentType.shortName }
        return name
    }

    var displayTitle: String {
        // 旧记录只修正标题投影，保留历史原文，不触发数据库迁移或批量重写。
        let titlePrompt = agentType == .codex ? CodexPromptText.normalized(prompt) : prompt
        if !titlePrompt.isEmpty {
            let trimmed = titlePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
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

    init(from session: AgentSession, includeChildren: Bool = true) {
        self.sessionId = session.id
        self.agentTypeRaw = session.agentType.rawValue
        self.startTime = session.startTime
        self.completedAt = session.completedAt
        self.completionNeedsReview = session.completionNeedsReview
        self.sourceNamespace = session.sourceNamespace
        self.sourceInstanceId = session.sourceInstanceId
        self.nativeTaskId = session.nativeTaskId
        self.observationEndedAt = session.observationEndedAt
        self.historyDate = session.completedAt ?? session.observationEndedAt ?? session.startTime
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
        self.toolEvents = includeChildren ? session.events.map { StoredToolEvent(from: $0) } : []
        self.chatMessages = includeChildren ? session.chatHistory.map { StoredChatMessage(from: $0) } : []
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
        self.historyDate = completedAt ?? startTime
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
