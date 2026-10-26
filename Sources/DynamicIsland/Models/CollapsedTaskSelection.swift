import Foundation

/// 只选择收起态的展示候选，不裁剪会话数据或待处理请求。
enum CollapsedTaskSelection {
    static let defaultLimit = 3
    static let limitRange = 1...5

    static func normalizedLimit(_ value: Int) -> Int {
        min(limitRange.upperBound, max(limitRange.lowerBound, value))
    }

    static func select(from sessions: [AgentSession], limit: Int,
                       remindersEnabled: Bool = AppPreferences.defaults.object(forKey: "taskAttentionEnabled") as? Bool ?? true) -> [AgentSession] {
        Array(sessions.sorted { lhs, rhs in
            // 实际待处理请求不能被较新的后台活动挤走。
            if lhs.hasPendingInteraction != rhs.hasPendingInteraction {
                return lhs.hasPendingInteraction
            }
            let lhsNeedsReview = remindersEnabled && lhs.status == .completed && lhs.completionNeedsReview
            let rhsNeedsReview = remindersEnabled && rhs.status == .completed && rhs.completionNeedsReview
            if lhsNeedsReview != rhsNeedsReview { return lhsNeedsReview }
            if lhsNeedsReview, lhs.completedAt != rhs.completedAt {
                return (lhs.completedAt ?? .distantPast) > (rhs.completedAt ?? .distantPast)
            }
            if lhs.lastActivityTime != rhs.lastActivityTime {
                return lhs.lastActivityTime > rhs.lastActivityTime
            }
            if lhs.startTime != rhs.startTime {
                return lhs.startTime > rhs.startTime
            }
            return lhs.id < rhs.id
        }.prefix(normalizedLimit(limit)))
    }
}
