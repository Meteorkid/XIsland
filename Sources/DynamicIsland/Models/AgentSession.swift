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
    case observationUnavailable
    case completionUnconfirmed

    var color: String {
        switch self {
        case .active: "cyan"
        case .idle: "green"
        case .thinking: "purple"
        case .waitingPermission, .waitingAnswer, .waitingPlanReview: "orange"
        case .completed, .observationUnavailable, .completionUnconfirmed: "gray"
        case .error: "red"
        case .compacting: "yellow"
        }
    }

    /// 排序优先级：数值越小越靠前
    var statusPriority: Int {
        switch self {
        case .error:             return 0  // 出错需要关注
        case .waitingPermission: return 1  // 等待用户授权
        case .waitingAnswer:     return 2  // 等待用户回答
        case .waitingPlanReview: return 3  // 等待计划审核
        case .active:            return 4  // 正在运行
        case .thinking:          return 5  // 思考中
        case .compacting:        return 6  // 压缩中
        case .idle:              return 7  // 空闲
        case .completionUnconfirmed: return 8
        case .completed:         return 9  // 已完成
        case .observationUnavailable: return 10
        }
    }

    /// SwiftUI Color for animation effects
    var uiColor: Color {
        switch self {
        case .active: .cyan
        case .idle: .green
        case .thinking: .purple
        case .waitingPermission, .waitingAnswer, .waitingPlanReview: .orange
        case .completed, .observationUnavailable, .completionUnconfirmed: .gray
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
        case .observationUnavailable: return L10n.statusObservationUnavailable
        case .completionUnconfirmed: return L10n.completionUnconfirmed
        }
    }
}

struct ChatMessage: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let role: ChatRole
    let content: String

    init(id: UUID = UUID(), timestamp: Date, role: ChatRole, content: String) {
        self.id = id
        self.timestamp = timestamp
        self.role = role
        self.content = content
    }

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
    var sourceNamespace: String?
    var sourceInstanceId: String?
    var nativeTaskId: String?
    var observationEndedAt: Date?
    var kimiCodeApprovalObservation: KimiCodeApprovalObservation?
    var windowNumber: Int?
    var termSessionId: String?

    var pendingPermission: PendingPermission?
    var pendingQuestion: PendingQuestion?
    var pendingPlanReview: PendingPlanReview?

    var hasPendingInteraction: Bool {
        pendingPermission != nil || pendingQuestion != nil || pendingPlanReview != nil
    }

    var hasRunningSubagents: Bool {
        events.contains { $0.tool == "Subagent" && $0.isRunning }
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

    var hasPromptTitle: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var duration: TimeInterval { (completedAt ?? observationEndedAt ?? Date()).timeIntervalSince(startTime) }

    var formattedDuration: String {
        let mins = Int(duration) / 60
        if mins < 1 { return "<1m" }
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h\(mins % 60)m"
    }

    var lastActivity: String {
        if !hasPendingInteraction, status != .completed, status != .observationUnavailable,
           let text = kimiCodeApprovalObservation?.displayedText { return text }
        if status == .completionUnconfirmed { return L10n.completionUnconfirmed }
        if status == .observationUnavailable {
            return observationEndedAt == nil ? L10n.statusObservationUnavailable : L10n.observationInterrupted
        }
        if let tool = currentTool {
            return "Running \(tool)"
        }
        if let last = events.last {
            if last.completionUnconfirmed { return "\(last.displayName): \(last.summary)" }
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
    let state = InteractionRequestState()
    let requestingAgent: AgentType
    let tool: String
    let description: String
    let diff: String?
    let filePath: String?
    let respond: @Sendable (Bool) -> Void
    var delivery: InteractionDelivery? = nil
    var cancel: (@Sendable () -> Void)? = nil
    var nativeRequestId: String? = nil
}

struct PendingQuestion {
    let id = UUID()
    let state = InteractionRequestState()
    let requestingAgent: AgentType
    let text: String
    let options: [String]
    let respond: @Sendable (String) -> Void
    /// Closes the socket fd without sending a response (used when this question is
    /// superseded by a newer event or filtered as a stub).
    let cancel: (@Sendable () -> Void)?
    var delivery: InteractionDelivery? = nil
    var nativeRequestId: String? = nil
    var allowsCustomAnswer = false
    var allowsMultipleAnswers = false
    var respondMultiple: (@Sendable ([String]) -> Void)? = nil

    func acceptsAnswer(_ answer: String) -> Bool {
        options.contains(answer) || (allowsCustomAnswer
            && !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && answer.utf8.count <= 8192 && !answer.utf8.contains(0))
    }

    func acceptsAnswers(_ answers: [String]) -> Bool {
        allowsMultipleAnswers && !answers.isEmpty && answers.count <= 128
            && Set(answers).count == answers.count && answers.allSatisfy(acceptsAnswer)
            && answers.reduce(0, { $0 + $1.utf8.count }) <= 8192
            && answers.filter { !options.contains($0) }.count <= 1
    }

    var selectedAnswerValues: [String] {
        var values = options.filter { state.selectedAnswers.contains($0) }
        if allowsCustomAnswer && !state.draftAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values.append(state.draftAnswer)
        }
        return values
    }
}

struct PendingPlanReview {
    let id = UUID()
    let state = InteractionRequestState()
    let requestingAgent: AgentType
    let markdown: String
    let respond: @Sendable (Bool, String?) -> Void
    var delivery: InteractionDelivery? = nil
    var cancel: (@Sendable () -> Void)? = nil
}
