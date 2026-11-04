import Foundation

/// `[AgentSession]` → `[IslandSessionSummary]` 的唯一转换点。
/// 把 `@Observable` 类、回传闭包、SwiftUI 类型都挡在策略层之外。
enum IslandSummaryMapper {
    @MainActor
    static func make(_ sessions: [AgentSession]) -> [IslandSessionSummary] {
        sessions.map { session in
            let interactionId: String?
            let interactionKind: String?
            let detail: String

            if let permission = session.pendingPermission {
                interactionId = permission.id.uuidString
                interactionKind = "permission"
                // operationText 会展示真实命令与完整参数，出本机前必须脱敏。
                detail = permission.operationText
            } else if let question = session.pendingQuestion {
                interactionId = question.id.uuidString
                interactionKind = "question"
                detail = question.text
            } else if let plan = session.pendingPlanReview {
                interactionId = plan.id.uuidString
                interactionKind = "planReview"
                detail = plan.markdown
            } else {
                interactionId = nil
                interactionKind = nil
                detail = session.statusText
            }

            return IslandSessionSummary(
                id: session.id,
                status: session.status.rawValue,
                title: session.workspaceName,
                detail: detail,
                workingDirectory: session.workingDirectory,
                isSubagent: session.isSubagent,
                lastActivityAt: session.lastActivityTime,
                completedAt: session.completedAt,
                needsReview: session.completionNeedsReview,
                interactionId: interactionId,
                interactionKind: interactionKind,
                isObservationEnded: session.observationEndedAt != nil
            )
        }
    }

    static func hasWorkingSession(_ summaries: [IslandSessionSummary]) -> Bool {
        let working: Set<String> = [
            "active", "thinking", "compacting",
            "waitingPermission", "waitingAnswer", "waitingPlanReview",
        ]
        return summaries.contains { working.contains($0.status) }
    }
}
