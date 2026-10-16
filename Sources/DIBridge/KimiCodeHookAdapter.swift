import Foundation
import CoreFoundation
import DIShared

/// Kimi Code Node.js 2.1.1 的观察协议，与旧 Python kimi-cli 分开处理。
enum KimiCodeHookAdapter {
    enum PayloadError: Error, Equatable {
        case invalidField(String)
        case unsupportedEvent(String)
    }

    static func normalize(hookType: String, stdinData: [String: Any]?,
                          environment: [String: String] = ProcessInfo.processInfo.environment) throws -> DIMessage {
        guard let data = stdinData, JSONSerialization.isValidJSONObject(data) else { throw PayloadError.invalidField("payload") }
        let sessionID = try identifier(data, "session_id")
        guard try identifier(data, "hook_event_name") == hookType else { throw PayloadError.invalidField("hook_event_name") }
        _ = try identifier(data, "client_type")
        _ = try optionalString(data, "session_title")
        var message = DIMessage(type: .statusUpdate, sessionId: "kimi_code-" + sessionID)
        message.agentType = "kimi"
        message.nativeEvent = "kimi_code." + hookType
        message.workingDir = try string(data, "cwd")
        message.statusIsAssistantReply = false
        message.terminal = environment["TERM_PROGRAM"]
        message.termSessionId = environment["TERM_SESSION_ID"]

        switch hookType {
        case "SessionStart":
            _ = try choice(data, "source", ["startup", "resume"])
            message.model = try optionalString(data, "model")
            _ = try optionalString(data, "profile")
            message.observedState = "idle"
            message.status = "Kimi Code connected"
        case "SessionEnd":
            let reason = try choice(data, "reason", ["exit", "archive"])
            message.type = .sessionEnd
            message.observedState = "completed"
            message.status = "Kimi Code session: " + reason
        case "UserPromptSubmit":
            message.type = .sessionStart
            message.prompt = try promptText(data, "prompt")
            _ = try optionalBoolean(data, "is_steer")
        case "UserPromptQueued":
            _ = try identifier(data, "prompt_id")
            let text = try promptText(data, "prompt")
            let count = try integer(data, "queue_length")
            message.status = "Queued (\(count)): \(text)"
        case "TurnStarted":
            message.nativeTurnId = String(try integer(data, "turn_id"))
            let origin = try identifier(data, "origin_kind")
            let name = try optionalString(data, "origin_name")
            _ = try optionalString(data, "prompt")
            // task/system_trigger 的提示并非用户发言；UserPromptSubmit 已负责用户历史。
            message.observedState = "active"
            message.status = "Turn started: " + [origin, name].compactMap { $0 }.joined(separator: "/")
        case "PreToolUse", "PostToolUse", "PostToolUseFailure":
            message.tool = try identifier(data, "tool_name")
            message.toolCallId = try identifier(data, "tool_call_id")
            guard let input = data["tool_input"] as? [String: Any] else { throw PayloadError.invalidField("tool_input") }
            message.toolInput = try jsonText(input)
            message.filePath = input["file_path"] as? String ?? input["path"] as? String
            if hookType == "PreToolUse" { message.type = .toolStart }
            else {
                message.type = .toolComplete
                if hookType == "PostToolUse" { message.toolResult = try string(data, "tool_output") }
                else {
                    guard let error = data["error"] as? [String: Any] else { throw PayloadError.invalidField("error") }
                    message.toolResult = try jsonText(error)
                    message.observedState = "error"
                }
            }
        case "PermissionRequest", "PermissionResult":
            message.nativeRequestId = try optionalIdentifier(data, "id")
            message.nativeRequestKind = "permission"
            message.nativeAgentId = try identifier(data, "agent_id")
            message.nativeTurnId = String(try integer(data, "turn_id"))
            message.toolCallId = try identifier(data, "tool_call_id")
            message.tool = try identifier(data, "tool_name")
            let action = try string(data, "action")
            guard data["display"] is [String: Any], let input = data["tool_input"] else {
                throw PayloadError.invalidField("approval context")
            }
            message.toolInput = try jsonText(input)
            if hookType == "PermissionRequest" {
                message.status = "Waiting for approval in Kimi Code: " + action
            } else {
                let decision = try choice(data, "decision", ["approved", "rejected", "cancelled", "error"])
                if data["scope"] != nil { _ = try choice(data, "scope", ["session"]) }
                _ = try optionalString(data, "feedback")
                _ = try optionalString(data, "selected_label")
                _ = try optionalString(data, "error")
                message.status = "Kimi Code approval result: " + decision
            }
            // 不创建 permissionRequest，也不返回 approval JSON；这里只观察原生决定。
        case "Stop":
            _ = try optionalBoolean(data, "stop_hook_active")
            message.observedState = "completionUnconfirmed"
        case "StopFailure":
            let kind = try optionalString(data, "error_type")
            message.status = [kind, try string(data, "error_message")].compactMap { $0 }.joined(separator: ": ")
            message.observedState = "error"
        case "Interrupt":
            message.nativeTurnId = String(try integer(data, "turn_id"))
            _ = try choice(data, "reason", ["cancelled"])
            message.observedState = "completionUnconfirmed"
            message.status = "Kimi Code turn interrupted; outcome unconfirmed"
        case "SessionHeartbeat":
            _ = try integer(data, "uptime_ms")
            message.status = "Kimi Code session heartbeat"
        case "SubagentStart", "SubagentStop":
            let name = try identifier(data, "agent_name")
            let text = try string(data, hookType == "SubagentStart" ? "prompt" : "response")
            // 2.1.1 未提供唯一子代理身份，名称不能用于并发任务配对。
            message.status = name + ": " + text
        case "TaskStarted":
            let task = try identifier(data, "task_id")
            let kind = try choice(data, "kind", ["agent", "process", "question"])
            let description = try string(data, "description")
            let state = try choice(data, "status", ["running", "completed", "failed", "timed_out", "killed", "lost"])
            let startedAt = try integer(data, "started_at")
            _ = try optionalBoolean(data, "detached")
            message.status = "Task \(task) (\(kind)): \(description)"
            message.nativeBackgroundTask = DINativeBackgroundTask(id: task, kind: kind, status: state,
                description: description, startedAtMilliseconds: startedAt)
        case "PreCompact":
            _ = try choice(data, "trigger", ["manual", "auto"])
            _ = try integer(data, "token_count")
            message.type = .contextCompact
        case "PostCompact":
            let trigger = try choice(data, "trigger", ["manual", "auto"])
            _ = try integer(data, "estimated_token_count")
            // 手动压缩不启动执行回合，也不会再发 Stop，不能据此显示正在运行。
            message.observedState = trigger == "manual" ? "completionUnconfirmed" : "active"
        case "Notification":
            _ = try choice(data, "sink", ["context"])
            message.nativeAgentId = try identifier(data, "agent_id")
            let notification = try identifier(data, "notification_type")
            let source = try identifier(data, "source_kind")
            let sourceID = try identifier(data, "source_id")
            _ = try choice(data, "severity", ["info", "warning"])
            message.status = [try string(data, "title"), try string(data, "body")].filter { !$0.isEmpty }.joined(separator: "\n")
            let taskStates = ["completed", "failed", "timed_out", "killed", "lost"]
            if source == "background_task", let state = taskStates.first(where: { notification == "task." + $0 }) {
                message.nativeBackgroundTask = DINativeBackgroundTask(id: sourceID, status: state, result: message.status)
            }
        default:
            throw PayloadError.unsupportedEvent(hookType)
        }
        return message
    }

