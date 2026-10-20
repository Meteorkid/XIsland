import Foundation
import CoreData
import SwiftData

/// 写入先失效令牌；串行数据库提交不持有主线程可能等待的锁。
final class HistoryJobToken: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    private let serializedCommit: Bool
    private let commitRegistry: HistoryJobRegistry?

    init(serializedCommit: Bool = false, commitRegistry: HistoryJobRegistry? = nil) {
        self.serializedCommit = serializedCommit
        self.commitRegistry = commitRegistry
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    func check() throws {
        try Task.checkCancellation()
        lock.lock()
        defer { lock.unlock() }
        if invalidated { throw HistoryReadError.historyChanged }
    }

    func withCommit<T>(_ work: () throws -> T) throws -> T {
        if serializedCommit {
            // 同一后台写队列已保证事务顺序；只锁提交前检查，主线程失效不等待磁盘。
            try check()
            let lease = commitRegistry.map(HistoryCommitLease.init)
            lease?.begin()
            defer { lease?.end() }
            return try work()
        }
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()
        if invalidated { throw HistoryReadError.historyChanged }
        return try work()
    }
}

/// 登记和失效只持短锁；写线程也能使提交期间新登记的读取失效。
final class HistoryJobRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [UUID: (token: HistoryJobToken, destructive: Bool)] = [:]
    private var activeCommits = 0

    func insert(_ token: HistoryJobToken, id: UUID, destructive: Bool) {
        lock.lock()
        jobs[id] = (token, destructive)
        let committing = activeCommits > 0
        lock.unlock()
        if committing { token.invalidate() }
    }

    func remove(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        jobs.removeValue(forKey: id)
    }

    func invalidate(destructiveOnly: Bool = false) {
        lock.lock()
        let tokens = jobs.values.filter { !destructiveOnly || $0.destructive }.map(\.token)
        lock.unlock()
        tokens.forEach { $0.invalidate() }
    }

    func beginCommit() {
        lock.lock()
        activeCommits += 1
        let tokens = jobs.values.map(\.token)
        lock.unlock()
        tokens.forEach { $0.invalidate() }
    }

    func endCommit() {
        lock.lock(); defer { lock.unlock() }
        precondition(activeCommits > 0)
        activeCommits -= 1
    }
}

/// changed事务才开始保护；成功和失败路径均结束，no-op不会失效读取。
final class HistoryCommitLease: @unchecked Sendable {
    private let registry: HistoryJobRegistry
    private let lock = NSLock()
    private var active = false

    init(registry: HistoryJobRegistry) { self.registry = registry }

    func begin() {
        lock.lock(); defer { lock.unlock() }
        guard !active else { return }
        registry.beginCommit()
        active = true
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        registry.endCommit()
        active = false
    }

    deinit { end() }
}

