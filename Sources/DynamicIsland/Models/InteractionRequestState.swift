import Foundation
import Observation

enum InteractionKind: String, Sendable {
    case permission, question, plan
}

enum InteractionDecision: Sendable {
    case permission(Bool)
    case question(String)
    case questionSelections([String])
    case plan(Bool, String?)
}

typealias InteractionDelivery = @Sendable (InteractionDecision) async -> Bool

/// 一次请求的展示和发送状态；请求被替代后不会把草稿或结果带到新请求。
@Observable
final class InteractionRequestState {
    enum Phase { case pending, sending, sent, failed }
    var phase: Phase = .pending
    var isExpanded = false
    var draftFeedback = ""
    var draftAnswer = ""
    var selectedAnswers: Set<String> = []
    var canSubmit: Bool { phase == .pending }
}

struct InteractionFocus: Equatable {
    let sessionID: String
    let kind: InteractionKind
    let requestID: UUID
}
