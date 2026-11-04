import Foundation

/// 只选择收起态的展示候选，不裁剪会话数据或待处理请求。
///
/// 排序是纯函数（可单测），"最短驻留"由 `stableSelection` 表达：
/// 展示项一旦确定，除非出现严格更紧急的候选，否则在 `minHold` 内不换位。
enum CollapsedTaskSelection {
    static let defaultLimit = 3
    static let limitRange = 1...5

    /// 同级候选的最短驻留时间：参照 coucou 的 minHold 经验值。
    static let minHold: TimeInterval = 1.2

    /// "刚失败"的时间窗：窗内失败优先级高于完成待查看，窗外降级。
    static let errorMoment: TimeInterval = 60

    static func normalizedLimit(_ value: Int) -> Int {
        min(limitRange.upperBound, max(limitRange.lowerBound, value))
    }

    /// 展示档位，数值越小越紧急。
    ///
    /// - 0 用户正在等（权限、问题、计划审查）
    /// - 1 刚刚失败（需立刻看一眼，否则会被后续完成事件淹没）
    /// - 2 完成但未查看
    /// - 3 其余活动
    /// - 4 空闲 / 观察不可用 / 已完成未需查看 / 较早的失败与完成
    static func rank(_ session: AgentSession, remindersEnabled: Bool, now: Date) -> Int {
        if session.hasPendingInteraction { return 0 }

        if session.status == .error {
            if let endedAt = session.completedAt {
                return now.timeIntervalSince(endedAt) < errorMoment ? 1 : 4
            }
            // 无完成时间的失败按"刚刚发生"处理，避免状态迁移中途掉到最低档。
            return 1
        }

        if remindersEnabled, session.status == .completed, session.completionNeedsReview {
            return 2
        }

        switch session.status {
        case .idle, .completed, .observationUnavailable, .completionUnconfirmed:
            return 4
        default:
            return 3
        }
    }

    /// 同档内的次序：完成待查看按完成时间，其余按最后活动时间，最后以 id 兜底保证确定性。
    static func ordered(
        from sessions: [AgentSession],
        remindersEnabled: Bool = AppPreferences.defaults.object(forKey: "taskAttentionEnabled") as? Bool ?? true,
        now: Date = Date()
    ) -> [AgentSession] {
        sessions.sorted { lhs, rhs in
            let lhsRank = rank(lhs, remindersEnabled: remindersEnabled, now: now)
            let rhsRank = rank(rhs, remindersEnabled: remindersEnabled, now: now)
            if lhsRank != rhsRank { return lhsRank < rhsRank }

            if lhsRank == 2, lhs.completedAt != rhs.completedAt {
                return (lhs.completedAt ?? .distantPast) > (rhs.completedAt ?? .distantPast)
            }
            if lhs.lastActivityTime != rhs.lastActivityTime {
                return lhs.lastActivityTime > rhs.lastActivityTime
            }
            if lhs.startTime != rhs.startTime {
                return lhs.startTime > rhs.startTime
            }
            return lhs.id < rhs.id
        }
    }

    static func select(
        from sessions: [AgentSession],
        limit: Int,
        remindersEnabled: Bool = AppPreferences.defaults.object(forKey: "taskAttentionEnabled") as? Bool ?? true
    ) -> [AgentSession] {
        Array(ordered(from: sessions, remindersEnabled: remindersEnabled).prefix(normalizedLimit(limit)))
    }

    /// 一次稳定选择的结果，调用方负责把 `shownId` / `shownSince` 存起来下次回传。
    struct StableResult {
        let sessions: [AgentSession]
        let shownId: String?
        let shownSince: Date
    }

    /// 带最短驻留的选择。
    ///
    /// 两条稳定性保证：
    /// 1. **顺序保持**：候选集合与 `previousOrder` 完全一致时，沿用上次顺序，避免同档内
    ///    `lastActivityTime` 的微小变化让图标左右平移、让轮播 index 指向别的会话。
    /// 2. **驻留**：`current` 仍在候选内、不比最佳候选更紧急、且未用满 `minHold` 时继续保留。
    ///    出现严格更紧急的候选（新的待处理请求、新的失败）则立即让位。
    static func stableSelection(
        from sessions: [AgentSession],
        limit: Int,
        remindersEnabled: Bool = AppPreferences.defaults.object(forKey: "taskAttentionEnabled") as? Bool ?? true,
        current: String? = nil,
        since: Date = .distantPast,
        previousOrder: [String] = [],
        now: Date = Date()
    ) -> StableResult {
        let candidates = ordered(from: sessions, remindersEnabled: remindersEnabled, now: now)
        var visible = Array(candidates.prefix(normalizedLimit(limit)))
        guard let best = visible.first else {
            return StableResult(sessions: visible, shownId: nil, shownSince: now)
        }

        // 集合未变则保住原顺序：id 集合相等是必要条件，避免漏掉"同 id 换内容"的情况。
        if !previousOrder.isEmpty, Set(visible.map(\.id)) == Set(previousOrder) {
            let byId = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
            let restored = previousOrder.compactMap { byId[$0] }
            if restored.count == visible.count { visible = restored }
        }

        if let current,
           current != best.id,
           let held = candidates.first(where: { $0.id == current }),
           visible.contains(where: { $0.id == current }) {
            let heldRank = rank(held, remindersEnabled: remindersEnabled, now: now)
            let bestRank = rank(best, remindersEnabled: remindersEnabled, now: now)
            if heldRank <= bestRank, now.timeIntervalSince(since) < minHold {
                return StableResult(sessions: visible, shownId: current, shownSince: since)
            }
        }

        return StableResult(sessions: visible, shownId: best.id, shownSince: now)
    }
}
