import Foundation
import Darwin

/// 全历史 JSON 导出；只保存已持久化事实，不包含任何可执行审批能力。
enum HistoryArchiveExporter {
    @MainActor
    static func export(from manager: SessionPersistenceManager, to url: URL) throws -> Int {
        try export(to: url, forEachBatch: { visit in
            try manager.forEachHistoryBatch(batchSize: 500, visit)
        })
    }

    // 批次与写入注入用于验证中途读取、编码或磁盘失败时不会发布半成品。
    static func export(
        to url: URL,
        forEachBatch: (_ visit: ([StoredSession]) throws -> Void) throws -> Void,
        write: @escaping (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) },
        checkCancellation: @escaping () throws -> Void = { try Task.checkCancellation() },
        commit: (URL, URL) throws -> Void = { try publish($0, to: $1) }
    ) throws -> Int {
        try checkCancellation()
        guard url.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        let destination = url.standardizedFileURL
        let originalState = try destinationState(at: destination)
        let temporaryURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".xisland-history-\(UUID().uuidString).tmp")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError(at: temporaryURL) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var isOpen = true
        defer {
            if isOpen { try? handle.close() }
            // rename 成功后该路径已不存在；失败时只清理本次临时文件。
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        var header = try encoder.encode(Header(exportedAt: Date()))
        header.removeLast()
        try write(handle, header)
        try write(handle, Data(",\"sessions\":[".utf8))
        var count = 0
        try forEachBatch { sessions in
            try checkCancellation()
            for session in sessions {
                try checkCancellation()
                let data = try encoder.encode(SessionRecord(session))
                if count > 0 { try write(handle, Data(",".utf8)) }
                try write(handle, data)
                count += 1
            }
        }
        try checkCancellation()
        try write(handle, Data("],\"sessionCount\":\(count)}\n".utf8))
        try handle.synchronize()
        try handle.close()
        isOpen = false

        // 不覆盖导出期间被换成目录、链接、只读文件或其他文件的目标。
        guard try destinationState(at: destination) == originalState else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        try checkCancellation()
        try commit(temporaryURL, destination)
        return count
    }

    static func publish(_ temporaryURL: URL, to destination: URL) throws {
        guard rename(temporaryURL.path, destination.path) == 0 else {
            throw posixError(at: destination)
        }
    }

    private struct DestinationState: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    private static func destinationState(at url: URL) throws -> DestinationState? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError(at: url)
        }
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (metadata.st_mode & 0o222) != 0,
              FileManager.default.isWritableFile(atPath: url.path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        return DestinationState(
            device: metadata.st_dev,
            inode: metadata.st_ino,
            size: metadata.st_size,
            modifiedSeconds: metadata.st_mtimespec.tv_sec,
            modifiedNanoseconds: metadata.st_mtimespec.tv_nsec
        )
    }

    private static func posixError(at url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }

    private struct Header: Encodable {
        let format = "xisland.history"
        let schemaVersion = 1
        let dateEncoding = "secondsSince1970"
        let binaryEncoding = "base64"
        let exportedAt: Date
    }
}

private struct SessionRecord: Encodable {
    /// 显式保留 null，避免把升级前未知的查看状态转换为 false。
    struct CompletionReviewValue: Encodable {
        let value: Bool?

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }

    let sessionId: String
    let agentTypeRaw: String
    let startTime: Date
    let completedAt: Date?
    let completionNeedsReview: CompletionReviewValue
    let sourceNamespace: String?
    let sourceInstanceId: String?
    let nativeTaskId: String?
    let observationEndedAt: Date?
    let kimiCodeApprovalObservationData: Data?
    let historyDate: Date?
    let prompt: String
    let workingDirectory: String
    let terminal: String
    let statusRaw: String
    let recapText: String?
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let estimatedCostUSD: Double
    let model: String
    let toolEvents: [ToolRecord]
    let chatMessages: [ChatRecord]

    init(_ session: StoredSession) {
        sessionId = session.sessionId
        agentTypeRaw = session.agentTypeRaw
        startTime = session.startTime
        completedAt = session.completedAt
        completionNeedsReview = CompletionReviewValue(value: session.completionNeedsReview)
        sourceNamespace = session.sourceNamespace
        sourceInstanceId = session.sourceInstanceId
        nativeTaskId = session.nativeTaskId
        observationEndedAt = session.observationEndedAt
        kimiCodeApprovalObservationData = session.kimiCodeApprovalObservationData
        historyDate = session.historyDate
        prompt = session.prompt
        workingDirectory = session.workingDirectory
        terminal = session.terminal
        statusRaw = session.statusRaw
        recapText = session.recapText
        inputTokens = session.inputTokens
        outputTokens = session.outputTokens
        totalTokens = session.totalTokens
        estimatedCostUSD = session.estimatedCostUSD
        model = session.model
        toolEvents = session.toolEvents.map(ToolRecord.init)
        chatMessages = session.chatMessages.map(ChatRecord.init)
    }
}

private struct ToolRecord: Encodable {
    let eventId: UUID?
    let tool: String
    let input: String?
    let result: String?
    let timestamp: Date
    let linesAdded: Int?
    let linesRemoved: Int?
    let isComplete: Bool
    let completionUnconfirmed: Bool
    let nativeCompletionStatus: String?
    let toolCallId: String?
    let linesRead: Int?
    let testPassed: Int
    let testFailed: Int
    let testSkipped: Int

    init(_ event: StoredToolEvent) {
        eventId = event.eventId
        tool = event.tool
        input = event.input
        result = event.result
        timestamp = event.timestamp
        linesAdded = event.linesAdded
        linesRemoved = event.linesRemoved
        isComplete = event.isComplete
        completionUnconfirmed = event.completionUnconfirmed
        nativeCompletionStatus = event.nativeCompletionStatus
        toolCallId = event.toolCallId
        linesRead = event.linesRead
        testPassed = event.testPassed
        testFailed = event.testFailed
        testSkipped = event.testSkipped
    }
}

private struct ChatRecord: Encodable {
    let messageId: UUID?
    let timestamp: Date
    let role: String
    let content: String

    init(_ message: StoredChatMessage) {
        messageId = message.messageId
        timestamp = message.timestamp
        role = message.role
        content = message.content
    }
}