    private static func string(_ data: [String: Any], _ field: String) throws -> String {
        guard let value = data[field] as? String, !value.utf8.contains(0) else { throw PayloadError.invalidField(field) }
        return value
    }

    private static func identifier(_ data: [String: Any], _ field: String) throws -> String {
        let value = try string(data, field)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 1024 else {
            throw PayloadError.invalidField(field)
        }
        return value
    }

    private static func optionalString(_ data: [String: Any], _ field: String) throws -> String? {
        data[field] == nil ? nil : try string(data, field)
    }

    private static func optionalIdentifier(_ data: [String: Any], _ field: String) throws -> String? {
        data[field] == nil ? nil : try identifier(data, field)
    }

    private static func choice(_ data: [String: Any], _ field: String, _ options: [String]) throws -> String {
        let value = try string(data, field)
        guard options.contains(value) else { throw PayloadError.invalidField(field) }
        return value
    }

    private static func integer(_ data: [String: Any], _ field: String) throws -> Int64 {
        guard let value = data[field] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue <= 9_007_199_254_740_991,
              value.doubleValue.rounded() == value.doubleValue else { throw PayloadError.invalidField(field) }
        return value.int64Value
    }

    private static func optionalBoolean(_ data: [String: Any], _ field: String) throws -> Bool? {
        guard let value = data[field] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw PayloadError.invalidField(field) }
        return number.boolValue
    }

    private static func promptText(_ data: [String: Any], _ field: String) throws -> String {
        guard let parts = data[field] as? [[String: Any]] else { throw PayloadError.invalidField(field) }
        return try parts.compactMap { part -> String? in
            let type = try identifier(part, "type")
            return type == "text" ? try string(part, "text") : nil
        }.joined(separator: "\n")
    }

    private static func jsonText(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }
}
