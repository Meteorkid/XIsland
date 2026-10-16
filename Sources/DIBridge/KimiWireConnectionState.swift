import Foundation

/// 从连接建立时开始观察双向报文；不修改握手能力、不猜测原生会话身份。
final class KimiWireConnectionState {
    private var initializationID: String?
    private var replayIDs: Set<String> = []
    private(set) var negotiatedVersion: String?
    private(set) var closed = false
    var canHandleLiveApproval: Bool { !closed && negotiatedVersion == "1.10" && replayIDs.isEmpty && initializationID == nil }

    func observeClient(_ packet: [String: Any]) {
        guard !closed, packet["jsonrpc"] as? String == "2.0",
              let method = packet["method"] as? String, ["initialize", "replay"].contains(method) else { return }
        guard let id = packet["id"] as? String, !id.isEmpty, id.utf8.count <= 4096, !id.utf8.contains(0),
              initializationID != id, !replayIDs.contains(id) else { close(); return }
        if method == "initialize" {
            guard initializationID == nil, replayIDs.isEmpty,
                  let params = packet["params"] as? [String: Any], params["protocol_version"] as? String == "1.10" else {
                close(); return
            }
            negotiatedVersion = nil
            initializationID = id
        } else {
            guard replayIDs.count < 16 else { close(); return }
            replayIDs.insert(id)
        }
    }

    func observeAgent(_ packet: [String: Any]) {
        guard !closed, packet["jsonrpc"] as? String == "2.0", packet["method"] == nil,
              let id = packet["id"] as? String, packet["result"] != nil || packet["error"] != nil else { return }
        if id == initializationID {
            initializationID = nil
            guard packet["error"] == nil, let result = packet["result"] as? [String: Any],
                  result["protocol_version"] as? String == "1.10" else { close(); return }
            negotiatedVersion = "1.10"
        } else if replayIDs.contains(id) {
            // 错误响应也结束该次回放；不能由另一条请求的响应提前解锁。
            if packet["error"] == nil {
                guard let result = packet["result"] as? [String: Any],
                      let status = result["status"] as? String, ["finished", "cancelled"].contains(status) else {
                    close(); return
                }
            }
            replayIDs.remove(id)
        }
    }

    func close() {
        closed = true
        negotiatedVersion = nil
        initializationID = nil
        replayIDs.removeAll()
    }
}
