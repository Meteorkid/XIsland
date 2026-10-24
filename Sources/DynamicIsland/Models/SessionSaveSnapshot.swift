import Foundation

struct SessionChildRevision: Sendable, Equatable {
    let eventVersion: UInt
    let chatVersion: UInt
}

struct SessionChildSnapshot: Sendable {
    var events: [UUID: ToolEvent]
    var messages: [UUID: ChatMessage]
}

struct SessionPendingChildChanges: Sendable {
    let events: [ToolEvent]
    let messages: [ChatMessage]
}

/// 跨执行器只传值；可观察会话及交互回调留在主执行器。
struct SessionSaveSnapshot: Sendable {
    let id: String
    let agentType: AgentType
    let startTime: Date
    let completedAt: Date?
    let completionNeedsReview: Bool
    let sourceNamespace: String?
    let sourceInstanceId: String?
    let nativeTaskId: String?
    let observationEndedAt: Date?
    let prompt: String
    let workingDirectory: String
    let terminal: String
    let status: SessionStatus
    let statusText: String
    let recapText: String?
    let tokenUsage: TokenUsage
    let kimiCodeApprovalObservation: KimiCodeApprovalObservation?
    let hasPendingInteraction: Bool
    let events: [ToolEvent]
    let chatHistory: [ChatMessage]
    let pendingChildChanges: SessionPendingChildChanges?
    let childRevision: SessionChildRevision

    @MainActor
    init(session: AgentSession) {
        id = session.id
        agentType = session.agentType
        startTime = session.startTime
        completedAt = session.completedAt
        completionNeedsReview = session.completionNeedsReview
        sourceNamespace = session.sourceNamespace
        sourceInstanceId = session.sourceInstanceId
        nativeTaskId = session.nativeTaskId
        observationEndedAt = session.observationEndedAt
        prompt = session.prompt
        workingDirectory = session.workingDirectory
        terminal = session.terminal
        status = session.status
        statusText = session.statusText
        recapText = session.recapText
        tokenUsage = session.tokenUsage
        kimiCodeApprovalObservation = session.kimiCodeApprovalObservation
        hasPendingInteraction = session.hasPendingInteraction
        events = session.events
        chatHistory = session.chatHistory
        pendingChildChanges = session.pendingChildChanges.map {
            SessionPendingChildChanges(events: $0.events, messages: $0.messages)
        }
        childRevision = session.childRevision
    }

    func committedChildren(previous: SessionChildSnapshot?) -> SessionChildSnapshot {
        if let changes = pendingChildChanges, var previous {
            for event in changes.events { previous.events[event.id] = event }
            for message in changes.messages { previous.messages[message.id] = message }
            return previous
        }
        return SessionChildSnapshot(
            events: Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }),
            messages: Dictionary(chatHistory.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }))
    }
}
