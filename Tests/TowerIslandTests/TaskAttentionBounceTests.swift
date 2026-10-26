import XCTest
@testable import XIsland

final class TaskAttentionBounceTests: XCTestCase {
    @MainActor
    func testPassiveWaitingStateKeepsSessionSpecificReminderWithoutCreatingAnInteraction() {
        for status in [SessionStatus.waitingPermission, .waitingAnswer, .waitingPlanReview] {
            let session = AgentSession(id: "observed-task", agentType: .codex)
            session.status = status
            let expectedKind = AgentIcon.attentionToken(status: status, completionNeedsReview: false)!
            XCTAssertEqual(AgentIcon(session: session).attentionToken, "observed-observed-task-\(expectedKind)")
            XCTAssertFalse(session.hasPendingInteraction)
            session.status = .active
            XCTAssertNil(AgentIcon(session: session).attentionToken)
        }
    }

    func testOnlyReviewableCompletionAndWaitingStatesHaveAttentionToken() {
        XCTAssertEqual(AgentIcon.attentionToken(status: .completed, completionNeedsReview: true), "completion")
        for status in [SessionStatus.waitingPermission, .waitingAnswer, .waitingPlanReview] {
            XCTAssertNotNil(AgentIcon.attentionToken(status: status, completionNeedsReview: false))
        }
        for status in [SessionStatus.active, .thinking, .idle, .compacting, .error, .observationUnavailable, .completionUnconfirmed] {
            XCTAssertNil(AgentIcon.attentionToken(status: status, completionNeedsReview: true))
        }
        XCTAssertNil(AgentIcon.attentionToken(status: .completed, completionNeedsReview: false))
    }

    func testSingleBurstHasTwoJumpsAndSettlesWithoutResidualTransform() {
        for progress in [0.0, 0.5, 1.0] {
            let pose = TaskAttentionBounceFrame.pose(progress: progress, size: 24)
            XCTAssertEqual(pose.lift, 0, accuracy: 0.0001)
            XCTAssertEqual(pose.rotation, 0, accuracy: 0.0001)
        }
        let first = TaskAttentionBounceFrame.pose(progress: 0.25, size: 24)
        let second = TaskAttentionBounceFrame.pose(progress: 0.75, size: 24)
        XCTAssertLessThan(first.lift, 0)
        XCTAssertLessThan(second.lift, 0)
        XCTAssertLessThan(first.lift, second.lift)
        XCTAssertEqual(TaskAttentionBounceFrame.duration, 1.05)
    }

    func testMotionRemainsSmallAcrossMascotSizes() {
        for size in [CGFloat(20), 24, 32, 64] {
            for step in 0...100 {
                let pose = TaskAttentionBounceFrame.pose(progress: Double(step) / 100, size: size)
                XCTAssertLessThanOrEqual(pose.lift, 0)
                XCTAssertGreaterThanOrEqual(pose.lift, -min(5, size * 0.16))
                XCTAssertLessThanOrEqual(abs(pose.rotation), 5)
            }
        }
    }

    func testInvalidOrFinishedProgressProducesRestPose() {
        for progress in [-1.0, 1, 2, .nan, .infinity] {
            XCTAssertEqual(TaskAttentionBounceFrame.pose(progress: progress, size: 24), .init())
        }
        for size in [CGFloat.zero, -1, .infinity, .nan] {
            XCTAssertEqual(TaskAttentionBounceFrame.pose(progress: 0.25, size: size), .init())
        }
    }
}
