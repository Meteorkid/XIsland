import Foundation
import CoreFoundation
import DIShared

/// Hmbown/Codewhale v0.10.0 的观察适配器。DeepSeek 仅为注册表兼容名。
enum DeepSeekHookAdapter {
    enum PayloadError: Error, Equatable {
        case invalidField(String)
        case unsupportedEvent(String)
    }

    static func normalize(
        hookType: String, stdinData: [String: Any]?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DIMessage {
        let structured = ["message_submit", "turn_end", "subagent_spawn", "subagent_complete",
                          "session_busy", "session_idle", "session_error", "waiting_for_user"]
        let environmentOnly = ["session_start", "session_end", "tool_call_before", "tool_call_after", "mode_change", "on_error"]
        guard structured.contains(hookType) || environmentOnly.contains(hookType) else { throw PayloadError.unsupportedEvent(hookType) }
        let data: [String: Any]
        if structured.contains(hookType) {
            guard let input = stdinData, JSONSerialization.isValidJSONObject(input) else { throw PayloadError.invalidField("payload") }
            data = input
        } else {
            guard stdinData == nil || stdinData?.isEmpty == true else { throw PayloadError.invalidField("unexpected stdin") }
            data = [:]
        }
        // 每个受支持事件都由执行器携带原生环境 ID；不能用工作目录、PID 或随机值代替。
        let nativeID = try identity(environment, modern: "CODEWHALE_SESSION_ID", legacy: "DEEPSEEK_SESSION_ID")
        if let payloadID = try optionalString(data, "session_id"), payloadID != nativeID { throw PayloadError.invalidField("session_id mismatch") }
        if let event = try optionalString(data, "event"), event != hookType { throw PayloadError.invalidField("event mismatch") }
        if ["message_submit", "turn_end", "subagent_spawn", "subagent_complete"].contains(hookType) {
            guard try requiredString(data, "event") == hookType else { throw PayloadError.invalidField("event") }
        }

        let type: DIMessageType
        switch hookType {
        case "session_start", "message_submit": type = .sessionStart
        case "session_end": type = .sessionEnd
        case "tool_call_before": type = .toolStart
        case "tool_call_after": type = .toolComplete
        case "subagent_spawn": type = .subagentStart
        case "subagent_complete": type = .subagentEnd
        default: type = .statusUpdate
        }
        var message = DIMessage(type: type, sessionId: "deepseek-\(nativeID)")
        message.agentType = "deepseek"
        message.nativeEvent = hookType
        message.usageIsCumulative = true
        message.workingDir = try environmentString(environment, "DEEPSEEK_WORKSPACE")
        message.model = try environmentString(environment, "DEEPSEEK_MODEL")
        message.terminal = environment["TERM_PROGRAM"]
        message.termSessionId = environment["TERM_SESSION_ID"]
        message.statusIsAssistantReply = false
        if let tokens = try environmentString(environment, "DEEPSEEK_TOTAL_TOKENS") {
            guard let number = Int(tokens), number >= 0, tokens.allSatisfy(\.isNumber), !tokens.isEmpty else { throw PayloadError.invalidField("DEEPSEEK_TOTAL_TOKENS") }
            message.totalTokens = number
        }
        if let cost = try environmentString(environment, "DEEPSEEK_SESSION_COST") {
            guard let number = Double(cost), number.isFinite, number >= 0 else { throw PayloadError.invalidField("DEEPSEEK_SESSION_COST") }
            message.costUSD = number
        }

        switch hookType {
        case "session_start": break
        case "session_end": message.observedState = "completed"
        case "message_submit":
            message.prompt = try string(data, "text")
            if try optionalBool(data, "text_truncated") == true { message.prompt? += "\n[Codewhale preview truncated]" }
            message.observedState = "active"
        case "tool_call_before", "tool_call_after":
            message.tool = try requiredEnvironment(environment, "DEEPSEEK_TOOL_NAME")
            message.toolCallId = try identity(environment, modern: "CODEWHALE_TOOL_CALL_ID", legacy: "DEEPSEEK_TOOL_CALL_ID")
            if hookType == "tool_call_before" {
                // 上游只提供有界 JSON 预览；截断的 JSON 仍是有效的观察文本，不伪造完整输入。
                message.toolInput = try requiredEnvironment(environment, "DEEPSEEK_TOOL_ARGS")
                if let inputData = message.toolInput?.data(using: .utf8),
                   let input = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] {
                    message.filePath = input["file_path"] as? String ?? input["path"] as? String
                }
            } else {
                guard let result = try environmentString(environment, "DEEPSEEK_TOOL_RESULT") else { throw PayloadError.invalidField("DEEPSEEK_TOOL_RESULT") }
                message.toolResult = result
                let success = try requiredEnvironment(environment, "DEEPSEEK_TOOL_SUCCESS")
                guard ["true", "false"].contains(success) else { throw PayloadError.invalidField("DEEPSEEK_TOOL_SUCCESS") }
                if success == "false" { message.observedState = "error" }
            }
            if let exit = try environmentString(environment, "DEEPSEEK_TOOL_EXIT_CODE"), Int64(exit) == nil { throw PayloadError.invalidField("DEEPSEEK_TOOL_EXIT_CODE") }
        case "mode_change":
            let mode = try requiredEnvironment(environment, "DEEPSEEK_MODE")
            let previous = try requiredEnvironment(environment, "DEEPSEEK_PREVIOUS_MODE")
            message.status = "Codewhale: \(previous) → \(mode)"
        case "on_error":
            message.status = try requiredEnvironment(environment, "DEEPSEEK_ERROR")
            // on_error 也含代理可能自行恢复的工具失败；只有 session_error 声明终止失败。
        case "turn_end":
            let status = try requiredString(data, "status")
            message.status = try optionalString(data, "error")
            if status == "failed" { message.observedState = "error" }
            guard let totals = data["totals"] as? [String: Any] else { throw PayloadError.invalidField("totals") }
            message.totalTokens = try integer(totals, "session_tokens")
            message.tokensIn = try integer(totals, "input_tokens")
            message.tokensOut = try integer(totals, "output_tokens")
            // usage 是本轮增量；totals 才是累计用量。完成一轮时仍可能有排队消息或等待。
        case "subagent_spawn", "subagent_complete":
            message.parentSessionId = message.sessionId
            let agentID = try requiredString(data, "agent_id")
            message.subagentId = "\(message.sessionId)-subagent-\(agentID)"
            let field = hookType == "subagent_spawn" ? "prompt" : "result"
            var preview = try string(data, field + "_preview")
            if try optionalBool(data, field + "_truncated") == true { preview += "\n[Codewhale preview truncated]" }
            if hookType == "subagent_spawn" { message.prompt = preview }
            else {
                message.toolResult = preview
                message.status = try requiredString(data, "status")
            }
        case "session_busy", "session_idle", "waiting_for_user":
            let previous = try requiredString(data, "from")
            let next = try requiredString(data, "to")
            let expected = hookType == "session_busy" ? "in_progress" : hookType == "session_idle" ? "idle" : "waiting"
            guard ["idle", "in_progress", "waiting"].contains(previous), next == expected, previous != next else { throw PayloadError.invalidField("state transition") }
            if hookType == "session_busy" { message.observedState = "active" }
            else if hookType == "session_idle" {
                message.observedState = "idle"
                _ = try optionalString(data, "last_turn_status")
            } else {
                let reason = try optionalString(data, "reason")
                switch reason {
                case "approval": message.observedState = "waitingPermission"; message.status = "Codewhale: waiting for approval in the TUI"
                case "user_input": message.observedState = "waitingAnswer"; message.status = "Codewhale: waiting for input in the TUI"
                case "goal_continuation": message.observedState = "waitingAnswer"; message.status = "Codewhale: waiting for goal continuation in the TUI"
                case nil: message.status = "Codewhale: waiting for user in the TUI"
                default: throw PayloadError.invalidField("reason")
                }
                // 没有原生问题文本、选项或可回传 request ID：不创建交互按钮。
            }
        case "session_error":
            guard try requiredString(data, "status") == "failed" else { throw PayloadError.invalidField("status") }
            message.status = try string(data, "error")
            message.observedState = "error"
        default: break
        }
        return message
    }

