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
    static let onCompletionKey = "taskAttentionOnCompletion"
    static let onInteractionKey = "taskAttentionOnInteraction"
    static let forceAcrossSpacesKey = "taskAttentionForceAcrossSpaces"

    static func isEnabled(defaults: UserDefaults = AppPreferences.defaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func onCompletion(defaults: UserDefaults = AppPreferences.defaults) -> Bool {
        defaults.object(forKey: onCompletionKey) as? Bool ?? true
    }

    static func onInteraction(defaults: UserDefaults = AppPreferences.defaults) -> Bool {
        defaults.object(forKey: onInteractionKey) as? Bool ?? true
    }

    static func forcesAcrossSpaces(defaults: UserDefaults = AppPreferences.defaults) -> Bool {
        defaults.object(forKey: forceAcrossSpacesKey) as? Bool ?? false
    }

    /// 总开关优先；随后按事件类型分流，完成与审批/问答/计划可以分开控制。
    static func shouldPresent(for kind: TaskAttentionEvent.Kind,
                              defaults: UserDefaults = AppPreferences.defaults) -> Bool {
        guard isEnabled(defaults: defaults) else { return false }
        switch kind {
        case .completion:
            return onCompletion(defaults: defaults)
        case .permission, .question, .planReview:
            return onInteraction(defaults: defaults)
        }
    }
}
