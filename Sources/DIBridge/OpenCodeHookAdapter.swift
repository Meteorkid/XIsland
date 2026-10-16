import Foundation
import CoreFoundation
import DIShared

enum OpenCodeHookAdapter {
    static func normalize(hookType: String, stdinData: [String: Any]?) throws -> DIMessage {
        guard let data = stdinData, JSONSerialization.isValidJSONObject(data), data["native_event"] as? String == hookType else {
            throw DIBridge.NativePayloadError.invalidField("native_event")
        }
        let id = try text(data, "session_id")
        let type: DIMessageType
        switch hookType {
        case "session.created", "prompt.submitted": type = .sessionStart
        case "session.deleted": type = .sessionEnd
        case "tool.started": type = .toolStart
        case "tool.completed", "tool.failed": type = .toolComplete
        case "permission.asked": type = .permissionRequest
        case "question.asked": type = .question
        case "interaction.resolved": type = .interactionResolved
        case "session.compacted": type = .recap
        case "session.idle", "session.busy", "session.error", "assistant.message", "interaction.unavailable": type = .statusUpdate
        default: throw DIBridge.NativePayloadError.invalidField("native_event")
        }
        var message = DIMessage(type: type, sessionId: "opencode-\(id)")
        message.agentType = "opencode"
        message.workingDir = data["cwd"] as? String
        message.terminal = data["terminal"] as? String
        message.model = data["model"] as? String
        message.statusIsAssistantReply = false
        if ["permission.asked", "question.asked", "interaction.resolved", "interaction.unavailable"].contains(hookType) {
            message.nativeRequestId = try text(data, "native_request_id")
            let kind = try text(data, "native_request_kind")
            guard ["permission", "question"].contains(kind),
                  hookType != "permission.asked" || kind == "permission",
                  hookType != "question.asked" || kind == "question" else { throw DIBridge.NativePayloadError.invalidField("native_request_kind") }
            message.nativeRequestKind = kind
        }
        switch hookType {
        case "prompt.submitted": message.prompt = data["prompt"] as? String
        case "session.deleted": message.observedState = "completed"
        case "tool.started", "tool.completed", "tool.failed":
            message.tool = try text(data, "tool_name")
            message.toolCallId = try text(data, "tool_use_id")
            message.toolInput = DIBridge.outputText(data["tool_input"])
            message.toolResult = DIBridge.outputText(data["tool_response"])
            if hookType == "tool.failed" { message.observedState = "error" }
        case "permission.asked":
            message.tool = try text(data, "permission")
            guard let patterns = data["patterns"] as? [String] else { throw DIBridge.NativePayloadError.invalidField("patterns") }
            message.permDescription = patterns.joined(separator: "\n")
            message.toolInput = DIBridge.outputText(data["metadata"])
            if ["edit", "write", "external_directory"].contains(message.tool ?? ""), let path = patterns.first, path.hasPrefix("/") {
                message.filePath = path
            }
        case "question.asked":
            message.questionText = try text(data, "question")
            if let value = data["allow_custom_answer"] {
                guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                    throw DIBridge.NativePayloadError.invalidField("allow_custom_answer")
                }
            }
            let custom = data["allow_custom_answer"] as? Bool == true
            guard let options = data["options"] as? [String], !options.isEmpty || custom,
                  options.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  Set(options).count == options.count else { throw DIBridge.NativePayloadError.invalidField("options") }
            message.options = options
            message.allowsCustomAnswer = custom
            if let value = data["allow_multiple_answers"] {
                guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                    throw DIBridge.NativePayloadError.invalidField("allow_multiple_answers")
                }
                message.allowsMultipleAnswers = flag.boolValue
            }
        case "session.idle": message.observedState = "idle"
        case "session.busy": message.observedState = "active"
        case "session.error": message.observedState = "error"; message.status = data["error"] as? String
        case "assistant.message": message.status = data["message"] as? String; message.statusIsAssistantReply = true
        case "interaction.unavailable":
            message.observedState = message.nativeRequestKind == "permission" ? "waitingPermission" : "waitingAnswer"
            message.status = "Please respond in OpenCode."
        default: break
        }
        return message
    }

    static func permissionResponse(approved: Bool) -> DIBridge.PermissionHookResponse {
        .init(stdout: approved ? "{\"decision\":\"allow\"}" : "{\"decision\":\"deny\"}", exitCode: 0)
    }

    static func questionResponse(answer: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["answer": answer]), as: UTF8.self)
    }

    static func questionResponse(answers: [String]) throws -> String {
        guard !answers.isEmpty, answers.count <= 128, Set(answers).count == answers.count,
              answers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.utf8.contains(0) }),
              answers.reduce(0, { $0 + $1.utf8.count }) <= 8192 else {
            throw DIBridge.NativePayloadError.invalidField("selectedAnswers")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["answers": answers]), as: UTF8.self)
    }

    private static func text(_ data: [String: Any], _ key: String) throws -> String {
        guard let value = data[key] as? String, !value.utf8.contains(0),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DIBridge.NativePayloadError.invalidField(key) }
        return value
    }
}
