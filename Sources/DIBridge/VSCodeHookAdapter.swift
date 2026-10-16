import Foundation
import DIShared

/// VS Code Local harness 的输入；与 Agent Host 上的 Copilot CLI/Claude/Codex 协议分开。
enum VSCodeHookAdapter {
    static func normalize(hookType: String, stdinData: [String: Any]?) throws -> DIMessage {
        guard let data = stdinData, JSONSerialization.isValidJSONObject(data),
              data["hook_event_name"] as? String == hookType else {
            throw DIBridge.NativePayloadError.invalidField("hook_event_name")
        }
        // 原生字段允许省略，但没有身份时无法安全区分同一目录中的多个会话。
        let id = try text(data, "session_id")
        let timestamp = try text(data, "timestamp")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: timestamp)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: timestamp)
        }
        guard let date else { throw DIBridge.NativePayloadError.invalidField("timestamp") }
        let type: DIMessageType
        switch hookType {
        case "SessionStart", "UserPromptSubmit": type = .sessionStart
        case "PreToolUse": type = .toolStart
        case "PostToolUse": type = .toolComplete
        case "SubagentStart": type = .subagentStart
        case "SubagentStop": type = .subagentEnd
        case "PreCompact": type = .contextCompact
        case "Stop": type = .statusUpdate
        default: throw DIBridge.NativePayloadError.invalidField("event")
        }
        var message = DIMessage(type: type, sessionId: "copilot-local-\(id)")
        message.agentType = "copilot"
        message.timestamp = date
        message.statusIsAssistantReply = false
        if data["cwd"] != nil { message.workingDir = try text(data, "cwd") }
        switch hookType {
        case "UserPromptSubmit": message.prompt = try text(data, "prompt", allowingEmpty: true)
        case "PreToolUse", "PostToolUse":
            message.tool = try text(data, "tool_name")
            message.toolCallId = try text(data, "tool_use_id")
            guard let input = data["tool_input"] as? [String: Any] else {
                throw DIBridge.NativePayloadError.invalidField("tool_input")
            }
            message.toolInput = DIBridge.outputText(input)
            if hookType == "PostToolUse" {
                guard let output = data["tool_response"], output is String || output is [String: Any] else {
                    throw DIBridge.NativePayloadError.invalidField("tool_response")
                }
                message.toolResult = DIBridge.outputText(output)
            }
        case "SubagentStart", "SubagentStop":
            message.subagentId = "copilot-local-\(id)-subagent-\(try text(data, "agent_id"))"
            message.parentSessionId = message.sessionId
            message.prompt = try text(data, "agent_type")
            if hookType == "SubagentStop" { message.subagentEndIsProvisional = true }
        case "Stop":
            // Stop 在其他 hooks 决定是否继续前触发，官方明确不代表会话结束或空闲。
            message.observedState = "completionUnconfirmed"
        default: break
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
