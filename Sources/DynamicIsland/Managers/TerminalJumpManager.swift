import AppKit
import Foundation
import DIShared

enum TerminalApp: String, CaseIterable {
    case iterm2 = "iTerm2"
    case terminal = "Terminal"
    case ghostty = "Ghostty"
    case warp = "Warp"
    case alacritty = "Alacritty"
    case kitty = "Kitty"
    case vscode = "Visual Studio Code"
    case cursor = "Cursor"
    case windsurf = "Windsurf"
    case trae = "Trae"
    case traeCn = "Trae CN"
    case codex = "Codex"
    case wezTerm = "WezTerm"
    case zellij = "Zellij"
    case antigravity = "Antigravity"
    case hyper = "Hyper"
    case zed = "Zed"
    case cmux = "CMux"
    case conductor = "Conductor"
    case termius = "Termius"

    var bundleIds: [String] {
        switch self {
        case .iterm2: ["com.googlecode.iterm2"]
        case .terminal: ["com.apple.Terminal"]
        case .ghostty: ["com.mitchellh.ghostty"]
        case .warp: ["dev.warp.Warp-Stable", "dev.warp.Warp"]
        case .alacritty: ["org.alacritty"]
        case .kitty: ["net.kovidgoyal.kitty"]
        case .vscode: ["com.microsoft.VSCode"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        case .windsurf: ["com.codeium.windsurf"]
        case .trae: ["com.trae.app"]
        case .traeCn: ["cn.trae.app"]
        case .codex: ["com.openai.codex"]
        case .wezTerm: ["org.wezfurlong.wezterm"]
        case .zellij: ["no.bundle.id.zellij"] // multiplexer, runs inside another terminal
        case .antigravity: ["com.antigravity.Antigravity"] // Antigravity IDE terminal
        case .hyper: ["co.zeit.hyper"]
        case .zed: ["dev.zed.Zed"]
        case .cmux: [] // cmux runs inside another terminal — no macOS bundle
        case .conductor: [] // conductor runs inside another terminal — no macOS bundle
        case .termius: ["com.termius.mac"]
        }
    }

    var bundleId: String {
        bundleIds[0]
    }

    var aliases: [String] {
        switch self {
        case .iterm2: ["iterm2", "iterm.app", "iterm"]
        case .terminal: ["terminal", "apple_terminal"]
        case .ghostty: ["ghostty"]
        case .warp: ["warp"]
        case .alacritty: ["alacritty"]
        case .kitty: ["kitty"]
        case .vscode: ["visual studio code", "vscode"]
        case .cursor: ["cursor"]
        case .windsurf: ["windsurf"]
        case .trae: ["trae"]
        case .traeCn: ["trae cn", "trae-cn", "traecn"]
        case .codex: ["codex"]
        case .wezTerm: ["wezterm"]
        case .zellij: ["zellij"]
        case .antigravity: ["antigravity"]
        case .hyper: ["hyper"]
        case .zed: ["zed"]
        case .cmux: ["cmux"]
        case .conductor: ["conductor"]
        case .termius: ["termius"]
        }
    }

    var isVSCodeFamily: Bool {
        switch self {
        case .vscode, .cursor, .windsurf, .trae, .traeCn, .antigravity:
            true
        default:
            false
        }
    }

    static func detect(from name: String) -> TerminalApp? {
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if lower.contains("warp") { return .warp }
        if lower.contains("iterm") { return .iterm2 }
        if lower.contains("ghostty") { return .ghostty }
        if lower.contains("alacritty") { return .alacritty }
        if lower.contains("kitty") { return .kitty }
        if lower.contains("wezterm") { return .wezTerm }
        if lower.contains("zellij") { return .zellij }
        if lower.contains("antigravity") { return .antigravity }
        if lower.contains("hyper") { return .hyper }
        if lower.contains("zed") { return .zed }
        if lower.contains("cmux") { return .cmux }
        if lower.contains("conductor") { return .conductor }
        if lower.contains("termius") { return .termius }
        if lower.contains("apple_terminal") || lower == "terminal" || lower.contains("com.apple.terminal") {
            return .terminal
        }

        if let exact = allCases.first(where: {
            $0.bundleIds.contains(where: { $0.lowercased() == lower }) || $0.aliases.contains(lower)
        }) {
            return exact
        }

        if let byBundle = allCases.first(where: { app in
            app.bundleIds.contains(where: { lower.contains($0.lowercased()) })
        }) {
            return byBundle
        }

        let aliasMatches: [(app: TerminalApp, score: Int)] = allCases.compactMap { app in
            let longestAlias = app.aliases
                .filter { lower.contains($0) }
                .map(\.count)
                .max() ?? 0
            guard longestAlias > 0 else { return nil }
            return (app, longestAlias)
        }

        return aliasMatches.sorted(by: { $0.score > $1.score }).first?.app
    }

    static func forAgent(_ agentType: AgentType) -> TerminalApp? {
        switch agentType {
        case .cursor: return .cursor
        case .trae: return .trae
        case .codex: return .codex
        case .copilot: return .vscode
        case .claudeCode, .geminiCli, .openCode, .droid, .qoder, .codeBuddy,
             .qwen, .kimi, .deepseek, .kiro, .amp, .pi, .hermes, .glm, .aider:
            return nil
        }
    }
}

enum TerminalJumpManager {
    static func jump(to session: AgentSession) -> Bool {
        let targetApp = resolveTargetApp(for: session)
        log("click session=\(session.id) agent=\(session.agentType.rawValue) terminal=\(session.terminal) cwd=\(session.workingDirectory) target=\(targetApp?.rawValue ?? "nil")")

        if session.agentType == .cursor {
            let preferredApp = (targetApp == .windsurf) ? TerminalApp.windsurf : TerminalApp.cursor
            if raiseMatchingWindow(session: session, app: preferredApp, allowFallbackActivate: false) {
                log("cursor matched existing window app=\(preferredApp.rawValue)")
                return true
            }
            if raiseAllCursorWindows(preferredBundleId: preferredApp.bundleId) {
                log("cursor raised all cursor-family windows")
                return true
            }
            if !session.workingDirectory.isEmpty,
               openWorkspaceWindow(app: preferredApp, workingDirectory: session.workingDirectory) {
                log("cursor opened workspace app=\(preferredApp.rawValue)")
                return true
            }
            log("cursor fallback activate app=\(preferredApp.rawValue)")
            activateApp(preferredApp)
            return true
        }

        if let app = targetApp {
            if let tsid = session.termSessionId, !tsid.isEmpty, app == .iterm2 {
                log("jumping to iTerm session id=\(tsid)")
                jumpToITermSession(termSessionId: tsid)
                return true
            }

            if app == .terminal, jumpToTerminalWindow(session: session) {
                log("matched Terminal window")
                return true
            }

            if let tsid = session.termSessionId, !tsid.isEmpty,
               (tsid.lowercased().contains("tmux") || session.terminal.lowercased().contains("tmux")) {
                log("jumping to tmux session app=\(app.rawValue) tsid=\(tsid)")
                jumpToTmuxSession(session: session, app: app)
                return true
            }

            if app == .wezTerm, jumpToWezTerm(session: session) {
                log("matched WezTerm session")
                return true
            }

            if app == .kitty, jumpToKittyWindow(session: session) {
                log("matched Kitty window via remote control")
                return true
            }

            if app.isVSCodeFamily && !session.workingDirectory.isEmpty {
                if raiseMatchingWindow(session: session, app: app, allowFallbackActivate: false) {
                    log("matched VSCode-family window app=\(app.rawValue)")
                    return true
                }
                if app == .cursor, raiseAllWindows(bundleId: app.bundleId) {
                    log("raised all windows for app=\(app.rawValue)")
                    return true
                }
                if openWorkspaceWindow(app: app, workingDirectory: session.workingDirectory) {
                    log("opened workspace window app=\(app.rawValue)")
                    return true
                }
                log("activating app fallback app=\(app.rawValue)")
                activateApp(app)
                return true
            } else {
                if raiseMatchingWindow(session: session, app: app) {
                    log("matched window app=\(app.rawValue)")
                    return true
                }
                log("activating app fallback app=\(app.rawValue)")
                activateApp(app)
                return app != .warp
            }
        }

        if session.agentType == .openCode {
            log("openCode has no resolvable target app; skip jump")
            return false
        }

        log("fallback activate by agent name agent=\(session.agentType.rawValue)")
        activateByAgentName(session.agentType)
        return true
    }

