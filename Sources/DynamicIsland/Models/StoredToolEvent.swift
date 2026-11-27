import Foundation
import SwiftData

/// 工具输入/结果入库前的硬上限。
///
/// 工具输出可能是整段构建日志、图片 base64 或数 MB 的 JSON；这些内容只需要在历史里
/// 作为预览出现。完整结果仍保留在内存中的活动会话里，超出部分不会写进 SwiftData。
enum ToolEventPersistencePolicy {
    static let maxInputUTF8Bytes = 8 * 1024
    static let maxResultUTF8Bytes = 32 * 1024

    static func storedInput(_ value: String?) -> String? {
        truncated(value, limit: maxInputUTF8Bytes)
    }

    static func storedResult(_ value: String?) -> String? {
        truncated(value, limit: maxResultUTF8Bytes)
    }

    private static func truncated(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let bytes = value.utf8.count
        guard bytes > limit else { return value }
        let prefix = String(decoding: value.utf8.prefix(limit), as: UTF8.self)
        return "\(prefix)\n…[truncated; original \(bytes) bytes]"
    }
}

@Model
final class StoredToolEvent {
    // 可选字段让旧历史库兼容升级；旧记录在存储初始化时补齐一次。
    var eventId: UUID? = nil
    var tool: String
    var input: String?
    var result: String?
    var timestamp: Date
    var linesAdded: Int?
    var linesRemoved: Int?
    var isComplete: Bool
    // 默认值用于旧历史库新增字段的轻量迁移。
    var completionUnconfirmed: Bool = false
    var nativeCompletionStatus: String? = nil
    var toolCallId: String?
    var linesRead: Int?
    var testPassed: Int
    var testFailed: Int
    var testSkipped: Int

    var session: StoredSession?

    init(from event: ToolEvent) {
        self.eventId = event.id
        self.tool = event.tool
        self.input = ToolEventPersistencePolicy.storedInput(event.input)
        self.result = ToolEventPersistencePolicy.storedResult(event.result)
        self.timestamp = event.timestamp
        self.linesAdded = event.linesAdded
        self.linesRemoved = event.linesRemoved
        self.isComplete = event.isComplete
        self.completionUnconfirmed = event.completionUnconfirmed
        self.nativeCompletionStatus = event.nativeCompletionStatus
        self.toolCallId = event.toolCallId
        self.linesRead = event.linesRead
        self.testPassed = event.testResults?.passed ?? 0
        self.testFailed = event.testResults?.failed ?? 0
        self.testSkipped = event.testResults?.skipped ?? 0
    }

    func update(from event: ToolEvent) {
        eventId = event.id
        tool = event.tool
        input = ToolEventPersistencePolicy.storedInput(event.input)
        result = ToolEventPersistencePolicy.storedResult(event.result)
        timestamp = event.timestamp
        linesAdded = event.linesAdded
        linesRemoved = event.linesRemoved
        isComplete = event.isComplete
        completionUnconfirmed = event.completionUnconfirmed
        nativeCompletionStatus = event.nativeCompletionStatus
        toolCallId = event.toolCallId
        linesRead = event.linesRead
        testPassed = event.testResults?.passed ?? 0
        testFailed = event.testResults?.failed ?? 0
        testSkipped = event.testResults?.skipped ?? 0
    }

    /// Internal initializer for SwiftData (all stored properties).
    init(
        tool: String,
        input: String? = nil,
        result: String? = nil,
        timestamp: Date = Date(),
        linesAdded: Int? = nil,
        linesRemoved: Int? = nil,
        isComplete: Bool = false,
        linesRead: Int? = nil,
        testPassed: Int = 0,
        testFailed: Int = 0,
        testSkipped: Int = 0,
        completionUnconfirmed: Bool = false,
        toolCallId: String? = nil,
        nativeCompletionStatus: String? = nil
    ) {
        self.tool = tool
        self.input = input
        self.result = result
        self.timestamp = timestamp
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.isComplete = isComplete
        self.completionUnconfirmed = completionUnconfirmed
        self.nativeCompletionStatus = nativeCompletionStatus
        self.toolCallId = toolCallId
        self.linesRead = linesRead
        self.testPassed = testPassed
        self.testFailed = testFailed
        self.testSkipped = testSkipped
    }
}
