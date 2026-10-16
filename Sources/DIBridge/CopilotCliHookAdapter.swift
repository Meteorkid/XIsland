import Foundation
import CoreFoundation
import DIShared

/// https://docs.github.com/en/copilot/reference/hooks-reference
/// 此入口仅解析本应用生成的 camelCase 配置，不猜测 VS Code 兼容输入。
enum CopilotCliHookAdapter {
    static func normalize(hookType: String, stdinData: [String: Any]?) throws -> DIMessage {
        guard let data = stdinData, JSONSerialization.isValidJSONObject(data) else {
            throw DIBridge.NativePayloadError.invalidField("payload")
        }
        let id = try requiredString(data, "sessionId")
        let directory = try requiredString(data, "cwd")
        guard let timestamp = data["timestamp"] as? NSNumber, CFGetTypeID(timestamp) != CFBooleanGetTypeID(),
              timestamp.doubleValue.isFinite, timestamp.doubleValue >= 0 else {
            throw DIBridge.NativePayloadError.invalidField("timestamp")
        }
        let type: DIMessageType
        switch hookType {
        case "sessionStart", "userPromptSubmitted": type = .sessionStart
        case "sessionEnd": type = .sessionEnd
        case "preToolUse": type = .toolStart
        case "postToolUse", "postToolUseFailure": type = .toolComplete
        case "preCompact": type = .contextCompact
        case "agentStop", "subagentStart", "subagentStop", "errorOccurred", "notification": type = .statusUpdate
        default: throw DIBridge.NativePayloadError.invalidField("event")
        }
        var message = DIMessage(type: type, sessionId: "copilot_cli-\(id)")
        message.agentType = "copilot_cli"
        message.timestamp = Date(timeIntervalSince1970: timestamp.doubleValue / 1000)
        message.workingDir = directory
        message.statusIsAssistantReply = false
        switch hookType {
        case "sessionStart": message.prompt = data["initialPrompt"] as? String
        case "userPromptSubmitted": message.prompt = try string(data, "prompt")
        case "sessionEnd": message.observedState = "completed"
        case "preToolUse", "postToolUse", "postToolUseFailure":
            message.tool = try requiredString(data, "toolName")
            guard let input = data["toolArgs"] else { throw DIBridge.NativePayloadError.invalidField("toolArgs") }
            message.toolInput = try jsonText(input)
            if hookType == "postToolUse" {
                guard let result = data["toolResult"] as? [String: Any] else {
                    throw DIBridge.NativePayloadError.invalidField("toolResult")
                }
                message.toolResult = try jsonText(result)
            } else if hookType == "postToolUseFailure" {
                message.toolResult = try string(data, "error")
                message.observedState = "error"
            }
        case "agentStop":
            // 其他 agentStop hooks 仍可要求继续，不能据此确定主会话已空闲。
            message.observedState = "completionUnconfirmed"
        case "notification":
            message.status = try string(data, "message")
            if data["notification_type"] as? String == "permission_prompt" { message.observedState = "waitingPermission" }
            if data["notification_type"] as? String == "elicitation_dialog" { message.observedState = "waitingAnswer" }
        case "errorOccurred":
            guard let error = data["error"] as? [String: Any] else { throw DIBridge.NativePayloadError.invalidField("error") }
            message.status = try string(error, "message")
            message.observedState = "error"
        case "subagentStart", "subagentStop":
            // 起始事件未提供与结束事件对应的实例ID，不能把 agentName 假作唯一子会话ID。
            message.status = try requiredString(data, "agentName")
        default: break
        }
        return message
    }

    /// 仅供已确认输入身份的原生 permissionRequest 使用；与 preToolUse 的输出不通用。
    static func permissionResponse(approved: Bool) -> DIBridge.PermissionHookResponse {
        .init(stdout: approved ? "{\"behavior\":\"allow\"}" : "{\"behavior\":\"deny\"}", exitCode: 0)
    }

    private static func requiredString(_ data: [String: Any], _ key: String) throws -> String {
        let value = try string(data, key)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DIBridge.NativePayloadError.invalidField(key) }
        return value
    }

    private static func string(_ data: [String: Any], _ key: String) throws -> String {
        guard let value = data[key] as? String, !value.utf8.contains(0) else { throw DIBridge.NativePayloadError.invalidField(key) }
        return value
    }

    private static func jsonText(_ value: Any) throws -> String {
        if let text = value as? String { return text }
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }
}
