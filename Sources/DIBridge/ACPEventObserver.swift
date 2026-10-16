import Foundation
import CoreFoundation
import CryptoKit
import DIShared

/// ACP 观察状态机，不产生 JSON-RPC 应答，也不消费认证、MCP 配置或表单答案。
/// 传输层仍须逐字节转发原始数据；这里返回的消息只发往 XIsland。
final class ACPEventObserver {
    enum Direction { case clientToAgent, agentToClient }
    enum ObserverError: Error { case invalidSource }
    private struct Request {
        let method: String
        let session: String?
        let cwd: String?
        let prompt: String?
    }
    private final class Session {
        var cwd: String?
        var confirmed = false
        var foreground = "idle"
        var prompts: Set<String> = []
        var loading = false
        var replay: [DIMessage] = []
        var tools: [String: [String: Any]] = [:]
        var messages: [String: String] = [:]
        var anonymousText = ""
    }
    private let host: String
    private let namespace: String
    private var version: Int?
    private var clientRequests: [String: Request] = [:]
    private var agentRequests: [String: Request] = [:]
    private var sessions: [String: Session] = [:]
    private var output: [DIMessage] = []
    private(set) var isObserving = true

    init(host: String, source: String) throws {
        guard ["zed", "jetbrains_ai"].contains(host), Self.id(source) != nil else { throw ObserverError.invalidSource }
        self.host = host
        namespace = SHA256.hash(data: Data(source.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func consume(_ data: Data, direction: Direction) -> [DIMessage] {
        output = []
        guard isObserving else { return [] }
        guard data.count <= 1_048_576 else { return suspend() }
        guard let packet = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              packet["jsonrpc"] as? String == "2.0" else { return [] }
        guard packet["method"] == nil || packet["method"] is String,
              !(packet["result"] != nil && packet["error"] != nil) else { return [] }
        if let method = packet["method"] as? String {
            let parameters = packet["params"] as? [String: Any] ?? [:]
            let requestID = Self.requestID(packet["id"])
            if direction == .clientToAgent {
                client(method, id: requestID, parameters: parameters)
            } else {
                agent(method, id: requestID, parameters: parameters)
            }
        } else if let requestID = Self.requestID(packet["id"]) {
            if direction == .agentToClient { agentResponse(requestID, packet: packet) }
            else { clientResponse(requestID, packet: packet) }
        }
        var retained = 0
        for session in sessions.values {
            for text in session.messages.values { retained += text.utf8.count }
            for tool in session.tools.values {
                for value in tool.values { retained += (value as? String)?.utf8.count ?? 0 }
            }
            for message in session.replay {
                retained += message.status?.utf8.count ?? 0
                retained += message.prompt?.utf8.count ?? 0
                retained += message.toolResult?.utf8.count ?? 0
            }
            retained += session.anonymousText.utf8.count
        }
        for request in clientRequests.values { retained += request.prompt?.utf8.count ?? 0 }
        if retained > 2_097_152 { return suspend() }
        return output
    }

    /// 丢失观察数据后宁可暂停，不能用不完整的 request ID 映射猜测后续响应。
    func suspend() -> [DIMessage] {
        output = []
        for (id, session) in sessions where session.confirmed {
            emit(id, status: "ACP 观察已暂停；原通道继续运行", state: nil)
        }
        isObserving = false
        clientRequests.removeAll(); agentRequests.removeAll(); sessions.removeAll()
        return output
    }

    private func client(_ method: String, id: String?, parameters: [String: Any]) {
        if method == "initialize", let id {
            guard version == nil, clientRequests[id] == nil, clientRequests.count < 1024 else { _ = suspend(); return }
            clientRequests[id] = Request(method: method, session: nil, cwd: nil, prompt: nil)
            return
        }
        guard version != nil else { return }
        if version == 2 && method == "session/load" { return }
        let sessionID = Self.id(parameters["sessionId"])
        if method == "session/cancel", let sessionID, sessions[sessionID] != nil {
            emit(sessionID, status: "客户端已请求取消；等待 Agent 确认", state: nil)
            return
        }
        if method == "$/cancel_request" {
            if let key = Self.requestID(parameters["requestId"]), let session = clientRequests[key]?.session {
                emit(session, status: "客户端已请求取消调用；等待响应", state: nil)
            }
            return
        }
        guard ["session/new", "session/load", "session/resume", "session/prompt", "session/close", "session/delete"].contains(method), let id else { return }
        guard clientRequests[id] == nil, clientRequests.count < 1024 else { _ = suspend(); return }
        guard method == "session/new" || sessionID != nil else { return }
        let cwd = (parameters["cwd"] as? String).flatMap { $0.hasPrefix("/") && !$0.utf8.contains(0) ? $0 : nil }
        let prompt = method == "session/prompt" ? Self.text(parameters["prompt"]) : nil
        clientRequests[id] = Request(method: method, session: sessionID, cwd: cwd, prompt: prompt)
        if ["session/load", "session/resume"].contains(method), let sessionID {
            guard let session = getSession(sessionID) else { return }
            session.cwd = cwd; session.loading = method == "session/load"
        }
        if method == "session/prompt", let sessionID, let session = sessions[sessionID], session.confirmed {
            session.prompts.insert(id)
            if version == 1 {
                session.anonymousText = ""
                var message = base(sessionID, type: .sessionStart)
                message.prompt = prompt
                output.append(message)
                session.foreground = "active"
                restate(sessionID)
            }
        }
    }

    private func agentResponse(_ id: String, packet: [String: Any]) {
        guard let request = clientRequests.removeValue(forKey: id) else { return }
        let result = packet["result"] as? [String: Any]
        if request.method == "initialize" {
            version = nil
            if let raw = result?["protocolVersion"] as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID(),
               [1.0, 2.0].contains(raw.doubleValue) { version = raw.intValue }
            return
        }
        guard version != nil else { return }
        if request.method == "session/new" {
            guard let result, let id = Self.id(result["sessionId"]), let session = getSession(id) else { return }
            session.confirmed = true; session.cwd = request.cwd
            emit(id, status: "ACP 会话已连接", state: "idle")
            return
        }
        guard let idString = request.session, let session = sessions[idString] else { return }
        if request.method == "session/load" || request.method == "session/resume" {
            session.loading = false
            guard result != nil else { session.replay = []; return }
            session.confirmed = true
            emit(idString, status: "ACP 会话已恢复", state: "idle")
            output.append(contentsOf: session.replay); session.replay = []
            restate(idString)
        } else if request.method == "session/prompt" {
            session.prompts.remove(id)
            if result == nil {
                if version == 1 { session.foreground = session.prompts.isEmpty ? "error" : "active" }
                emit(idString, status: "ACP prompt 请求失败", state: version == 1 ? effectiveState(idString) : nil)
            } else if version == 1, let reason = result?["stopReason"] as? String {
                session.foreground = session.prompts.isEmpty ? "idle" : "active"
                emit(idString, status: "ACP 回合结束：\(reason)", state: effectiveState(idString))
            } else if version == 2, let messageID = Self.id(result?["messageId"]), let prompt = request.prompt {
                let key = "user:" + messageID
                if session.messages[key] == nil, session.messages.count >= 128 { _ = suspend(); return }
                if session.messages[key] == nil { session.messages[key] = prompt }
                var message = base(idString, type: .statusUpdate)
                message.prompt = session.messages[key]; message.nativeMessageId = messageID
                output.append(message)
                // v2 是接收确认；只有 state_update 能证明前台工作结束。
            }
        } else if ["session/close", "session/delete"].contains(request.method), result != nil {
            var message = base(idString, type: .sessionEnd)
            message.observedState = "completed"; message.status = "ACP 活跃会话已关闭"
            output.append(message)
            sessions.removeValue(forKey: idString)
            agentRequests = agentRequests.filter { $0.value.session != idString }
        }
    }

    private func agent(_ method: String, id: String?, parameters: [String: Any]) {
        guard version != nil else { return }
        if method == "session/update", let session = Self.id(parameters["sessionId"]), let update = parameters["update"] as? [String: Any] {
            updateSession(session, update: update)
            return
        }
        if ["session/request_permission", "elicitation/create"].contains(method), let id,
           let sessionID = Self.id(parameters["sessionId"]), sessions[sessionID] != nil {
            guard agentRequests[id] == nil, agentRequests.count < 1024 else { _ = suspend(); return }
            if method == "session/request_permission" {
                guard parameters["options"] is [[String: Any]],
                      version == 1 ? parameters["toolCall"] is [String: Any] : parameters["title"] is String else { return }
            } else {
                guard ["form", "url"].contains(parameters["mode"] as? String ?? "") else { return }
            }
            agentRequests[id] = Request(method: method, session: sessionID, cwd: nil, prompt: nil)
            emit(sessionID, status: method == "session/request_permission" ? "请在编辑器处理 ACP 权限请求" : "请在编辑器处理 ACP 输入请求",
                 state: effectiveState(sessionID))
        }
    }

    private func clientResponse(_ id: String, packet: [String: Any]) {
        guard packet["result"] != nil || packet["error"] != nil,
              let request = agentRequests.removeValue(forKey: id), let session = request.session else { return }
        // 只知道客户端已回答，不能把未知 outcome 当批准，也不读取表单 content。
        restate(session)
    }

    private func updateSession(_ id: String, update: [String: Any]) {
        guard let session = sessions[id], let type = update["sessionUpdate"] as? String else { return }
        if version == 2, type == "state_update" {
            switch update["state"] as? String {
            case "running": session.foreground = "active"
            case "idle": session.foreground = "idle"
            case "requires_action": session.foreground = "waitingAnswer"
            default: return
            }
            if update["state"] as? String == "idle", let reason = update["stopReason"] as? String {
                emit(id, status: "ACP 前台结束：\(Self.bounded(reason))", state: effectiveState(id))
            } else { restate(id) }
            return
        }
        if (version == 1 && type == "plan") || (version == 2 && type == "plan_update") {
            let plan = version == 1 ? update : update["plan"] as? [String: Any] ?? [:]
            guard version == 1 || plan["type"] as? String == "items",
                  let entries = plan["entries"] as? [[String: Any]] else { return }
            let lines = entries.prefix(128).compactMap { entry -> String? in
                guard let content = entry["content"] as? String, let status = entry["status"] as? String else { return nil }
                return "[\(Self.bounded(status))] \(Self.bounded(content))"
            }
            var message = base(id, type: .statusUpdate)
            message.status = "ACP 执行计划：\n" + Self.bounded(lines.joined(separator: "\n"))
            publish(message, session: session)
            return
        }
        if version == 2, type == "tool_call_content_chunk", let toolID = Self.id(update["toolCallId"]),
           let added = Self.toolText([update["content"] as Any]) {
            if session.tools[toolID] == nil, session.tools.count >= 256 { _ = suspend(); return }
            var tool = session.tools[toolID] ?? [:]
            let content = Self.bounded((tool["content"] as? String ?? "") + added)
            tool["content"] = content
            session.tools[toolID] = tool
            updateSession(id, update: ["sessionUpdate": "tool_call_update", "toolCallId": toolID,
                                      "content": [["type": "content", "content": ["type": "text", "text": content]]]])
            return
        }
        if ["agent_message_chunk", "user_message_chunk", "agent_message", "user_message"].contains(type) {
            let isUser = type.hasPrefix("user_")
            guard version == 2 || type.hasSuffix("_chunk") else { return }
            if let messageID = Self.id(update["messageId"]) {
                let key = (isUser ? "user:" : "agent:") + messageID
                if session.messages[key] == nil, session.messages.count >= 128 { _ = suspend(); return }
                if type.hasSuffix("_chunk") {
                    guard let text = Self.text([update["content"] as Any]) else { return }
                    session.messages[key] = Self.bounded((session.messages[key] ?? "") + text)
                } else if update.keys.contains("content") {
                    session.messages[key] = Self.text(update["content"]) ?? ""
                } else { return }
                var message = base(id, type: .statusUpdate)
                message.nativeMessageId = messageID
                if isUser { message.prompt = session.messages[key] }
                else { message.status = session.messages[key]; message.statusIsAssistantReply = true; message.nativeMessagePartial = true }
                publish(message, session: session)
            } else if version == 1, !isUser, !session.loading, session.prompts.count == 1,
                      let text = Self.text([update["content"] as Any]) {
                session.anonymousText = Self.bounded(session.anonymousText + text)
                var message = base(id, type: .statusUpdate)
                message.status = session.anonymousText; message.statusIsAssistantReply = true; message.nativeMessagePartial = true
                publish(message, session: session)
            }
            return
        }
        if ["tool_call", "tool_call_update"].contains(type), let toolID = Self.id(update["toolCallId"]) {
            if version == 2 && type == "tool_call" { return }
            if session.tools[toolID] == nil, session.tools.count >= 256 { _ = suspend(); return }
            var tool = session.tools[toolID] ?? [:]
            for field in ["title", "name", "status", "content", "rawInput", "locations"] where update.keys.contains(field) {
                let value = update[field]!
                if value is NSNull { tool.removeValue(forKey: field) }
                else if field == "rawInput" { tool[field] = Self.bounded(DIBridge.outputText(value) ?? "") }
                else if field == "content" { tool[field] = Self.toolText(value) ?? "" }
                else if field == "locations" { tool[field] = ((value as? [[String: Any]])?.first?["path"] as? String) }
                else if let text = value as? String { tool[field] = Self.bounded(text) }
            }
            session.tools[toolID] = tool
            guard let status = tool["status"] as? String,
                  ["in_progress", "completed", "failed", "cancelled"].contains(status) else { return }
            if version == 1 && status == "cancelled" { return }
            var message = base(id, type: status == "in_progress" ? .toolStart : .toolComplete)
            message.toolCallId = toolID
            message.tool = tool["name"] as? String ?? tool["title"] as? String ?? "ACP tool"
            message.toolInput = tool["rawInput"] as? String ?? ""
            message.toolResult = tool["content"] as? String
            message.filePath = tool["locations"] as? String
            if status == "failed" { message.observedState = "error" }
            if status == "cancelled" { message.toolResult = "ACP 工具已取消" }
            if !(session.loading && status == "in_progress") { publish(message, session: session) }
            if session.confirmed, status != "failed" || version == 2 || agentRequests.values.contains(where: { $0.session == id }) {
                restate(id)
            }
            return
        }
        if type == "usage_update", let cost = update["cost"] as? [String: Any], cost["currency"] as? String == "USD",
           let amount = cost["amount"] as? NSNumber, CFGetTypeID(amount) != CFBooleanGetTypeID(), amount.doubleValue.isFinite, amount.doubleValue >= 0 {
            var message = base(id, type: .statusUpdate)
            message.costUSD = amount.doubleValue; message.usageIsCumulative = true
            publish(message, session: session)
            // used/size 是上下文占用，不是累计消耗，不能写进 totalTokens。
        }
    }

    private func publish(_ message: DIMessage, session: Session) {
        if session.loading {
            guard session.replay.count < 256 else { _ = suspend(); return }
            var replay = message
            replay.nativeMessageReplay = true
            session.replay.append(replay)
        } else if session.confirmed { output.append(message) }
    }

    private func effectiveState(_ id: String) -> String? {
        if agentRequests.values.contains(where: { $0.session == id && $0.method == "session/request_permission" }) { return "waitingPermission" }
        if agentRequests.values.contains(where: { $0.session == id && $0.method == "elicitation/create" }) { return "waitingAnswer" }
        return sessions[id]?.foreground
    }

    private func restate(_ id: String) { emit(id, status: "ACP 状态更新", state: effectiveState(id)) }

    private func emit(_ id: String, status: String, state: String?) {
        guard let session = sessions[id], session.confirmed else { return }
        var message = base(id, type: .statusUpdate)
        message.status = status; message.observedState = state
        output.append(message)
    }

    private func base(_ id: String, type: DIMessageType) -> DIMessage {
        let encoded = Data(id.utf8).base64EncodedString()
        var message = DIMessage(type: type, sessionId: "\(host)-acp-\(namespace)-\(encoded)")
        message.agentType = host; message.workingDir = sessions[id]?.cwd
        message.statusIsAssistantReply = false; message.nativeEvent = "acp"
        return message
    }

    private func getSession(_ id: String) -> Session? {
        if let session = sessions[id] { return session }
        guard sessions.count < 32 else { _ = suspend(); return nil }
        let session = Session(); sessions[id] = session; return session
    }

    private static func id(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 4096,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }

    private static func requestID(_ value: Any?) -> String? {
        if value is NSNull { return "null" }
        if let string = value as? String, string.utf8.count <= 4096 { return "s:" + string }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["q", "i", "s", "l", "c"].contains(String(cString: number.objCType)) else { return nil }
        return "n:" + number.stringValue
    }

    private static func bounded(_ text: String) -> String { String(decoding: text.utf8.prefix(32_768), as: UTF8.self) }
    private static func text(_ value: Any?) -> String? {
        guard let blocks = value as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        guard !texts.isEmpty else { return nil }
        return bounded(texts.joined())
    }
    private static func toolText(_ value: Any?) -> String? {
        guard let blocks = value as? [[String: Any]] else { return nil }
        return text(blocks.compactMap { $0["type"] as? String == "content" ? $0["content"] as? [String: Any] : nil })
    }
}
