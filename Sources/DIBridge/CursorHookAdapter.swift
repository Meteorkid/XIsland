import Foundation
import DIShared

/// Cursor 的 native hooks；通用工具事件只观察，不能按工具名猜问答或审批。
enum CursorHookAdapter {
    static func normalize(hookType: String, stdinData: [String: Any]?) throws -> DIMessage {
        guard let data = stdinData, JSONSerialization.isValidJSONObject(data),
              data["hook_event_name"] as? String == hookType else { throw DIBridge.NativePayloadError.invalidField("hook_event_name") }
        let id = try text(data, "conversation_id")
        let type: DIMessageType
        switch hookType {
        case "sessionStart", "beforeSubmitPrompt": type = .sessionStart
        case "sessionEnd": type = .sessionEnd
        case "preToolUse": type = .toolStart
        case "postToolUse", "postToolUseFailure": type = .toolComplete
        case "beforeShellExecution", "beforeMCPExecution": type = .permissionRequest
        case "preCompact": type = .contextCompact
        case "afterAgentResponse", "stop": type = .statusUpdate
        default: throw DIBridge.NativePayloadError.invalidField("event")
        }
        var message = DIMessage(type: type, sessionId: "cursor-\(id)")
        message.agentType = "cursor"
        message.model = data["model_id"] as? String ?? data["model"] as? String
        message.statusIsAssistantReply = false
        if let cwd = data["cwd"] as? String, !cwd.isEmpty { message.workingDir = cwd }
        else if let roots = data["workspace_roots"] as? [String], roots.count == 1 { message.workingDir = roots[0] }
        switch hookType {
        case "beforeSubmitPrompt": message.prompt = try text(data, "prompt", allowingEmpty: true)
        case "sessionStart", "sessionEnd":
            if let session = data["session_id"] as? String, session != id { throw DIBridge.NativePayloadError.invalidField("session_id") }
            if hookType == "sessionEnd" { message.observedState = "completed" }
        case "beforeShellExecution":
            // Cursor 的 shell 门禁只提供 command/cwd，没有工具调用 ID；不能用 generation_id 冒充。
            let command = try text(data, "command")
            message.tool = "Shell"
            message.toolInput = DIBridge.outputText(["command": command])
            message.permDescription = command
        case "beforeMCPExecution":
            message.tool = try text(data, "tool_name")
            let input = data["tool_input"] ?? [:]
            guard input is String || JSONSerialization.isValidJSONObject(input) else {
                throw DIBridge.NativePayloadError.invalidField("tool_input")
            }
            let inputText = DIBridge.outputText(input) ?? ""
            message.toolInput = inputText.isEmpty ? nil : inputText
            let server = (data["mcp_server_name"] as? String) ?? (data["mcp_server_url"] as? String)
            message.permDescription = [message.tool, server, inputText]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        case "preToolUse", "postToolUse", "postToolUseFailure":
            message.tool = try text(data, "tool_name")
            message.toolCallId = try text(data, "tool_use_id")
            guard let input = data["tool_input"] as? [String: Any] else { throw DIBridge.NativePayloadError.invalidField("tool_input") }
            message.toolInput = DIBridge.outputText(input)
            if hookType == "postToolUse" { message.toolResult = try text(data, "tool_output", allowingEmpty: true) }
            if hookType == "postToolUseFailure" {
                message.toolResult = try text(data, "error_message", allowingEmpty: true)
                // 用户中断不等同于工具故障；终态随后由 stop 给出。
                if data["is_interrupt"] as? Bool != true { message.observedState = "error" }
            }
        case "afterAgentResponse":
            message.status = try text(data, "text", allowingEmpty: true)
            message.statusIsAssistantReply = true
            // 一条助手消息结束并不意味着整个 agent loop 已经结束。
        case "stop":
            let status = try text(data, "status")
            guard ["completed", "aborted", "error"].contains(status) else { throw DIBridge.NativePayloadError.invalidField("status") }
            message.observedState = status == "error" ? "error" : "idle"
        default: break
        }
        return message
    }

    /// Cursor 的 shell/MCP/文件读取门禁使用顶层 `permission`，不是 preToolUse 的 `decision`。
    ///
    /// Cursor 3.15.6 的 `cursor-agent-exec` 只消费 `deny` 和 `ask`：
    /// `allow` 能通过校验，但调用点不会据此跳过原生确认。因此这里的 approved
    /// 也映射为 `ask`，避免 X Island 的按钮声称批准、Cursor 却继续弹窗。
    static func permissionResponse(hookType: String, approved: Bool) throws -> DIBridge.PermissionHookResponse {
        guard ["beforeShellExecution", "beforeMCPExecution", "beforeReadFile", "beforeTabFileRead", "subagentStart"].contains(hookType) else {
            throw DIBridge.NativePayloadError.invalidField("permission hook")
        }
        return .init(stdout: approved ? "{\"permission\":\"ask\"}" : "{\"permission\":\"deny\"}", exitCode: 0)
    }

    private static func text(_ data: [String: Any], _ key: String, allowingEmpty: Bool = false) throws -> String {
        guard let value = data[key] as? String, !value.utf8.contains(0),
              allowingEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DIBridge.NativePayloadError.invalidField(key)
        }
        return value
    }
}
