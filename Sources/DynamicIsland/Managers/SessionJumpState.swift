import AppKit
import Foundation
import Observation
import SwiftUI

/// 跳转结果返回前保持面板和未查看标记，旧请求不能确认新一轮结果。
@Observable @MainActor
final class SessionJumpState {
    typealias Performer = (AgentSession, @escaping (SessionJumpResult) -> Void) -> Void
    private(set) var isRunning = false
    private(set) var errorMessage: String?
    /// 非错误类反馈，例如「已粘贴，按回车发送」。
    private(set) var noticeMessage: String?
    private var generation = 0

    func request(_ session: AgentSession, manager: SessionManager,
                 perform: Performer = TerminalJumpManager.jump,
                 onAccepted: @escaping () -> Void = {}) {
        guard !isRunning else { return }
        guard let target = Self.targetSession(session, lookup: manager.sessionForNavigation) else {
            errorMessage = SessionJumpResult.missingIdentity.message
            return
        }
        isRunning = true
        errorMessage = nil
        generation += 1
        let requestGeneration = generation
        let completedAt = session.completedAt
        perform(target) { [weak self, weak session, weak manager] result in
            guard let self, self.isRunning, self.generation == requestGeneration else { return }
            self.isRunning = false
            guard result.accepted else {
                self.errorMessage = result.message
                return
            }
            if let session, let manager, manager.sessionForNavigation(session.id) === session,
               session.completedAt == completedAt {
                manager.markCompletionReviewed(sessionID: session.id)
            }
            onAccepted()
        }
    }

    func cancel() { generation += 1; isRunning = false }

    /// 「继续下一步」：复制指令 → 激活会话窗口 → 尝试自动粘贴 → 提示按回车发送。
    /// 不自动按回车：是否发送由用户决定，避免把未确认的指令直接提交给 Agent。
    func requestContinue(_ session: AgentSession, manager: SessionManager,
                         prompt: String = L10n.continueNextStep) {
        guard !isRunning else { return }
        guard let target = Self.targetSession(session, lookup: manager.sessionForNavigation) else {
            errorMessage = SessionJumpResult.missingIdentity.message
            return
        }
        isRunning = true
        errorMessage = nil
        noticeMessage = nil
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        TerminalJumpManager.jump(to: target) { [weak self] result in
            guard let self else { return }
            self.isRunning = false
            guard result.accepted else {
                self.errorMessage = result.message
                return
            }
            // 等窗口真正拿到焦点后再粘贴，否则按键会落到原来的前台应用。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if Self.pasteClipboard() {
                    self.noticeMessage = L10n.continuePasted
                } else {
                    self.noticeMessage = L10n.continueNeedsAccessibility
                    Self.openAccessibilitySettings()
                }
            }
        }
    }

    /// 需要辅助功能权限；未授权时向系统发起一次授权提示。
    private static func pasteClipboard() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    static func targetSession(_ session: AgentSession,
                              lookup: (String) -> AgentSession?) -> AgentSession? {
        var target = session
        var visited = Set<String>()
        while let parentID = target.parentSessionId {
            guard visited.insert(target.id).inserted, visited.count <= 32,
                  parentID != target.id, let parent = lookup(parentID) else { return nil }
            target = parent
        }
        return target
    }
}

struct SessionJumpFeedback: ViewModifier {
    let state: SessionJumpState

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content
            if let message = state.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("island.session-jump-error")
            }
            if let message = state.noticeMessage {
                Label(message, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.cyan)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("island.session-continue-notice")
            }
        }
        .onDisappear { state.cancel() }
    }
}
