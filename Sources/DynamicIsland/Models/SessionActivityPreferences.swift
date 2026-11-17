import Foundation

/// 活跃窗口：默认只展示最近 24 小时内有对话的会话。
/// 用户可以对单个会话「保留」，保留的会话不受时间窗口限制；窗口设为 0 表示不过滤。
enum SessionActivityPreferences {
    static let windowHoursKey = "activeSessionWindowHours"
    static let pinnedKey = "pinnedActiveSessionIDs"

    static let defaultWindowHours = 24

    static func windowHours(defaults: UserDefaults = AppPreferences.defaults) -> Int {
        defaults.object(forKey: windowHoursKey) as? Int ?? defaultWindowHours
    }

    static func pinnedIDs(defaults: UserDefaults = AppPreferences.defaults) -> Set<String> {
        Set(defaults.stringArray(forKey: pinnedKey) ?? [])
    }

    static func isPinned(_ id: String, defaults: UserDefaults = AppPreferences.defaults) -> Bool {
        pinnedIDs(defaults: defaults).contains(id)
    }

    static func setPinned(_ id: String, pinned: Bool, defaults: UserDefaults = AppPreferences.defaults) {
        var ids = pinnedIDs(defaults: defaults)
        if pinned { ids.insert(id) } else { ids.remove(id) }
        defaults.set(Array(ids).sorted(), forKey: pinnedKey)
    }

    static func isActive(_ session: AgentSession, now: Date = Date(),
                         windowHours: Int, pinned: Set<String>) -> Bool {
        if windowHours <= 0 { return true }
        if pinned.contains(session.id) { return true }
        // 待处理交互永远不能因为时间窗口被藏起来。
        if session.hasPendingInteraction { return true }
        switch session.status {
        case .active, .thinking, .compacting,
             .waitingPermission, .waitingAnswer, .waitingPlanReview:
            return true
        default:
            return session.lastActivityTime >= now.addingTimeInterval(-Double(windowHours) * 3600)
        }
    }
}
