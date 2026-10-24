import Foundation

/// 跨执行器只传页面所需的值，不向 SwiftUI 暴露后台 ModelContext 中的对象。
struct HistorySessionRow: Identifiable, Sendable {
    var id: String { sessionId }
    let sessionId: String
    let agentType: AgentType
    let startTime: Date
    let completedAt: Date?
    let completionNeedsReview: Bool
    let observationEndedAt: Date?
    let prompt: String
    let workingDirectory: String
    let displayTitle: String
    let formattedDuration: String

    init(_ session: StoredSession) {
        sessionId = session.sessionId
        agentType = session.agentType
        startTime = session.startTime
        completedAt = session.completedAt
        completionNeedsReview = session.statusRaw == SessionStatus.completed.rawValue && session.completionNeedsReview == true
        observationEndedAt = session.observationEndedAt
        prompt = session.prompt
        workingDirectory = session.workingDirectory
        displayTitle = session.displayTitle
        formattedDuration = session.formattedDuration
    }
}

struct HistoryPageSnapshot: Sendable {
    let sessions: [HistorySessionRow]
    let totalCount: Int
}
