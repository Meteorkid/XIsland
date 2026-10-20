import Foundation
import SwiftData

/// 同步和后台保存共享事务；每次调用创建自己的 Context，不携带可观察会话。
enum SessionSaveWorker {
    struct Result: Sendable {
        let changed: Bool
        let childWriteCount: Int
        let mergedApprovalObservation: KimiCodeApprovalObservation?
        /// 已在同一事务中消费的孤儿事实，供主执行器合并到保存期间更新的会话。
        let mergedOrphanObservation: KimiCodeApprovalObservation?
        let storedStatus: SessionStatus
        let projectedStatusText: String?
        let committedChildren: SessionChildSnapshot
    }

    static func save(snapshot: SessionSaveSnapshot, previousChildren: SessionChildSnapshot?,
                     container: ModelContainer,
                     beforeCommit: @Sendable () throws -> Void = {}) throws -> Result {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let sessionId = snapshot.id
        let descriptor = FetchDescriptor<StoredSession>(predicate: #Predicate { $0.sessionId == sessionId })
        do {
            let existing = try context.fetch(descriptor).first
            var orphanQuery = FetchDescriptor<StoredKimiCodeApprovalOrphan>(predicate: #Predicate { $0.sessionId == sessionId })
            orphanQuery.fetchLimit = 1
            let orphan = try context.fetch(orphanQuery).first
            let orphanObservation = try orphan.map { try KimiCodeApprovalObservation.decode($0.observationData) }
            var approvalObservation = snapshot.kimiCodeApprovalObservation
            if let orphanObservation {
                if approvalObservation == nil { approvalObservation = orphanObservation }
                else { approvalObservation?.merge(orphanObservation) }
            }
            if snapshot.agentType == .kimi, let existing, existing.agentType == .kimi,
               existing.sourceNamespace == snapshot.sourceNamespace,
               existing.sourceInstanceId == snapshot.sourceInstanceId,
               existing.nativeTaskId == snapshot.nativeTaskId,
               let data = existing.kimiCodeApprovalObservationData {
                // 排队快照可能早于前一笔孤儿转移；保留已提交的身份事实及当前快照的基础状态。
                let committed = try KimiCodeApprovalObservation.decode(data)
                if approvalObservation == nil {
                    approvalObservation = KimiCodeApprovalObservation(baseStatus: snapshot.status, baseStatusText: snapshot.statusText)
                }
                approvalObservation?.merge(committed)
                if snapshot.status == .completed || approvalObservation?.baseStatus == .completed {
                    approvalObservation?.endSession()
                }
            }
            let approvalData = try approvalObservation.map { try JSONEncoder().encode($0) }
            let canProjectApproval = !snapshot.hasPendingInteraction && snapshot.status != .completed && snapshot.status != .observationUnavailable
            let storedStatus = canProjectApproval ? approvalObservation?.displayedStatus ?? approvalObservation?.baseStatus ?? snapshot.status : snapshot.status
            let childWriteCount: Int
            if let existing {
                func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<StoredSession, Value>, to value: Value) {
                    if existing[keyPath: keyPath] != value { existing[keyPath: keyPath] = value }
                }
                let observed = snapshot.sourceInstanceId != nil
                update(\.agentTypeRaw, to: snapshot.agentType.rawValue)
                update(\.startTime, to: observed ? min(existing.startTime, snapshot.startTime) : snapshot.startTime)
                update(\.completedAt, to: snapshot.completedAt)
                update(\.sourceNamespace, to: snapshot.sourceNamespace)
                update(\.sourceInstanceId, to: snapshot.sourceInstanceId)
                update(\.nativeTaskId, to: snapshot.nativeTaskId)
                update(\.observationEndedAt, to: snapshot.observationEndedAt)
                update(\.kimiCodeApprovalObservationData, to: approvalData)
                update(\.historyDate, to: snapshot.completedAt ?? snapshot.observationEndedAt ?? snapshot.startTime)
                update(\.prompt, to: snapshot.prompt)
                update(\.workingDirectory, to: snapshot.workingDirectory)
                update(\.terminal, to: snapshot.terminal)
                update(\.statusRaw, to: storedStatus.rawValue)
                update(\.recapText, to: snapshot.recapText)
                update(\.inputTokens, to: observed ? max(existing.inputTokens, snapshot.tokenUsage.inputTokens) : snapshot.tokenUsage.inputTokens)
                update(\.outputTokens, to: observed ? max(existing.outputTokens, snapshot.tokenUsage.outputTokens) : snapshot.tokenUsage.outputTokens)
                update(\.totalTokens, to: observed ? max(existing.totalTokens, snapshot.tokenUsage.totalTokens) : snapshot.tokenUsage.totalTokens)
                update(\.estimatedCostUSD, to: observed ? max(existing.estimatedCostUSD, snapshot.tokenUsage.estimatedCostUSD) : snapshot.tokenUsage.estimatedCostUSD)
                update(\.model, to: snapshot.tokenUsage.model)
                childWriteCount = try updateChildren(of: existing, from: snapshot, previous: previousChildren, in: context)
            } else {
                let stored = StoredSession(sessionId: snapshot.id, agentTypeRaw: snapshot.agentType.rawValue,
                    startTime: snapshot.startTime, completedAt: snapshot.completedAt, prompt: snapshot.prompt,
                    workingDirectory: snapshot.workingDirectory, terminal: snapshot.terminal,
                    statusRaw: storedStatus.rawValue, recapText: snapshot.recapText,
                    inputTokens: snapshot.tokenUsage.inputTokens, outputTokens: snapshot.tokenUsage.outputTokens,
                    totalTokens: snapshot.tokenUsage.totalTokens, estimatedCostUSD: snapshot.tokenUsage.estimatedCostUSD,
                    model: snapshot.tokenUsage.model)
                stored.sourceNamespace = snapshot.sourceNamespace
                stored.sourceInstanceId = snapshot.sourceInstanceId
                stored.nativeTaskId = snapshot.nativeTaskId
                stored.observationEndedAt = snapshot.observationEndedAt
                stored.historyDate = snapshot.completedAt ?? snapshot.observationEndedAt ?? snapshot.startTime
                stored.kimiCodeApprovalObservationData = approvalData
                context.insert(stored)
                let events = snapshot.events.map { StoredToolEvent(from: $0) }
                let messages = snapshot.chatHistory.map { StoredChatMessage(from: $0) }
                for event in events { context.insert(event) }
                for message in messages { context.insert(message) }
                stored.toolEvents = events
                stored.chatMessages = messages
                childWriteCount = snapshot.events.count + snapshot.chatHistory.count
            }
            if let orphan { context.delete(orphan) }
            let changed = context.hasChanges
            if changed {
                try beforeCommit()
                try context.save()
            }
            return Result(changed: changed, childWriteCount: childWriteCount,
                mergedApprovalObservation: approvalObservation, mergedOrphanObservation: orphanObservation,
                storedStatus: storedStatus,
                projectedStatusText: canProjectApproval ? approvalObservation.map { $0.displayedText ?? $0.baseStatusText } : nil,
                committedChildren: snapshot.committedChildren(previous: previousChildren))
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func updateChildren(of stored: StoredSession, from snapshot: SessionSaveSnapshot,
                                       previous: SessionChildSnapshot?, in context: ModelContext) throws -> Int {
        var writeCount = 0
        if let previous {
            let sessionID = snapshot.id
            let changes = snapshot.pendingChildChanges
            for event in changes?.events ?? snapshot.events where previous.events[event.id] != event {
                let eventID = event.id
                var query = FetchDescriptor<StoredToolEvent>(predicate: #Predicate {
                    $0.eventId == eventID && $0.session?.sessionId == sessionID
                })
                query.fetchLimit = 1
                // 读取失败由整个事务回滚，不可把未知数据当成不存在。
                if let existing = try context.fetch(query).first { existing.update(from: event) }
                else { let child = StoredToolEvent(from: event); context.insert(child); child.session = stored }
                writeCount += 1
            }
            for message in changes?.messages ?? snapshot.chatHistory where previous.messages[message.id] != message {
                let messageID = message.id
                var query = FetchDescriptor<StoredChatMessage>(predicate: #Predicate {
                    $0.messageId == messageID && $0.session?.sessionId == sessionID
                })
                query.fetchLimit = 1
                if let existing = try context.fetch(query).first { existing.update(from: message) }
                else { let child = StoredChatMessage(from: message); context.insert(child); child.session = stored }
                writeCount += 1
            }
            return writeCount
        }
        var eventsById: [UUID: StoredToolEvent] = [:]
        for event in stored.toolEvents {
            let id = event.eventId ?? UUID()
            event.eventId = id
            eventsById[id] = event
        }
        for event in snapshot.events {
            writeCount += 1
            if let existing = eventsById[event.id] { existing.update(from: event) }
            else {
                let child = StoredToolEvent(from: event)
                stored.toolEvents.append(child)
                eventsById[event.id] = child
            }
        }
        var messagesById: [UUID: StoredChatMessage] = [:]
        for message in stored.chatMessages {
            let id = message.messageId ?? UUID()
            message.messageId = id
            messagesById[id] = message
        }
        for message in snapshot.chatHistory {
            writeCount += 1
            if let existing = messagesById[message.id] { existing.update(from: message) }
            else {
                let child = StoredChatMessage(from: message)
                stored.chatMessages.append(child)
                messagesById[message.id] = child
            }
        }
        return writeCount
    }
}
