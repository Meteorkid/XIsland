import Foundation
import SwiftData

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
    var linesRead: Int?
    var testPassed: Int
    var testFailed: Int
    var testSkipped: Int

    var session: StoredSession?

    init(from event: ToolEvent) {
        self.eventId = event.id
        self.tool = event.tool
        self.input = event.input
        self.result = event.result
        self.timestamp = event.timestamp
        self.linesAdded = event.linesAdded
        self.linesRemoved = event.linesRemoved
        self.isComplete = event.isComplete
        self.linesRead = event.linesRead
        self.testPassed = event.testResults?.passed ?? 0
        self.testFailed = event.testResults?.failed ?? 0
        self.testSkipped = event.testResults?.skipped ?? 0
    }

    func update(from event: ToolEvent) {
        eventId = event.id
        tool = event.tool
        input = event.input
        result = event.result
        timestamp = event.timestamp
        linesAdded = event.linesAdded
        linesRemoved = event.linesRemoved
        isComplete = event.isComplete
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
        testSkipped: Int = 0
    ) {
        self.tool = tool
        self.input = input
        self.result = result
        self.timestamp = timestamp
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.isComplete = isComplete
        self.linesRead = linesRead
        self.testPassed = testPassed
        self.testFailed = testFailed
        self.testSkipped = testSkipped
    }
}
