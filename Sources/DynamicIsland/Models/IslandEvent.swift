import Foundation

// MARK: - 会话摘要

/// A 类自动化共用的会话快照。刻意不引用 `AgentSession`（`@Observable` 类、内含回传闭包），
/// 让策略层可以在 XCTest 里用字面量构造，并做纯函数断言。
struct IslandSessionSummary: Equatable, Sendable {
    let id: String
    /// `SessionStatus.rawValue`。
    let status: String
    let title: String
    /// 可能包含命令、路径或回复正文；出本机前必须经 `EventRedaction`。
    let detail: String
    let workingDirectory: String
    let isSubagent: Bool
    let lastActivityAt: Date
    let completedAt: Date?
    let needsReview: Bool
    let interactionId: String?
    /// "permission" / "question" / "planReview"。
    let interactionKind: String?
    /// 观察型来源已明确报告结束，但会话还挂着的「失联」代理指标。
    var isObservationEnded: Bool = false

    var hasPendingInteraction: Bool { interactionId != nil }
}

enum IslandEventKind: String, CaseIterable, Equatable, Sendable {
    case started
    case permission
    case question
    case planReview
    case completed
    case error
    /// 后台压缩：用于过滤误唤醒，永远不产生通知或推送。
    case backgroundCompaction
}

struct IslandEvent: Equatable, Sendable {
    let kind: IslandEventKind
    let sessionId: String
    /// 交互请求 ID。仅审批/问答/计划类有值，回传决定时必须校验。
    let requestId: String?
    /// 与 `requestId` 分开：非交互事件也需要一个跨轮次稳定的判重依据。
    let stableToken: String
    let title: String
    let detail: String
    let workingDirectory: String
    let isSubagent: Bool
    let occurredAt: Date

    var deduplicationKey: String {
        "\(kind.rawValue)|\(sessionId)|\(stableToken)"
    }

    /// 是否需要用户介入。静默时段对此类事件网开一面，避免把用户挡在流程外。
    var requiresUserDecision: Bool {
        switch kind {
        case .permission, .question, .planReview: return true
        default: return false
        }
    }
}

enum IslandEventDeriver {
    /// 对比上一轮与这一轮快照，只对新出现的「需要注意」状态发事件。
    ///
    /// 两条判重规则缺一不可：
    /// 1. `previous` 中同一会话已处于同一注意状态 → 不是新事件（防止列表刷新重复提醒）；
    /// 2. `emitted` 记录历史键（防止状态被消费后又被重建为同一请求）。
    static func derive(previous: [IslandSessionSummary],
                       current: [IslandSessionSummary],
                       now: Date,
                       emitted: Set<String> = []) -> [IslandEvent] {
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [IslandEvent] = []
        for session in current {
            var kind = attentionKind(for: session)
            // 只有「一出现就处于工作态」才算新会话。若一出现就已完成 / 压缩 / 出错，
            // 说明是从持久化恢复的旧会话，不应再报一次 started。
            if kind == nil, previousByID[session.id] == nil, isInitialStatus(session.status) {
                kind = .started
            }
            guard let kind else { continue }

            let token = stableToken(for: session, kind: kind)
            let key = "\(kind.rawValue)|\(session.id)|\(token)"

            // 两类事件用两套判重：
            // - 请求型（审批/问答/计划）：同一 requestId 只报一次，靠 emitted 跨轮次去重；
            // - 状态型（started/completed/error）：只按上一轮状态迁移判定。
            //   状态型若也写入 emitted 永久阻断，同一会话第二次出错或第二次完成会被吞掉。
            let isRequestEvent = kind == .permission || kind == .question || kind == .planReview
            if isRequestEvent {
                guard !emitted.contains(key) else { continue }
            }
            if let old = previousByID[session.id], attentionKind(for: old) == kind {
                if !isRequestEvent { continue }
                if stableToken(for: old, kind: kind) == token { continue }
            }

            result.append(IslandEvent(
                kind: kind,
                sessionId: session.id,
                requestId: session.interactionKind == nil ? nil : session.interactionId,
                stableToken: token,
                title: session.title,
                detail: session.detail,
                workingDirectory: session.workingDirectory,
                isSubagent: session.isSubagent,
                occurredAt: now
            ))
        }
        return result
    }

    static func attentionKind(for session: IslandSessionSummary) -> IslandEventKind? {
        if let interaction = session.interactionKind {
            switch interaction {
            case "permission": return .permission
            case "question": return .question
            case "planReview": return .planReview
            default: break
            }
        }
        switch session.status {
        case "error": return .error
        case "completed", "completionUnconfirmed":
            return session.needsReview ? .completed : nil
        case "compacting":
            // 压缩不是「需要用户注意」的状态。不产生事件即可避免唤醒已完成卡片；
            // `DoNotDisturbPolicy` 里对该类型的过滤保留为防御性第二道闸。
            return nil
        default: return nil
        }
    }

    private static func isInitialStatus(_ status: String) -> Bool {
        ["active", "thinking", "idle"].contains(status)
    }

    private static func stableToken(for session: IslandSessionSummary, kind: IslandEventKind) -> String {
        switch kind {
        case .permission, .question, .planReview:
            return session.interactionId ?? session.id
        case .completed:
            return "completed-\(Int(session.completedAt?.timeIntervalSince1970 ?? 0))"
        case .error:
            return "error-\(Int(session.lastActivityAt.timeIntervalSince1970))"
        case .backgroundCompaction:
            return "compacting-\(Int(session.lastActivityAt.timeIntervalSince1970))"
        case .started:
            return "start-\(session.id)"
        }
    }

    /// 保留仍可能复用的键，丢弃已消失会话的历史，避免集合无限增长。
    static func prune(emitted: Set<String>, liveSessionIDs: Set<String>) -> Set<String> {
        Set(emitted.filter { key in
            liveSessionIDs.contains { key.contains("|\($0)|") }
        })
    }
}
