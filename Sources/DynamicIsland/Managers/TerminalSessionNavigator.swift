import AppKit
import ApplicationServices
import Darwin
import Foundation

indirect enum TerminalSessionTarget: Equatable, Sendable {
    case iTerm(id: String)
    case appleTerminalTTY(String)
    case wezTermPane(Int)
    case kittyWindow(Int)
    case ghostty(tty: String?, cwd: String)
    case warp(cwd: String)
    /// The pane is selected inside tmux first; `host` is the outer tab that
    /// must be focused afterwards. A nil host is resolved from tmux's
    /// `client_tty` at navigation time, never guessed from the current app.
    case tmux(pane: String, socketPath: String?, host: TerminalSessionTarget?, app: TerminalApp?, cwd: String)
}

enum TerminalSessionNavigationResult: Equatable, Sendable {
    case success
    case targetNotFound
    case automationDenied
    case commandFailed
}

/// 只接受会话自身的定位符；没有唯一匹配时不激活应用或其他窗口。
enum TerminalSessionNavigator {
    enum AppleScriptOutcome {
        case returned(Bool)
        case failed(Int?)
    }

    enum CommandOutcome {
        case exited(Int32)
        case failed
        case timedOut
    }

    struct Executor {
        var appleScript: (String) -> AppleScriptOutcome
        var command: ([String]) -> CommandOutcome
        var commandWithOutput: ([String]) -> (CommandOutcome, String)
        var resolveWarp: (String) -> WarpPaneMatch?
        var focusWarp: (WarpPaneMatch) -> TerminalSessionNavigationResult
        var isRunning: (TerminalApp) -> Bool

        init(
            appleScript: @escaping (String) -> AppleScriptOutcome,
            command: @escaping ([String]) -> CommandOutcome,
            commandWithOutput: @escaping ([String]) -> (CommandOutcome, String) = {
                TerminalSessionNavigator.executeCommandWithOutput($0)
            },
            resolveWarp: @escaping (String) -> WarpPaneMatch? = {
                WarpPaneResolver().bestMatch(cwd: $0)
            },
            focusWarp: @escaping (WarpPaneMatch) -> TerminalSessionNavigationResult = {
                TerminalSessionNavigator.focusWarpPane($0)
            },
            isRunning: @escaping (TerminalApp) -> Bool = {
                TerminalSessionNavigator.isTerminalRunning($0)
            }
        ) {
            self.appleScript = appleScript
            self.command = command
            self.commandWithOutput = commandWithOutput
            self.resolveWarp = resolveWarp
            self.focusWarp = focusWarp
            self.isRunning = isRunning
        }
    }

    static func navigate(_ target: TerminalSessionTarget) -> TerminalSessionNavigationResult {
        navigate(target, executor: Executor(
            appleScript: executeAppleScript,
            command: executeCommand,
            commandWithOutput: executeCommandWithOutput
        ))
    }

    static func navigate(_ target: TerminalSessionTarget, executor: Executor) -> TerminalSessionNavigationResult {
        switch target {
        case .tmux(let pane, let socketPath, let host, let app, let cwd):
            return navigateTmux(pane: pane, socketPath: socketPath, host: host, app: app, cwd: cwd,
                                executor: executor)
        case .warp(let cwd):
            guard let match = executor.resolveWarp(cwd) else { return .targetNotFound }
            return executor.focusWarp(match)
        case .ghostty:
            guard let script = appleScript(for: target) else { return .targetNotFound }
            switch executor.appleScript(script) {
            case .returned(true): return .success
            case .returned(false): return .targetNotFound
            case .failed(-1743), .failed(-1744): return .automationDenied
            case .failed: return .commandFailed
            }
        case .iTerm, .appleTerminalTTY, .wezTermPane, .kittyWindow:
            if let script = appleScript(for: target) {
                switch executor.appleScript(script) {
                case .returned(true): return .success
                case .returned(false): return .targetNotFound
                case .failed(-1743), .failed(-1744): return .automationDenied
                case .failed: return .commandFailed
                }
            }
            if let arguments = commandArguments(for: target) {
                if case .exited(0) = executor.command(arguments) { return .success }
                return .commandFailed
            }
            return .targetNotFound
        }
    }

