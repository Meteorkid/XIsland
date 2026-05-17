import XCTest
@testable import XIsland

final class AgentSessionTests: XCTestCase {

    private func makeSession(
        agentType: AgentType = .claudeCode,
        workingDir: String = "/Users/meteor/project",
        prompt: String = "Fix the bug"
    ) -> AgentSession {
        AgentSession(id: "test-\(UUID().uuidString)", agentType: agentType, terminal: "ttys001", workingDirectory: workingDir, prompt: prompt)
    }

    // MARK: - workspaceName

    func testWorkspaceNameReturnsLastPathComponent() {
        let session = makeSession(workingDir: "/Users/meteor/my-project")
        XCTAssertEqual(session.workspaceName, "my-project")
    }

    func testWorkspaceNameStripsLeadingDot() {
        let session = makeSession(workingDir: "/Users/meteor/.hidden")
        XCTAssertEqual(session.workspaceName, "hidden")
    }

    func testWorkspaceNameFallsBackToAgentShortNameWhenEmpty() {
        let session = makeSession(workingDir: "", prompt: "test")
        XCTAssertEqual(session.workspaceName, session.agentType.shortName)
    }

    // MARK: - displayTitle

    func testDisplayTitleShowsPromptFirstLine() {
        let session = makeSession(prompt: "Fix the bug\nAnd also clean up")
        XCTAssertEqual(session.displayTitle, "Fix the bug")
    }

    func testDisplayTitleTruncatesLongPrompt() {
        let longPrompt = String(repeating: "a", count: 50)
        let session = makeSession(prompt: longPrompt)
        XCTAssertTrue(session.displayTitle.hasSuffix("..."))
        XCTAssertLessThanOrEqual(session.displayTitle.count, 41)
    }

    func testDisplayTitleFallsBackToWorkspaceNameWhenPromptEmpty() {
        let session = makeSession(workingDir: "/tmp/test-project", prompt: "")
        XCTAssertEqual(session.displayTitle, "test-project")
    }

    // MARK: - hasPromptTitle

    func testHasPromptTitleTrueWhenPromptNonEmpty() {
        let session = makeSession(prompt: "Something")
        XCTAssertTrue(session.hasPromptTitle)
    }

    func testHasPromptTitleFalseWhenPromptEmpty() {
        let session = makeSession(prompt: "")
        XCTAssertFalse(session.hasPromptTitle)
    }

    func testHasPromptTitleFalseWhenPromptWhitespaceOnly() {
        let session = makeSession(prompt: "   \n  ")
        XCTAssertFalse(session.hasPromptTitle)
    }

    // MARK: - formattedDuration

    func testFormattedDurationShowsMinutes() {
        let session = makeSession()
        // Session was just created, duration < 1 min
        XCTAssertEqual(session.formattedDuration, "<1m")
    }

    // MARK: - isSubagent

    func testIsSubagentFalseByDefault() {
        let session = makeSession()
        XCTAssertFalse(session.isSubagent)
    }

    func testIsSubagentTrueWhenParentSet() {
        let session = makeSession()
        session.parentSessionId = "parent-123"
        XCTAssertTrue(session.isSubagent)
    }

    // MARK: - subagentIds

    func testSubagentIdsEmptyByDefault() {
        let session = makeSession()
        XCTAssertTrue(session.subagentIds.isEmpty)
    }

    // MARK: - Status

    func testDefaultStatusIsActive() {
        let session = makeSession()
        XCTAssertEqual(session.status, .active)
    }

    func testStatusColorMapping() {
        XCTAssertEqual(SessionStatus.active.color, "cyan")
        XCTAssertEqual(SessionStatus.completed.color, "gray")
        XCTAssertEqual(SessionStatus.error.color, "red")
        XCTAssertEqual(SessionStatus.thinking.color, "purple")
    }

    // MARK: - TokenUsage

    func testTokenUsageFormattedTokens() {
        var usage = TokenUsage()
        XCTAssertEqual(usage.formattedTokens, "")

        usage.totalTokens = 500
        XCTAssertEqual(usage.formattedTokens, "500")

        usage.totalTokens = 5000
        XCTAssertEqual(usage.formattedTokens, "5.0K")

        usage.totalTokens = 1_500_000
        XCTAssertEqual(usage.formattedTokens, "1.50M")
    }

    func testTokenUsageFormattedCost() {
        var usage = TokenUsage()
        XCTAssertEqual(usage.formattedCost, "")

        usage.estimatedCostUSD = 0.005
        XCTAssertEqual(usage.formattedCost, "<$0.01")

        usage.estimatedCostUSD = 1.23
        XCTAssertEqual(usage.formattedCost, "$1.23")
    }

    // MARK: - lastActivity

    func testLastActivityShowsStatusTextWhenNoEvents() {
        let session = makeSession()
        session.statusText = "Waiting for input"
        XCTAssertEqual(session.lastActivity, "Waiting for input")
    }

    func testLastActivityShowsWorkingWhenEmpty() {
        let session = makeSession()
        session.statusText = ""
        XCTAssertEqual(session.lastActivity, "Working...")
    }
}
