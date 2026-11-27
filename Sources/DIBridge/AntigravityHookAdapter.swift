import Foundation
import DIShared

/// Antigravity App / CLI（agy）/ IDE 的原生 hooks 适配。
///
/// 事件名与字段来自官方 hooks 文档：`conversationId` 标识会话，
/// `toolCall.name` / `toolCall.args` 描述工具，`stepIdx` 是轨迹步序，
/// `Stop` 带 `terminationReason` 与 `fullyIdle`。官方没有 SessionEnd，
/// 因此 Stop 只标「完成未确认」，不冒充会话结束。
enum AntigravityHookAdapter {
    static func normalize(hookType: String, stdinData: [String: Any]?) throws -> DIMessage {
        guard let data = stdinData, JSONSerialization.isValidJSONObject(data) else {
            throw DIBridge.NativePayloadError.invalidField("payload")
        }
        let conversationId = try text(data, "conversationId")

        let type: DIMessageType
        switch hookType {
        case "SessionStart", "PreInvocation": type = .sessionStart
        case "PreToolUse": type = .toolStart
        case "PostToolUse": type = .toolComplete
        case "Stop": type = .statusUpdate
        default: throw DIBridge.NativePayloadError.invalidField("event")
        }

        var message = DIMessage(type: type, sessionId: "antigravity-\(conversationId)")
        message.agentType = "antigravity"
        message.nativeEvent = hookType
        message.statusIsAssistantReply = false
        if let paths = data["workspacePaths"] as? [String],
           let first = paths.first, first.hasPrefix("/") {
            message.workingDir = first
        }
        if let model = data["modelName"] as? String, !model.isEmpty, !model.utf8.contains(0) {
            message.model = model
        }

        switch hookType {
        case "SessionStart", "PreInvocation":
            // PreInvocation 在每次模型调用前触发；与 SessionStart 一样映射为会话开始，
            // 由 nativeEvent 区分真正的开始与提交提示。
            message.prompt = try text(data, "lastUserInput", allowingEmpty: true)
        case "PreToolUse", "PostToolUse":
            guard let call = data["toolCall"] as? [String: Any] else {
                throw DIBridge.NativePayloadError.invalidField("toolCall")
            }
            message.tool = try text(call, "name")
            let step = data["stepIdx"] as? Int
            message.toolCallId = step.map { "antigravity-step-\($0)" } ?? "antigravity-tool"
            message.toolInput = DIBridge.outputText(call["args"])
            if hookType == "PostToolUse" {
                let error = ((data["error"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !error.isEmpty, !error.utf8.contains(0) { message.toolResult = error }
            }
        case "Stop":
            if let reason = data["terminationReason"] as? String, !reason.isEmpty, !reason.utf8.contains(0) {
                message.status = reason
            }
            // 没有 SessionEnd；其他 hook 仍可要求继续，只有 fullyIdle 能说明后台任务已停。
            message.observedState = "completionUnconfirmed"
        default:
            break
        }
        return message
    }

    private static func text(_ data: [String: Any], _ key: String, allowingEmpty: Bool = false) throws -> String {
        guard let value = data[key] as? String, !value.utf8.contains(0),
              allowingEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DIBridge.NativePayloadError.invalidField(key)
        }
        return value
    }
}
