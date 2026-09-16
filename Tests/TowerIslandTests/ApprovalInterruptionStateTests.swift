import XCTest
@testable import XIsland

final class ApprovalInterruptionStateTests: XCTestCase {
    func testConcurrentApprovalsRestoreOnlyAfterTheLastRequest() {
        var state = ApprovalInterruptionState()
        state.markInterrupted()
        state.markInterrupted()

        XCTAssertFalse(state.takeRestorationIfReady(hasPendingInteractions: true))
        XCTAssertTrue(state.takeRestorationIfReady(hasPendingInteractions: false))
        XCTAssertFalse(state.takeRestorationIfReady(hasPendingInteractions: false))

        state.markInterrupted()
        XCTAssertTrue(state.takeRestorationIfReady(hasPendingInteractions: false))
    }

    func testCancellingTheFinalRequestDoesNotRestoreOnALaterUnrelatedCompletion() {
        var state = ApprovalInterruptionState()
        state.markInterrupted()
        state.cancelIfFinished(hasPendingInteractions: false)

        XCTAssertFalse(state.takeRestorationIfReady(hasPendingInteractions: false))
        state.markInterrupted()
        XCTAssertTrue(state.takeRestorationIfReady(hasPendingInteractions: false))
    }

    func testCancellingOneRequestPreservesRestorationForOtherPendingRequests() {
        var state = ApprovalInterruptionState()
        state.markInterrupted()
        state.markInterrupted()
        state.cancelIfFinished(hasPendingInteractions: true)

        XCTAssertFalse(state.takeRestorationIfReady(hasPendingInteractions: true))
        XCTAssertTrue(state.takeRestorationIfReady(hasPendingInteractions: false))
    }

    func testUninterruptedSessionNeverRequestsRestoration() {
        var state = ApprovalInterruptionState()
        XCTAssertFalse(state.takeRestorationIfReady(hasPendingInteractions: false))
    }
}
