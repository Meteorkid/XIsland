import Foundation
import CoreFoundation
import DIShared

/// Cline VS Code 文件 hooks；cancel:false 只允许 hook 继续，不代表用户批准工具。
enum ClineHookAdapter {
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
        let event = try requiredString(data, "hookName")
        guard event == hookType else { throw PayloadError.invalidField("hookName") }
        let taskId = try requiredString(data, "taskId")
        let timestamp = try requiredString(data, "timestamp")
        guard timestamp.utf8.allSatisfy({ (48...57).contains($0) }),
              let milliseconds = Double(timestamp), milliseconds.isFinite,
              milliseconds <= 253_402_300_799_999 else { throw PayloadError.invalidField("timestamp") }

        let type: DIMessageType
        let field: String
        switch event {
        case "TaskStart": (type, field) = (.sessionStart, "taskStart")
        case "TaskResume": (type, field) = (.sessionStart, "taskResume")
        case "UserPromptSubmit": (type, field) = (.sessionStart, "userPromptSubmit")
        case "PreToolUse": (type, field) = (.toolStart, "preToolUse")
        case "PostToolUse": (type, field) = (.toolComplete, "postToolUse")
        case "TaskComplete": (type, field) = (.statusUpdate, "taskComplete")
        case "TaskCancel": (type, field) = (.statusUpdate, "taskCancel")
        default: throw PayloadError.unsupportedEvent(event)
        }
        guard let payload = data[field] as? [String: Any] else { throw PayloadError.invalidField(field) }

        var message = DIMessage(type: type, sessionId: "cline-\(taskId)")
        message.agentType = "cline"
        message.timestamp = Date(timeIntervalSince1970: milliseconds / 1_000)
        message.terminal = environment["TERM_PROGRAM"]
        message.termSessionId = environment["TERM_SESSION_ID"]
        message.statusIsAssistantReply = false
        if let roots = data["workspaceRoots"] {
            guard let roots = roots as? [String], roots.allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) }) else {
                throw PayloadError.invalidField("workspaceRoots")
            }
            // 多根工作区没有当前工具所属根字段，不能任取一个冒充 cwd。
            if roots.count == 1 { message.workingDir = roots[0] }
        }
        if let model = data["model"] {
            guard let model = model as? [String: Any] else { throw PayloadError.invalidField("model") }
            let slug = try optionalString(model, "slug")
            if let slug, !slug.isEmpty, slug != "unknown" { message.model = slug }
        }

        switch event {
        case "TaskStart", "TaskResume", "TaskComplete", "TaskCancel":
            let metadata = try stringMap(payload, "taskMetadata")
            if let nestedId = metadata["taskId"], nestedId != taskId { throw PayloadError.invalidField("taskMetadata.taskId") }
            if event == "TaskStart" { message.prompt = metadata["initialTask"] }
            if event == "TaskResume" { _ = try stringMap(payload, "previousState") }
            if event == "TaskComplete" {
                // 当前扩展在 afterRun 发出此事件；后续仍可向同一任务提交新轮次。
                message.observedState = "idle"
                message.status = metadata["result"]
                message.statusIsAssistantReply = metadata["result"]?.isEmpty == false
            }
            if event == "TaskCancel" {
                message.observedState = "idle"
                message.status = "任务已取消"
            }
        case "UserPromptSubmit":
            message.prompt = try string(payload, "prompt")
            if let attachments = payload["attachments"], !(attachments is [String]) {
                throw PayloadError.invalidField("userPromptSubmit.attachments")
            }
        case "PreToolUse", "PostToolUse":
            message.tool = try requiredString(payload, "toolName")
            let parameters = try stringMap(payload, "parameters")
            message.toolInput = String(decoding: try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys]), as: UTF8.self)
            message.filePath = parameters["path"] ?? parameters["file_path"]
            if event == "PostToolUse" {
                // Proto3 的 toJSON 会省略 false、空字符串和空 map，缺省值须按协议恢复。
                message.toolResult = try optionalString(payload, "result") ?? ""
                var success = false
                if let value = payload["success"] {
                    guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                        throw PayloadError.invalidField("postToolUse.success")
                    }
                    success = value.boolValue
                }
                if !success { message.observedState = "error" }
            }
        default: break
        }
        return message
    }

    private static func stringMap(_ data: [String: Any], _ field: String) throws -> [String: String] {
        guard let value = data[field] else { return [:] }
        guard let result = value as? [String: String], result.values.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw PayloadError.invalidField(field)
        }
        return result
    }

    private static func requiredString(_ data: [String: Any], _ field: String) throws -> String {
        let value = try string(data, field)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PayloadError.invalidField(field) }
        return value
    }

    private static func optionalString(_ data: [String: Any], _ field: String) throws -> String? {
        guard data[field] != nil else { return nil }
        return try string(data, field)
    }

    private static func string(_ data: [String: Any], _ field: String) throws -> String {
        guard let value = data[field] as? String, !value.utf8.contains(0) else { throw PayloadError.invalidField(field) }
        return value
    }
}
