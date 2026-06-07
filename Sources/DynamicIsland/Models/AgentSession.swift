import Foundation
import Observation
import SwiftUI

enum SessionStatus: String, Codable, Sendable {
    case active
    case idle
    case thinking
    case waitingPermission
    case waitingAnswer
    case waitingPlanReview
    case completed
    case error
    case compacting

    var color: String {
        switch self {
        case .active: "cyan"
        case .idle: "green"
        case .thinking: "purple"
        case .waitingPermission, .waitingAnswer, .waitingPlanReview: "orange"
        case .completed: "gray"
        case .error: "red"
        case .compacting: "yellow"
        }
    }

    /// SwiftUI Color for animation effects
    var uiColor: Color {
        switch self {
        case .active: .cyan
        case .idle: .green
        case .thinking: .purple
        case .waitingPermission, .waitingAnswer, .waitingPlanReview: .orange
        case .completed: .gray
        case .error: .red
        case .compacting: .yellow
        }
    }

    var displayName: String {
        switch self {
        case .active: return L10n.statusActive
        case .idle: return L10n.statusIdle
        case .thinking: return L10n.statusThinking
        case .waitingPermission: return L10n.statusWaitingPermission
        case .waitingAnswer: return L10n.statusWaitingAnswer
        case .waitingPlanReview: return L10n.statusWaitingPlanReview
        case .completed: return L10n.statusCompleted
        case .error: return L10n.statusError
        case .compacting: return L10n.statusCompacting
        }
    }
}

struct ChatMessage: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let role: ChatRole
    let content: String

    enum ChatRole: String, Sendable {
        case user
        case assistant
        case system
    }
}

struct TokenUsage: Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var totalTokens: Int = 0
    var estimatedCostUSD: Double = 0.0
    var model: String = ""

    var formattedTokens: String {
        let total = totalTokens > 0 ? totalTokens : inputTokens + outputTokens
        if total == 0 { return "" }
        if total < 1000 { return "\(total)" }
        if total < 1_000_000 { return String(format: "%.1fK", Double(total) / 1000) }
        return String(format: "%.2fM", Double(total) / 1_000_000)
    }

    var formattedCost: String {
        if estimatedCostUSD <= 0 { return "" }
        if estimatedCostUSD < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", estimatedCostUSD)
    }
}

struct GitCheckpoint: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let hash: String
    let message: String
}

@Observable
final class AgentSession: Identifiable {
    let id: String
    /// May be updated when bridging both Cursor and Claude hooks for the same logical session (mirrored id suffix).
    var agentType: AgentType
    let startTime: Date
    var terminal: String
    var workingDirectory: String
    var prompt: String

    var status: SessionStatus = .active
    var events: [ToolEvent] = []
    var currentTool: String?
    var statusText: String = ""
    var lastActivityTime: Date = Date()
    var agentResponse: String = ""

    var tokenUsage = TokenUsage()
    var chatHistory: [ChatMessage] = []
    var subagentIds: [String] = []
    var parentSessionId: String?
    var checkpoints: [GitCheckpoint] = []

    var recapText: String?

    var completedAt: Date?
    var windowNumber: Int?
    var termSessionId: String?

    var pendingPermission: PendingPermission?
    var pendingQuestion: PendingQuestion?
    var pendingPlanReview: PendingPlanReview?

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

    var hasPromptTitle: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var duration: TimeInterval { Date().timeIntervalSince(startTime) }

    var formattedDuration: String {
        let mins = Int(duration) / 60
        if mins < 1 { return "<1m" }
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h\(mins % 60)m"
    }

    var lastActivity: String {
        if let tool = currentTool {
            return "Running \(tool)"
        }
        if let last = events.last {
            return last.isComplete ? "\(last.tool) done" : "Running \(last.tool)"
        }
        return statusText.isEmpty ? "Working..." : statusText
    }

    var isSubagent: Bool { parentSessionId != nil }

    init(id: String, agentType: AgentType, terminal: String = "", workingDirectory: String = "", prompt: String = "", startTime: Date = Date()) {
        self.id = id
        self.agentType = agentType
        self.startTime = startTime
        self.terminal = terminal
        self.workingDirectory = workingDirectory
        self.prompt = prompt
    }
}

struct PendingPermission {
    let id = UUID()
    let requestingAgent: AgentType
    let tool: String
    let description: String
    let diff: String?
    let filePath: String?
    let respond: @Sendable (Bool) -> Void
}

struct PendingQuestion {
    let id = UUID()
    let requestingAgent: AgentType
    let text: String
    let options: [String]
    let respond: @Sendable (String) -> Void
    /// Closes the socket fd without sending a response (used when this question is
    /// superseded by a newer event or filtered as a stub).
    let cancel: (@Sendable () -> Void)?
}

struct PendingPlanReview {
    let id = UUID()
    let requestingAgent: AgentType
    let markdown: String
    let respond: @Sendable (Bool, String?) -> Void
}
