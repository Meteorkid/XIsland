import Foundation
import XCTest
@testable import DIBridge
@testable import XIsland

@MainActor
final class TerminalHostNavigationTests: XCTestCase {
    // MARK: - PID → TTY

    func testProcessTreeWalksThroughShellToControllingTTY() {
        let entries: [Int32: ProcessTreeEntry] = [
            900: .init(pid: 900, parentPID: 800, tty: nil, command: "di-bridge"),
            800: .init(pid: 800, parentPID: 700, tty: "ttys004", command: "zsh"),
            700: .init(pid: 700, parentPID: 1, tty: nil, command: "login"),
        ]
        let tty = ProcessTreeResolver.controllingTTY(startingAt: 900) { entries[$0] }
        XCTAssertEqual(tty, "/dev/ttys004")
    }

    func testProcessTreeRejectsCyclesAndUnusableTTYValues() {
        let entries: [Int32: ProcessTreeEntry] = [
            700: .init(pid: 700, parentPID: 701, tty: nil, command: "a"),
            701: .init(pid: 701, parentPID: 700, tty: nil, command: "b"),
            800: .init(pid: 800, parentPID: 1, tty: "??", command: "c"),
        ]
        XCTAssertNil(ProcessTreeResolver.controllingTTY(startingAt: 700) { entries[$0] })
        XCTAssertNil(ProcessTreeResolver.controllingTTY(startingAt: 800) { entries[$0] })
        XCTAssertEqual(ProcessTreeResolver.normalizeTTY("ttys004"), "/dev/ttys004")
        XCTAssertEqual(ProcessTreeResolver.normalizeTTY("/dev/ttys004"), "/dev/ttys004")
        XCTAssertNil(ProcessTreeResolver.normalizeTTY("tty"))
        XCTAssertNil(ProcessTreeResolver.normalizeTTY("tty;open /tmp/evil"))
    }

    func testBridgeResolvesOuterHostWithoutUsingTmuxPaneTTY() {
        // tmux server env points at the tab that started the server, not the
        // client currently viewing the pane, so no host identity is captured.
        XCTAssertEqual(DIBridge.resolveHostTermSessionId(
            environment: ["ITERM_SESSION_ID": "w0t0p0:ABC"],
            tty: "/dev/ttys004", tmuxPresent: true), "")
        XCTAssertEqual(DIBridge.resolveHostTermSessionId(
            environment: ["TERM_SESSION_ID": "terminal-session"],
            tty: "/dev/ttys004", tmuxPresent: true), "")
        XCTAssertEqual(DIBridge.resolveHostTermSessionId(
            environment: [:], tty: "/dev/ttys004", tmuxPresent: false), "tty:/dev/ttys004")
        XCTAssertEqual(DIBridge.resolveHostTermSessionId(
            environment: ["ITERM_SESSION_ID": "w0t0p0:ABC"],
            tty: "/dev/ttys004", tmuxPresent: false), "iterm:w0t0p0:ABC")
        XCTAssertEqual(DIBridge.resolveHostTermSessionId(
            environment: ["TERM_SESSION_ID": "terminal-session"],
            tty: "/dev/ttys004", tmuxPresent: false), "ts:terminal-session")
    }

    func testJumpPlanPrefersIdentityThatMatchesTheTargetTerminalType() {
        let iTerm = TerminalJumpManager.SessionSnapshot(
            id: "task", agentType: .claudeCode, terminal: "iTerm2",
            workingDirectory: "/tmp/project", termSessionId: "iterm:w0t0p0:ABC",
            windowNumber: nil, title: "", hostTermSessionId: "ts:terminal-session")
        XCTAssertEqual(TerminalJumpManager.plan(for: iTerm), .terminal(.iTerm(id: "iterm:w0t0p0:ABC")))

        let terminal = TerminalJumpManager.SessionSnapshot(
            id: "task", agentType: .claudeCode, terminal: "Terminal",
            workingDirectory: "/tmp/project", termSessionId: "tty:/dev/ttys004",
            windowNumber: nil, title: "", hostTermSessionId: "ts:terminal-session")
        XCTAssertEqual(TerminalJumpManager.plan(for: terminal),
                       .terminal(.appleTerminalTTY("tty:/dev/ttys004")))
    }

    // MARK: - Ghostty

