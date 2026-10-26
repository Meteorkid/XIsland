import Foundation

/// 提醒只是呈现事件，不代表任务被查看、请求被回答或权限已授权。
struct TaskAttentionEvent: Equatable {
    enum Kind: Hashable { case completion, permission, question, planReview }

    let id = UUID()
    let sessionID: String
    let kind: Kind
    var completedAt: Date? = nil
    var requestID: UUID? = nil
    var nativeRequestID: String? = nil
}

enum TaskAttentionSettings {
    static let enabledKey = "taskAttentionEnabled"

    static func isEnabled(defaults: UserDefaults = AppPreferences.defaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}
