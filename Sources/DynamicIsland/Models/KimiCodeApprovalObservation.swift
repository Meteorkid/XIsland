import Foundation
import SwiftData
import DIShared
import CryptoKit

/// 记录 CLI 原生状态事实；不保存回调，也不代表 XIsland 可以批准请求。
struct KimiCodeApprovalObservation: Codable, Equatable {
    struct Request: Codable, Equatable {
        let id: String
        let agentID: String
        let turnID: String
        let toolCallID: String

        init?(id: String?, agentID: String?, turnID: String?, toolCallID: String?) {
            guard let id, let agentID, let turnID, let toolCallID,
                  [id, agentID, turnID, toolCallID].allSatisfy(Self.isIdentifier) else { return nil }
            self.id = id
            self.agentID = agentID
            self.turnID = turnID
            self.toolCallID = toolCallID
        }

        private static func isIdentifier(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 1024
                && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }

        var isValid: Bool { [id, agentID, turnID, toolCallID].allSatisfy(Self.isIdentifier) }
    }

    private(set) var pending: [String: Request] = [:]
    private(set) var resolved: [String: Request] = [:]
    private(set) var hasUnidentifiedRequest = false
    private(set) var wasInterrupted = false
    /// 可选以兼容已有 JSON；任务 ID 独立于模型工具调用和子代理身份。
    private(set) var backgroundTasks: [String: DINativeBackgroundTask]?
    var baseStatus: SessionStatus
    var baseStatusText: String

    init(baseStatus: SessionStatus = .active, baseStatusText: String = "", unidentified: Bool = false) {
        self.baseStatus = [.waitingPermission, .waitingAnswer, .waitingPlanReview].contains(baseStatus) ? .active : baseStatus
        self.baseStatusText = baseStatusText
        self.hasUnidentifiedRequest = unidentified
    }

    var hasPendingApproval: Bool { !pending.isEmpty || hasUnidentifiedRequest }
    var displayedStatus: SessionStatus? {
        guard hasPendingApproval else { return nil }
        return hasUnidentifiedRequest || wasInterrupted ? .completionUnconfirmed : .waitingPermission
    }
    var displayedText: String? {
        guard hasPendingApproval else { return nil }
        return hasUnidentifiedRequest || wasInterrupted
            ? "Kimi CLI approval result is unconfirmed"
            : "Waiting for permission in Kimi CLI"
    }

    mutating func observeRequest(_ request: Request?) {
        guard let request else { hasUnidentifiedRequest = true; return }
        if let completed = resolved[request.id] {
            if completed != request { hasUnidentifiedRequest = true }
            return
        }
        if let existing = pending[request.id], existing != request {
            hasUnidentifiedRequest = true
            return
        }
        pending[request.id] = request
    }

    mutating func observeResult(_ request: Request?) {
        guard let request else { return }
        if let existing = pending[request.id], existing != request { return }
        if let completed = resolved[request.id], completed != request { return }
        resolved[request.id] = request
        pending.removeValue(forKey: request.id)
        if pending.isEmpty { wasInterrupted = false }
    }

    mutating func observeInterrupt() {
        // turn_id 不含 agent_id，不能据此认领或清除任何一项并发审批。
        if hasPendingApproval { wasInterrupted = true }
    }

    mutating func endSession() {
        for (id, request) in pending { resolved[id] = request }
        pending.removeAll()
        hasUnidentifiedRequest = false
        wasInterrupted = false
        baseStatus = .completed
        markBackgroundTasksUnconfirmed()
    }

    mutating func observeBackgroundTask(_ incoming: DINativeBackgroundTask) {
        guard Self.isValidBackgroundTask(incoming) else { return }
        var task = incoming
        if baseStatus == .completed, task.status == "running" { task.status = "unconfirmed" }
        if var existing = backgroundTasks?[task.id] {
            if let kind = existing.kind, let newKind = task.kind, kind != newKind { return }
            existing.kind = existing.kind ?? task.kind
            existing.description = existing.description ?? task.description
            existing.startedAtMilliseconds = existing.startedAtMilliseconds ?? task.startedAtMilliseconds
            let oldRank = Self.backgroundTaskRank(existing.status)
            let newRank = Self.backgroundTaskRank(task.status)
            if newRank > oldRank {
                existing.status = task.status
                existing.result = task.result
            } else if existing.status == task.status {
                existing.result = existing.result ?? task.result
            }
            task = existing
        }
        if backgroundTasks == nil { backgroundTasks = [:] }
        backgroundTasks?[task.id] = task
    }

    mutating func markBackgroundTasksUnconfirmed() {
        for (id, task) in backgroundTasks ?? [:] where task.status == "running" {
            var ended = task
            ended.status = "unconfirmed"
            backgroundTasks?[id] = ended
        }
    }

    static func backgroundTaskEventID(sessionID: String, taskID: String) -> UUID {
        let key = "kimi_code.background_task\0" + sessionID + "\0" + taskID
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                          bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func backgroundTaskStatuses(sessionID: String) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: (backgroundTasks ?? [:]).values.filter { $0.kind == "agent" }.map {
            (Self.backgroundTaskEventID(sessionID: sessionID, taskID: $0.id), $0.status)
        })
    }

    static func isFailedBackgroundTask(_ status: String?) -> Bool {
        status.map { ["failed", "timed_out", "killed"].contains($0) } ?? false
    }

    private static func backgroundTaskRank(_ status: String) -> Int {
        switch status {
        case "running": return 0
        case "unconfirmed": return 1
        case "lost": return 2
        default: return 3
        }
    }

    private static func isValidBackgroundTask(_ task: DINativeBackgroundTask) -> Bool {
        let states = ["running", "completed", "failed", "timed_out", "killed", "lost", "unconfirmed"]
        return !task.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && task.id.utf8.count <= 1024
            && !task.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && (task.kind.map { ["agent", "process", "question"].contains($0) } ?? true)
            && states.contains(task.status)
            && (task.startedAtMilliseconds.map { (0...9_007_199_254_740_991).contains($0) } ?? true)
            && !(task.description?.utf8.contains(0) ?? false) && !(task.result?.utf8.contains(0) ?? false)
    }

    mutating func merge(_ other: Self) {
        for request in other.resolved.values { observeResult(request) }
        for request in other.pending.values { observeRequest(request) }
        hasUnidentifiedRequest = hasUnidentifiedRequest || other.hasUnidentifiedRequest
        wasInterrupted = hasPendingApproval && (wasInterrupted || other.wasInterrupted)
        for task in (other.backgroundTasks ?? [:]).values {
            observeBackgroundTask(task)
        }
    }

    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.pending.allSatisfy({ $0.key == $0.value.id && $0.value.isValid }),
              value.resolved.allSatisfy({ $0.key == $0.value.id && $0.value.isValid }),
              Set(value.pending.keys).isDisjoint(with: value.resolved.keys) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard value.backgroundTasks?.allSatisfy({ $0.key == $0.value.id && isValidBackgroundTask($0.value) }) ?? true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }
}

/// Result 可能先于任何会话活动到达；单独保存事实，不制造可见会话或历史空壳。
@Model
final class StoredKimiCodeApprovalOrphan {
    @Attribute(.unique) var sessionId: String
    var observationData: Data
    var updatedAt: Date

    init(sessionId: String, observationData: Data, updatedAt: Date = Date()) {
        self.sessionId = sessionId
        self.observationData = observationData
        self.updatedAt = updatedAt
    }
}
