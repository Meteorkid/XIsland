import XCTest
@testable import XIsland

/// 键盘快捷键行为的单元测试（不依赖 UI 渲染，验证通知和状态变化）
@MainActor
final class KeyboardShortcutTests {

    // MARK: - Helpers

    private func makeSessionManager() -> SessionManager {
        SessionManager()
    }

    private func makeThemeManager() -> ThemeManager {
        ThemeManager()
    }

    /// 模拟 keyEquivalentHandler 的调用逻辑
    private func simulateKeyEquivalent(
        event: NSEvent,
        sessionManager: SessionManager,
        themeManager: ThemeManager
    ) -> Bool {
        let flags = event.modifierFlags
        let chars = event.charactersIgnoringModifiers?.lowercased()
        let isCommand = flags.contains(.command)

        if isCommand, let chars = chars {
            switch chars {
            case "e" where flags.contains(.shift):
                NotificationCenter.default.post(name: .xislandExportSession, object: nil)
                return true
            case "f":
                NotificationCenter.default.post(name: .xislandToggleSearch, object: nil)
                return true
            case "t":
                themeManager.toggleMode()
                return true
            case "[":
                navigateSession(direction: -1, sessionManager: sessionManager)
                return true
            case "]":
                navigateSession(direction: 1, sessionManager: sessionManager)
                return true
            default:
                break
            }
        }

        // Escape 键
        if chars == "\u{1b}" && sessionManager.currentIslandState == .expanded {
            NotificationCenter.default.post(name: .xislandCollapse, object: nil)
            return true
        }

        return false
    }

    private func navigateSession(direction: Int, sessionManager: SessionManager) {
        let visible = sessionManager.visibleSessions
        guard !visible.isEmpty else { return }

        if let currentId = sessionManager.selectedSessionId,
           let idx = visible.firstIndex(where: { $0.id == currentId }) {
            let next = (idx + direction + visible.count) % visible.count
            sessionManager.selectedSessionId = visible[next].id
        } else {
            sessionManager.selectedSessionId = visible[direction > 0 ? 0 : visible.count - 1].id
        }
    }

    private func makeKeyEvent(characters: String, modifierFlags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: NSPoint.zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        )!
    }

    // MARK: - Escape Collapses Expanded

    func testEscapeCollapsesExpanded() {
        let manager = makeSessionManager()
        let theme = makeThemeManager()

        manager.currentIslandState = .expanded

        var notificationReceived = false
        let token = NotificationCenter.default.addObserver(
            forName: .xislandCollapse, object: nil, queue: .main
        ) { _ in notificationReceived = true }

        let event = makeKeyEvent(characters: "\u{1b}")
        let handled = simulateKeyEquivalent(event: event, sessionManager: manager, themeManager: theme)

        XCTAssertTrue(handled, "Escape 应当被处理")
        // NotificationCenter 在同一线程同步投递
        XCTAssertTrue(notificationReceived, "应收到 collapse 通知")
        NotificationCenter.default.removeObserver(token)
    }

    // MARK: - Cmd+T Navigates Theme

    func testCmdTNavigatesTheme() {
        let manager = makeSessionManager()
        let theme = makeThemeManager()

        // 初始状态是 dark
        XCTAssertEqual(theme.mode, .dark)

        let event = makeKeyEvent(characters: "t", modifierFlags: .command)
        let handled = simulateKeyEquivalent(event: event, sessionManager: manager, themeManager: theme)

        XCTAssertTrue(handled, "Cmd+T 应当被处理")
        XCTAssertEqual(theme.mode, .light, "Cmd+T 后应切换到 light")

        // 再按一次
        _ = simulateKeyEquivalent(event: event, sessionManager: manager, themeManager: theme)
        XCTAssertEqual(theme.mode, .system, "再次 Cmd+T 后应切换到 system")

        // 再按一次回到 dark
        _ = simulateKeyEquivalent(event: event, sessionManager: manager, themeManager: theme)
        XCTAssertEqual(theme.mode, .dark, "第三次 Cmd+T 后应回到 dark")
    }

    // MARK: - Cmd+Bracket Navigation

    func testCmdBracketNavigation() {
        let manager = makeSessionManager()

        // 创建 3 个会话
        let s1 = AgentSession(id: "s1", agentType: .claudeCode, prompt: "a")
        s1.status = .active
        let s2 = AgentSession(id: "s2", agentType: .codex, prompt: "b")
        s2.status = .active
        let s3 = AgentSession(id: "s3", agentType: .cursor, prompt: "c")
        s3.status = .active

        manager.sessions = [s1, s2, s3]
        manager.selectedSessionId = "s1"

        let theme = makeThemeManager()
        let event = makeKeyEvent(characters: "]", modifierFlags: .command)
        _ = simulateKeyEquivalent(event: event, sessionManager: manager, themeManager: theme)
        XCTAssertEqual(manager.selectedSessionId, "s2", "Cmd+ 应前进到 s2")

        _ = simulateKeyEquivalent(event: event, sessionManager: manager, themeManager: theme)
        XCTAssertEqual(manager.selectedSessionId, "s3", "Cmd+ 应前进到 s3")
    }

    // MARK: - Cmd+Bracket Wraps Around

    func testCmdBracketWrapsAround() {
        let manager = makeSessionManager()

        let s1 = AgentSession(id: "s1", agentType: .claudeCode, prompt: "a")
        s1.status = .active
        let s2 = AgentSession(id: "s2", agentType: .codex, prompt: "b")
        s2.status = .active
        let s3 = AgentSession(id: "s3", agentType: .cursor, prompt: "c")
        s3.status = .active

        manager.sessions = [s1, s2, s3]
        manager.selectedSessionId = "s3"

        let theme = makeThemeManager()
        let event = makeKeyEvent(characters: "]", modifierFlags: .command)
        _ = simulateKeyEquivalent(event: event, sessionManager: manager, themeManager: theme)
        XCTAssertEqual(manager.selectedSessionId, "s1", "在最后一个会话时 Cmd+] 应循环回第一个")
    }

    // MARK: - Shift+Cmd+E Triggers Export

    func testShiftCmdETriggersExport() {
        let manager = makeSessionManager()
        let theme = makeThemeManager()

        var notificationReceived = false
        let token = NotificationCenter.default.addObserver(
            forName: .xislandExportSession, object: nil, queue: .main
        ) { _ in notificationReceived = true }

        let event = makeKeyEvent(characters: "e", modifierFlags: [.command, .shift])
        let handled = simulateKeyEquivalent(event: event, sessionManager: manager, themeManager: theme)

        XCTAssertTrue(handled, "Cmd+Shift+E 应当被处理")
        XCTAssertTrue(notificationReceived, "应收到 export 通知")
        NotificationCenter.default.removeObserver(token)
    }

    // MARK: - Cmd+F Toggles Search

    func testCmdFTogglesSearch() {
        let manager = makeSessionManager()
        let theme = makeThemeManager()

        var notificationReceived = false
        let token = NotificationCenter.default.addObserver(
            forName: .xislandToggleSearch, object: nil, queue: .main
        ) { _ in notificationReceived = true }

        let event = makeKeyEvent(characters: "f", modifierFlags: .command)
        let handled = simulateKeyEquivalent(event: event, sessionManager: manager, themeManager: theme)

        XCTAssertTrue(handled, "Cmd+F 应当被处理")
        XCTAssertTrue(notificationReceived, "应收到 search 通知")
        NotificationCenter.default.removeObserver(token)
    }
}