    func testGhosttyScriptUsesTTYThenFallsBackToWorkingDirectory() {
        let script = TerminalSessionNavigator.appleScript(
            for: .ghostty(tty: "/dev/ttys004", cwd: "/tmp/project"))
        let source = try! XCTUnwrap(script)
        XCTAssertTrue(source.contains("every terminal whose tty is \"/dev/ttys004\""))
        XCTAssertTrue(source.contains("every terminal whose working directory is \"/tmp/project\""))
        XCTAssertTrue(source.contains("if (count of matches) is not 1 then return false"))
        XCTAssertTrue(source.contains("focus (item 1 of matches)"))
        XCTAssertFalse(source.contains("activate \"Ghostty\""))
    }

    func testGhosttyScriptNeverFallsBackToWholeApplication() {
        let cwdOnly = try! XCTUnwrap(TerminalSessionNavigator.appleScript(
            for: .ghostty(tty: nil, cwd: "/tmp/project")))
        XCTAssertFalse(cwdOnly.contains("whose tty is"))
        XCTAssertTrue(cwdOnly.contains("whose working directory is"))
        XCTAssertNil(TerminalSessionNavigator.appleScript(for: .ghostty(tty: nil, cwd: "")))
        XCTAssertNil(TerminalSessionNavigator.appleScript(for: .ghostty(tty: nil, cwd: "/tmp/a\nb")))
        XCTAssertNil(TerminalSessionNavigator.target(for: .ghostty, identifier: "", cwd: ""))
    }

    func testJumpPlanCarriesGhosttyTTYAsAnExactTarget() {
        let snap = TerminalJumpManager.SessionSnapshot(
            id: "task", agentType: .claudeCode, terminal: "Ghostty",
            workingDirectory: "/tmp/project", termSessionId: "tty:/dev/ttys004",
            windowNumber: nil, title: "")
        XCTAssertEqual(TerminalJumpManager.plan(for: snap),
                       .terminal(.ghostty(tty: "/dev/ttys004", cwd: "/tmp/project")))
    }

    // MARK: - tmux

