import AppKit
import Foundation
import DIShared

enum TerminalApp: String, CaseIterable, Sendable {
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
    case traeWorkCn = "TRAE SOLO CN"
    case codex = "Codex"
    case workBuddy = "WorkBuddy"
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
        case .traeWorkCn: ["cn.trae.solo.app"]
        case .codex: ["com.openai.codex"]
        case .workBuddy: ["com.tencent.workbuddy.mac"]
        case .wezTerm: ["org.wezfurlong.wezterm"]
        case .zellij: ["no.bundle.id.zellij"] // multiplexer, runs inside another terminal
        case .antigravity: ["com.antigravity.Antigravity"] // Antigravity IDE terminal
        case .hyper: ["co.zeit.hyper"]
        case .zed: ["dev.zed.Zed", "dev.zed.Zed-Preview"]
        case .cmux: [] // cmux runs inside another terminal — no macOS bundle
        case .conductor: [] // conductor runs inside another terminal — no macOS bundle
        case .termius: ["com.termius.mac"]
        }
    }

    var bundleId: String? {
        bundleIds.first
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
        case .traeWorkCn: ["trae work cn", "trae solo cn", "trae-work-cn", "trae-solo-cn", "traeworkcn", "traesolocn", "trae aicc", "trae-aicc"]
        case .codex: ["codex"]
        case .workBuddy: ["workbuddy", "work-buddy"]
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
        case .vscode, .cursor, .windsurf, .trae, .traeCn, .traeWorkCn, .antigravity:
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
        case .workBuddy: return .workBuddy
        case .copilot: return .vscode
        case .windsurf: return .windsurf
        case .zed: return .zed
        // CLI 工具，或没有对应的 TerminalApp 条目：跳转目标改由会话上报的 terminal 决定。
        // 不用 default，新增 AgentType 时编译器会强制在这里表态。
        case .claudeCode, .geminiCli, .openCode, .droid, .qoder, .codeBuddy,
             .qwen, .kimi, .deepseek, .kiro, .amp, .pi, .hermes, .glm, .aider,
             .devin, .amazonQ, .tabnine, .cody, .cline, .`continue`, .copilotCli,
             .rooCode, .pearai, .jetbrainsAi:
            return nil
        }
    }
}

enum SessionJumpResult: Equatable {
    /// 客户端已接收带会话 ID 的链接；不将系统回调表述为已验证客户端渲染。
    case conversationRequested
    case terminalFocused
    case unavailable
    case missingIdentity
    case applicationUnavailable
    case automationDenied
    case targetNotFound
    case commandFailed

    var accepted: Bool { self == .conversationRequested || self == .terminalFocused }

    var message: String { L10n.sessionJumpMessage(self) }
}

enum SessionJumpPlan: Equatable {
    case conversation(TerminalApp, URL)
    case terminal(TerminalSessionTarget)
    case failure(SessionJumpResult)
}

enum TerminalJumpManager {
    static let controlledPATH = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

    static func appleScriptQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    struct SessionSnapshot: Sendable {
        let id: String
        let agentType: AgentType
        let terminal: String
        let workingDirectory: String
        let termSessionId: String?
        let windowNumber: Int?
    }

    static func snapshot(_ session: AgentSession) -> SessionSnapshot {
        SessionSnapshot(id: session.id, agentType: session.agentType, terminal: session.terminal,
                        workingDirectory: session.workingDirectory, termSessionId: session.termSessionId,
                        windowNumber: session.windowNumber)
    }

    static func plan(for snap: SessionSnapshot) -> SessionJumpPlan {
        guard let app = resolveTargetApp(snap: snap) else { return .failure(.unavailable) }
        let terminalID = snap.termSessionId ?? ""
        if terminalID.hasPrefix("tmux:") { return .failure(.unavailable) }
        switch app {
        case .iterm2:
            guard !terminalID.hasPrefix("tmux:"),
                  TerminalSessionNavigator.appleScript(for: .iTerm(id: terminalID)) != nil else { return .failure(.missingIdentity) }
            return .terminal(.iTerm(id: terminalID))
        case .terminal:
            guard TerminalSessionNavigator.appleScript(for: .appleTerminalTTY(terminalID)) != nil else { return .failure(.missingIdentity) }
            return .terminal(.appleTerminalTTY(terminalID))
        case .wezTerm:
            guard let id = paneID(terminalID, prefix: "wezterm:") else { return .failure(.missingIdentity) }
            return .terminal(.wezTermPane(id))
        case .kitty:
            guard let id = paneID(terminalID, prefix: "kitty:") else { return .failure(.missingIdentity) }
            return .terminal(.kittyWindow(id))
        case .codex:
            guard snap.agentType == .codex, let id = nativeID(snap.id, prefix: "codex-"),
                  UUID(uuidString: id) != nil, id.count == 36 else { return .failure(.missingIdentity) }
            return conversation(app: app, host: "threads", id: id)
        case .workBuddy:
            guard snap.agentType == .workBuddy, snap.id.hasPrefix("workbuddy-"),
                  let data = Data(base64Encoded: String(snap.id.dropFirst(10))),
                  data.base64EncodedString() == String(snap.id.dropFirst(10)),
                  let id = String(data: data, encoding: .utf8), validID(id) else { return .failure(.missingIdentity) }
            return conversation(app: app, host: "chat", id: id)
        case .cursor:
            guard snap.agentType == .cursor, let id = nativeID(snap.id, prefix: "cursor-") else { return .failure(.missingIdentity) }
            var components = URLComponents()
            components.scheme = "cursor"
            components.host = "anysphere.cursor-deeplink"
            components.path = "/agent"
            components.percentEncodedQuery = "id=" + encodedID(id)
            guard let url = components.url else { return .failure(.missingIdentity) }
            return .conversation(app, url)
        default:
            // 工作目录、窗口标题与曾经的前台窗口都不能唯一标识聊天或标签页。
            return .failure(.unavailable)
        }
    }