    /// Select the exact tmux pane, then focus the outer tab. The outer identity
    /// is either captured at hook time or read from `client_tty`; if neither is
    /// available, the pane selection is not reported as a successful jump.
    private static func navigateTmux(
        pane: String, socketPath: String?, host: TerminalSessionTarget?, app: TerminalApp?, cwd: String,
        executor: Executor
    ) -> TerminalSessionNavigationResult {
        guard validTmuxPane(pane), socketPath.map(validSocketPath) ?? true else { return .targetNotFound }
        let prefix = tmuxPrefix(socketPath)
        // Switch the attached client to the target session first; otherwise a
        // pane in another session cannot become visible. Failure is tolerated
        // (no client attached, or already in that session).
        _ = executor.command(prefix + ["switch-client", "-t", pane])
        // Within that session, switch to the pane's window, then select the pane.
        switch executor.command(prefix + ["select-window", "-t", pane]) {
        case .exited(0):
            break
        case .failed, .timedOut:
            return .commandFailed
        case .exited:
            return .targetNotFound
        }
        switch executor.command(prefix + ["select-pane", "-t", pane]) {
        case .exited(0):
            break
        case .failed, .timedOut:
            return .commandFailed
        case .exited:
            return .targetNotFound
        }

        if let host {
            return navigate(host, executor: executor)
        }

        let (outcome, output) = executor.commandWithOutput(
            prefix + ["display-message", "-p", "-t", pane, "#{client_tty}"])
        guard case .exited(0) = outcome, let tty = ttyPath(from: output) else {
            return .targetNotFound
        }

        // tmux overwrites TERM_PROGRAM, and a server's environment may describe
        // the tab that started it rather than the client viewing this pane.
        // Probe the running tty-capable hosts in a fixed order and accept only
        // a script that actually matched this tty. The preferred app from
        // terminal metadata is tried after that, so Warp can use its CWD map.
        var candidates: [TerminalApp] = []
        // Try the host reported by the session first, but keep Warp last: it
        // can only match by CWD, so a tty-matched terminal must win if present.
        if let app, app != .warp, !candidates.contains(app) { candidates.append(app) }
        for fallback in [TerminalApp.iterm2, .terminal, .ghostty] where !candidates.contains(fallback) {
            candidates.append(fallback)
        }
        if let app, app == .warp { candidates.append(app) }
        var fallbackFailure: TerminalSessionNavigationResult = .targetNotFound
        for candidate in candidates {
            guard executor.isRunning(candidate),
                  let hostTarget = target(for: candidate, identifier: "tty:\(tty)", cwd: cwd) else {
                continue
            }
            switch navigate(hostTarget, executor: executor) {
            case .success:
                return .success
            case .automationDenied:
                fallbackFailure = .automationDenied
            case .commandFailed:
                if fallbackFailure != .automationDenied { fallbackFailure = .commandFailed }
            case .targetNotFound:
                break
            }
        }
        return fallbackFailure
    }

    /// Build a precise target for a host terminal from a session identity.
    /// Returns nil for terminals that have no verified session/tab locator.
    static func target(for app: TerminalApp, identifier: String, cwd: String) -> TerminalSessionTarget? {
        switch app {
        case .iterm2:
            guard let id = nonEmpty(identifier), appleScript(for: .iTerm(id: id)) != nil else { return nil }
            return .iTerm(id: id)
        case .terminal:
            guard let tty = ttyPath(from: identifier), appleScript(for: .appleTerminalTTY(tty)) != nil else {
                return nil
            }
            return .appleTerminalTTY(tty)
        case .wezTerm:
            guard let id = paneID(identifier, prefix: "wezterm:") else { return nil }
            return .wezTermPane(id)
        case .kitty:
            guard let id = paneID(identifier, prefix: "kitty:") else { return nil }
            return .kittyWindow(id)
        case .ghostty:
            let tty = ttyPath(from: identifier)
            guard tty != nil || !cwd.isEmpty else { return nil }
            return .ghostty(tty: tty, cwd: cwd)
        case .warp:
            guard !cwd.isEmpty else { return nil }
            return .warp(cwd: cwd)
        default:
            return nil
        }
    }

