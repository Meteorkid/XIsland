import Foundation
import DIShared

/// 只接受配套插件明确订阅的观察事件，不把 tool.call 转换为权限申请。
enum AmpHookAdapter {
    static func normalize(hookType: String, stdinData: [String: Any]?) throws -> DIMessage {
        guard let data = stdinData,
              let id = data["session_id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let event = data["native_event"] as? String else {
            throw DIBridge.NativePayloadError.invalidField("session_id/native_event")
        }
        let expected: (String, String)
        switch event {
        case "session.start": expected = ("session_start", "SessionStart")
        case "agent.start": expected = ("UserPromptSubmit", "UserPromptSubmit")
        case "tool.result": expected = ("toolcomplete", "PostToolUse")
        case "agent.end": expected = ("notification", "Stop")
        default: throw DIBridge.NativePayloadError.invalidField("native_event")
        }
        guard hookType == expected.0, data["hook_event_name"] as? String == expected.1 else {
            throw DIBridge.NativePayloadError.invalidField("hook_event_name")
        }
        var message = DIBridge.buildMessage(agentType: "amp", hookType: hookType, sessionId: "amp-\(id)", stdinData: data)
        message.agentType = "amp"
        message.statusIsAssistantReply = false
        if event == "tool.result" {
            guard let callId = data["tool_use_id"] as? String, !callId.isEmpty,
                  let tool = data["tool_name"] as? String, !tool.isEmpty else {
                throw DIBridge.NativePayloadError.invalidField("tool_use_id/tool_name")
            }
            message.toolCallId = callId
            message.toolInput = DIBridge.outputText(data["tool_input"])
            if data["native_status"] as? String == "error" { message.observedState = "error" }
        }
        if event == "agent.end" {
            message.type = .statusUpdate
            message.observedState = data["native_status"] as? String == "error" ? "error" : "idle"
            // messages 是宿主对象数组；未经验证其正文结构，不能转写为助手回答。
            message.status = nil
        }
        return message
    }
}
