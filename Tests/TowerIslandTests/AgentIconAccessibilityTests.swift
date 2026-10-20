import XCTest
@testable import XIsland

final class AgentIconAccessibilityTests: XCTestCase {
    func testAgentIconLabelNamesAgentAndReadableStatus() {
        let statuses: [SessionStatus] = [.active, .idle, .thinking, .waitingPermission, .waitingAnswer,
            .waitingPlanReview, .completed, .error, .compacting, .observationUnavailable, .completionUnconfirmed]
        for status in statuses {
            let icon = AgentIcon(agentType: .codex, status: status)
            XCTAssertEqual(icon.accessibilityDescription, "\(AgentType.codex.displayName) · \(status.displayName)")
        }
    }
}
