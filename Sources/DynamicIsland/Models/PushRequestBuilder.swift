import Foundation

/// 纯函数：只构造请求，不发网络。便于单测验证每个渠道的 URL 与 body。
enum PushChannelRequestBuilder {
    /// 调用方必须先传 `EventRedaction.redact` 的结果；本方法不做二次校验以外的内容清洗。
    static func makeRequest(config: PushConfiguration,
                            event: IslandEvent,
                            redactedDetail: String) -> URLRequest? {
        guard config.isValid,
              config.enabledEvents.contains(event.kind.rawValue),
              let base = URL(string: config.endpoint) else { return nil }

        // 标题同样会进入 Bark 的 URL 路径和所有渠道的正文，必须一起脱敏。
        let title = event.title.isEmpty ? "X Island" : EventRedaction.redact(event.title)
        let body = redactedDetail.isEmpty ? event.kind.rawValue : redactedDetail

        if config.kind == .bark {
            guard let encodedTitle = percent(title), let encodedBody = percent(body),
                  var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
            let existing = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = "/" + [existing, encodedTitle, encodedBody]
                .filter { !$0.isEmpty }.joined(separator: "/")
            guard let url = components.url else { return nil }
            return URLRequest(url: url)
        }

        var request = URLRequest(url: base)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonBody(for: config, event: event, title: title, body: body)
        if config.kind == .ntfy {
            request.setValue(title, forHTTPHeaderField: "Title")
            request.setValue(String(event.requiresUserDecision ? 4 : 3), forHTTPHeaderField: "Priority")
        }
        return request
    }

    /// Webhook 转发的结构化事件。刻意不含密钥、不含原始命令、不含决定按钮。
    static func webhookPayload(event: IslandEvent, title: String, body: String) -> [String: String] {
        [
            "source": "X Island",
            "event": event.kind.rawValue,
            "sessionId": event.sessionId,
            "requestId": event.requestId ?? "",
            "title": title,
            "detail": body,
            "occurredAt": ISO8601DateFormatter().string(from: event.occurredAt),
        ]
    }

    private static func jsonBody(for config: PushConfiguration,
                                 event: IslandEvent,
                                 title: String, body: String) -> Data? {
        let payload: [String: Any]
        switch config.kind {
        case .webhook:
            payload = webhookPayload(event: event, title: title, body: body)
        case .ntfy:
            payload = ["topic": "xisland", "message": body, "title": title,
                       "tags": [event.kind.rawValue],
                       "priority": event.requiresUserDecision ? 4 : 3]
        case .slack, .wecom:
            payload = ["text": "\(title)\n\(body)"]
        case .dingTalk:
            payload = ["msgtype": "text", "text": ["content": "\(title)\n\(body)"]]
        case .feishu:
            payload = ["msg_type": "text", "content": ["text": "\(title)\n\(body)"]]
        case .telegram:
            payload = ["chat_id": config.secret, "text": "\(title)\n\(body)"]
        case .bark:
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private static func percent(_ text: String) -> String? {
        text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    }
}
