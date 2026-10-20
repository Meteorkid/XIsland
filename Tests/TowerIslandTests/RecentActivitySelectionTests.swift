import XCTest
@testable import XIsland

final class RecentActivitySelectionTests: XCTestCase {
    @MainActor
    func testRepeatedRenderingReusesSelectionUntilAnEventChanges() {
        let manager = SessionManager()
        let session = AgentSession(id: "activity", agentType: .codex)
        session.events = [ToolEvent(tool: "Read")]
        manager.sessions = [session]
        XCTAssertEqual(manager.recentActivityEvents.count, 1)
        for _ in 0..<100 { _ = manager.recentActivityEvents }
        XCTAssertEqual(manager.activitySelectionCount, 1)
        session.updateEvent(at: 0) { $0.result = "updated" }
        XCTAssertEqual(manager.recentActivityEvents[0].event.result, "updated")
        XCTAssertEqual(manager.activitySelectionCount, 2)
        manager.sessions = []
        XCTAssertTrue(manager.recentActivityEvents.isEmpty)
        XCTAssertEqual(manager.activitySelectionCount, 3)
    }
    private func event(_ index: Int, timestamp: Int) -> ToolEvent {
        ToolEvent(tool: "Read", input: "file-\(index)", result: "result-\(index)",
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
            timestamp: Date(timeIntervalSince1970: Double(timestamp)))
    }

    private func session(_ id: String, events: [ToolEvent]) -> AgentSession {
        let session = AgentSession(id: id, agentType: .claudeCode)
        session.events = events
        return session
    }

    private func identities(_ rows: [(session: AgentSession, event: ToolEvent)]) -> [String] {
        rows.map { "\($0.session.id)/\($0.event.id.uuidString)" }
    }

    private func fullSort(_ sessions: [AgentSession], limit: Int) -> [(session: AgentSession, event: ToolEvent)] {
        let rows = sessions.flatMap { session in session.events.map { (session: session, event: $0) } }
        return rows.enumerated().sorted { left, right in
            let lhs = left.element, rhs = right.element
            if lhs.event.timestamp != rhs.event.timestamp { return lhs.event.timestamp > rhs.event.timestamp }
            if lhs.session.id != rhs.session.id { return lhs.session.id < rhs.session.id }
            if lhs.event.id != rhs.event.id { return lhs.event.id.uuidString < rhs.event.id.uuidString }
            return left.offset < right.offset
        }.prefix(min(max(limit, 0), 30)).map(\.element)
    }

    func testEmptyAndNonpositiveLimitsReturnNoCandidates() {
        XCTAssertTrue(RecentActivitySelection.latest(in: []).isEmpty)
        let sessions = [session("empty", events: []), session("one", events: [event(1, timestamp: 1)])]
        XCTAssertTrue(RecentActivitySelection.latest(in: sessions, limit: 0).isEmpty)
        XCTAssertTrue(RecentActivitySelection.latest(in: sessions, limit: -1).isEmpty)
    }

    func testMultipleUnorderedSessionsMatchFullSortForEachSupportedLimit() {
        let sessions = [session("z", events: [event(1, timestamp: 5), event(2, timestamp: 300), event(3, timestamp: 1)]),
            session("a", events: [event(4, timestamp: 99), event(5, timestamp: 300), event(6, timestamp: 2)]),
            session("empty", events: [])]
        for limit in [1, 3, 6, 30, 100] {
            let selected = RecentActivitySelection.latest(in: sessions, limit: limit)
            XCTAssertEqual(identities(selected), identities(fullSort(sessions, limit: limit)))
            for item in selected { XCTAssertTrue(sessions.contains { $0 === item.session }) }
        }
    }

    func testNewestOutOfOrderEventsBeforeLastThirtyAreStillSelected() {
        let events = (0..<200).map { event($0, timestamp: $0 < 30 ? 10_000 + $0 : $0) }
        let source = session("late-arrival", events: events)
        let selected = RecentActivitySelection.latest(in: [source])
        XCTAssertEqual(selected.count, 30)
        XCTAssertEqual(selected.map(\.event.id), Array(events.prefix(30).reversed()).map(\.id))
        XCTAssertEqual(source.events, events)
    }

    func testTimestampTiesHaveStableSessionAndEventOrderingIndependentOfInputOrder() {
        let first = session("b", events: (0..<40).reversed().map { event($0, timestamp: 100) })
        let second = session("a", events: (40..<80).reversed().map { event($0, timestamp: 100) })
        let expected = identities(fullSort([first, second], limit: 30))
        XCTAssertEqual(identities(RecentActivitySelection.latest(in: [first, second])), expected)
        first.events.reverse(); second.events.reverse()
        XCTAssertEqual(identities(RecentActivitySelection.latest(in: [second, first])), expected)
    }

    func testDuplicateIdentitiesUseOriginalOrderAsFinalTieBreaker() {
        var first = event(1, timestamp: 1), second = first
        first.result = "first"; second.result = "second"
        let selected = RecentActivitySelection.latest(in: [session("same", events: [first, second])], limit: 1)
        XCTAssertEqual(selected.first?.event.result, "first")
    }

    func testFiftyThousandEventsMatchCompleteSortWithoutMutatingHistory() {
        let sessions = (0..<10).map { group in
            session("session-\(group)", events: (0..<5000).map { offset in
                let index = group * 5000 + offset
                return event(index, timestamp: (index * 7919) % 50_021)
            })
        }
        let original = sessions.map(\.events)
        let selected = RecentActivitySelection.latest(in: sessions, limit: Int.max)
        XCTAssertEqual(selected.count, 30)
        XCTAssertEqual(identities(selected), identities(fullSort(sessions, limit: 30)))
        XCTAssertEqual(sessions.map(\.events), original)
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.events.count }, 50_000)
    }
}