    static func resolveTargetApp(for session: AgentSession) -> TerminalApp? {
        let appFromTerminal: TerminalApp? = session.terminal.isEmpty ? nil : TerminalApp.detect(from: session.terminal)
        let appFromAgent = TerminalApp.forAgent(session.agentType)

        if session.agentType == .cursor {
            if let appFromTerminal {
                if appFromTerminal == .cursor || appFromTerminal == .windsurf {
                    return appFromTerminal
                }
                if appFromTerminal == .terminal {
                    if let termSessionId = session.termSessionId, !termSessionId.isEmpty {
                        return .terminal
                    }
                    if session.windowNumber != nil {
                        return .terminal
                    }
                    return .cursor
                }
                if appFromTerminal.isVSCodeFamily {
                    return .cursor
                }
                return appFromTerminal
            }
            return .cursor
        }

        if session.agentType == .trae {
            if let appFromTerminal, appFromTerminal == .trae || appFromTerminal == .traeCn {
                return appFromTerminal
            }
            return .trae
        }

        if appFromTerminal == .terminal {
            return appFromAgent ?? .terminal
        }

        return appFromTerminal ?? appFromAgent
    }

    private static func jumpToITermSession(termSessionId: String) {
        let matchProp: String
        let matchValue: String

        if termSessionId.hasPrefix("iterm:") {
            matchProp = "unique ID"
            let fullId = String(termSessionId.dropFirst(6))
            if let colonIdx = fullId.firstIndex(of: ":") {
                matchValue = String(fullId[fullId.index(after: colonIdx)...])
            } else {
                matchValue = fullId
            }
        } else if termSessionId.hasPrefix("tty:") {
            matchProp = "tty"
            matchValue = String(termSessionId.dropFirst(4))
        } else {
            matchProp = "unique ID"
            matchValue = termSessionId
        }

        let script = """
        tell application "iTerm2"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        if \(matchProp) of aSession is "\(matchValue)" then
                            select aTab
                            set index of aWindow to 1
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end repeat
            activate
        end tell
        """
        runAppleScript(script)
    }

