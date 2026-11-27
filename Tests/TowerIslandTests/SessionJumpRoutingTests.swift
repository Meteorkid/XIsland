import XCTest
@testable import XIsland

@MainActor
final class SessionJumpRoutingTests: XCTestCase {
    private let thread = "11111111-2222-4333-8444-555555555555"

    private func snapshot(_ id: String, agent: AgentType = .codex, terminal: String = "",
                          locator: String? = nil, status: SessionStatus = .idle) -> TerminalJumpManager.SessionSnapshot {
        .init(id: id, agentType: agent, terminal: terminal, workingDirectory: "/tmp/same-project",
              termSessionId: locator, windowNumber: 123, title: "", status: status)
    }

    func testCodexUsesConversationIDRatherThanSharedDirectoryOrCapturedWindow() throws {
        // 用官方 CODEX_HOME 指向临时索引；否则本机已有的索引会把测试线程降级成打开项目。
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("xisland-codex-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try "{\"id\":\"\(thread)\"}\n".write(
            to: codexHome.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        setenv("CODEX_HOME", codexHome.path, 1)
        defer { unsetenv("CODEX_HOME") }

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

    func testClaudeDesktopRequiresItsOwnLocalSessionMapping() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("xisland-claude-plan-\(UUID().uuidString)", isDirectory: true)
        let codeRoot = support.appendingPathComponent("claude-code-sessions/org/account", isDirectory: true)
        try FileManager.default.createDirectory(at: codeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let cli = "c2d57ea0-55b6-4cc2-b032-a6c476da9263"
        let local = "local_f39fbf5b-7e13-47ef-87a7-2a22f1f1e676"
        let data = try JSONSerialization.data(withJSONObject: [
            "sessionId": local, "cliSessionId": cli, "lastActivityAt": 1788784570652,
        ])
        try data.write(to: codeRoot.appendingPathComponent(local + ".json"))
        setenv("X_ISLAND_CLAUDE_SUPPORT_DIR", support.path, 1)
        defer { unsetenv("X_ISLAND_CLAUDE_SUPPORT_DIR") }

        XCTAssertEqual(TerminalJumpManager.plan(for: snapshot("claude-" + cli, agent: .claudeCode,
            terminal: "Claude Desktop")),
            .conversation(.claudeDesktop, URL(string: "claude://claude.ai/epitaxy/" + local)!))
        XCTAssertEqual(TerminalJumpManager.plan(for: snapshot("claude-" + cli + "-missing", agent: .claudeCode,
            terminal: "Claude Desktop")),
            .project(.claudeDesktop, URL(fileURLWithPath: "/tmp/same-project"), ""))
    }

    func testVSCodeUsesTheClaudeSessionLinkOnlyForExtensionChat() throws {
        let extensions = FileManager.default.temporaryDirectory
            .appendingPathComponent("xisland-vscode-routes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extensions.appendingPathComponent(
            "anthropic.claude-code-2.1.0", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extensions) }
        setenv("X_ISLAND_VSCODE_EXTENSIONS_DIR", extensions.path, 1)
        defer { unsetenv("X_ISLAND_VSCODE_EXTENSIONS_DIR") }

        let id = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        guard case .conversation(.vscode, let url) = TerminalJumpManager.plan(for: snapshot(
            "claude-" + id, agent: .claudeCode, terminal: "Visual Studio Code", status: .completed)) else {
            return XCTFail("Expected the official Claude Code VS Code session link")
        }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(parts.scheme, "vscode")
        XCTAssertEqual(parts.host, "anthropic.claude-code")
        XCTAssertEqual(parts.path, "/open")
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "session", value: id)])

        // 已打开且忙碌的 VS Code 会话会被上游 open?session= 新建空白对话，
        // 因此活动/等待状态必须降级为项目级打开，而不是冒险用会话链接。
        XCTAssertEqual(TerminalJumpManager.plan(for: snapshot(
            "claude-" + id, agent: .claudeCode, terminal: "Visual Studio Code", status: .active)),
            .project(.vscode, URL(fileURLWithPath: "/tmp/same-project"), ""))
    }

    func testVSCodeCompanionFocusesOnlyAnExistingTTY() throws {
        let extensions = FileManager.default.temporaryDirectory
            .appendingPathComponent("xisland-vscode-companion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extensions.appendingPathComponent(
            "meteorkid.xisland-vscode-1.1.0", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extensions) }
        setenv("X_ISLAND_VSCODE_EXTENSIONS_DIR", extensions.path, 1)
        defer { unsetenv("X_ISLAND_VSCODE_EXTENSIONS_DIR") }

        guard case .companion(.vscode, let url) = TerminalJumpManager.plan(for: snapshot(
            "copilot-local-task", agent: .copilot, terminal: "Visual Studio Code",
            locator: "tty:/dev/ttys004")) else {
            return XCTFail("Expected the VS Code companion focus route")
        }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(parts.scheme, "vscode")
        XCTAssertEqual(parts.host, "meteorkid.xisland-vscode")
        XCTAssertEqual(parts.path, "/focus")
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "tty" })?.value, "/dev/ttys004")
        XCTAssertTrue(parts.queryItems?.contains(where: { $0.name == "cwd" && $0.value == "/tmp/same-project" }) == true)
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

    func testMultiplexerNeverFallsBackWhileIDEsOpenTheProjectWithoutSessionLink() {
        // 2.2.0 起 IDE 没有会话级 deeplink 时退化为打开项目目录；tmux 仍不猜测。
        XCTAssertEqual(TerminalJumpManager.plan(for: snapshot("copilot-local-" + thread, agent: .copilot,
            terminal: "Visual Studio Code")),
            .project(.vscode, URL(fileURLWithPath: "/tmp/same-project"), ""))
        // tmux 内层 pane 可精确选择；外层宿主身份缺失时，导航层会在运行时
        // 通过 `#{client_tty}` 反查，而不是在规划阶段猜一个标签页。
        XCTAssertEqual(TerminalJumpManager.plan(for: snapshot("task", agent: .claudeCode,
            terminal: "iTerm2", locator: "tmux:%3")),
            .terminal(.tmux(pane: "%3", socketPath: nil, host: nil, app: .iterm2, cwd: "/tmp/same-project")))
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
