import Foundation
import DIShared

/// Wire 1.10 的原生审批合同；调用方仍须拥有连接并管理请求是否已解决。
struct KimiWireApproval: Equatable {
    enum ApprovalError: Error { case unsupportedContext, invalidRequest, invalidFeedback }
    let rpcID: String
    let requestID: String
    let toolCallID: String
    let sender: String
    let action: String
    let description: String
    let sourceKind: String?
    let sourceID: String?
    let agentID: String?
    let sourceDescription: String?
    let displayJSON: String

    init(packet: [String: Any], protocolVersion: String, isReplay: Bool) throws {
        guard protocolVersion == "1.10", !isReplay else { throw ApprovalError.unsupportedContext }
        guard JSONSerialization.isValidJSONObject(packet), packet["jsonrpc"] as? String == "2.0",
              packet["method"] as? String == "request",
              packet["result"] == nil, packet["error"] == nil,
              let params = packet["params"] as? [String: Any], params["type"] as? String == "ApprovalRequest",
              let payload = params["payload"] as? [String: Any] else { throw ApprovalError.invalidRequest }
        rpcID = try Self.text(packet, key: "id", limit: 4096)
        requestID = try Self.text(payload, key: "id", limit: 4096)
        toolCallID = try Self.text(payload, key: "tool_call_id", limit: 4096)
        sender = try Self.text(payload, key: "sender", limit: 4096, allowsEmpty: true)
        action = try Self.text(payload, key: "action", limit: 32_768, allowsEmpty: true)
        description = try Self.text(payload, key: "description", limit: 32_768, allowsEmpty: true)
        sourceKind = try Self.optionalText(payload, key: "source_kind")
        guard sourceKind == nil || ["foreground_turn", "background_agent"].contains(sourceKind!) else { throw ApprovalError.invalidRequest }
        sourceID = try Self.optionalText(payload, key: "source_id")
        agentID = try Self.optionalText(payload, key: "agent_id")
        sourceDescription = try Self.optionalText(payload, key: "source_description")
        let display: [[String: Any]]
        if let value = payload["display"] {
            guard let blocks = value as? [[String: Any]] else { throw ApprovalError.invalidRequest }
            display = blocks
        } else { display = [] }
        let encoded = try JSONSerialization.data(withJSONObject: display, options: .sortedKeys)
        guard encoded.count <= 131_072 else { throw ApprovalError.invalidRequest }
        displayJSON = String(decoding: encoded, as: UTF8.self)
    }

    func response(approved: Bool, feedback: String = "") throws -> Data {
        guard feedback.utf8.count <= 8192, !feedback.utf8.contains(0), !approved || feedback.isEmpty else {
            throw ApprovalError.invalidFeedback
        }
        let packet: [String: Any] = ["jsonrpc": "2.0", "id": rpcID,
            "result": ["request_id": requestID, "response": approved ? "approve" : "reject", "feedback": feedback]]
        var data = try JSONSerialization.data(withJSONObject: packet, options: .sortedKeys)
        data.append(10)
        return data
    }

    func permissionMessage(connectionID: UUID) -> DIMessage {
        var message = DIMessage(type: .permissionRequest, sessionId: "kimi-wire-connection-" + connectionID.uuidString.lowercased())
        message.agentType = "kimi"
        message.nativeEvent = "kimi_wire_approval"
        message.nativeRequestId = requestID
        message.nativeRequestKind = "permission"
        message.toolCallId = toolCallID
        message.tool = sender.isEmpty ? "Kimi operation" : sender
        var details = [action, description].filter { !$0.isEmpty }
        if let sourceDescription, !sourceDescription.isEmpty { details.append("来源：" + sourceDescription) }
        if sourceKind == "background_agent" { details.append("此操作来自后台代理") }
        if displayJSON != "[]" { details.append("原生操作详情：\n" + displayJSON) }
        message.permDescription = details.isEmpty ? "Kimi 请求执行操作，未提供说明" : details.joined(separator: "\n\n")
        message.statusIsAssistantReply = false
        return message
    }

    func resolvedMessage(connectionID: UUID) -> DIMessage {
        var message = DIMessage(type: .interactionResolved, sessionId: "kimi-wire-connection-" + connectionID.uuidString.lowercased())
        message.agentType = "kimi"
        message.nativeRequestId = requestID
        message.nativeRequestKind = "permission"
        return message
    }

    private static func text(_ object: [String: Any], key: String, limit: Int, allowsEmpty: Bool = false) throws -> String {
        guard let text = object[key] as? String, allowsEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= limit, !text.utf8.contains(0) else { throw ApprovalError.invalidRequest }
        return text
    }

    private static func optionalText(_ object: [String: Any], key: String) throws -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        return try text(object, key: key, limit: 4096, allowsEmpty: true)
    }
}
