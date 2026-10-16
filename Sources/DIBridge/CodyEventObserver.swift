import Foundation
import CoreFoundation
import CryptoKit
import DIShared

/// 仅接收显式包装的 Cody 5.5.26 Agent 输出，不订阅任意已打开的 IDE。
final class CodyEventObserver {
    enum ObserverError: Error { case invalidSource, invalidTranscript, sessionLimit }
    private let source: String
    private var fingerprints: [String: String] = [:]
    private var ended = false

    init(source: String) throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.utf8.count <= 256, !source.utf8.contains(0) else { throw ObserverError.invalidSource }
        self.source = source
    }

    func consumeAgentFrame(_ data: Data) throws -> [DIMessage] {
        guard !ended else { return [] }
        guard data.count <= 2_097_152,
              let packet = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              packet["jsonrpc"] as? String == "2.0", packet["id"] == nil,
              let method = packet["method"] as? String,
              ["webview/postMessage", "webview/postMessageStringEncoded"].contains(method) else { return [] }
        guard let params = packet["params"] as? [String: Any] else { throw ObserverError.invalidTranscript }
        let message: [String: Any]?
        if method == "webview/postMessageStringEncoded" {
            guard let text = params["stringEncodedMessage"] as? String else { throw ObserverError.invalidTranscript }
            message = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        } else { message = params["message"] as? [String: Any] }
        guard let message else { throw ObserverError.invalidTranscript }
        guard message["type"] as? String == "transcript" else { return [] }
        guard let chatID = message["chatID"] as? String, !chatID.isEmpty,
              chatID.utf8.count <= 4096, !chatID.utf8.contains(0),
              let processing = message["isMessageInProgress"] as? NSNumber,
              CFGetTypeID(processing) == CFBooleanGetTypeID(),
              let messages = message["messages"] as? [[String: Any]] else { throw ObserverError.invalidTranscript }
        guard fingerprints[chatID] != nil || fingerprints.count < 64 else { throw ObserverError.sessionLimit }
        let latest = messages.last
        let error = latest?["error"] as? [String: Any]
        let observed = processing.boolValue ? "active" : error != nil ? "error" : "idle"
        var status = processing.boolValue ? "Cody 正在回复" : "Cody 当前空闲"
        if error != nil { status = "Cody 本轮报告错误" }
        if let assistant = messages.last(where: { $0["speaker"] as? String == "assistant" }),
           let text = assistant["text"] as? String, !text.isEmpty {
            status += "\n回复预览：" + String(decoding: text.utf8.prefix(32_768), as: UTF8.self)
        }
        let digest = SHA256.hash(data: Data((observed + "\n" + status).utf8)).map { String(format: "%02x", $0) }.joined()
        guard fingerprints[chatID] != digest else { return [] }
        fingerprints[chatID] = digest
        // JSON 数组编码避免 source/chatID 分隔符歧义；不使用 panel ID 或工作目录合并。
        let identity = try JSONEncoder().encode([source, chatID]).base64EncodedString()
        var result = DIMessage(type: .statusUpdate, sessionId: "cody-agent-" + identity)
        result.agentType = "cody"
        result.nativeEvent = "cody_transcript"
        result.observedState = observed
        result.status = status
        result.statusIsAssistantReply = false
        return [result]
    }

    func finish(interrupted: Bool) -> [DIMessage] {
        guard !ended else { return [] }
        ended = true
        return fingerprints.keys.sorted().compactMap { chatID in
            guard let identity = try? JSONEncoder().encode([source, chatID]).base64EncodedString() else { return nil }
            var result = DIMessage(type: .statusUpdate, sessionId: "cody-agent-" + identity)
            result.agentType = "cody"
            result.nativeEvent = "cody_observation_ended"
            result.statusIsAssistantReply = false
            result.status = interrupted ? "Cody 状态观察已中断；显示的活动状态可能已过期" : "Cody 状态观察已结束；不代表原生会话结束"
            return result
        }
    }
}