    static func appleScript(for target: TerminalSessionTarget) -> String? {
        switch target {
        case .iTerm(let id):
            guard let identity = iTermIdentity(id) else { return nil }
            let value = TerminalJumpManager.appleScriptQuoted(identity.value)
            return """
            with timeout of 5 seconds
                if application "iTerm2" is not running then return false
                tell application "iTerm2"
                    set matchCount to 0
                    repeat with aWindow in windows
                        repeat with aTab in tabs of aWindow
                            repeat with aSession in sessions of aTab
                                if \(identity.property) of aSession is "\(value)" then
                                    set matchCount to matchCount + 1
                                    set targetWindow to contents of aWindow
                                    set targetTab to contents of aTab
                                    set targetSession to contents of aSession
                                end if
                            end repeat
                        end repeat
                    end repeat
                    if matchCount is not 1 then return false
                    select targetSession
                    select targetTab
                    select targetWindow
                    activate
                    return true
                end tell
            end timeout
            """
        case .appleTerminalTTY(let value):
            guard let tty = ttyPath(from: value) else { return nil }
            return """
            with timeout of 5 seconds
                if application "Terminal" is not running then return false
                tell application "Terminal"
                    set matchCount to 0
                    repeat with aWindow in windows
                        repeat with aTab in tabs of aWindow
                            if tty of aTab is "\(TerminalJumpManager.appleScriptQuoted(tty))" then
                                set matchCount to matchCount + 1
                                set targetWindow to contents of aWindow
                                set targetTab to contents of aTab
                            end if
                        end repeat
                    end repeat
                    if matchCount is not 1 then return false
                    set selected tab of targetWindow to targetTab
                    set index of targetWindow to 1
                    activate
                    return true
                end tell
            end timeout
            """
        case .ghostty(let tty, let cwd):
            return ghosttyAppleScript(tty: tty, cwd: cwd)
        case .wezTermPane, .kittyWindow, .warp, .tmux:
            return nil
        }
    }

    static func commandArguments(for target: TerminalSessionTarget) -> [String]? {
        switch target {
        case .wezTermPane(let id) where id >= 0:
            return ["wezterm", "cli", "activate-pane", "--pane-id", String(id)]
        case .kittyWindow(let id) where id >= 0:
            return ["kitty", "@", "focus-window", "--match", "id:\(id)"]
        default:
            return nil
        }
    }

    private static func ghosttyAppleScript(tty: String?, cwd: String) -> String? {
        guard tty != nil || !cwd.isEmpty else { return nil }
        guard cwd.utf8.count <= 4096,
              !cwd.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        let ttyMatch: String
        if let tty {
            ttyMatch = """
                    try
                        set matches to (every terminal whose tty is "\(TerminalJumpManager.appleScriptQuoted(tty))")
                    end try
            """
        } else {
            ttyMatch = ""
        }
        let cwdMatch = cwd.isEmpty ? "" : """
                if (count of matches) is not 1 then
                    try
                        set matches to (every terminal whose working directory is "\(TerminalJumpManager.appleScriptQuoted(cwd))")
                    end try
                end if
        """
        return """
        with timeout of 5 seconds
            if application "Ghostty" is not running then return false
            tell application "Ghostty"
                set matches to {}
        \(ttyMatch)
        \(cwdMatch)
                if (count of matches) is not 1 then return false
                focus (item 1 of matches)
                activate
                return true
            end tell
        end timeout
        """
    }

    private static func iTermIdentity(_ id: String) -> (property: String, value: String)? {
        guard !id.isEmpty, id.utf8.count <= 512,
              !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        if id.hasPrefix("tty:") {
            return ttyPath(from: id).map { ("tty", $0) }
        }
        var value = id.hasPrefix("iterm:") ? String(id.dropFirst(6)) : id
        // ITERM_SESSION_ID 的窗口/标签位置前缀会变化，真正稳定的身份在冒号之后。
        if let separator = value.firstIndex(of: ":") {
            value = String(value[value.index(after: separator)...])
        }
        guard !value.isEmpty else { return nil }
        return ("unique ID", value)
    }