    private static func jumpToTerminalWindow(session: AgentSession) -> Bool {
        let folderName = (session.workingDirectory as NSString).lastPathComponent
        let escapedFolder = folderName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let hasWindowId = session.windowNumber != nil
        guard hasWindowId || !folderName.isEmpty else { return false }

        let commands: [String] = {
            if let wid = session.windowNumber {
                return [
                    "repeat with w in windows",
                    "if id of w is \(wid) then",
                    "set index of w to 1",
                    "activate",
                    "return true",
                    "end if",
                    "end repeat"
                ]
            }
            return [
                "repeat with w in windows",
                "repeat with t in tabs of w",
                "set tn to custom title of t",
                "if tn is missing value then set tn to \"\"",
                "set tname to (tn as text)",
                "if tname contains \"\(escapedFolder)\" then",
                "set selected tab of w to t",
                "set index of w to 1",
                "activate",
                "return true",
                "end if",
                "end repeat",
                "end repeat"
            ]
        }()

        let script = """
        tell application \"Terminal\"
            \(commands.joined(separator: "\n            "))
            return false
        end tell
        """

        return runAppleScriptBool(script)
    }

    private static func raiseMatchingWindow(session: AgentSession, app: TerminalApp, allowFallbackActivate: Bool = true) -> Bool {
        let runningApps = app.bundleIds
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        guard let runningApp = runningApps.first else {
            return false
        }

        let appElement = AXUIElementCreateApplication(runningApp.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, "AXWindows" as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            if allowFallbackActivate {
                runningApp.activate()
                return true
            }
            return false
        }

        if let targetWid = session.windowNumber {
            if let matchedWindow = matchAXWindowByWindowNumber(windows: windows, windowNumber: targetWid)
                ?? matchAXWindowByWindowTitle(windows: windows, title: windowTitle(for: targetWid)) {
                AXUIElementPerformAction(matchedWindow, "AXRaise" as CFString)
                runningApp.activate()
                return true
            }
        }

        let folderName = (session.workingDirectory as NSString).lastPathComponent
        if !folderName.isEmpty {
            for window in windows {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, "AXTitle" as CFString, &titleRef) == .success,
                   let title = titleRef as? String,
                   title.localizedCaseInsensitiveContains(folderName) {
                    AXUIElementPerformAction(window, "AXRaise" as CFString)
                    runningApp.activate()
                    return true
                }
            }
        }

