import DIShared
import XCTest
@testable import XIsland

@MainActor
final class AppUpdateTerminationTests: XCTestCase {
    override func setUpWithError() throws {
        XCTAssertTrue(AppPreferences.isIsolated, "退出测试必须使用隔离偏好")
    }

    func testUpdatePreparationRejectsOrdinaryQuitUntilHelperCommits() async throws {
        let entered = expectation(description: "保存进入后台事务")
        let gate = UpdateCommitGate(entered: entered)
        defer { gate.release() }
        let delegate = makeDelegate(beforeCommit: { try gate.wait() })
        delegate.sessionManager.handleMessage(message(.sessionStart))
        let preparation = Task { await delegate.prepareForUpdateTermination() }
        await fulfillment(of: [entered], timeout: 5)

        XCTAssertEqual(delegate.requestTermination { _ in XCTFail("更新准备期间不能确认普通退出") }, .terminateCancel)
        XCTAssertFalse(delegate.commitUpdateTermination())
        let duplicatePrepared = await delegate.prepareForUpdateTermination()
        XCTAssertFalse(duplicatePrepared)
        gate.release()
        let prepared = await preparation.value
        XCTAssertTrue(prepared)
        XCTAssertEqual(delegate.requestTermination { _ in XCTFail("helper 尚未启动") }, .terminateCancel)

        let handled = delegate.sessionManager.handledMessageCount
        delegate.sessionManager.handleMessage(message(.progress))
        let saved = await delegate.sessionManager.drainPersistenceOperations()
        XCTAssertTrue(saved)
        XCTAssertEqual(delegate.sessionManager.handledMessageCount, handled)
        XCTAssertTrue(delegate.commitUpdateTermination())
        delegate.cancelUpdateTermination()
        XCTAssertEqual(delegate.requestTermination { _ in XCTFail("提交后无需再次排空") }, .terminateNow)
        delegate.sessionManager.handleMessage(message(.progress))
        XCTAssertEqual(delegate.sessionManager.handledMessageCount, handled)
    }

    func testFailedUpdatePreparationRetainsHistoryAndResumesReception() async throws {
        let delegate = makeDelegate(beforeCommit: { throw CocoaError(.fileWriteNoPermission) })
        delegate.sessionManager.handleMessage(message(.sessionStart))

        let prepared = await delegate.prepareForUpdateTermination()
        XCTAssertFalse(prepared)
        XCTAssertEqual(delegate.sessionManager.unsavedSessionIDs, ["update-termination"])
        XCTAssertFalse(delegate.commitUpdateTermination())
        let handled = delegate.sessionManager.handledMessageCount
        delegate.sessionManager.handleMessage(message(.progress))
        _ = await delegate.sessionManager.drainPersistenceOperations()
        XCTAssertEqual(delegate.sessionManager.handledMessageCount, handled + 1)
    }

    func testCancelledHelperPreparationResumesReception() async throws {
        let delegate = makeDelegate()
        let prepared = await delegate.prepareForUpdateTermination()
        XCTAssertTrue(prepared)
        delegate.cancelUpdateTermination()
        XCTAssertFalse(delegate.commitUpdateTermination())
        delegate.sessionManager.handleMessage(message(.sessionStart))
        let saved = await delegate.sessionManager.drainPersistenceOperations()
        XCTAssertTrue(saved)
        XCTAssertEqual(delegate.sessionManager.handledMessageCount, 1)
    }

    func testOrdinaryQuitAlreadyDrainingRejectsUpdatePreparation() async throws {
        let entered = expectation(description: "普通退出等待保存")
        let replied = expectation(description: "普通退出收到真实保存结果")
        let gate = UpdateCommitGate(entered: entered)
        defer { gate.release() }
        let delegate = makeDelegate(beforeCommit: { try gate.wait() })
        delegate.sessionManager.handleMessage(message(.sessionStart))
        XCTAssertEqual(delegate.requestTermination { saved in
            XCTAssertTrue(saved)
            replied.fulfill()
        }, .terminateLater)
        await fulfillment(of: [entered], timeout: 5)
        let prepared = await delegate.prepareForUpdateTermination()
        XCTAssertFalse(prepared)
        delegate.cancelUpdateTermination()
        delegate.sessionManager.handleMessage(message(.progress))
        gate.release()
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(delegate.sessionManager.handledMessageCount, 1)
    }

    func testCancelledPreparationStillDrainsAcceptedWriteAndResumesReception() async throws {
        let entered = expectation(description: "取消之前开始保存")
        let gate = UpdateCommitGate(entered: entered)
        defer { gate.release() }
        let delegate = makeDelegate(beforeCommit: { try gate.wait() })
        delegate.sessionManager.handleMessage(message(.sessionStart))
        let preparation = Task { await delegate.prepareForUpdateTermination() }
        await fulfillment(of: [entered], timeout: 5)
        preparation.cancel()
        gate.release()
        let prepared = await preparation.value
        XCTAssertFalse(prepared)
        XCTAssertFalse(delegate.commitUpdateTermination())
        delegate.sessionManager.handleMessage(message(.progress))
        let saved = await delegate.sessionManager.drainPersistenceOperations()
        XCTAssertTrue(saved)
        XCTAssertEqual(delegate.sessionManager.handledMessageCount, 2)
    }

    private func makeDelegate(beforeCommit: @escaping @Sendable () throws -> Void = {}) -> AppDelegate {
        let delegate = AppDelegate(testConfiguration: AppTestConfiguration.make(arguments: ["--ui-test-mode"], environment: [:]))
        let persistence = SessionPersistenceManager(usesBackgroundWrites: true, beforeBackgroundCommit: beforeCommit)
        XCTAssertTrue(persistence.setupContainer(isStoredInMemoryOnly: true))
        delegate.sessionManager.persistenceManager = persistence
        return delegate
    }

    private func message(_ type: DIMessageType) -> DIMessage {
        var value = DIMessage(type: type, sessionId: "update-termination")
        value.agentType = "claude_code"
        value.statusIsAssistantReply = false
        return value
    }
}

private final class UpdateCommitGate: @unchecked Sendable {
    private let entered: XCTestExpectation
    private let released = DispatchSemaphore(value: 0)

    init(entered: XCTestExpectation) { self.entered = entered }

    func wait() throws {
        entered.fulfill()
        guard released.wait(timeout: .now() + 5) == .success else { throw CocoaError(.userCancelled) }
    }

    func release() { released.signal() }
}
