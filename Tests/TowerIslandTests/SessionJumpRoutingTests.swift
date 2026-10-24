import XCTest
@testable import XIsland

@MainActor
final class SessionJumpRoutingTests: XCTestCase {
    private let thread = "11111111-2222-4333-8444-555555555555"

    private func snapshot(_ id: String, agent: AgentType = .codex, terminal: String = "",
                          locator: String? = nil) -> TerminalJumpManager.SessionSnapshot {
        .init(id: id, agentType: agent, terminal: terminal, workingDirectory: "/tmp/same-project",
              termSessionId: locator, windowNumber: 123)
    }

    func testCodexUsesConversationIDRatherThanSharedDirectoryOrCapturedWindow() {
        let first = TerminalJumpManager.plan(for: snapshot("codex-" + thread))
        XCTAssertEqual(first, .conversation(.codex, URL(string: "codex://threads/" + thread)!))
        let second = TerminalJumpManager.plan(for: snapshot("codex-AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))
        XCTAssertNotEqual(first, second)
    }

    func testCodexRejectsFallbackHashesAndMalformedConversationIDs() {
        for id in ["codex-deadbeef", "codex-" + thread + "-child", "codex-" + thread + "?hostId=elsewhere", "codex-\n", thread] {
            XCTAssertEqual(TerminalJumpManager.plan(for: snapshot(id)), .failure(.missingIdentity), id)
        }
    }

    func testCLIHostsWinOverDesktopAgentIdentity() {
        for agent in [AgentType.codex, .cursor, .windsurf] {
            XCTAssertEqual(TerminalJumpManager.plan(for: snapshot("codex-" + thread, agent: agent,
                terminal: "iTerm2", locator: "iterm:w0t0p0:" + thread)), .terminal(.iTerm(id: "iterm:w0t0p0:" + thread)))
        }
        XCTAssertEqual(TerminalJumpManager.plan(for: snapshot("codex-" + thread,
            terminal: "Terminal", locator: "tty:/dev/ttys013")), .terminal(.appleTerminalTTY("tty:/dev/ttys013")))
        XCTAssertEqual(TerminalJumpManager.plan(for: snapshot("codex-" + thread,
            terminal: "Terminal", locator: "ts:" + thread)), .failure(.missingIdentity))
        XCTAssertEqual(TerminalJumpManager.plan(for: snapshot("codex-" + thread,
            terminal: "unknown-client")), .failure(.unavailable))
    }

    func testWorkBuddyDecodesNativeIDAndEscapesOnePathSegment() {
        let native = "chat/空间?tab=1#hello+world"
        let id = "workbuddy-" + Data(native.utf8).base64EncodedString()
        guard case .conversation(.workBuddy, let url) = TerminalJumpManager.plan(for: snapshot(id, agent: .workBuddy)) else {
            return XCTFail("Expected a WorkBuddy conversation route")
        }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(parts.host, "chat")
        XCTAssertEqual(parts.percentEncodedPath.removingPercentEncoding, "/" + native)
        XCTAssertTrue(parts.percentEncodedPath.contains("%2F"))
        XCTAssertNil(parts.query)
        XCTAssertNil(parts.fragment)
    }

    func testWorkBuddyRejectsNonCanonicalOrControlCharacterIdentity() {
        for encoded in ["", "invalid!", Data("chat\nnext".utf8).base64EncodedString(), "YQ==\n"] {
            XCTAssertEqual(TerminalJumpManager.plan(for: snapshot("workbuddy-" + encoded, agent: .workBuddy)), .failure(.missingIdentity))
        }
    }

    func testCursorAgentRouteCarriesOnlyTheRequestedConversation() {
        let id = "agent+A&B/中文"
        guard case .conversation(.cursor, let url) = TerminalJumpManager.plan(for: snapshot("cursor-" + id, agent: .cursor)) else {
            return XCTFail("Expected a Cursor agent route")
        }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(parts.host, "anysphere.cursor-deeplink")
        XCTAssertEqual(parts.path, "/agent")
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "id", value: id)])
        XCTAssertTrue(parts.percentEncodedQuery!.contains("%2B"))
    }

    func testTerminalPaneIDsAreRequiredAndValidated() {
        XCTAssertEqual(TerminalJumpManager.plan(for: snapshot("task", agent: .claudeCode,
            terminal: "WezTerm", locator: "wezterm:42")), .terminal(.wezTermPane(42)))
        XCTAssertEqual(TerminalJumpManager.plan(for: snapshot("task", agent: .claudeCode,
            terminal: "Kitty", locator: "kitty:9")), .terminal(.kittyWindow(9)))
        for invalid in [nil, "42", "wezterm:-1", "wezterm:999999999999999999999999", "wezterm:1;echo"] {
            XCTAssertEqual(TerminalJumpManager.plan(for: snapshot("task", agent: .claudeCode,
                terminal: "WezTerm", locator: invalid)), .failure(.missingIdentity))
        }
    }

    func testUnknownClientAndMultiplexerNeverUseWorkspaceOrAppFallback() {
        XCTAssertEqual(TerminalJumpManager.plan(for: snapshot("copilot-local-" + thread, agent: .copilot,
            terminal: "Visual Studio Code")), .failure(.unavailable))
        XCTAssertEqual(TerminalJumpManager.plan(for: snapshot("task", agent: .claudeCode,
            terminal: "iTerm2", locator: "tmux:%3")), .failure(.unavailable))
        XCTAssertNil(TerminalJumpManager.captureFrontWindowNumber(for: .codex, terminal: "Codex"))
    }

    func testSubagentUsesParentIdentityAndParentHostTogether() {
        let parent = AgentSession(id: "codex-" + thread, agentType: .codex, terminal: "Codex")
        let child = AgentSession(id: "sub-task", agentType: .claudeCode, terminal: "iTerm2")
        child.parentSessionId = parent.id
        XCTAssertTrue(SessionJumpState.targetSession(child, lookup: { $0 == parent.id ? parent : nil }) === parent)
        XCTAssertNil(SessionJumpState.targetSession(child, lookup: { _ in nil }))
        parent.parentSessionId = child.id
        XCTAssertNil(SessionJumpState.targetSession(child, lookup: { $0 == parent.id ? parent : child }))
    }

    func testFailureDoesNotDismissOrMarkCompletedResultReviewed() {
        let (manager, session) = completedSession()
        let state = SessionJumpState()
        var callback: ((SessionJumpResult) -> Void)?
        var accepted = 0
        state.request(session, manager: manager, perform: { _, done in callback = done }) { accepted += 1 }
        XCTAssertTrue(state.isRunning)
        XCTAssertTrue(session.completionNeedsReview)
        callback?(.missingIdentity)
        XCTAssertFalse(state.isRunning)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertEqual(accepted, 0)
        XCTAssertTrue(session.completionNeedsReview)
    }

    func testAcceptedNavigationReviewsOnlyTheClickedCompletion() {
        let (manager, session) = completedSession()
        let state = SessionJumpState()
        var callback: ((SessionJumpResult) -> Void)?
        var accepted = 0
        state.request(session, manager: manager, perform: { _, done in callback = done }) { accepted += 1 }
        callback?(.conversationRequested)
        callback?(.conversationRequested)
        XCTAssertFalse(session.completionNeedsReview)
        XCTAssertEqual(accepted, 1)
    }

    func testOldNavigationDoesNotReviewANewCompletion() {
        let (manager, session) = completedSession()
        let state = SessionJumpState()
        var callback: ((SessionJumpResult) -> Void)?
        state.request(session, manager: manager, perform: { _, done in callback = done })
        session.completedAt = Date(timeIntervalSince1970: 200)
        callback?(.terminalFocused)
        XCTAssertTrue(session.completionNeedsReview)
    }

    func testCancelledNavigationIgnoresLateCompletion() {
        let (manager, session) = completedSession()
        let state = SessionJumpState()
        var callback: ((SessionJumpResult) -> Void)?
        var accepted = 0
        state.request(session, manager: manager, perform: { _, done in callback = done }) { accepted += 1 }
        state.cancel()
        callback?(.conversationRequested)
        XCTAssertEqual(accepted, 0)
        XCTAssertTrue(session.completionNeedsReview)
    }

    private func completedSession() -> (SessionManager, AgentSession) {
        let manager = SessionManager()
        let session = AgentSession(id: "codex-" + thread, agentType: .codex)
        session.status = .completed
        session.completedAt = Date(timeIntervalSince1970: 100)
        session.completionNeedsReview = true
        manager.sessions = [session]
        return (manager, session)
    }
}
