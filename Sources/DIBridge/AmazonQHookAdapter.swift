import Foundation
import CoreFoundation
import DIShared

/// 仅旧 Q CLI v1.19.7；sessionID 必须由显式进程包装器提供，不是原生会话 ID。
enum AmazonQHookAdapter {
    static func normalize(hookType: String, stdinData: [String: Any]?, wrapperSessionID: String?) throws -> DIMessage {
        guard let identity = wrapperSessionID, UUID(uuidString: identity) != nil else {
            throw DIBridge.NativePayloadError.invalidField("wrapper identity")
        }
        guard let data = stdinData, JSONSerialization.isValidJSONObject(data),
              data["hook_event_name"] as? String == hookType else {
            throw DIBridge.NativePayloadError.invalidField("hook_event_name")
        }
        var message = DIMessage(type: .statusUpdate, sessionId: "amazonq-wrapper-" + identity.lowercased())
        message.agentType = "amazon_q"
        message.nativeEvent = "amazonq_1_19_7_" + hookType
        message.workingDir = try text(data, "cwd")
        message.statusIsAssistantReply = false
        switch hookType {
        case "agentSpawn":
            message.status = "Amazon Q Agent 已激活（进程范围观察）"
        case "userPromptSubmit":
            message.type = .sessionStart
            message.prompt = try text(data, "prompt", allowEmpty: true)
        case "preToolUse":
            let tool = try text(data, "tool_name")
            guard data["tool_input"] is [String: Any] else { throw DIBridge.NativePayloadError.invalidField("tool_input") }
            message.status = "Amazon Q 准备调用：" + tool
            message.observedState = "active"
        case "postToolUse":
            message.type = .toolComplete
            message.tool = try text(data, "tool_name")
            guard let input = data["tool_input"] as? [String: Any],
                  let response = data["tool_response"] as? [String: Any] else { throw DIBridge.NativePayloadError.invalidField("tool payload") }
            message.toolInput = DIBridge.outputText(input)
            message.toolResult = DIBridge.outputText(response)
            if let success = response["success"] as? NSNumber,
               CFGetTypeID(success) == CFBooleanGetTypeID(), !success.boolValue { message.observedState = "error" }
        case "stop":
            // 此发布版 runner 没有发送 assistant_response，不能伪造最终答复。
            message.status = "Amazon Q 本轮回复结束"
            message.observedState = "idle"
        default: throw DIBridge.NativePayloadError.invalidField("event")
        }
        return message
    }

    private static func text(_ data: [String: Any], _ key: String, allowEmpty: Bool = false) throws -> String {
        guard let value = data[key] as? String, !value.utf8.contains(0),
              allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DIBridge.NativePayloadError.invalidField(key)
        }
        return value
    }
}
