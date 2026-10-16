import Foundation
import CoreFoundation
import DIShared

/// 官方 CLI 文档载荷；V3 配置可显式导出，真实客户端加载仍须独立验收。
enum KiroHookAdapter {
    static func normalize(hookType: String, stdinData: [String: Any]?) throws -> DIMessage {
        guard let data = stdinData, JSONSerialization.isValidJSONObject(data),
              data["hook_event_name"] as? String == hookType else {
            throw DIBridge.NativePayloadError.invalidField("hook_event_name")
        }
        let id = try text(data, "session_id")
        var message = DIMessage(type: .statusUpdate, sessionId: "kiro-cli-" + Data(id.utf8).base64EncodedString())
        message.agentType = "kiro"
        message.nativeEvent = "kiro_cli_" + hookType
        message.workingDir = try text(data, "cwd")
        message.statusIsAssistantReply = false
        switch hookType {
        case "agentSpawn", "AgentSpawn":
            message.status = "Kiro Agent 已激活"
        case "SessionStart":
            // V3 明确的新会话事件可恢复已关闭的同 ID 历史；旧 AgentSpawn 仅表示激活。
            message.type = .sessionStart
            message.status = "Kiro 会话已开始"
        case "userPromptSubmit", "UserPromptSubmit":
            message.type = .sessionStart
            message.prompt = try text(data, "prompt", allowingEmpty: true)
        case "preToolUse", "PreToolUse":
            // 前置 hook 之后用户仍可拒绝；无调用 ID，不能声称执行或配对并行调用。
            let tool = try text(data, "tool_name")
            guard data["tool_input"] is [String: Any] else { throw DIBridge.NativePayloadError.invalidField("tool_input") }
            message.status = "Kiro 准备调用：" + tool
            message.observedState = "active"
        case "postToolUse", "PostToolUse":
            message.type = .toolComplete
            message.tool = try text(data, "tool_name")
            guard let input = data["tool_input"] as? [String: Any],
                  let result = data["tool_response"] as? [String: Any] else {
                throw DIBridge.NativePayloadError.invalidField("tool payload")
            }
            message.toolInput = DIBridge.outputText(input)
            message.toolResult = DIBridge.outputText(result)
            if let success = result["success"] as? NSNumber,
               CFGetTypeID(success) == CFBooleanGetTypeID(), !success.boolValue {
                message.observedState = "error"
            }
        case "stop", "Stop":
            // V3 官方 Stop 示例只有会话字段，不能因为缺少答案正文而丢掉回合结束。
            // 同时不能用状态文案覆盖此前真实答案，或给历史补一条虚构助手消息。
            if data["assistant_response"] != nil {
                message.status = try text(data, "assistant_response", allowingEmpty: true)
                message.statusIsAssistantReply = true
            } else {
                message.status = "Kiro 本轮结束待确认"
            }
            // 其他 Stop hook 可通过 block/exit 1 触发继续执行，收到本条不能证明空闲。
            message.observedState = "completionUnconfirmed"
        case "SessionEnd":
            message.type = .sessionEnd
            message.observedState = "completed"
            message.status = "Kiro 会话已结束"
        default: throw DIBridge.NativePayloadError.invalidField("event")
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
