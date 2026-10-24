import Foundation
import Observation
import SwiftUI

/// 跳转结果返回前保持面板和未查看标记，旧请求不能确认新一轮结果。
@Observable @MainActor
final class SessionJumpState {
    typealias Performer = (AgentSession, @escaping (SessionJumpResult) -> Void) -> Void
    private(set) var isRunning = false
    private(set) var errorMessage: String?
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
        }
        .onDisappear { state.cancel() }
    }
}
