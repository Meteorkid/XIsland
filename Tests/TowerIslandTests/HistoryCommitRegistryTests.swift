import Foundation
import XCTest
@testable import XIsland

final class HistoryCommitRegistryTests: XCTestCase {
    func testReadsRegisteredDuringCommitAreInvalidAndDoNotRevive() throws {
        let registry = HistoryJobRegistry(), lease = HistoryCommitLease(registry: HistoryJobRegistry())
        lease.end() // 未开始的no-op保护可安全结束。
        let before = HistoryJobToken(), during = HistoryJobToken(), after = HistoryJobToken()
        registry.insert(before, id: UUID(), destructive: false)
        registry.beginCommit()
        registry.insert(during, id: UUID(), destructive: false)
        XCTAssertThrowsError(try before.check())
        XCTAssertThrowsError(try during.check())
        XCTAssertThrowsError(try during.withCommit { XCTFail("跨事务读取不得发布导出") })
        registry.endCommit()
        XCTAssertThrowsError(try during.check())
        registry.insert(after, id: UUID(), destructive: false)
        XCTAssertNoThrow(try after.check())
    }

    func testNestedCommitsKeepProtectionUntilBothEnd() throws {
        let registry = HistoryJobRegistry()
        registry.beginCommit(); registry.beginCommit(); registry.endCommit()
        let pending = HistoryJobToken()
        registry.insert(pending, id: UUID(), destructive: false)
        XCTAssertThrowsError(try pending.check())
        registry.endCommit()
        let fresh = HistoryJobToken()
        registry.insert(fresh, id: UUID(), destructive: false)
        XCTAssertNoThrow(try fresh.check())
    }

    func testSerializedFailedCommitReleasesRegistrationProtection() throws {
        let registry = HistoryJobRegistry()
        let writer = HistoryJobToken(serializedCommit: true, commitRegistry: registry)
        XCTAssertThrowsError(try writer.withCommit {
            let reading = HistoryJobToken()
            registry.insert(reading, id: UUID(), destructive: false)
            XCTAssertThrowsError(try reading.check())
            throw CocoaError(.fileWriteNoPermission)
        })
        let next = HistoryJobToken()
        registry.insert(next, id: UUID(), destructive: false)
        XCTAssertNoThrow(try next.check())
    }
}
