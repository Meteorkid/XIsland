import XCTest
@testable import XIsland

@MainActor
final class SessionFilterTests: XCTestCase {

    // MARK: - Helpers

    private func makeSession(
        id: String = UUID().uuidString,
        agentType: AgentType = .claudeCode,
        status: SessionStatus = .active,
        prompt: String = "",
        workingDir: String = "/Users/test/project"
    ) -> AgentSession {
        let session = AgentSession(
            id: id,
            agentType: agentType,
            terminal: "ttys001",
            workingDirectory: workingDir,
            prompt: prompt
        )
        session.status = status
        return session
    }

    private func makeSessionAt(
        id: String = UUID().uuidString,
        agentType: AgentType = .claudeCode,
        prompt: String = "",
        daysAgo: Int
    ) -> AgentSession {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let session = AgentSession(
            id: id,
            agentType: agentType,
            terminal: "ttys001",
            workingDirectory: "/Users/test/project",
            prompt: prompt,
            startTime: date
        )
        session.status = .active
        return session
    }

    private func makeSessionManager(sessions: [AgentSession]) -> SessionManager {
        let sm = SessionManager()
        sm.sessions = sessions
        return sm
    }

    // MARK: - Filter by AgentType

    func testFilterByAgentType() {
        let claudeSession = makeSession(agentType: .claudeCode, prompt: "Fix bug")
        let cursorSession = makeSession(agentType: .cursor, prompt: "Refactor code")
        let sm = makeSessionManager(sessions: [claudeSession, cursorSession])

        sm.activeFilter = .agentType(.claudeCode)

        let filtered = sm.filteredSessions
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.agentType, .claudeCode)
    }

    // MARK: - Filter by Status

    func testFilterByStatus() {
        let activeSession = makeSession(status: .active, prompt: "Working")
        let completedSession = makeSession(status: .completed, prompt: "Done")
        completedSession.completedAt = Date()
        let sm = makeSessionManager(sessions: [activeSession, completedSession])

        sm.activeFilter = .status(.active)

        let filtered = sm.filteredSessions
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.status, .active)
    }

    // MARK: - Filter by Text

    func testFilterByText() {
        let session1 = makeSession(prompt: "Fix the login bug")
        let session2 = makeSession(prompt: "Refactor the database layer")
        let session3 = makeSession(prompt: "Add tests", workingDir: "/Users/test/bug-tracker")
        let sm = makeSessionManager(sessions: [session1, session2, session3])

        sm.activeFilter = SessionFilter.text("bug")

        let filtered = sm.filteredSessions
        XCTAssertEqual(filtered.count, 2, "Should match prompt containing 'bug' and workspace containing 'bug'")
    }

    // MARK: - Group by AgentType

    func testGroupByAgentType() {
        let claude1 = makeSession(agentType: .claudeCode, prompt: "A")
        let claude2 = makeSession(agentType: .claudeCode, prompt: "B")
        let cursor = makeSession(agentType: .cursor, prompt: "C")
        let sm = makeSessionManager(sessions: [claude1, claude2, cursor])

        sm.grouping = .agentType

        let groups = sm.groupedSessions
        XCTAssertEqual(groups.count, 2)

        let claudeGroup = groups.first { $0.id == AgentType.claudeCode.rawValue }
        XCTAssertEqual(claudeGroup?.sessions.count, 2)

        let cursorGroup = groups.first { $0.id == AgentType.cursor.rawValue }
        XCTAssertEqual(cursorGroup?.sessions.count, 1)
    }

    // MARK: - Group by Date

    func testGroupByDate() {
        let todaySession = makeSessionAt(prompt: "Today work", daysAgo: 0)
        let yesterdaySession = makeSessionAt(prompt: "Yesterday work", daysAgo: 1)
        let lastWeekSession = makeSessionAt(prompt: "Last week", daysAgo: 10)

        let sm = makeSessionManager(sessions: [todaySession, yesterdaySession, lastWeekSession])
        sm.grouping = .date

        let groups = sm.groupedSessions
        XCTAssertEqual(groups.count, 3, "Should have today, yesterday, and older groups")

        let todayGroup = groups.first { $0.id == "today" }
        XCTAssertEqual(todayGroup?.sessions.count, 1)

        let yesterdayGroup = groups.first { $0.id == "yesterday" }
        XCTAssertEqual(yesterdayGroup?.sessions.count, 1)

        let olderGroup = groups.first { $0.id == "older" }
        XCTAssertEqual(olderGroup?.sessions.count, 1)
    }

    // MARK: - Group None returns single group

    func testGroupNoneReturnsSingleGroup() {
        let s1 = makeSession(prompt: "A")
        let s2 = makeSession(prompt: "B")
        let sm = makeSessionManager(sessions: [s1, s2])

        sm.grouping = .none

        let groups = sm.groupedSessions
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.sessions.count, 2)
    }

    // MARK: - Search text combines with filter

    func testSearchTextCombinesWithFilter() {
        let claudeBug = makeSession(agentType: .claudeCode, prompt: "Fix the login bug")
        let claudeFeature = makeSession(agentType: .claudeCode, prompt: "Add new feature")
        let cursorBug = makeSession(agentType: .cursor, prompt: "Fix the crash bug")
        let sm = makeSessionManager(sessions: [claudeBug, claudeFeature, cursorBug])

        sm.activeFilter = .agentType(.claudeCode)
        sm.searchText = "bug"

        let filtered = sm.filteredSessions
        XCTAssertEqual(filtered.count, 1, "Should match only Claude session with 'bug' in prompt")
        XCTAssertEqual(filtered.first?.id, claudeBug.id)
    }
}
