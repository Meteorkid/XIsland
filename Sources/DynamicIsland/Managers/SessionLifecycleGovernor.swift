import Foundation
import Observation

/// A5 的显示层状态：自动隐藏只影响列表可见性，绝不删除会话或历史。
///
/// `@Observable` 是必要的：`SessionManager.visibleSessions` 在 SwiftUI body 中被读取，
/// Observation 需要跟踪这里的集合变化才能触发重绘。
@MainActor
@Observable
final class SessionLifecycleGovernor {
    static let shared = SessionLifecycleGovernor()

    private(set) var hiddenSessionIDs: Set<String> = []
    private(set) var supersededSessionIDs: Set<String> = []

    private init() {}

    func update(hidden: Set<String>, superseded: Set<String>) {
        if hidden != hiddenSessionIDs { hiddenSessionIDs = hidden }
        if superseded != supersededSessionIDs { supersededSessionIDs = superseded }
    }

    /// 会话有新活动时立即恢复显示。
    func reveal(_ id: String) {
        guard hiddenSessionIDs.contains(id) else { return }
        hiddenSessionIDs.remove(id)
    }

    func reset() {
        hiddenSessionIDs = []
        supersededSessionIDs = []
    }
}