    static func ttyPath(from value: String) -> String? {
        let raw = value.hasPrefix("tty:") ? String(value.dropFirst(4)) : value
        let tty = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tty.hasPrefix("/dev/tty"), tty.utf8.count <= 128 else { return nil }
        let suffix = tty.dropFirst(8)
        guard !suffix.isEmpty, suffix.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }) else { return nil }
        return tty
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func paneID(_ value: String, prefix: String) -> Int? {
        guard value.hasPrefix(prefix) else { return nil }
        let suffix = value.dropFirst(prefix.count)
        guard !suffix.isEmpty, suffix.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(suffix), number >= 0 else { return nil }
        return number
    }

    private static func tmuxPrefix(_ socketPath: String?) -> [String] {
        guard let socketPath else { return ["tmux"] }
        return ["tmux", "-S", socketPath]
    }

    private static func validSocketPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.isEmpty && path.utf8.count <= 1024
            && !path.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
            })
    }

    private static func validTmuxPane(_ pane: String) -> Bool {
        guard pane.hasPrefix("%") else { return false }
        let suffix = pane.dropFirst()
        return !suffix.isEmpty && suffix.utf8.allSatisfy({ (48...57).contains($0) })
    }

    private static func isTerminalRunning(_ app: TerminalApp) -> Bool {
        app.bundleIds.contains {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
    }

    private static func executeAppleScript(_ source: String) -> AppleScriptOutcome {
        let execute = { () -> AppleScriptOutcome in
            guard let script = NSAppleScript(source: source) else { return .failed(nil) }
            var error: NSDictionary?
            let output = script.executeAndReturnError(&error)
            if let error { return .failed(error[NSAppleScript.errorNumber] as? Int) }
            return .returned(output.booleanValue)
        }
        if Thread.isMainThread { return execute() }
        return DispatchQueue.main.sync(execute: execute)
    }

    private static func executeCommand(_ arguments: [String]) -> CommandOutcome {
        executeCommandWithOutput(arguments).0
    }

    private static func executeCommandWithOutput(_ arguments: [String]) -> (CommandOutcome, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = TerminalJumpManager.controlledPATH
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // Commands used here produce a single short line; they never need stdin.
        process.standardInput = FileHandle.nullDevice
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        let deadline = DispatchTime.now() + 5
        do { try process.run() } catch { return (.failed, "") }
        if terminated.wait(timeout: deadline - .milliseconds(500)) == .timedOut {
            if process.isRunning { process.terminate() }
            if terminated.wait(timeout: deadline - .milliseconds(350)) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = terminated.wait(timeout: deadline)
            }
            return (.timedOut, "")
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationReason == .exit else { return (.failed, output) }
        return (.exited(process.terminationStatus), output)
    }

    // MARK: - Warp

    static func focusWarpPane(_ match: WarpPaneMatch) -> TerminalSessionNavigationResult {
        let bundleIDs = ["dev.warp.Warp-Stable", "dev.warp.Warp"]
        guard let app = bundleIDs.compactMap({
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
        }).first else {
            return .targetNotFound
        }
        let activate = {
            if app.isHidden { app.unhide() }
            app.activate(options: [])
        }
        if Thread.isMainThread { activate() } else { DispatchQueue.main.sync(execute: activate) }

        if match.isActiveTab { return .success }
        guard AXIsProcessTrusted() else { return .automationDenied }
        guard let position = warpShortcutPosition(for: match) else { return .targetNotFound }
        // The shortcut is only meaningful when Warp is frontmost. Activation is
        // asynchronous, so poll briefly instead of sleeping once and posting a
        // keystroke into whatever application happens to be in front.
        guard let bundleID = app.bundleIdentifier else { return .targetNotFound }
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.05)
            var frontmost = false
            let check = { frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID }
            if Thread.isMainThread { check() } else { DispatchQueue.main.sync(execute: check) }
            if frontmost {
                sendWarpTabShortcut(position: position, pid: app.processIdentifier)
                return .success
            }
        }
        return .targetNotFound
    }

    static func warpTabPosition(tabIndex: Int, tabCount: Int) -> Int? {
        let position = tabIndex + 1
        if (1...8).contains(position) { return position }
        // Cmd+9 means "last tab", not "ninth tab". With ten or more tabs,
        // the ninth tab has no dedicated shortcut, so it must not be guessed.
        if position == tabCount && position >= 9 { return 9 }
        return nil
    }

    private static func warpShortcutPosition(for match: WarpPaneMatch) -> Int? {
        warpTabPosition(tabIndex: match.tabIndexInWindow, tabCount: match.tabCountInWindow)
    }

    private static func sendWarpTabShortcut(position: Int, pid: pid_t) {
        guard (1...9).contains(position), let source = CGEventSource(stateID: .combinedSessionState) else {
            return
        }
        let keyCodes: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        let keyCode = keyCodes[position - 1]
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = .maskCommand
            down.postToPid(pid)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = .maskCommand
            up.postToPid(pid)
        }
    }
}
