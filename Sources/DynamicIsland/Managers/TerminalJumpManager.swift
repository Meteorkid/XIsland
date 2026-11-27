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
    /// Claude Desktop 的 Code / Cowork 标签页；不是终端，也不应该作为
    /// Claude Code CLI 的默认宿主。
    case claudeDesktop = "Claude Desktop"
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
        case .claudeDesktop: ["com.anthropic.claudefordesktop"]
        case .wezTerm: ["org.wezfurlong.wezterm"]
        case .zellij: ["no.bundle.id.zellij"] // multiplexer, runs inside another terminal
        case .antigravity: ["com.google.antigravity"] // 已核实的 App bundle：com.google.antigravity
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
        case .claudeDesktop: ["claude desktop", "claude.app"]
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
        case .antigravity: return .antigravity
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
             .rooCode, .pearai, .jetbrainsAi, .doubaoWork, .kiloCode:
            // 豆包工作与 Kilo 没有已核实的会话级跳转链接，跳转目标交给会话上报的 terminal。
            return nil
        }
    }
}

enum SessionJumpResult: Equatable {
    /// 客户端接收了带会话 ID 的链接；不将系统回调表述为已验证客户端渲染。
    case conversationRequested
    /// IDE 伴生扩展已接收终端聚焦请求；扩展是否真的匹配到终端由扩展侧决定。
    case companionRequested
    case terminalFocused
    /// 客户端没有会话级链接：已切换到该客户端并打开会话所在目录。
    case projectOpened
    /// 客户端已在运行：只前置了窗口，但没有打开目录，也未唯一定位会话行。
    case applicationRaised
    /// 无 deeplink，但通过辅助功能在界面里定位并点击了会话条目。
    case conversationFocused
    case unavailable
    case missingIdentity
    case applicationUnavailable
    case automationDenied
    /// AX 兜底需要“辅助功能”权限；与 AppleScript 的“自动化”权限不是同一项。
    case accessibilityDenied
    case targetNotFound
    /// AX 兜底找到多个同名会话行/标签，刻意不点击任何一个。
    case conversationAmbiguous
    case commandFailed

    var accepted: Bool {
        self == .conversationRequested || self == .companionRequested || self == .terminalFocused
            || self == .projectOpened || self == .applicationRaised || self == .conversationFocused
    }

    var message: String { L10n.sessionJumpMessage(self) }
}

enum SessionJumpPlan: Equatable {
    case conversation(TerminalApp, URL)
    /// IDE 伴生扩展：只请求它显示已存在的终端/标签，不新建、不写内容。
    case companion(TerminalApp, URL)
    case terminal(TerminalSessionTarget)
    /// 无会话级 deeplink 的客户端：打开项目目录并前置应用；title 用于尝试在界面里定位会话。
    case project(TerminalApp, URL, String)
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
        let title: String
        let hostTermSessionId: String?
        let processId: Int32?
        let tmuxSocketPath: String?
        let status: SessionStatus