    private static func identity(_ environment: [String: String], modern: String, legacy: String) throws -> String {
        let current = try environmentString(environment, modern)
        let old = try environmentString(environment, legacy)
        guard let value = current ?? old, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              current == nil || old == nil || current == old else { throw PayloadError.invalidField(modern) }
        return value
    }

    private static func environmentString(_ environment: [String: String], _ field: String) throws -> String? {
        guard let value = environment[field] else { return nil }
        guard !value.utf8.contains(0) else { throw PayloadError.invalidField(field) }
        return value
    }

    private static func requiredEnvironment(_ environment: [String: String], _ field: String) throws -> String {
        guard let value = try environmentString(environment, field), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PayloadError.invalidField(field) }
        return value
    }

    private static func string(_ data: [String: Any], _ field: String) throws -> String {
        guard let value = data[field] as? String, !value.utf8.contains(0) else { throw PayloadError.invalidField(field) }
        return value
    }

    private static func requiredString(_ data: [String: Any], _ field: String) throws -> String {
        let value = try string(data, field)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PayloadError.invalidField(field) }
        return value
    }

    private static func optionalString(_ data: [String: Any], _ field: String) throws -> String? {
        guard let value = data[field], !(value is NSNull) else { return nil }
        return try string(data, field)
    }

    private static func optionalBool(_ data: [String: Any], _ field: String) throws -> Bool? {
        guard let value = data[field] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw PayloadError.invalidField(field) }
        return number.boolValue
    }

    private static func integer(_ data: [String: Any], _ field: String) throws -> Int {
        guard let number = data[field] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue < Double(Int.max),
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { throw PayloadError.invalidField(field) }
        return number.intValue
    }
}
