import AppKit
import Darwin
import Foundation

enum TerminalSessionTarget: Equatable, Sendable {
    case iTerm(id: String)
    case appleTerminalTTY(String)
    case wezTermPane(Int)
    case kittyWindow(Int)
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
    }

    static func navigate(_ target: TerminalSessionTarget) -> TerminalSessionNavigationResult {
        navigate(target, executor: Executor(appleScript: executeAppleScript, command: executeCommand))
    }

    static func navigate(_ target: TerminalSessionTarget, executor: Executor) -> TerminalSessionNavigationResult {
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
            guard let tty = terminalTTY(value) else { return nil }
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
        case .wezTermPane, .kittyWindow:
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

    private static func iTermIdentity(_ id: String) -> (property: String, value: String)? {
        guard !id.isEmpty, id.utf8.count <= 512,
              !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        if id.hasPrefix("tty:") {
            return terminalTTY(id).map { ("tty", $0) }
        }
        var value = id.hasPrefix("iterm:") ? String(id.dropFirst(6)) : id
        // ITERM_SESSION_ID 的窗口/标签位置前缀会变化，真正稳定的身份在冒号之后。
        if let separator = value.firstIndex(of: ":") {
            value = String(value[value.index(after: separator)...])
        }
        guard !value.isEmpty else { return nil }
        return ("unique ID", value)
    }

    private static func terminalTTY(_ value: String) -> String? {
        let tty = value.hasPrefix("tty:") ? String(value.dropFirst(4)) : value
        guard tty.hasPrefix("/dev/tty"), tty.utf8.count <= 128 else { return nil }
        let suffix = tty.dropFirst(8)
        guard !suffix.isEmpty, suffix.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }) else { return nil }
        return tty
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = TerminalJumpManager.controlledPATH
        process.environment = environment
        // 导航只需要退出状态；不用管道，避免大量输出阻塞或无界缓存。
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        let deadline = DispatchTime.now() + 5
        do { try process.run() } catch { return .failed }
        if terminated.wait(timeout: deadline - .milliseconds(500)) == .timedOut {
            if process.isRunning { process.terminate() }
            if terminated.wait(timeout: deadline - .milliseconds(350)) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = terminated.wait(timeout: deadline)
            }
            return .timedOut
        }
        guard process.terminationReason == .exit else { return .failed }
        return .exited(process.terminationStatus)
    }
}