        init(id: String, agentType: AgentType, terminal: String, workingDirectory: String,
             termSessionId: String?, windowNumber: Int?, title: String,
             hostTermSessionId: String? = nil, processId: Int32? = nil,
             tmuxSocketPath: String? = nil, status: SessionStatus = .idle) {
            self.id = id
            self.agentType = agentType
            self.terminal = terminal
            self.workingDirectory = workingDirectory
            self.termSessionId = termSessionId
            self.windowNumber = windowNumber
            self.title = title
            self.hostTermSessionId = hostTermSessionId
            self.processId = processId
            self.tmuxSocketPath = tmuxSocketPath
            self.status = status
        }
    }

    /// Codex 的 deeplink 只对本机存在的 thread 有效；索引缺失时放行，交给客户端判断。
    /// 也遵循官方 `CODEX_HOME`，否则自定义配置目录的用户会被错误降级为打开项目。
    private static func codexThreadExists(_ id: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let override = (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = override.hasPrefix("/") ? URL(fileURLWithPath: override) : home.appendingPathComponent(".codex")
        let url = directory.appendingPathComponent("session_index.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return true }
        return text.contains(id)
    }

    static func snapshot(_ session: AgentSession) -> SessionSnapshot {
        SessionSnapshot(id: session.id, agentType: session.agentType, terminal: session.terminal,
                        workingDirectory: session.workingDirectory, termSessionId: session.termSessionId,
                        windowNumber: session.windowNumber, title: session.displayTitle,
                        hostTermSessionId: session.hostTermSessionId, processId: session.processId,
                        tmuxSocketPath: session.tmuxSocketPath, status: session.status)
    }

    static func plan(for snap: SessionSnapshot) -> SessionJumpPlan {
        let app = resolveTargetApp(snap: snap)
        let terminalID = snap.termSessionId ?? ""
        let cwd = snap.workingDirectory

        // tmux 的 `termSessionId` 是 pane，不是外层标签页；先选 pane，再按
        // 已捕获的宿主身份（或运行时 client_tty）聚焦外层标签页。tmux 会把
        // TERM_PROGRAM 改成 "tmux"，因此这里不要求提前解析出宿主应用。
        if terminalID.hasPrefix("tmux:") {
            let pane = String(terminalID.dropFirst("tmux:".count))
            guard validTmuxPane(pane), !cwd.isEmpty || snap.hostTermSessionId != nil else {
                return .failure(.missingIdentity)
            }
            let host = app.flatMap { hostTarget(app: $0, identity: snap.hostTermSessionId, cwd: cwd) }
            let socketPath = snap.tmuxSocketPath.flatMap(validTmuxSocketPath)
            return .terminal(.tmux(pane: pane, socketPath: socketPath, host: host, app: app, cwd: cwd))
        }

        guard let app else { return .failure(.unavailable) }
        switch app {
        case .iterm2:
            let candidates = [snap.hostTermSessionId, terminalID].compactMap { $0 }
            // The host identity can be a Terminal.app `ts:` token even when the
            // inner session is iTerm; only an iTerm/tty token belongs here.
            let identity = candidates.first {
                $0.hasPrefix("iterm:") || $0.hasPrefix("tty:")
            } ?? snap.hostTermSessionId ?? terminalID
            guard TerminalSessionNavigator.appleScript(for: .iTerm(id: identity)) != nil else {
                return .failure(.missingIdentity)
            }
            return .terminal(.iTerm(id: identity))
        case .terminal:
            let candidates = [snap.hostTermSessionId, terminalID].compactMap { $0 }
            // `TERM_SESSION_ID` is a Terminal session token, not the tab's tty;
            // prefer any candidate that actually maps to a tty.
            let identity = candidates.first {
                TerminalSessionNavigator.ttyPath(from: $0) != nil
            } ?? snap.hostTermSessionId ?? terminalID
            guard TerminalSessionNavigator.appleScript(for: .appleTerminalTTY(identity)) != nil else {
                return .failure(.missingIdentity)
            }
            return .terminal(.appleTerminalTTY(identity))
        case .wezTerm:
            guard let id = paneID(terminalID, prefix: "wezterm:") else { return .failure(.missingIdentity) }
            return .terminal(.wezTermPane(id))
        case .kitty:
            guard let id = paneID(terminalID, prefix: "kitty:") else { return .failure(.missingIdentity) }
            return .terminal(.kittyWindow(id))
        case .ghostty:
            let identity: String? = snap.hostTermSessionId ?? (terminalID.isEmpty ? nil : terminalID)
            let tty = identity.flatMap(ghosttyTTY)
            guard tty != nil || !cwd.isEmpty else { return .failure(.missingIdentity) }
            return .terminal(.ghostty(tty: tty, cwd: cwd))
        case .warp:
            guard !cwd.isEmpty else { return .failure(.missingIdentity) }
            return .terminal(.warp(cwd: cwd))
        case .codex:
            guard snap.agentType == .codex, let id = nativeID(snap.id, prefix: "codex-"),
                  UUID(uuidString: id) != nil, id.count == 36 else { return .failure(.missingIdentity) }
            // codex://threads/<id> 只对本机存在的 thread 有效，否则 ChatGPT 会显示
            // 「Chat unavailable on this computer」。先用本地索引校验，再决定是否跳转。
            guard codexThreadExists(id) else {
                if !snap.workingDirectory.isEmpty {
                    return .project(.codex, URL(fileURLWithPath: snap.workingDirectory), snap.title)
                }
                return .failure(.targetNotFound)
            }
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
        case .claudeDesktop:
            // Claude 桌面 App 同时承载 Code 与 Cowork。hook 拿到的是 CLI
            // session id，必须用应用自己的 local_* 元数据换成桌面标签 id；
            // 找不到映射就只打开项目，绝不把 CLI id 直接塞进 claude://。
            guard snap.agentType == .claudeCode,
                  let native = nativeID(snap.id, prefix: "claude-"),
                  let match = ClaudeDesktopSessionIndex().match(cliSessionID: native),
                  let url = ClaudeDesktopSessionIndex.deepLink(for: match) else {
                guard !cwd.isEmpty else { return .failure(.missingIdentity) }
                return .project(app, URL(fileURLWithPath: cwd), snap.title)
            }
            return .conversation(app, url)
        case .vscode:
            let tty = TerminalSessionNavigator.ttyPath(from: terminalID)
            // 扩展聊天页由 Electron 宿主触发 hook，没有控制 TTY；集成终端
            // 则有 P0 解析出的 tty。前者用官方会话恢复链接，后者用伴生扩展
            // 只聚焦那个已存在的终端，避免把“聚焦终端”误报成“打开会话”。
            // 上游 open?session= 对“已打开且忙碌”的会话会新建空白对话
            // （anthropics/claude-code#65542），所以只在已完成状态使用；
            // 活动/等待中的会话继续交给项目级打开 + AX 行定位。
            if snap.agentType == .claudeCode, tty == nil, snap.status == .completed,
               VSCodeHostRoutes.isClaudeCodeExtensionInstalled(),
               let native = nativeID(snap.id, prefix: "claude-"),
               let url = VSCodeHostRoutes.claudeCodeSessionURL(sessionID: native) {
                return .conversation(app, url)
            }
            if let tty, VSCodeHostRoutes.isCompanionInstalled(),
               let url = VSCodeHostRoutes.companionFocusURL(tty: tty, cwd: cwd) {
                return .companion(app, url)
            }
            guard !cwd.isEmpty else { return .failure(.missingIdentity) }
            return .project(app, URL(fileURLWithPath: cwd), snap.title)
        case .trae, .traeCn, .traeWorkCn, .windsurf, .zed, .antigravity:
            // 这些 IDE 只注册登录/文件 scheme，没有会话级 deeplink，也没有可脚本化的窗口定位。
            // 退化为打开会话所在目录并前置客户端，由用户在聊天列表中继续。
            guard !cwd.isEmpty else { return .failure(.missingIdentity) }
            return .project(app, URL(fileURLWithPath: cwd), snap.title)
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

    private static func hostTarget(app: TerminalApp, identity: String?, cwd: String) -> TerminalSessionTarget? {
        guard let identity, !identity.isEmpty else { return nil }
        return TerminalSessionNavigator.target(for: app, identifier: identity, cwd: cwd)
    }

    private static func ghosttyTTY(_ value: String) -> String? {
        TerminalSessionNavigator.ttyPath(from: value)
    }

    private static func validTmuxSocketPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.isEmpty, path.utf8.count <= 1024,
              !path.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
              }) else { return nil }
        return path
    }

    private static func validTmuxPane(_ pane: String) -> Bool {
        guard pane.hasPrefix("%") else { return false }
        let digits = pane.dropFirst()
        return !digits.isEmpty && digits.utf8.allSatisfy({ (48...57).contains($0) })
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
        case .companion(let app, let url):
            guard let bundleID = app.bundleId,
                  let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                  Bundle(url: appURL)?.bundleIdentifier == bundleID else {
                completion(.applicationUnavailable); return
            }
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { application, error in
                DispatchQueue.main.async {
                    completion(error == nil && application?.bundleIdentifier == bundleID ? .companionRequested : .applicationUnavailable)
                }
            }
        case .project(let app, let url, let title):
            guard let bundleID = app.bundleId,
                  let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                completion(.applicationUnavailable); return
            }
            // 客户端已运行时只前置：不要传 .activateAllWindows，它会把窗口整体提到当前 Space，
            // 表现为“窗口被搬到当前位置”。空选项交给系统切换到该应用窗口所在的桌面。
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
               !running.isTerminated {
                running.activate(options: [])
                // 进一步尝试在界面里点开对应会话；Electron 客户端可能在前置后
                // 才把侧栏行挂进 AX 树，所以在 notFound 时短暂重试两次。歧义
                // 不重试：同名行出现多次时绝不能靠时间差点中其中一个。
                func focusAttempt(_ attempt: Int) {
                    let outcome = AXConversationFocus.focus(title: title, in: running)
                    switch outcome {
                    case .notFound where attempt < 2:
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            focusAttempt(attempt + 1)
                        }
                    case .focused:
                        completion(.conversationFocused)
                    case .permissionDenied:
                        completion(.accessibilityDenied)
                    case .ambiguous:
                        completion(.conversationAmbiguous)
                    case .notFound, .notActionable:
                        completion(.applicationRaised)
                    }
                }
                focusAttempt(0)
                return
            }
            NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration()) { application, error in
                DispatchQueue.main.async {
                    completion(error == nil && application != nil ? .projectOpened : .applicationUnavailable)
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

    static func hostApp(from identity: String?) -> TerminalApp? {
        guard let identity else { return nil }
        if identity.hasPrefix("iterm:") { return .iterm2 }
        if identity.hasPrefix("wezterm:") { return .wezTerm }
        if identity.hasPrefix("kitty:") { return .kitty }
        if identity.hasPrefix("ts:") || identity.hasPrefix("tty:") { return .terminal }
        return nil
    }

    static func resolveTargetApp(snap: SessionSnapshot) -> TerminalApp? {
        let appFromTerminal: TerminalApp? = snap.terminal.isEmpty
            ? hostApp(from: snap.hostTermSessionId)
            : TerminalApp.detect(from: snap.terminal)
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