        if allowFallbackActivate {
            runningApp.activate()
            return true
        }
        return false
    }

    private static func raiseAllWindows(bundleId: String) -> Bool {
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            return false
        }

        let appElement = AXUIElementCreateApplication(runningApp.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, "AXWindows" as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            runningApp.activate()
            return true
        }

        for window in windows {
            AXUIElementPerformAction(window, "AXRaise" as CFString)
        }
        runningApp.activate()
        return true
    }

    private static func raiseAllCursorWindows(preferredBundleId: String) -> Bool {
        var bundleIds = [preferredBundleId]
        if !bundleIds.contains(TerminalApp.cursor.bundleId) {
            bundleIds.append(TerminalApp.cursor.bundleId)
        }
        if !bundleIds.contains(TerminalApp.windsurf.bundleId) {
            bundleIds.append(TerminalApp.windsurf.bundleId)
        }

        var raised = false
        for bundleId in bundleIds {
            if raiseAllWindows(bundleId: bundleId) {
                raised = true
            }
        }
        return raised
    }

    // MARK: - tmux

    private static func jumpToTmuxSession(session: AgentSession, app: TerminalApp) {
        let dir = session.workingDirectory
        guard !dir.isEmpty else { return }

        let script: String
        switch app {
        case .iterm2:
            script = """
            tell application "iTerm2"
                activate
                tell current window
                    repeat with aTab in tabs
                        repeat with aSession in sessions of aTab
                            if name of aSession contains "\(dir)" then
                                select aTab
                                select aSession
                                return
                            end if
                        end repeat
                    end repeat
                end tell
            end tell
            """
        default:
            activateApp(app)
            return
        }
        runAppleScript(script)
    }

    private static func jumpToWezTerm(session: AgentSession) -> Bool {
        guard !session.workingDirectory.isEmpty else { return false }
        let dir = session.workingDirectory

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["wezterm", "cli", "list", "--format", "json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for item in json {
                    if let cwd = item["cwd"] as? String,
                       (cwd.hasPrefix(dir) || dir.hasPrefix(cwd)) {
                        if let tabId = item["tab_id"] as? Int {
                            let activate = Process()
                            activate.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                            activate.arguments = ["wezterm", "cli", "activate-tab", "--tab-id", String(tabId)]
                            activate.standardOutput = FileHandle.nullDevice
                            activate.standardError = FileHandle.nullDevice
                            try? activate.run()
                            return true
                        }
                    }
                }
            }
        } catch {
            // 回退到 AXUIElement 由调用方处理
        }
        return false
    }

    private static func jumpToKittyWindow(session: AgentSession) -> Bool {
        guard !session.workingDirectory.isEmpty else { return false }
        let dir = session.workingDirectory
        let folderName = (dir as NSString).lastPathComponent

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["kitty", "@", "ls"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for tab in json {
                    if let windows = tab["windows"] as? [[String: Any]] {
                        for window in windows {
                            if let title = window["title"] as? String,
                               title.localizedCaseInsensitiveContains(folderName) {
                                if let id = window["id"] as? Int {
                                    let focus = Process()
                                    focus.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                                    focus.arguments = ["kitty", "@", "focus-window", "--match", "id:\(id)"]
                                    focus.standardOutput = FileHandle.nullDevice
                                    focus.standardError = FileHandle.nullDevice
                                    try? focus.run()
                                    return true
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            // 回退到 AXUIElement 由调用方处理
        }
        return false
    }

    static func captureFrontWindowNumber(for agentType: AgentType, terminal: String) -> Int? {
        let targetApp: TerminalApp?
        if let app = TerminalApp.forAgent(agentType) {
            targetApp = app
        } else if !terminal.isEmpty, let app = TerminalApp.detect(from: terminal) {
            targetApp = app
        } else {
            targetApp = nil
        }

        guard let targetApp else { return nil }
        let runningApps = targetApp.bundleIds
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        guard let app = runningApps.first else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowRef) == .success,
           let focusedWindowRef {
            let focusedWindow = unsafeBitCast(focusedWindowRef, to: AXUIElement.self)
            var numberRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(focusedWindow, "_AXWindowNumber" as CFString, &numberRef) == .success,
               let windowNumber = numberRef as? Int {
                return windowNumber
            }
        }

        let opts = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid == app.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let wid = info[kCGWindowNumber as String] as? Int else { continue }
            return wid
        }
        return nil
    }

    // MARK: - Helpers

    private static func matchAXWindowByWindowNumber(windows: [AXUIElement], windowNumber: Int) -> AXUIElement? {
        for window in windows {
            var numberRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, "_AXWindowNumber" as CFString, &numberRef) == .success,
               let num = numberRef as? Int,
               num == windowNumber {
                return window
            }
        }
        return nil
    }

    private static func matchAXWindowByWindowTitle(windows: [AXUIElement], title: String?) -> AXUIElement? {
        guard let title, !title.isEmpty else { return nil }
        for window in windows {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, "AXTitle" as CFString, &titleRef) == .success,
               let axTitle = titleRef as? String,
               (axTitle == title || axTitle.localizedCaseInsensitiveContains(title) || title.localizedCaseInsensitiveContains(axTitle)) {
                return window
            }
        }
        return nil
    }

    private static func windowTitle(for windowNumber: Int) -> String? {
        let options = CGWindowListOption([.optionAll])
        guard let list = CGWindowListCopyWindowInfo(options, CGWindowID(windowNumber)) as? [[String: Any]],
              let info = list.first else {
            return nil
        }
        return info[kCGWindowName as String] as? String
    }

    private static func activateApp(_ app: TerminalApp) {
        let runningApps = app.bundleIds
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        if let running = runningApps.first {
            running.activate(options: [.activateAllWindows])
            return
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func openWorkspaceWindow(app: TerminalApp, workingDirectory: String) -> Bool {
        let dir = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return false }

        let commandCandidates: [[String]]
        switch app {
        case .vscode:
            commandCandidates = [["code", "-r"]]
        case .cursor:
            commandCandidates = [["cursor", "-r"]]
        case .windsurf:
            commandCandidates = [["windsurf", "-r"]]
        case .trae, .traeCn:
            commandCandidates = [["trae", "-r"], ["trae-cn", "-r"], ["traecn", "-r"]]
        default:
            return false
        }

        for candidate in commandCandidates {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = candidate + [dir]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                return true
            } catch {
                continue
            }
        }
        return false
    }

    private static func activateByAgentName(_ agentType: AgentType) {
        let name = agentType.displayName.lowercased()
        let apps = NSWorkspace.shared.runningApplications
        if let app = apps.first(where: {
            guard let appName = $0.localizedName?.lowercased() else { return false }
            return appName.contains(name) || name.contains(appName)
        }) {
            app.activate()
        }
    }

    private static func runAppleScriptBool(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if error != nil { return false }
        return output.booleanValue
    }

    private static func runAppleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runAppleScriptBool(source)
        }
    }

    private static func log(_ message: String) {
        print("[JumpDebug] \(message)")
    }
}
