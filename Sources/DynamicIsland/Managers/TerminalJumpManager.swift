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
    /// 主线程快照，避免后台线程读取 @Observable 对象产生数据竞争
    struct SessionSnapshot {
        let id: String
        let agentType: AgentType
        let terminal: String
        let workingDirectory: String
        let termSessionId: String?
        let windowNumber: Int?
    }

    /// 点击跳转：主线程快照数据，阻塞操作放到 userInitiated 后台线程
    static func jump(to session: AgentSession) {
        // 在主线程快照所有需要的属性
        let snap = SessionSnapshot(
            id: session.id,
            agentType: session.agentType,
            terminal: session.terminal,
            workingDirectory: session.workingDirectory,
            termSessionId: session.termSessionId,
            windowNumber: session.windowNumber
        )
        log("jump called: agent=\(snap.agentType.rawValue) terminal=\(snap.terminal) cwd=\(snap.workingDirectory)")
        DispatchQueue.global(qos: .userInitiated).async {
            performJump(snap: snap)
        }
    }

    private static func performJump(snap: SessionSnapshot) {
        let targetApp = resolveTargetApp(snap: snap)
        log("performJump: id=\(snap.id) agent=\(snap.agentType.rawValue) terminal=\(snap.terminal) cwd=\(snap.workingDirectory) tsid=\(snap.termSessionId ?? "nil") wid=\(snap.windowNumber.map(String.init) ?? "nil") target=\(targetApp?.rawValue ?? "nil")")

        if snap.agentType == .cursor {
            let preferredApp = (targetApp == .windsurf) ? TerminalApp.windsurf : TerminalApp.cursor
            if raiseMatchingWindow(snap: snap, app: preferredApp, allowFallbackActivate: false) {
                log("cursor matched existing window app=\(preferredApp.rawValue)")
                return
            }
            if raiseAllCursorWindows(preferredBundleId: preferredApp.bundleId) {
                log("cursor raised all cursor-family windows")
                return
            }
            if !snap.workingDirectory.isEmpty,
               openWorkspaceWindow(app: preferredApp, workingDirectory: snap.workingDirectory) {
                log("cursor opened workspace app=\(preferredApp.rawValue)")
                return
            }
            log("cursor fallback activate app=\(preferredApp.rawValue)")
            activateApp(preferredApp)
            return
        }

        if let app = targetApp {
            if let tsid = snap.termSessionId, !tsid.isEmpty, app == .iterm2 {
                log("jumping to iTerm session id=\(tsid)")
                jumpToITermSession(termSessionId: tsid)
                return
            }

            if app == .terminal, jumpToTerminalWindow(snap: snap) {
                log("matched Terminal window")
                return
            }

            if let tsid = snap.termSessionId, !tsid.isEmpty,
               (tsid.lowercased().contains("tmux") || snap.terminal.lowercased().contains("tmux")) {
                log("jumping to tmux session app=\(app.rawValue) tsid=\(tsid)")
                jumpToTmuxSession(snap: snap, app: app)
                return
            }

            if app == .wezTerm, jumpToWezTerm(snap: snap) {
                log("matched WezTerm session")
                return
            }

            if app == .kitty, jumpToKittyWindow(snap: snap) {
                log("matched Kitty window via remote control")
                return
            }

            if app.isVSCodeFamily && !snap.workingDirectory.isEmpty {
                if raiseMatchingWindow(snap: snap, app: app, allowFallbackActivate: false) {
                    log("matched VSCode-family window app=\(app.rawValue)")
                    return
                }
                if app == .cursor, raiseAllWindows(bundleId: app.bundleId) {
                    log("raised all windows for app=\(app.rawValue)")
                    return
                }
                if openWorkspaceWindow(app: app, workingDirectory: snap.workingDirectory) {
                    log("opened workspace window app=\(app.rawValue)")
                    return
                }
                log("activating app fallback app=\(app.rawValue)")
                activateApp(app)
                return
            } else {
                if raiseMatchingWindow(snap: snap, app: app) {
                    log("matched window app=\(app.rawValue)")
                    return
                }
                log("activating app fallback app=\(app.rawValue)")
                activateApp(app)
                return
            }
        }

        if snap.agentType == .openCode {
            log("openCode has no resolvable target app; skip jump")
            return
        }

        log("fallback activate by agent name agent=\(snap.agentType.rawValue)")
        activateByAgentName(snap.agentType)
    }

    static func resolveTargetApp(snap: SessionSnapshot) -> TerminalApp? {
        let appFromTerminal: TerminalApp? = snap.terminal.isEmpty ? nil : TerminalApp.detect(from: snap.terminal)
        let appFromAgent = TerminalApp.forAgent(snap.agentType)

        if snap.agentType == .cursor {
            if let appFromTerminal {
                if appFromTerminal == .cursor || appFromTerminal == .windsurf {
                    return appFromTerminal
                }
                if appFromTerminal == .terminal {
                    if let termSessionId = snap.termSessionId, !termSessionId.isEmpty {
                        return .terminal
                    }
                    if snap.windowNumber != nil {
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

        if snap.agentType == .trae {
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
            // 格式: iterm:ITERM_SESSION_ID:UUID
            // iTerm2 的 unique ID 是 UUID 部分（如 0B0D70D0-...）
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

        // 转义 AppleScript 字符串中的双引号、反斜杠和换行符
        let escapedValue = matchValue.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        log("iTerm jump: prop=\(matchProp) value=\(escapedValue)")
        let script = """
        tell application "iTerm2"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        if \(matchProp) of aSession is "\(escapedValue)" then
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
        _ = runAppleScript(script)
    }

    private static func jumpToTerminalWindow(snap: SessionSnapshot) -> Bool {
        let folderName = (snap.workingDirectory as NSString).lastPathComponent
        let escapedFolder = folderName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let hasWindowId = snap.windowNumber != nil
        guard hasWindowId || !folderName.isEmpty else { return false }

        let commands: [String] = {
            if let wid = snap.windowNumber {
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

    private static func raiseMatchingWindow(snap: SessionSnapshot, app: TerminalApp, allowFallbackActivate: Bool = true) -> Bool {
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

        if let targetWid = snap.windowNumber {
            if let matchedWindow = matchAXWindowByWindowNumber(windows: windows, windowNumber: targetWid)
                ?? matchAXWindowByWindowTitle(windows: windows, title: windowTitle(for: targetWid)) {
                AXUIElementPerformAction(matchedWindow, "AXRaise" as CFString)
                runningApp.activate()
                return true
            }
        }

        let folderName = (snap.workingDirectory as NSString).lastPathComponent
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

    private static func jumpToTmuxSession(snap: SessionSnapshot, app: TerminalApp) {
        let dir = snap.workingDirectory
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
        _ = runAppleScript(script)
    }

    private static func jumpToWezTerm(snap: SessionSnapshot) -> Bool {
        guard !snap.workingDirectory.isEmpty else { return false }
        let dir = snap.workingDirectory

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

    private static func jumpToKittyWindow(snap: SessionSnapshot) -> Bool {
        guard !snap.workingDirectory.isEmpty else { return false }
        let dir = snap.workingDirectory
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
        log("activateApp: \(app.rawValue) bundleIds=\(app.bundleIds)")
        let runningApps = app.bundleIds
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        log("activateApp: found \(runningApps.count) running apps")
        if let running = runningApps.first {
            log("activateApp: activating \(running.localizedName ?? "unknown") pid=\(running.processIdentifier)")
            running.activate(options: [.activateAllWindows])
            return
        }

        log("activateApp: no running app found, trying to open")
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId) else {
            log("activateApp: cannot find app URL for \(app.bundleId)")
            return
        }
        log("activateApp: opening \(url.path)")
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

        // 1. 尝试直接匹配应用名
        if let app = apps.first(where: {
            guard let appName = $0.localizedName?.lowercased() else { return false }
            return appName.contains(name) || name.contains(appName)
        }) {
            log("activateByAgentName: matched app name '\(app.localizedName ?? "")'")
            app.activate(options: [.activateAllWindows])
            return
        }

        // 2. CLI 工具没有 macOS 应用——尝试找到包含该进程的终端
        if let terminalApp = findTerminalHostingAgent(agentType) {
            log("activateByAgentName: found terminal '\(terminalApp.rawValue)' hosting agent")
            if let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: terminalApp.bundleId
            ).first {
                app.activate(options: [.activateAllWindows])
                return
            }
        }

        // 3. 回退：激活最近使用的终端（排除 IDE 类）
        for terminalApp in TerminalApp.allCases where !terminalApp.bundleId.isEmpty && !terminalApp.isVSCodeFamily {
            if let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: terminalApp.bundleId
            ).first {
                log("activateByAgentName: activating terminal '\(terminalApp.rawValue)'")
                app.activate(options: [.activateAllWindows])
                return
            }
        }
    }

    /// 尝试找到运行指定 agent 进程的终端应用
    private static func findTerminalHostingAgent(_ agentType: AgentType) -> TerminalApp? {
        // 获取 agent 的进程名
        let processNames: [String]
        switch agentType {
        case .claudeCode: processNames = ["claude"]
        case .geminiCli: processNames = ["gemini"]
        case .openCode: processNames = ["opencode"]
        case .aider: processNames = ["aider"]
        case .codex: processNames = ["codex"]
        default: processNames = []
        }

        guard !processNames.isEmpty else { return nil }

        // 查找 agent 进程的 TTY
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "pid,tty,comm", "-ax"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        // 找到 agent 进程的 TTY
        var agentTTYs: Set<String> = []
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }
            let comm = String(parts[2]).lowercased()
            let tty = String(parts[1])
            if processNames.contains(where: { comm.contains($0) }) && !tty.isEmpty {
                agentTTYs.insert(tty)
            }
        }

        guard !agentTTYs.isEmpty else { return nil }
        log("findTerminalHostingAgent: agent TTYs=\(agentTTYs)")

        // 查找哪个终端应用拥有这些 TTY 的窗口
        for terminalApp in TerminalApp.allCases where !terminalApp.bundleId.isEmpty {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: terminalApp.bundleId)
            guard let app = runningApps.first else { continue }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, "AXWindows" as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }

            for window in windows {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, "AXTitle" as CFString, &titleRef) == .success,
                   let title = titleRef as? String {
                    // 窗口标题通常包含 TTY 信息
                    for tty in agentTTYs {
                        if title.contains(tty) || title.lowercased().contains(terminalApp.rawValue.lowercased()) {
                            return terminalApp
                        }
                    }
                }
            }
        }

        return nil
    }

    private static func runAppleScriptBool(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else {
            log("AppleScript: failed to create script")
            return false
        }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            log("AppleScript error: \(error)")
            return false
        }
        return output.booleanValue
    }

    private static func runAppleScript(_ source: String) -> Bool {
        // NSAppleScript 控制 GUI 应用（activate/select）需要在主线程执行
        if Thread.isMainThread {
            return runAppleScriptBool(source)
        } else {
            var result = false
            DispatchQueue.main.sync {
                result = runAppleScriptBool(source)
            }
            return result
        }
    }

    private static func log(_ message: String) {
        NSLog("[JumpDebug] \(message)")
    }
}