    private static func conversation(app: TerminalApp, host: String, id: String) -> SessionJumpPlan {
        var components = URLComponents()
        components.scheme = app == .codex ? "codex" : "workbuddy"
        components.host = host
        components.percentEncodedPath = "/" + encodedID(id)
        guard let url = components.url else { return .failure(.missingIdentity) }
        return .conversation(app, url)
    }

    private static func validID(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && id.utf8.count <= 4096
            && !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func nativeID(_ value: String, prefix: String) -> String? {
        guard value.hasPrefix(prefix) else { return nil }
        let id = String(value.dropFirst(prefix.count))
        guard validID(id), !(id.count <= 16 && id.allSatisfy(\.isHexDigit)) else { return nil }
        return id
    }

    private static func encodedID(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
    }

    private static func paneID(_ value: String, prefix: String) -> Int? {
        guard value.hasPrefix(prefix) else { return nil }
        let suffix = value.dropFirst(prefix.count)
        guard !suffix.isEmpty, suffix.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(suffix), number >= 0 else { return nil }
        return number
    }

    /// 原生链接明确指定应用与会话，禁止退化成激活应用、工作区或任意窗口。
    static func jump(to session: AgentSession, completion: @escaping (SessionJumpResult) -> Void = { _ in }) {
        let route = plan(for: snapshot(session))
        switch route {
        case .failure(let result): completion(result)
        case .conversation(let app, let url):
            guard let bundleID = app.bundleId,
                  let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                  Bundle(url: appURL)?.bundleIdentifier == bundleID else {
                completion(.applicationUnavailable); return
            }
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { application, error in
                DispatchQueue.main.async {
                    completion(error == nil && application?.bundleIdentifier == bundleID ? .conversationRequested : .applicationUnavailable)
                }
            }
        case .terminal(let target):
            DispatchQueue.global(qos: .userInitiated).async {
                let result: SessionJumpResult
                switch TerminalSessionNavigator.navigate(target) {
                case .success: result = .terminalFocused
                case .targetNotFound: result = .targetNotFound
                case .automationDenied: result = .automationDenied
                case .commandFailed: result = .commandFailed
                }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// 保留初始化注入接口；hook 到达时的前台窗口并不能证明会话来自该窗口。
    static func captureFrontWindowNumber(for agentType: AgentType, terminal: String) -> Int? { nil }

    static func resolveTargetApp(snap: SessionSnapshot) -> TerminalApp? {
        let appFromTerminal: TerminalApp? = snap.terminal.isEmpty ? nil : TerminalApp.detect(from: snap.terminal)
        let appFromAgent = TerminalApp.forAgent(snap.agentType)

        guard snap.terminal.isEmpty || appFromTerminal != nil else { return nil }

        if snap.agentType == .cursor || snap.agentType == .windsurf {
            let defaultApp: TerminalApp = snap.agentType == .windsurf ? .windsurf : .cursor
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
                    return defaultApp
                }
                if appFromTerminal.isVSCodeFamily {
                    return defaultApp
                }
                return appFromTerminal
            }
            return defaultApp
        }

        if snap.agentType == .trae {
            if let appFromTerminal, !appFromTerminal.isVSCodeFamily, appFromTerminal != .terminal {
                return appFromTerminal
            }
            if let appFromTerminal, appFromTerminal == .trae || appFromTerminal == .traeCn || appFromTerminal == .traeWorkCn {
                return appFromTerminal
            }
            return .trae
        }

        if appFromTerminal == .terminal {
            if let id = snap.termSessionId, !id.isEmpty { return .terminal }
            return appFromAgent ?? .terminal
        }

        return appFromTerminal ?? appFromAgent
    }
}
