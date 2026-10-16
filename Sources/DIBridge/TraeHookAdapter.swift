import Foundation
import DIShared

enum TraeHookAdapter {
    static func normalize(hookType: String, stdinData: [String: Any]?) throws -> DIMessage {
        guard let data = stdinData, JSONSerialization.isValidJSONObject(data),
              data["hook_event_name"] as? String == hookType else { throw DIBridge.NativePayloadError.invalidField("hook_event_name") }
        let id = try text(data, "session_id")
        let type: DIMessageType
        switch hookType {
        case "SessionStart", "UserPromptSubmit": type = .sessionStart
        case "PreToolUse": type = .toolStart
        case "PostToolUse": type = .toolComplete
        case "Stop", "Notification": type = .statusUpdate
        default: throw DIBridge.NativePayloadError.invalidField("event")
        }
        var message = DIMessage(type: type, sessionId: "trae-\(id)")
        message.agentType = "trae"
        message.workingDir = try text(data, "cwd")
        message.statusIsAssistantReply = false
        switch hookType {
        case "UserPromptSubmit": message.prompt = try text(data, "prompt", allowingEmpty: true)
        case "PreToolUse", "PostToolUse":
            message.tool = try text(data, "tool_name")
            message.toolCallId = try text(data, "tool_use_id")
            guard let input = data["tool_input"] as? [String: Any] else { throw DIBridge.NativePayloadError.invalidField("tool_input") }
            message.toolInput = DIBridge.outputText(input)
            if hookType == "PostToolUse" {
                guard let output = data["tool_response"] as? [String: Any] else { throw DIBridge.NativePayloadError.invalidField("tool_response") }
                message.toolResult = DIBridge.outputText(output)
            }
        case "Stop":
            message.status = try text(data, "last_assistant_message", allowingEmpty: true)
            message.statusIsAssistantReply = true
            // 其他 Stop hooks 仍可要求继续；idle_prompt 才提供明确的空闲通知。
            message.observedState = "completionUnconfirmed"
        case "Notification":
            message.status = data["message"] as? String
            switch try text(data, "notification_type") {
            case "idle_prompt": message.observedState = "idle"
            case "permission_prompt": message.observedState = "waitingPermission"
            case "document_review": message.observedState = "waitingPlanReview"
            case "ask_user_question": message.observedState = "waitingAnswer"
            default: break
            }
        default: break
        }
        return message
    }

    /// 仅编码本地前置门禁，不宣称能覆盖 Trae 本身的手动确认模式。
    static func permissionResponse(approved: Bool) -> DIBridge.PermissionHookResponse {
        let decision = approved ? "allow" : "deny"
        return .init(stdout: "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"\(decision)\"}}", exitCode: 0)
    }

    private static func text(_ data: [String: Any], _ key: String, allowingEmpty: Bool = false) throws -> String {
        guard let value = data[key] as? String, !value.utf8.contains(0),
              allowingEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DIBridge.NativePayloadError.invalidField(key)
        }
        return value
    }
}
