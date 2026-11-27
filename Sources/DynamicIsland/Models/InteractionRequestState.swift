import Foundation
import Observation

enum InteractionKind: String, Sendable {
    case permission, question, plan
}

enum InteractionDecision: Sendable {
    case permission(Bool)
    /// 带原因的拒绝；只用于支持 PermissionRequest `decision.message` 的来源。
    /// 它不是“交回原生”，客户端必须真正拒绝。
    case permissionDenial(String)
    /// 修改工具参数后批准；只用于支持 PermissionRequest `decision.updatedInput` 的来源。
    case permissionEdited(String)
    /// 拒绝并停止本轮；只用于支持 PermissionRequest `decision.interrupt` 的来源。
    case permissionInterrupted(String?)
    /// 允许并为本次会话写入精确规则；只用于支持 `decision.updatedPermissions` 的来源。
    case permissionRemembered(String)
    /// 不替用户裁决，把请求交回客户端原生确认。Claude 兼容 hook 对应空输出，
    /// Cursor 对应 `{"permission":"ask"}`；绝不能降级成默认批准或默认拒绝。
    case permissionDeferred
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
