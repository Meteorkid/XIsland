import XCTest
@testable import XIsland

/// A 类测试共用的值类型构造入口，避免各测试文件重复字面量。
enum ASuiteFixtures {
    static let base = Date(timeIntervalSince1970: 1_700_000_000)

    static func summary(id: String = "s1",
                        status: String = "active",
                        interactionId: String? = nil,
                        interactionKind: String? = nil,
                        cwd: String = "/tmp/proj",
                        last: Date = ASuiteFixtures.base,
                        needsReview: Bool = false,
                        isSubagent: Bool = false,
                        completedAt: Date? = nil,
                        detail: String = "run tests") -> IslandSessionSummary {
        IslandSessionSummary(
            id: id, status: status, title: "Proj", detail: detail,
            workingDirectory: cwd, isSubagent: isSubagent,
            lastActivityAt: last, completedAt: completedAt,
            needsReview: needsReview,
            interactionId: interactionId, interactionKind: interactionKind)
    }

    static func event(kind: IslandEventKind = .completed,
                      sessionId: String = "s1",
                      requestId: String? = nil,
                      cwd: String = "/tmp/proj",
                      isSubagent: Bool = false,
                      detail: String = "done") -> IslandEvent {
        IslandEvent(kind: kind, sessionId: sessionId, requestId: requestId,
                    stableToken: "t1", title: "Proj", detail: detail,
                    workingDirectory: cwd, isSubagent: isSubagent,
                    occurredAt: base)
    }
}
