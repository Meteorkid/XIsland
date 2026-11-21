import Foundation

/// 会话完成时用 LLM 归纳「做了什么 / 完成到哪一步」。
///
/// 密钥来自环境变量（OPENAI_API_KEY / ANTHROPIC_API_KEY）；没有密钥时静默跳过，
/// 卡片继续使用 `LocalRecapGenerator` 的事件归纳。每个会话只总结一次。
enum SessionSummarizer {
    private static var generatedSessionIDs = Set<String>()
    /// 记录生成时的工具事件数量：会话再次完成且事件增加时，摘要需要重做。
    private static var lastEventCount: [String: Int] = [:]
    /// 客户端自己上报过摘要的会话，不覆盖其内容。
    private static var clientReported = Set<String>()
    private static let lock = NSLock()

    static func markClientReported(_ sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        clientReported.insert(sessionID)
    }

    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: "llmRecapEnabled") as? Bool) ?? true
    }

    /// 有云端密钥或本地 Ollama 时才值得尝试。
    static var isAvailable: Bool {
        isEnabled
    }

    static func shouldSummarize(_ session: AgentSession) -> Bool {
        guard isEnabled, !session.events.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        if clientReported.contains(session.id) { return false }
        if let last = lastEventCount[session.id] {
            // 同一轮内重复完成不重做；有新事件才刷新。
            return session.events.count > last
        }
        return (session.recapText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func summarize(_ session: AgentSession, force: Bool = false) async -> String? {
        if force {
            guard isEnabled, !session.events.isEmpty else { return nil }
        } else {
            guard shouldSummarize(session) else { return nil }
            lock.lock(); generatedSessionIDs.insert(session.id); lock.unlock()
        }

        let prompt = makePrompt(session)
        var raw: String?
        switch preset.kind {
        case .anthropic:
            if let key = configuredKey {
                raw = await callAnthropic(prompt: prompt, key: key, model: modelName)
            }
        case .openAICompatible:
            if let key = configuredKey, let base = preset.baseURL {
                raw = await callChatCompletions(prompt: prompt, key: key, base: base, model: modelName)
            }
        case .ollama:
            if let model = await ollamaModel() {
                raw = await callOllama(prompt: prompt, model: model)
            }
        }
        // 选的是云端服务但没填 key 时，退回本机 Ollama。
        if raw == nil, preset.kind != .ollama, let model = await ollamaModel() {
            raw = await callOllama(prompt: prompt, model: model)
        }
        guard let text = raw else {
            // 失败时允许下次重试，否则该会话会被永久跳过。
            lock.lock(); generatedSessionIDs.remove(session.id); lock.unlock()
            return nil
        }
        lock.lock(); lastEventCount[session.id] = session.events.count; lock.unlock()
        return postProcess(text, status: session.status.displayName)
    }

    /// 去掉模型自带的「第 1 行」标签，并在缺少状态行时补齐。
    private static func postProcess(_ text: String, status: String) -> String {
        var lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        lines = lines.map {
            $0.replacingOccurrences(of: "^第[一二三四1-4]行[：:]\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "^中间行[：:]\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "^最后一行[：:]\\s*", with: "", options: .regularExpression)
        }
        if !lines.contains(where: { $0.hasPrefix("状态") }) {
            lines.append("状态：\(status)")
        }
        return lines.joined(separator: "\n")
    }

    /// 模型驻留时长：30s / 2m / 5m，-1 表示一直保留。
    private static var keepAliveValue: Any {
        let saved = UserDefaults.standard.string(forKey: "ollamaKeepAlive") ?? "30s"
        return saved == "-1" ? -1 : saved
    }

    /// 走 Ollama 原生 /api/chat：可以限制 num_ctx 并设置 keep_alive，
    /// 避免 3B 模型以 32K 上下文常驻占用 3GB+ 内存。
    private static func callOllama(prompt: String, model: String) async -> String? {
        guard let url = URL(string: "http://127.0.0.1:11434/api/chat") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 40
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
            "keep_alive": keepAliveValue,
            "options": ["num_ctx": 4096, "temperature": 0.2, "num_predict": 260],
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = message["content"] as? String else { return nil }
        return normalize(text)
    }

    /// 取本地 Ollama 已下载的第一个模型；没有模型或服务未启动时返回 nil。
    private static func ollamaModel() async -> String? {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]],
              let name = models.first?["name"] as? String, !name.isEmpty else { return nil }
        return name
    }

    private static var preset: SummaryProviderPreset {
        SummaryProviderPreset.preset(UserDefaults.standard.string(forKey: "summaryProvider") ?? "zhipu")
    }

    private static var modelName: String {
        let saved = (UserDefaults.standard.string(forKey: "summaryModel") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty { return saved }
        return preset.defaultModel
    }

    /// 钥匙串里的 key 优先；环境变量只作为开发时的回退。
    private static var configuredKey: String? {
        if let stored = APIKeyStore.load(account: preset.id) { return stored }
        guard let envName = preset.environmentKeyName else { return nil }
        return apiKey(envName)
    }

    private static func apiKey(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func makePrompt(_ session: AgentSession) -> String {
        let actions = session.events.suffix(30).map { event -> String in
            let input = (event.input ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(80)
            let result = (event.result ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(60)
            var line = "- \(event.tool)"
            if !input.isEmpty { line += ": \(input)" }
            if !result.isEmpty { line += " → \(result)" }
            return line
        }.joined(separator: "\n")

        return """
        根据下面的任务与工具记录，用 3-5 行中文总结。直接输出内容，不要写「第 1 行」「中间行」之类的标签，不要解释你在做什么。

        示例写法：
        检查并修复了会话跳转的点击命中问题
        - 移除摘要区展开按钮，改到底部操作行
        - 面板展开期间冻结列表顺序
        状态：已完成，构建通过

        任务：\(session.prompt.prefix(200))
        记录：
        \(actions)
        """
    }

    private static func callChatCompletions(prompt: String, key: String, base: String, model: String) async -> String? {
        guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.2,
            "max_tokens": 260,
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else { return nil }
        return normalize(text)
    }

    private static func callAnthropic(prompt: String, key: String, model: String) async -> String? {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 320,
            "messages": [["role": "user", "content": prompt]],
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { return nil }
        let text = content.compactMap { $0["text"] as? String }.joined()
        return normalize(text)
    }

    private static func normalize(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
