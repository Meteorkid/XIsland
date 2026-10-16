import Foundation
import DIShared

/// Kimi 原生 hooks 仅供观察；allow 不是对 Wire ApprovalRequest 的批准。
enum KimiHookAdapter {
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
        let nativeId = try requiredString(data, "session_id")
        let event = try requiredString(data, "hook_event_name")
        guard event == hookType else { throw PayloadError.invalidField("hook_event_name") }

        let type: DIMessageType
        switch event {
        case "SessionStart", "UserPromptSubmit": type = .sessionStart
        case "SessionEnd": type = .sessionEnd
        case "PreToolUse": type = .toolStart
        case "PostToolUse", "PostToolUseFailure": type = .toolComplete
        case "PreCompact": type = .contextCompact
        case "Stop", "StopFailure", "PostCompact", "Notification", "SubagentStart", "SubagentStop":
            type = .statusUpdate
        default: throw PayloadError.unsupportedEvent(event)
        }

        var message = DIMessage(type: type, sessionId: "kimi-\(nativeId)")
        message.agentType = "kimi"
        message.workingDir = try optionalString(data, "cwd")
        message.terminal = environment["TERM_PROGRAM"]
        message.termSessionId = environment["TERM_SESSION_ID"]
        message.statusIsAssistantReply = false

        switch event {
        case "SessionStart":
            _ = try optionalString(data, "source")
        case "SessionEnd":
            _ = try optionalString(data, "reason")
            message.observedState = "completed"
        case "UserPromptSubmit":
            message.prompt = try string(data, "prompt")
        case "PreToolUse", "PostToolUse", "PostToolUseFailure":
            message.tool = try requiredString(data, "tool_name")
            guard let input = data["tool_input"] as? [String: Any] else {
                throw PayloadError.invalidField("tool_input")
            }
            message.toolInput = try jsonString(input)
            message.toolCallId = try optionalString(data, "tool_call_id")
            message.filePath = input["file_path"] as? String ?? input["path"] as? String
            if event == "PostToolUse" {
                guard let output = data["tool_output"] else { throw PayloadError.invalidField("tool_output") }
                message.toolResult = try outputText(output)
            } else if event == "PostToolUseFailure" {
                guard let error = data["error"] else { throw PayloadError.invalidField("error") }
                message.toolResult = try outputText(error)
                message.observedState = "error"
            }
        case "Stop":
            // Stop 可被阻止并续跑，也没有可据此确认最终完成的回答字段。
            message.observedState = "completionUnconfirmed"
        case "StopFailure":
            let kind = try requiredString(data, "error_type")
            let detail = try string(data, "error_message")
            message.status = "\(kind): \(detail)"
            message.observedState = "error"
        case "PreCompact", "PostCompact":
            _ = try optionalString(data, "trigger")
            // token_count 是上下文大小，不是累计 token 使用量。
            if event == "PostCompact" { message.observedState = "active" }
        case "Notification":
            _ = try requiredString(data, "sink")
            _ = try requiredString(data, "notification_type")
            let title = try string(data, "title")
            let body = try string(data, "body")
            _ = try requiredString(data, "severity")
            message.status = [title, body].filter { !$0.isEmpty }.joined(separator: "\n")
        case "SubagentStart", "SubagentStop":
            let name = try requiredString(data, "agent_name")
            let field = event == "SubagentStart" ? "prompt" : "response"
            let text = try string(data, field)
            // 仅有名字，没有唯一子代理 ID；避免把同名并行任务错误配对。
            message.status = [name, text].filter { !$0.isEmpty }.joined(separator: "\n")
        default: break
        }
        return message
    }

    private static func requiredString(_ data: [String: Any], _ field: String) throws -> String {
        let value = try string(data, field)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PayloadError.invalidField(field)
        }
        return value
    }

    private static func optionalString(_ data: [String: Any], _ field: String) throws -> String? {
        guard data[field] != nil else { return nil }
        return try string(data, field)
    }

    private static func string(_ data: [String: Any], _ field: String) throws -> String {
        guard let value = data[field] as? String, !value.utf8.contains(0) else {
            throw PayloadError.invalidField(field)
        }
        return value
    }

    private static func outputText(_ value: Any) throws -> String {
        if let text = value as? String { return text }
        return try jsonString(value)
    }

    private static func jsonString(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }
}
