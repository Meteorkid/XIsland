import Foundation
import DIShared

/// WorkBuddy 5.7.6 安装包中验证的命令 hook；独立于 CodeBuddy CLI 合同。
enum WorkBuddyHookAdapter {
    static func normalize(hookType: String, stdinData: [String: Any]?) throws -> DIMessage {
        guard let data = stdinData, JSONSerialization.isValidJSONObject(data),
              data["hook_event_name"] as? String == hookType else { throw DIBridge.NativePayloadError.invalidField("hook_event_name") }
        let nativeID = try text(data, "session_id")
        var message = DIMessage(type: .statusUpdate, sessionId: "workbuddy-" + Data(nativeID.utf8).base64EncodedString())
        message.agentType = "workbuddy"
        message.terminal = "WorkBuddy"
        message.workingDir = try optionalText(data, "cwd")
        message.nativeEvent = "workbuddy_5_7_6:" + hookType
        message.statusIsAssistantReply = false
        switch hookType {
        case "SessionStart":
            message.status = "WorkBuddy 会话已连接"
            if try optionalText(data, "source") == "startup" { message.observedState = "idle" }
        case "UserPromptSubmit":
            message.type = .sessionStart
            message.prompt = try text(data, "prompt")
        case "PreToolUse", "PostToolUse", "PostToolUseFailure":
            let tool = try text(data, "tool_name")
            let call = try optionalText(data, "call_id"), toolUse = try optionalText(data, "tool_use_id")
            guard call == nil || toolUse == nil || call == toolUse,
                  let input = data["tool_input"] as? [String: Any] else { throw DIBridge.NativePayloadError.invalidField("tool identity or input") }
            if let id = call ?? toolUse, id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw DIBridge.NativePayloadError.invalidField("tool identity")
            }
            message.toolCallId = call ?? toolUse
            message.toolInput = DIBridge.outputText(input)
            if hookType == "PreToolUse" {
                // 前置检查还可能阻断或等待原生审批，不把它当成已执行。
                message.status = "WorkBuddy 准备调用：" + tool
                message.observedState = "active"
            } else {
                message.type = .toolComplete
                message.tool = tool
                message.toolResult = DIBridge.outputText(data[hookType == "PostToolUseFailure" ? "error" : "tool_response"])
            }
        case "Stop":
            // Stop hooks 可以请求继续；仅提供回复，不能据此完成会话或宣布空闲。
            message.observedState = "completionUnconfirmed"
            if let reply = try optionalText(data, "last_assistant_message"), !reply.isEmpty {
                message.status = reply
                message.statusIsAssistantReply = true
            } else { message.status = "WorkBuddy 回复阶段已结束" }
        case "FinalStop":
            let reason = try text(data, "final_stop_reason")
            message.status = "WorkBuddy 本轮处理已结束"
            if reason == "failed" { message.observedState = "error" }
            else if ["completed", "cancelled", "interrupted"].contains(reason) { message.observedState = "idle" }
        case "SessionEnd":
            // JSON 的 session_id 可能已归并到父会话，不能据此删除父会话。
            message.status = "收到 WorkBuddy 会话结束通知"
        case "SubagentStart", "SubagentStop":
            let id = try optionalText(data, "agent_id")
            let name = try optionalText(data, "agent_type") ?? id ?? "未命名代理"
            message.status = "WorkBuddy 子代理" + (hookType == "SubagentStart" ? "已开始：" : "已结束：") + name
        case "Notification":
            message.status = try text(data, "message", allowsEmpty: true)
            let kind = try text(data, "notification_type")
            if kind == "permission_prompt" { message.observedState = "waitingPermission" }
        default: throw DIBridge.NativePayloadError.invalidField("unsupported WorkBuddy event")
        }
        return message
    }

    private static func text(_ data: [String: Any], _ key: String, allowsEmpty: Bool = false) throws -> String {
        guard let value = data[key] as? String, !value.utf8.contains(0),
              allowsEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DIBridge.NativePayloadError.invalidField(key) }
        return value
    }

    private static func optionalText(_ data: [String: Any], _ key: String) throws -> String? {
        guard let value = data[key], !(value is NSNull) else { return nil }
        return try text(data, key, allowsEmpty: true)
    }
}