actor HistoryBackgroundStore {
    private let container: ModelContainer

    init(container: ModelContainer) {
        // 初始化可能发生在主线程；Context 必须延迟到 actor 的任务内创建。
        self.container = container
    }

    func save(snapshot: SessionSaveSnapshot, previousChildren: SessionChildSnapshot?,
              registry: HistoryJobRegistry, beforeCommit: @Sendable () throws -> Void) throws -> SessionSaveWorker.Result {
        let lease = HistoryCommitLease(registry: registry)
        defer { lease.end() }
        return try SessionSaveWorker.save(snapshot: snapshot, previousChildren: previousChildren,
            container: container, beforeCommit: { try beforeCommit(); lease.begin() })
    }

    func saveOrphan(sessionID: String, observation: KimiCodeApprovalObservation,
                    registry: HistoryJobRegistry, beforeCommit: @Sendable () throws -> Void) throws {
        let context = makeContext()
        let lease = HistoryCommitLease(registry: registry)
        defer { lease.end() }
        do {
            var query = FetchDescriptor<StoredKimiCodeApprovalOrphan>(predicate: #Predicate { $0.sessionId == sessionID })
            query.fetchLimit = 1
            if let existing = try context.fetch(query).first {
                var merged = try KimiCodeApprovalObservation.decode(existing.observationData)
                merged.merge(observation)
                if merged.baseStatus == .completed || observation.baseStatus == .completed { merged.endSession() }
                existing.observationData = try JSONEncoder().encode(merged)
                existing.updatedAt = Date()
            } else {
                context.insert(StoredKimiCodeApprovalOrphan(sessionId: sessionID,
                    observationData: try JSONEncoder().encode(observation)))
            }
            try beforeCommit()
            lease.begin()
            try context.save()
        } catch { context.rollback(); throw error }
    }

    func page(limit: Int, offset: Int, search: String, matchingAgents: [String],
              token: HistoryJobToken) throws -> HistoryPageSnapshot {
        try token.check()
        guard limit > 0, offset >= 0 else { throw HistoryReadError.invalidPage }
        let context = makeContext()
        var descriptor = FetchDescriptor<StoredSession>(
            sortBy: [SortDescriptor(\.historyDate, order: .reverse), SortDescriptor(\.sessionId, comparator: .lexical)]
        )
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            descriptor.predicate = #Predicate {
                $0.prompt.localizedStandardContains(query)
                    || $0.workingDirectory.localizedStandardContains(query)
                    || matchingAgents.contains($0.agentTypeRaw)
                    || $0.model.localizedStandardContains(query)
                    || $0.sessionId.localizedStandardContains(query)
            }
        }
        let count = try context.fetchCount(FetchDescriptor<StoredSession>(predicate: descriptor.predicate))
        try token.check()
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        let rows = try context.fetch(descriptor).map(HistorySessionRow.init)
        try token.check()
        return HistoryPageSnapshot(sessions: rows, totalCount: count)
    }

    func statistics(timeRange: HistoryStatistics.TimeRange, now: Date, calendar: Calendar,
                    token: HistoryJobToken) throws -> HistoryStatistics {
        try token.check()
        let result = try HistoryStatistics.load(timeRange: timeRange, now: now, calendar: calendar) { visit in
            try forEachBatch(token: token, visit)
        }
        try token.check()
        return result
    }

    func export(to url: URL, token: HistoryJobToken) throws -> Int {
        try HistoryArchiveExporter.export(to: url, forEachBatch: { visit in
            try forEachBatch(token: token, visit)
        }, checkCancellation: token.check, commit: { temporary, destination in
            try token.withCommit {
                try HistoryArchiveExporter.publish(temporary, to: destination)
            }
        })
    }

    func delete(sessionID: String, token: HistoryJobToken) throws -> Bool {
        try token.check()
        let context = makeContext()
        do {
            let sessions = try context.fetch(FetchDescriptor<StoredSession>(predicate: #Predicate { $0.sessionId == sessionID }))
            let orphans = try context.fetch(FetchDescriptor<StoredKimiCodeApprovalOrphan>(predicate: #Predicate { $0.sessionId == sessionID }))
            try token.check()
            guard !sessions.isEmpty || !orphans.isEmpty else { return false }
            for record in sessions { context.delete(record) }
            for record in orphans { context.delete(record) }
            try token.withCommit { try context.save() }
            return true
        } catch {
            context.rollback()
            throw error
        }
    }

    func cleanup(olderThanDays days: Int, token: HistoryJobToken) throws -> Bool {
        try token.check()
        guard days != .max else { return false }
        guard days >= 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else {
            throw CocoaError(.validationNumberTooSmall, userInfo: [NSLocalizedDescriptionKey: "Invalid history retention period."])
        }
        let context = makeContext()
        do {
            var cursor: String?
            var expiredIDs = Set<String>()
            var retainedIDs = Set<String>()
            while true {
                try token.check()
                var descriptor = FetchDescriptor<StoredSession>(sortBy: [SortDescriptor(\.sessionId, comparator: .lexical)])
                if let after = cursor { descriptor.predicate = #Predicate { $0.sessionId > after } }
                descriptor.fetchLimit = 500
                let batch = try context.fetch(descriptor)
                guard let last = batch.last else { break }
                cursor = last.sessionId
                for record in batch {
                    let ended = record.statusRaw == SessionStatus.completed.rawValue
                        || record.statusRaw == SessionStatus.observationUnavailable.rawValue
                    if ended, let endDate = record.completedAt ?? record.observationEndedAt,
                       days == 0 || endDate < cutoff {
                        expiredIDs.insert(record.sessionId)
                        context.delete(record)
                    } else {
                        retainedIDs.insert(record.sessionId)
                    }
                }
            }
            cursor = nil
            var removedOrphan = false
            while true {
                try token.check()
                var descriptor = FetchDescriptor<StoredKimiCodeApprovalOrphan>(sortBy: [SortDescriptor(\.sessionId, comparator: .lexical)])
                if let after = cursor { descriptor.predicate = #Predicate { $0.sessionId > after } }
                descriptor.fetchLimit = 500
                let batch = try context.fetch(descriptor)
                guard let last = batch.last else { break }
                cursor = last.sessionId
                for record in batch {
                    if expiredIDs.contains(record.sessionId)
                        || (!retainedIDs.contains(record.sessionId) && (days == 0 || record.updatedAt < cutoff)) {
                        context.delete(record)
                        removedOrphan = true
                    }
                }
            }
            try token.check()
            guard !expiredIDs.isEmpty || removedOrphan else { return false }
            try token.withCommit { try context.save() }
            return true
        } catch {
            context.rollback()
            throw error
        }
    }

    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func forEachBatch(token: HistoryJobToken, _ visit: ([StoredSession]) throws -> Void) throws {
        let context = makeContext()
        var cursor: String?
        while true {
            try token.check()
            var descriptor = FetchDescriptor<StoredSession>(sortBy: [SortDescriptor(\.sessionId, comparator: .lexical)])
            if let after = cursor { descriptor.predicate = #Predicate { $0.sessionId > after } }
            descriptor.fetchLimit = 500
            let batch = try context.fetch(descriptor)
            guard let last = batch.last else { return }
            cursor = last.sessionId
            try visit(batch)
        }
    }
}
