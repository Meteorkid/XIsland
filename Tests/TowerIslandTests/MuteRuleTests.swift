import XCTest
@testable import XIsland

final class MuteRuleTests: XCTestCase {

    private func makeSession(agentType: AgentType = .claudeCode, workingDir: String = "/tmp") -> AgentSession {
        AgentSession(id: "test", agentType: agentType, terminal: "", workingDirectory: workingDir, prompt: "")
    }

    // MARK: - Basic matching

    func testMatchesAgentTypeByRegex() {
        let rule = MuteRule(pattern: "claude", matchField: .agentType, isEnabled: true)
        let session = makeSession(agentType: .claudeCode)
        XCTAssertTrue(rule.matches(session: session, event: .sessionStart))
    }

    func testMatchesToolByRegex() {
        let rule = MuteRule(pattern: "tool_.*", matchField: .tool, isEnabled: true)
        let session = makeSession()
        XCTAssertTrue(rule.matches(session: session, event: .toolStart))
    }

    func testMatchesWorkingDirByRegex() {
        let rule = MuteRule(pattern: "/Users/.*", matchField: .workingDir, isEnabled: true)
        let session = makeSession(workingDir: "/Users/meteor/project")
        XCTAssertTrue(rule.matches(session: session, event: .sessionEnd))
    }

    func testDoesNotMatchWhenPatternIsWrong() {
        let rule = MuteRule(pattern: "nonexistent_agent", matchField: .agentType, isEnabled: true)
        let session = makeSession(agentType: .claudeCode)
        XCTAssertFalse(rule.matches(session: session, event: .sessionStart))
    }

    // MARK: - Disabled rule

    func testDisabledRuleNeverMatches() {
        let rule = MuteRule(pattern: "claude", matchField: .agentType, isEnabled: false)
        let session = makeSession(agentType: .claudeCode)
        XCTAssertFalse(rule.matches(session: session, event: .sessionStart))
    }

    // MARK: - Empty pattern

    func testEmptyPatternNeverMatches() {
        let rule = MuteRule(pattern: "", matchField: .agentType, isEnabled: true)
        let session = makeSession()
        XCTAssertFalse(rule.matches(session: session, event: .sessionStart))
    }

    // MARK: - Invalid regex

    func testInvalidRegexNeverMatches() {
        let rule = MuteRule(pattern: "[invalid", matchField: .agentType, isEnabled: true)
        let session = makeSession()
        XCTAssertFalse(rule.matches(session: session, event: .sessionStart))
    }

    // MARK: - Case insensitive

    func testCaseInsensitiveMatching() {
        let rule = MuteRule(pattern: "CLAUDE", matchField: .agentType, isEnabled: true)
        let session = makeSession(agentType: .claudeCode)
        XCTAssertTrue(rule.matches(session: session, event: .sessionStart))
    }

    // MARK: - Codable

    func testMuteRuleEncodesAndDecodes() throws {
        let rule = MuteRule(pattern: "test.*", matchField: .tool, isEnabled: true)
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(MuteRule.self, from: data)
        XCTAssertEqual(decoded.pattern, "test.*")
        XCTAssertEqual(decoded.matchField, .tool)
        XCTAssertTrue(decoded.isEnabled)
    }

    // MARK: - MatchField

    func testMatchFieldAllCases() {
        XCTAssertEqual(MatchField.allCases.count, 3)
        XCTAssertTrue(MatchField.allCases.contains(.agentType))
        XCTAssertTrue(MatchField.allCases.contains(.tool))
        XCTAssertTrue(MatchField.allCases.contains(.workingDir))
    }
}
