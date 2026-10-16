import Foundation
import DIShared

/// https://docs.devin.ai/cli/extensibility/hooks/overview
/// 仅处理原生 hooks；Devin 尚未公开可用于完整问答/计划反馈的同类回传协议。
enum DevinHookAdapter {
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
        guard let data = stdinData, JSONSerialization.isValidJSONObject(data),
              let nativeSessionId = data["session_id"] as? String,
              !nativeSessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PayloadError.invalidField("session_id")
        }
        guard let event = data["hook_event_name"] as? String, event == hookType else {
            throw PayloadError.invalidField("hook_event_name")
        }
        if let promptId = data["prompt_id"], !(promptId is String) {
            throw PayloadError.invalidField("prompt_id")
        }

        let type: DIMessageType
        switch event {
        case "SessionStart", "UserPromptSubmit": type = .sessionStart
        case "SessionEnd": type = .sessionEnd
        case "PreToolUse": type = .toolStart
        case "PostToolUse": type = .toolComplete
        case "PermissionRequest": type = .permissionRequest
        case "Stop": type = .statusUpdate
        case "PostCompaction": type = .recap
        default: throw PayloadError.unsupportedEvent(event)
        }

        var message = DIMessage(type: type, sessionId: sessionId)
        message.agentType = "devin"
        message.workingDir = nonempty(environment["DEVIN_PROJECT_DIR"])
            ?? nonempty(data["cwd"] as? String)
        message.terminal = nonempty(environment["TERM_PROGRAM"])
        message.termSessionId = nonempty(environment["TERM_SESSION_ID"])

        if event == "UserPromptSubmit" {
            guard let prompt = data["prompt"] as? String else {
                throw PayloadError.invalidField("prompt")
            }
            message.prompt = prompt
        }

        if type == .toolStart || type == .toolComplete || type == .permissionRequest {
            guard let name = nonempty(data["tool_name"] as? String),
                  let input = data["tool_input"] as? [String: Any] else {
                throw PayloadError.invalidField("tool_name/tool_input")
            }
            let inputText = try jsonString(input)
            message.tool = name
            message.toolInput = inputText
            if type == .permissionRequest {
                // 不把 question/exit_plan_mode 工具名猜成问答或计划请求。
                message.permDescription = inputText
                message.filePath = input["file_path"] as? String ?? input["path"] as? String
            }
            if type == .toolComplete {
                guard let response = data["tool_response"] as? [String: Any] else {
                    throw PayloadError.invalidField("tool_response")
                }
                message.toolResult = try jsonString(response)
                if response["success"] as? Bool == false { message.observedState = "error" }
            }
        }

        if event == "PostCompaction" {
            // 此时压缩已经完成，不发送会令界面进入“正在压缩”的 contextCompact。
            message.recapText = data["summary"] as? String
        }
        // Stop 只表明该轮停止；协议没有最终回答字段，不能把 reason 等伪装成回答。
        return message
    }

    static func permissionResponse(approved: Bool) -> DIBridge.PermissionHookResponse {
        DIBridge.PermissionHookResponse(
            stdout: approved ? "{\"decision\":\"approve\"}" : "{\"decision\":\"block\"}",
            exitCode: 0
        )
    }

    /// exit 1 不能表达拒绝；这里采用 XIsland 的保守阻断策略，不代表宿主会自动授权。
    static func unavailablePermissionResponse() -> DIBridge.PermissionHookResponse {
        DIBridge.PermissionHookResponse(
            stdout: "{\"decision\":\"block\",\"reason\":\"X Island could not complete this permission request.\"}",
            exitCode: 2
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
