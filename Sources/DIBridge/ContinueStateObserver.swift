import Foundation
import CoreFoundation
import CryptoKit
import DIShared

/// cn serve 1.5.47 的状态快照。没有把普通 CLI/IDE 或未接线 hooks 算入此通道。
final class ContinueStateObserver {
    enum StateError: Error { case invalidSnapshot(String), sessionChanged }
    private(set) var sessionID: String?
    private var toolDigests: [String: String] = [:]
    private var stateDigest: String?
    private var usageDigest: String?
    private var hasObservedState = false

    init(expectedSessionID: String? = nil) { sessionID = expectedSessionID }

    func consume(_ data: Data) throws -> [DIMessage] {
        guard data.count <= 2_097_152,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = root["session"] as? [String: Any],
              let id = string(session["sessionId"]), !id.isEmpty,
              let processing = boolean(root["isProcessing"]),
              let queued = integer(root["messageQueueLength"]),
              let history = session["history"] as? [[String: Any]] else { throw StateError.invalidSnapshot("root") }
        if let expected = sessionID, expected != id { throw StateError.sessionChanged }
        let permission: [String: Any]?
        if root["pendingPermission"] is NSNull { permission = nil }
        else if let value = root["pendingPermission"] as? [String: Any],
                let request = string(value["requestId"]), !request.isEmpty,
                let tool = string(value["toolName"]), !tool.isEmpty { permission = value }
        else { throw StateError.invalidSnapshot("pendingPermission") }
        sessionID = id
        let cwd = string(session["workspaceDirectory"])
        let model = string(session["chatModelTitle"])
        var output: [DIMessage] = []
        var nextTools: [String: String] = [:]
        for item in history {
            guard let states = item["toolCallStates"] as? [[String: Any]] else { continue }
            for state in states {
                guard let callID = string(state["toolCallId"]), !callID.isEmpty,
                      let call = state["toolCall"] as? [String: Any], call["id"] as? String == callID,
                      let function = call["function"] as? [String: Any],
                      let name = string(function["name"]), !name.isEmpty,
                      let status = state["status"] as? String,
                      ["generating", "generated", "calling", "done", "errored", "canceled"].contains(status) else { continue }
                let input = state["parsedArgs"].flatMap(DIBridge.outputText).map(bounded)
                let result = (state["output"] as? [[String: Any]])?.filter { $0["hidden"] as? Bool != true }
                    .compactMap { $0["content"] as? String }.map(bounded).joined(separator: "\n")
                let digest = fingerprint([callID, name, status, input ?? "", result ?? ""])
                guard nextTools[callID] == nil || nextTools[callID] == digest else { throw StateError.invalidSnapshot("duplicate tool identity") }
                if nextTools[callID] == digest { continue }
                nextTools[callID] = digest
                guard toolDigests[callID] != digest, ["calling", "done", "errored", "canceled"].contains(status) else { continue }
                var message = base(id, cwd: cwd, model: model, type: status == "calling" ? .toolStart : .toolComplete)
                message.nativeMessageReplay = !hasObservedState && status != "calling"
                message.toolCallId = callID; message.tool = name; message.toolInput = input
                message.toolResult = status == "canceled" ? "Continue 工具已取消" : result.map(bounded)
                if status == "errored" { message.observedState = "error" }
                output.append(message)
            }
        }
        guard nextTools.count <= 4096 else { throw StateError.invalidSnapshot("tool history limit") }
        toolDigests = nextTools
        if let usage = session["usage"] as? [String: Any], let input = integer(usage["promptTokens"]),
           let completion = integer(usage["completionTokens"]), let cost = number(usage["totalCost"]) {
            let digest = fingerprint([String(input), String(completion), String(cost)])
            if digest != usageDigest {
                var message = base(id, cwd: cwd, model: model, type: .statusUpdate)
                message.tokensIn = input; message.tokensOut = completion; message.costUSD = cost; message.usageIsCumulative = true
                if input <= Int.max - completion { message.totalTokens = input + completion }
                output.append(message); usageDigest = digest
            }
        }
        // 消息无稳定ID，不按可变数组位置或文本哈希伪造聊天记录身份。
        let reply = history.reversed().compactMap { item -> String? in
            guard let message = item["message"] as? [String: Any], message["role"] as? String == "assistant" else { return nil }
            if let text = message["content"] as? String, !text.isEmpty { return bounded(text) }
            if let blocks = message["content"] as? [[String: Any]] {
                let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
                return text.isEmpty ? nil : bounded(text)
            }
            return nil
        }.first
        let observed = permission != nil ? "waitingPermission" : processing ? "active" : "idle"
        var status = permission.map { "请在 Continue 处理 \($0["toolName"] as? String ?? "") 权限请求" }
            ?? (processing ? "Continue 正在处理" : "Continue 当前空闲")
        if queued > 0 { status += "；排队 \(queued) 条" }
        if let reply { status += "\n回复预览：" + reply }
        let digest = fingerprint([observed, status, permission?["requestId"] as? String ?? "", cwd ?? "", model ?? ""])
        // 工具更新不能把原生等待状态误改为active，快照状态最后应用。
        if stateDigest != digest || !output.isEmpty {
            var message = base(id, cwd: cwd, model: model, type: .statusUpdate)
            message.status = bounded(status); message.observedState = observed
            output.append(message); stateDigest = digest
        }
        hasObservedState = true
        return output
    }

    func disconnected() -> DIMessage? {
        guard hasObservedState, let id = sessionID else { return nil }
        var message = base(id, cwd: nil, model: nil, type: .statusUpdate)
        message.status = "Continue 状态观察已结束；服务会话未被关闭"
        return message
    }

    private func base(_ id: String, cwd: String?, model: String?, type: DIMessageType) -> DIMessage {
        var message = DIMessage(type: type, sessionId: "continue-server-" + Data(id.utf8).base64EncodedString())
        message.agentType = "continue"; message.workingDir = cwd; message.model = model
        message.statusIsAssistantReply = false; message.nativeEvent = "continue_snapshot"
        return message
    }
    private func string(_ value: Any?) -> String? {
        guard let text = value as? String, text.utf8.count <= 4096, !text.utf8.contains(0) else { return nil }
        return text
    }
    private func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }
    private func integer(_ value: Any?) -> Int? {
        guard let value = number(value), value.rounded(.towardZero) == value, value < Double(Int.max) else { return nil }
        return Int(value)
    }
    private func bounded(_ value: String) -> String { String(decoding: value.utf8.prefix(32_768), as: UTF8.self) }
    private func fingerprint(_ values: [String]) -> String {
        SHA256.hash(data: (try? JSONEncoder().encode(values)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
}