    func testTmuxSelectsPaneBeforeFocusingHost() {
        var commands: [[String]] = []
        var scripts: [String] = []
        let executor = TerminalSessionNavigator.Executor(
            appleScript: { scripts.append($0); return .returned(true) },
            command: { commands.append($0); return .exited(0) },
            commandWithOutput: { commands.append($0); return (.exited(0), "") },
            resolveWarp: { _ in nil },
            focusWarp: { _ in .targetNotFound })
        let result = TerminalSessionNavigator.navigate(
            .tmux(pane: "%3", socketPath: nil, host: .appleTerminalTTY("/dev/ttys009"),
                  app: .terminal, cwd: "/tmp/project"),
            executor: executor)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(commands, [["tmux", "switch-client", "-t", "%3"],
                                  ["tmux", "select-window", "-t", "%3"],
                                  ["tmux", "select-pane", "-t", "%3"]])
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("tty of aTab is \"/dev/ttys009\""))
    }

    func testTmuxResolvesHostTTYWhenNoHostIdentityWasCaptured() {
        var commands: [[String]] = []
        var scripts: [String] = []
        let executor = TerminalSessionNavigator.Executor(
            appleScript: { script in
                scripts.append(script)
                // Simulate a Terminal.app host: the iTerm probe must miss and
                // the Terminal probe must match the client tty.
                return script.contains("tell application \"Terminal\"") ? .returned(true) : .returned(false)
            },
            command: { commands.append($0); return .exited(0) },
            commandWithOutput: { commands.append($0); return (.exited(0), "/dev/ttys009\n") },
            resolveWarp: { _ in nil },
            focusWarp: { _ in .targetNotFound },
            isRunning: { _ in true })
        let result = TerminalSessionNavigator.navigate(
            .tmux(pane: "%3", socketPath: nil, host: nil, app: .terminal, cwd: "/tmp/project"),
            executor: executor)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(commands.first, ["tmux", "switch-client", "-t", "%3"])
        XCTAssertTrue(commands.contains(["tmux", "select-window", "-t", "%3"]))
        XCTAssertTrue(commands.contains(["tmux", "select-pane", "-t", "%3"]))
        XCTAssertTrue(commands.contains(["tmux", "display-message", "-p", "-t", "%3", "#{client_tty}"]))
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("tty of aTab is \"/dev/ttys009\""))
    }

    func testTmuxSelectionFailureIsNotReportedAsSuccess() {
        var scripts: [String] = []
        let executor = TerminalSessionNavigator.Executor(
            appleScript: { scripts.append($0); return .returned(true) },
            command: { _ in .exited(1) },
            commandWithOutput: { _ in (.exited(0), "/dev/ttys009\n") },
            resolveWarp: { _ in nil },
            focusWarp: { _ in .targetNotFound })
        XCTAssertEqual(TerminalSessionNavigator.navigate(
            .tmux(pane: "%3", socketPath: nil, host: nil, app: .terminal, cwd: "/tmp"),
            executor: executor), .targetNotFound)
        XCTAssertTrue(scripts.isEmpty)
    }

    func testTmuxRejectsUnsafePaneIdentitiesBeforeRunningAnything() {
        var ranCommand = false
        let executor = TerminalSessionNavigator.Executor(
            appleScript: { _ in .returned(true) },
            command: { _ in ranCommand = true; return .exited(0) },
            commandWithOutput: { _ in (.exited(0), "") },
            resolveWarp: { _ in nil },
            focusWarp: { _ in .targetNotFound })
        XCTAssertEqual(TerminalSessionNavigator.navigate(
            .tmux(pane: "3;open /tmp/evil", socketPath: nil, host: nil, app: .terminal, cwd: "/tmp"),
            executor: executor), .targetNotFound)
        XCTAssertFalse(ranCommand)
    }

    func testTmuxPlanUsesCapturedOuterITermIdentity() {
        let snap = TerminalJumpManager.SessionSnapshot(
            id: "task", agentType: .claudeCode, terminal: "iTerm2",
            workingDirectory: "/tmp/project", termSessionId: "tmux:%3",
            windowNumber: nil, title: "", hostTermSessionId: "iterm:w0t0p0:ABC")
        XCTAssertEqual(TerminalJumpManager.plan(for: snap),
                       .terminal(.tmux(pane: "%3", socketPath: nil, host: .iTerm(id: "iterm:w0t0p0:ABC"),
                                       app: .iterm2, cwd: "/tmp/project")))
    }

    func testTmuxUsesExplicitServerSocket() {
        var commands: [[String]] = []
        let executor = TerminalSessionNavigator.Executor(
            appleScript: { _ in .returned(true) },
            command: { commands.append($0); return .exited(0) },
            commandWithOutput: { commands.append($0); return (.exited(0), "/dev/ttys009\n") },
            resolveWarp: { _ in nil },
            focusWarp: { _ in .targetNotFound },
            isRunning: { _ in true })
        let result = TerminalSessionNavigator.navigate(
            .tmux(pane: "%3", socketPath: "/tmp/tmux-501/custom", host: nil,
                  app: .terminal, cwd: "/tmp/project"),
            executor: executor)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(commands.first, ["tmux", "-S", "/tmp/tmux-501/custom", "switch-client", "-t", "%3"])
        XCTAssertTrue(commands.contains(["tmux", "-S", "/tmp/tmux-501/custom", "select-window", "-t", "%3"]))
        XCTAssertTrue(commands.contains(["tmux", "-S", "/tmp/tmux-501/custom", "select-pane", "-t", "%3"]))
        XCTAssertTrue(commands.contains(["tmux", "-S", "/tmp/tmux-501/custom", "display-message",
                                         "-p", "-t", "%3", "#{client_tty}"]))
    }

    func testTmuxRejectsMalformedSocketPath() {
        var ran = false
        let executor = TerminalSessionNavigator.Executor(
            appleScript: { _ in .returned(true) },
            command: { _ in ran = true; return .exited(0) },
            commandWithOutput: { _ in (.exited(0), "") },
            resolveWarp: { _ in nil },
            focusWarp: { _ in .targetNotFound })
        XCTAssertEqual(TerminalSessionNavigator.navigate(
            .tmux(pane: "%3", socketPath: "relative/socket", host: nil, app: .terminal, cwd: "/tmp"),
            executor: executor), .targetNotFound)
        XCTAssertFalse(ran)
    }

    func testBridgeParsesOnlyTheSocketPartOfTmuxEnvironment() {
        XCTAssertEqual(DIBridge.tmuxSocketPath(from: "/tmp/tmux-501/default,1234,0"),
                       "/tmp/tmux-501/default")
        XCTAssertNil(DIBridge.tmuxSocketPath(from: "relative/socket,1234,0"))
        XCTAssertNil(DIBridge.tmuxSocketPath(from: "/tmp/tmux-501/default"))
        XCTAssertNil(DIBridge.tmuxSocketPath(from: "/tmp/tmux 501/default,1234,0"))
    }

    func testTmuxPlanDoesNotRequireAKnownHostApp() {
        let snap = TerminalJumpManager.SessionSnapshot(
            id: "task", agentType: .claudeCode, terminal: "tmux",
            workingDirectory: "/tmp/project", termSessionId: "tmux:%3",
            windowNumber: nil, title: "", tmuxSocketPath: "/tmp/tmux-501/default")
        XCTAssertEqual(TerminalJumpManager.plan(for: snap),
                       .terminal(.tmux(pane: "%3", socketPath: "/tmp/tmux-501/default",
                                       host: nil, app: nil, cwd: "/tmp/project")))
    }

    func testTmuxPlanCarriesSocketAndRejectsUnsafeSocket() {
        let good = TerminalJumpManager.SessionSnapshot(
            id: "task", agentType: .claudeCode, terminal: "Terminal",
            workingDirectory: "/tmp/project", termSessionId: "tmux:%3",
            windowNumber: nil, title: "", tmuxSocketPath: "/tmp/tmux-501/custom")
        guard case .terminal(.tmux(_, let socket, _, _, _)) = TerminalJumpManager.plan(for: good) else {
            return XCTFail("Expected tmux route")
        }
        XCTAssertEqual(socket, "/tmp/tmux-501/custom")

        let bad = TerminalJumpManager.SessionSnapshot(
            id: "task", agentType: .claudeCode, terminal: "Terminal",
            workingDirectory: "/tmp/project", termSessionId: "tmux:%3",
            windowNumber: nil, title: "", tmuxSocketPath: "relative/socket")
        guard case .terminal(.tmux(_, let socket, _, _, _)) = TerminalJumpManager.plan(for: bad) else {
            return XCTFail("Expected tmux route")
        }
        XCTAssertNil(socket)
    }

    func testBridgeMapsTerminalBundleIDsToFriendlyHostNames() {
        XCTAssertEqual(DIBridge.terminalName(forBundleID: "com.apple.Terminal"), "Terminal")
        XCTAssertEqual(DIBridge.terminalName(forBundleID: "com.googlecode.iterm2"), "iTerm2")
        XCTAssertEqual(DIBridge.terminalName(forBundleID: "com.mitchellh.ghostty"), "Ghostty")
        XCTAssertEqual(DIBridge.terminalName(forBundleID: "com.anthropic.claudefordesktop"), "Claude Desktop")
        XCTAssertEqual(DIBridge.terminalName(forBundleID: "dev.warp.Warp-Stable"), "Warp")
        XCTAssertEqual(DIBridge.terminalName(forBundleID: "org.wezfurlong.wezterm"), "WezTerm")
        XCTAssertEqual(DIBridge.terminalName(forBundleID: "net.kovidgoyal.kitty"), "kitty")
        XCTAssertEqual(DIBridge.terminalName(forBundleID: "com.example.other"), "com.example.other")
    }

    func testClaudeDesktopBundleWinsOverGenericTermProgram() {
        setenv("__CFBundleIdentifier", "com.anthropic.claudefordesktop", 1)
        setenv("TERM_PROGRAM", "Apple_Terminal", 1)
        unsetenv("CLAUDE_CODE_HOST_SESSION_ID")
        defer {
            unsetenv("__CFBundleIdentifier")
            unsetenv("TERM_PROGRAM")
            unsetenv("CLAUDE_CODE_HOST_SESSION_ID")
        }
        let message = DIBridge.buildSessionStart(sessionId: "claude-test", agentType: "claude_code", data: nil)
        XCTAssertEqual(message.terminal, "Claude Desktop")
    }

    // MARK: - Warp

    func testWarpShortcutMappingNeverGuessesBeyondVisibleTabs() {
        XCTAssertEqual(TerminalSessionNavigator.warpTabPosition(tabIndex: 0, tabCount: 3), 1)
        XCTAssertEqual(TerminalSessionNavigator.warpTabPosition(tabIndex: 7, tabCount: 10), 8)
        XCTAssertNil(TerminalSessionNavigator.warpTabPosition(tabIndex: 8, tabCount: 10))
        XCTAssertEqual(TerminalSessionNavigator.warpTabPosition(tabIndex: 9, tabCount: 10), 9)
        XCTAssertEqual(TerminalSessionNavigator.warpTabPosition(tabIndex: 8, tabCount: 9), 9)
        XCTAssertEqual(TerminalSessionNavigator.warpTabPosition(tabIndex: 3, tabCount: 10), 4)
        XCTAssertEqual(TerminalSessionNavigator.warpTabPosition(tabIndex: 4, tabCount: 10), 5)
    }

    func testWarpPlanUsesWorkingDirectoryOnlyWhenItExists() {
        let snap = TerminalJumpManager.SessionSnapshot(
            id: "task", agentType: .claudeCode, terminal: "Warp",
            workingDirectory: "/tmp/project", termSessionId: nil,
            windowNumber: nil, title: "")
        XCTAssertEqual(TerminalJumpManager.plan(for: snap), .terminal(.warp(cwd: "/tmp/project")))
        XCTAssertEqual(TerminalJumpManager.plan(for: .init(
            id: "task", agentType: .claudeCode, terminal: "Warp", workingDirectory: "",
            termSessionId: nil, windowNumber: nil, title: "")), .failure(.missingIdentity))
    }

    func testWarpPaneResolverReadsSingleTabFromSQLite() throws {
        let db = FileManager.default.temporaryDirectory
            .appendingPathComponent("warp-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: db) }
        let sql = """
        CREATE TABLE windows (id INTEGER PRIMARY KEY, active_tab_index INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE tabs (id INTEGER PRIMARY KEY, window_id INTEGER NOT NULL);
        CREATE TABLE pane_nodes (id INTEGER PRIMARY KEY, tab_id INTEGER);
        CREATE TABLE pane_leaves (pane_node_id INTEGER PRIMARY KEY, kind TEXT, is_focused INTEGER);
        CREATE TABLE terminal_panes (id INTEGER PRIMARY KEY, cwd TEXT, is_active INTEGER);
        INSERT INTO windows VALUES (1, 1);
        INSERT INTO tabs VALUES (10, 1), (11, 1), (12, 1);
        INSERT INTO pane_nodes VALUES (200, 11);
        INSERT INTO terminal_panes VALUES (200, '/tmp/project', 1);
        INSERT INTO pane_leaves VALUES (200, 'terminal', 1);
        """
        try runSQLite(db: db, sql: sql)

        let resolver = WarpPaneResolver(sqlitePath: db.path)
        let matches = try resolver.resolve(cwd: "/tmp/project")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].tabId, 11)
        XCTAssertEqual(matches[0].windowDbId, 1)
        XCTAssertEqual(matches[0].tabIndexInWindow, 1)
        XCTAssertEqual(matches[0].tabCountInWindow, 3)
        XCTAssertTrue(matches[0].isActiveTab)
        XCTAssertTrue(matches[0].isPaneActive)
        XCTAssertTrue(matches[0].isPaneFocused)
        XCTAssertEqual(resolver.bestMatch(cwd: "/tmp/project"), matches[0])
        XCTAssertNil(resolver.bestMatch(cwd: "/tmp/missing"))
    }

    func testWarpPaneResolverRefusesToGuessAcrossWindows() throws {
        let db = FileManager.default.temporaryDirectory
            .appendingPathComponent("warp-two-windows-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: db) }
        let sql = """
        CREATE TABLE windows (id INTEGER PRIMARY KEY, active_tab_index INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE tabs (id INTEGER PRIMARY KEY, window_id INTEGER NOT NULL);
        CREATE TABLE pane_nodes (id INTEGER PRIMARY KEY, tab_id INTEGER);
        CREATE TABLE pane_leaves (pane_node_id INTEGER PRIMARY KEY, kind TEXT, is_focused INTEGER);
        CREATE TABLE terminal_panes (id INTEGER PRIMARY KEY, cwd TEXT, is_active INTEGER);
        INSERT INTO windows VALUES (1, 0), (2, 0);
        INSERT INTO tabs VALUES (10, 1), (20, 2);
        INSERT INTO pane_nodes VALUES (200, 10), (300, 20);
        INSERT INTO terminal_panes VALUES (200, '/tmp/project', 1), (300, '/tmp/project', 1);
        INSERT INTO pane_leaves VALUES (200, 'terminal', 1), (300, 'terminal', 1);
        """
        try runSQLite(db: db, sql: sql)
        let resolver = WarpPaneResolver(sqlitePath: db.path)
        XCTAssertEqual(try resolver.resolve(cwd: "/tmp/project").count, 2)
        XCTAssertNil(resolver.bestMatch(cwd: "/tmp/project"))
    }

    func testWarpPaneResolverFailsClosedWhenDatabaseIsMissing() {
        let resolver = WarpPaneResolver(sqlitePath: "/tmp/\(UUID().uuidString).sqlite")
        XCTAssertNil(resolver.bestMatch(cwd: "/tmp/project"))
        XCTAssertThrowsError(try resolver.resolve(cwd: "/tmp/project"))
    }

    private func runSQLite(db: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db.path, sql]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
