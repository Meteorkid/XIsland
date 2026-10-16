import Foundation
import DIShared

enum PiHookAdapter {
    static func normalize(hookType: String, stdinData: [String: Any]?) throws -> DIMessage {
        guard let data = stdinData,
              let id = data["session_id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let event = data["native_event"] as? String else {
            throw DIBridge.NativePayloadError.invalidField("session_id/native_event")
        }
        let expected: (String, String)
        switch event {
        case "session_start": expected = ("session_start", "SessionStart")
        case "before_agent_start": expected = ("UserPromptSubmit", "UserPromptSubmit")
        case "agent_start": expected = ("notification", "AgentStart")
        case "tool_execution_start": expected = ("toolstart", "PreToolUse")
        case "tool_execution_end": expected = ("toolcomplete", "PostToolUse")
        case "agent_end": expected = ("notification", "AgentEnd")
        case "agent_settled": expected = ("notification", "Stop")
        case "session_shutdown": expected = ("session_end", "SessionEnd")
        default: throw DIBridge.NativePayloadError.invalidField("native_event")
        }
        guard hookType == expected.0, data["hook_event_name"] as? String == expected.1 else {
            throw DIBridge.NativePayloadError.invalidField("hook_event_name")
        }
        var message = DIBridge.buildMessage(agentType: "pi", hookType: hookType, sessionId: "pi-\(id)", stdinData: data)
        message.agentType = "pi"
        message.workingDir = data["cwd"] as? String
        message.statusIsAssistantReply = false
        if event == "tool_execution_start" || event == "tool_execution_end" {
            guard let callId = data["tool_use_id"] as? String, !callId.isEmpty,
                  let tool = data["tool_name"] as? String, !tool.isEmpty else {
                throw DIBridge.NativePayloadError.invalidField("tool_use_id/tool_name")
            }
            message.toolCallId = callId
            message.toolInput = DIBridge.outputText(data["tool_input"])
            if data["native_status"] as? String == "error" { message.observedState = "error" }
        }
        switch event {
        case "agent_start": message.observedState = "active"
        case "agent_settled": message.observedState = "idle"
        case "session_shutdown": message.observedState = "completed"
        default: break
        }
        // agent_end 之后可能重试或续跑；保持当前状态直到 settled 或 shutdown。
        if event == "agent_end" { message.status = nil }
        return message
    }
}
