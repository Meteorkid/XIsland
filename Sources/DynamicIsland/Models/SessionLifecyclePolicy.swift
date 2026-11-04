import Foundation

/// 会话生命周期判定。全部是纯函数：进程存活、时间、电量等由调用方注入，
/// 便于在无真实进程的 XCTest 里锁定边界。
enum SessionLifecyclePolicy {
    static let autoHideThreshold: TimeInterval = 30 * 60
    /// 进程已失联后，再给一段时间等迟到的 SessionEnd。
    static let reapGrace: TimeInterval = 60

    /// 30 分钟无活动的静默会话可以隐藏；需要人工介入的必须常驻。
    static func shouldAutoHide(status: String,
                               hasPendingInteraction: Bool,
                               needsReview: Bool = false,
                               lastActivityAt: Date,
                               now: Date,
                               threshold: TimeInterval = autoHideThreshold) -> Bool {
        // 待审批/待回答/待审计划，以及「已完成但用户还没看过」的会话，
        // 都属于需要人工介入，不能被"无活动"悄悄收走。
        guard !hasPendingInteraction, !needsReview else { return false }
        guard !["error", "completionUnconfirmed"].contains(status) else { return false }
        guard ["idle", "completed", "observationUnavailable", "active", "thinking"].contains(status) else {
            return false
        }
        return now.timeIntervalSince(lastActivityAt) >= threshold
    }

    /// 同一工作目录里的多个会话，只保留最近活跃的一条作为主会话。
    ///
    /// 三条约束：
    /// 1. 待审批/待回答/待审计划的会话绝不取代——否则会丢掉用户的决定通道；
    /// 2. 平局用 id 排序打破，保证不同轮次结果稳定，不产生列表抖动；
    /// 3. 空目录不分组（很多观察型来源拿不到 cwd）。
    static func supersededSessionIDs(_ summaries: [IslandSessionSummary]) -> Set<String> {
        var groups: [String: [IslandSessionSummary]] = [:]
        for session in summaries {
            let directory = session.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            // 观察型来源可能出现「状态是 waitingPermission、但没有可回传的交互请求」的情况。
            // 只看 hasPendingInteraction 会把这类会话隐藏成幽灵，必须同时排除等待态。
            let waitingStatus = ["waitingPermission", "waitingAnswer", "waitingPlanReview"]
                .contains(session.status)
            guard !directory.isEmpty, !session.hasPendingInteraction, !waitingStatus else { continue }
            groups[directory, default: []].append(session)
        }
        var superseded: Set<String> = []
        for (_, var members) in groups where members.count > 1 {
            members.sort {
                if $0.lastActivityAt != $1.lastActivityAt { return $0.lastActivityAt < $1.lastActivityAt }
                return $0.id < $1.id
            }
            // 最后一条是主会话，其余被取代。
            for member in members.dropLast() { superseded.insert(member.id) }
        }
        return superseded
    }

    /// 进程已死但没收到 SessionEnd：撤销挂起审批，避免用户对着幽灵请求点批准。
    static func shouldReap(status: String,
                           isProcessAlive: Bool,
                           lastActivityAt: Date,
                           now: Date,
                           grace: TimeInterval = reapGrace) -> Bool {
        guard !isProcessAlive else { return false }
        guard now.timeIntervalSince(lastActivityAt) >= grace else { return false }
        // 已完成 / 已结束的状态本来就在等待清理，不需要"失联"判定。
        guard !["completed", "observationUnavailable", "error"].contains(status) else { return false }
        return true
    }

    /// 跨重启身份关联：优先精确标识；回退时**只接受同目录恰好一条候选**，
    /// 多会话并存时宁可新建，也不把身份错并到别人的历史上。
    static func associate(identity: SessionIdentity,
                          candidates: [IslandSessionSummary]) -> String? {
        if let nativeTaskID = identity.nativeTaskID,
           let exact = candidates.first(where: { $0.id == nativeTaskID }) { return exact.id }
        guard !identity.workingDirectory.isEmpty else { return nil }
        let matches = candidates.filter {
            $0.workingDirectory == identity.workingDirectory
        }
        guard matches.count == 1 else { return nil }
        return matches[0].id
    }
}

struct SessionIdentity: Equatable, Sendable {
    /// 客户端提供的稳定任务 ID（如 termSessionId / nativeTaskId）。
    let nativeTaskID: String?
    let workingDirectory: String
}
