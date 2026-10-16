import Foundation
import CoreFoundation
import DIShared

/// https://www.codebuddy.cn/docs/cli/hooks
/// CodeBuddy Code CLI 的观察事件；不复用 Claude 的权限、问答或计划回传格式。
enum CodeBuddyHookAdapter {
    enum PayloadError: Error, Equatable {
        case invalidField(String)
        case unsupportedEvent(String)
    }

    static func normalize(
        hookType: String,
        sessionId: String,
        stdinData: [String: Any]?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DIMessage {
        guard let data = stdinData, JSONSerialization.isValidJSONObject(data) else {
            throw PayloadError.invalidField("payload")
        }
        _ = try string(data, "session_id", allowingEmpty: false)
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sessionId.utf8.contains(0) else { throw PayloadError.invalidField("session_id") }
        let event = try string(data, "hook_event_name", allowingEmpty: false)
        guard event == hookType else { throw PayloadError.invalidField("hook_event_name") }
        for field in ["cwd", "transcript_path", "permission_mode", "generation_id"] {
            _ = try optionalString(data, field)
        }

        let type: DIMessageType
        switch event {
        case "SessionStart", "UserPromptSubmit": type = .sessionStart
        case "SessionEnd": type = .sessionEnd
        case "PreToolUse": type = .toolStart
        case "PostToolUse": type = .toolComplete
        case "PreCompact": type = .contextCompact
        case "PostCompact": type = .recap
        case "Stop", "SubagentStop", "Notification": type = .statusUpdate
        default: throw PayloadError.unsupportedEvent(event)
        }

        var message = DIMessage(type: type, sessionId: sessionId)
        message.agentType = "code_buddy"
        // cwd 是调用时的位置；PROJECT_DIR 是项目根，二者在执行 cd 后可以不同。
        message.workingDir = nonempty(try optionalString(data, "cwd"))
            ?? nonempty(environment["CODEBUDDY_PROJECT_DIR"])
        message.terminal = nonempty(environment["TERM_PROGRAM"])
        message.termSessionId = nonempty(environment["TERM_SESSION_ID"])
        message.statusIsAssistantReply = false

        switch event {
        case "SessionStart":
            _ = try optionalString(data, "source")
        case "SessionEnd":
            _ = try optionalString(data, "reason")
            message.observedState = "completed"
        case "UserPromptSubmit":
            message.prompt = try string(data, "prompt")
        case "PreToolUse", "PostToolUse":
            message.tool = try string(data, "tool_name", allowingEmpty: false)
            guard let input = data["tool_input"] as? [String: Any] else {
                throw PayloadError.invalidField("tool_input")
            }
            message.toolInput = try jsonString(input)
            message.filePath = input["file_path"] as? String
            if event == "PostToolUse" {
                guard let response = data["tool_response"] as? [String: Any] else {
                    throw PayloadError.invalidField("tool_response")
                }
                message.toolResult = try jsonString(response)
            }
        case "Stop", "SubagentStop":
            if let active = data["stop_hook_active"] {
                guard let number = active as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw PayloadError.invalidField("stop_hook_active")
                }
            }
            if event == "Stop" {
                // 文档没有最终回答字段，也不保证此时会话退出。
                message.observedState = "completionUnconfirmed"
            } else {
                // 输入示例没有唯一子代理 ID；不能清除任意子代理或把主会话标为空闲。
                message.status = "CodeBuddy 子代理完成未确认"
            }
        case "PreCompact", "PostCompact":
            _ = try optionalString(data, "trigger")
            if event == "PreCompact" { _ = try optionalString(data, "custom_instructions") }
            else { message.recapText = try string(data, "compact_summary") }
        case "Notification":
            message.status = try string(data, "message")
            switch try string(data, "notification_type", allowingEmpty: false) {
            case "permission_prompt": message.observedState = "waitingPermission"
            case "idle_prompt": message.observedState = "idle"
            default: break
            }
        default: break
        }
        return message
    }

    private static func string(_ data: [String: Any], _ field: String, allowingEmpty: Bool = true) throws -> String {
        guard let value = data[field] as? String, !value.utf8.contains(0),
              allowingEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PayloadError.invalidField(field)
        }
        return value
    }

    private static func optionalString(_ data: [String: Any], _ field: String) throws -> String? {
        guard data[field] != nil else { return nil }
        return try string(data, field)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.utf8.contains(0) else { return nil }
        return value
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
