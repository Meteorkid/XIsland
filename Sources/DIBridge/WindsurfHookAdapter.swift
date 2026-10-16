import Foundation
import DIShared

/// https://docs.devin.ai/desktop/cascade/hooks
/// 只观察 Cascade；pre-hook 不是原生权限申请，轮次响应也不是会话关闭。
enum WindsurfHookAdapter {
    enum PayloadError: Error, Equatable {
        case invalidField(String)
        case unsupportedEvent(String)
    }

    static func normalize(
        hookType: String,
        stdinData: [String: Any]?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DIMessage {
        guard let data = stdinData, JSONSerialization.isValidJSONObject(data) else {
            throw PayloadError.invalidField("payload")
        }
        let event = try requiredString(data, "agent_action_name")
        guard event == hookType else { throw PayloadError.invalidField("agent_action_name") }
        let trajectoryId = try requiredString(data, "trajectory_id")
        _ = try requiredString(data, "execution_id")
        let timestamp = try requiredString(data, "timestamp")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: timestamp)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: timestamp)
        }
        guard let date else { throw PayloadError.invalidField("timestamp") }
        let model = try requiredString(data, "model_name")
        guard let info = data["tool_info"] as? [String: Any] else {
            throw PayloadError.invalidField("tool_info")
        }

        let type: DIMessageType
        switch event {
        case "pre_user_prompt": type = .sessionStart
        case "pre_read_code", "pre_write_code", "pre_run_command", "pre_mcp_tool_use": type = .toolStart
        case "post_read_code", "post_write_code", "post_run_command", "post_mcp_tool_use": type = .toolComplete
        case "post_cascade_response": type = .statusUpdate
        default: throw PayloadError.unsupportedEvent(event)
        }
        var message = DIMessage(type: type, sessionId: "windsurf-\(trajectoryId)")
        message.agentType = "windsurf"
        message.timestamp = date
        message.model = model
        message.terminal = environment["TERM_PROGRAM"]
        message.termSessionId = environment["TERM_SESSION_ID"]
        message.statusIsAssistantReply = false

        switch event {
        case "pre_user_prompt":
            message.prompt = try string(info, "user_prompt")
        case "pre_read_code", "post_read_code", "pre_write_code", "post_write_code":
            message.filePath = try requiredString(info, "file_path")
            message.tool = event.contains("write") ? "Write" : "Read"
            if event.contains("write") {
                guard let edits = info["edits"] as? [[String: Any]] else {
                    throw PayloadError.invalidField("tool_info.edits")
                }
                for edit in edits {
                    _ = try string(edit, "old_string")
                    _ = try string(edit, "new_string")
                }
            }
        case "pre_run_command", "post_run_command":
            _ = try requiredString(info, "command_line")
            message.workingDir = try requiredString(info, "cwd")
            message.tool = "Bash"
        case "pre_mcp_tool_use", "post_mcp_tool_use":
            let server = try requiredString(info, "mcp_server_name")
            let tool = try requiredString(info, "mcp_tool_name")
            guard info["mcp_tool_arguments"] is [String: Any] else {
                throw PayloadError.invalidField("tool_info.mcp_tool_arguments")
            }
            message.tool = "mcp__\(server)__\(tool)"
            if event == "post_mcp_tool_use" {
                guard let result = info["mcp_result"] else { throw PayloadError.invalidField("tool_info.mcp_result") }
                if let text = result as? String { message.toolResult = text }
                else { message.toolResult = try jsonString(result) }
            }
        case "post_cascade_response":
            message.status = try string(info, "response")
            message.observedState = "idle"
            message.statusIsAssistantReply = true
        default: break
        }
        if type == .toolStart || type == .toolComplete {
            message.toolInput = try jsonString(info)
        }
        // 其他事件没有官方 cwd 字段，不把 hook 安装目录或文件父目录猜作项目根目录。
        return message
    }

    private static func requiredString(_ data: [String: Any], _ field: String) throws -> String {
        let value = try string(data, field)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PayloadError.invalidField(field)
        }
        return value
    }

    private static func string(_ data: [String: Any], _ field: String) throws -> String {
        guard let value = data[field] as? String, !value.utf8.contains(0) else {
            throw PayloadError.invalidField(field)
        }
        return value
    }

    private static func jsonString(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }
}
