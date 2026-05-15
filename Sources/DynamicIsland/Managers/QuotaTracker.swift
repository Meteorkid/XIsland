import Foundation
import Observation
import Security
import SQLite3

@Observable
@MainActor
final class QuotaTracker {
    var quotas: [QuotaInfo] = []
    nonisolated(unsafe) private var timer: Timer?
    private let updateInterval: TimeInterval = 60

    init() {
        fetchAll()
        startTimer()
    }

    func fetchAll() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.anthropicEnabledKey) { fetchAnthropic() }
        if defaults.bool(forKey: Self.openAIEnabledKey) { fetchOpenAI() }
        if defaults.bool(forKey: Self.kimiEnabledKey) { fetchKimi() }
        if defaults.bool(forKey: Self.deepseekEnabledKey) { fetchDeepSeek() }
        if defaults.bool(forKey: Self.glmEnabledKey) { fetchGLM() }
    }

    // MARK: - Anthropic

    func fetchAnthropic() {
        guard let apiKey = Self.loadAPIKey(for: "anthropic"), !apiKey.isEmpty else {
            updateQuota(QuotaInfo(provider: "Anthropic", requestsRemaining: nil, requestsLimit: nil,
                                  tokensRemaining: nil, tokensLimit: nil, resetTime: nil, lastChecked: Date()))
            return
        }

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            guard let httpResponse = response as? HTTPURLResponse else { return }
            let headers = httpResponse.allHeaderFields
            let reqRemaining = Self.parseIntHeader(headers, key: "anthropic-ratelimit-requests-remaining")
            let reqLimit = Self.parseIntHeader(headers, key: "anthropic-ratelimit-requests-limit")
            let tokRemaining = Self.parseIntHeader(headers, key: "anthropic-ratelimit-tokens-remaining")
            let tokLimit = Self.parseIntHeader(headers, key: "anthropic-ratelimit-tokens-limit")
            let resetTime = Self.parseDateHeader(headers, key: "anthropic-ratelimit-reset")

            let info = QuotaInfo(provider: "Anthropic", requestsRemaining: reqRemaining, requestsLimit: reqLimit,
                                 tokensRemaining: tokRemaining, tokensLimit: tokLimit, resetTime: resetTime, lastChecked: Date())
            Task { @MainActor [weak self] in self?.updateQuota(info) }
        }
        task.resume()
    }

    // MARK: - OpenAI (Codex local SQLite)

    func fetchOpenAI() {
        let dbPath = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/state_5.sqlite")
        guard FileManager.default.fileExists(atPath: dbPath) else {
            updateQuota(QuotaInfo(provider: "OpenAI", requestsRemaining: nil, requestsLimit: nil,
                                  tokensRemaining: nil, tokensLimit: nil, resetTime: nil, lastChecked: Date()))
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database = db else {
            sqlite3_close(db); return
        }
        defer { sqlite3_close(database) }

        let query = "SELECT SUM(tokens_used) FROM threads;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            sqlite3_finalize(statement); return
        }
        defer { sqlite3_finalize(stmt) }

        var totalTokens: Int?
        if sqlite3_step(stmt) == SQLITE_ROW { totalTokens = Int(sqlite3_column_int64(stmt, 0)) }

        let info = QuotaInfo(provider: "OpenAI", requestsRemaining: nil, requestsLimit: nil,
                             tokensRemaining: totalTokens, tokensLimit: nil, resetTime: nil, lastChecked: Date())
        updateQuota(info)
    }

    // MARK: - Kimi (Moonshot)

    func fetchKimi() {
        guard let apiKey = Self.loadAPIKey(for: "kimi"), !apiKey.isEmpty else {
            updateQuota(QuotaInfo(provider: "Kimi", requestsRemaining: nil, requestsLimit: nil,
                                  tokensRemaining: nil, tokensLimit: nil, resetTime: nil, lastChecked: Date()))
            return
        }

        let url = URL(string: "https://api.moonshot.cn/v1/users/me/balance")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let balanceData = json["data"] as? [String: Any] else {
                Task { @MainActor [weak self] in
                    self?.updateQuota(QuotaInfo(provider: "Kimi", requestsRemaining: nil, requestsLimit: nil,
                                                tokensRemaining: nil, tokensLimit: nil,
                                                resetTime: nil, lastChecked: Date()))
                }
                return
            }
            // balance is in CNY yuan
            let balance = balanceData["balance"] as? Double
            let info = QuotaInfo(provider: "Kimi", requestsRemaining: nil, requestsLimit: nil,
                                 tokensRemaining: balance.map { Int($0 * 100) }, // approximate: 1 yuan ≈ 100 tokens
                                 tokensLimit: nil, resetTime: nil, lastChecked: Date())
            Task { @MainActor [weak self] in self?.updateQuota(info) }
        }
        task.resume()
    }

    // MARK: - DeepSeek

    func fetchDeepSeek() {
        guard let apiKey = Self.loadAPIKey(for: "deepseek"), !apiKey.isEmpty else {
            updateQuota(QuotaInfo(provider: "DeepSeek", requestsRemaining: nil, requestsLimit: nil,
                                  tokensRemaining: nil, tokensLimit: nil, resetTime: nil, lastChecked: Date()))
            return
        }

        let url = URL(string: "https://api.deepseek.com/user/balance")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Task { @MainActor [weak self] in
                    self?.updateQuota(QuotaInfo(provider: "DeepSeek", requestsRemaining: nil, requestsLimit: nil,
                                                tokensRemaining: nil, tokensLimit: nil,
                                                resetTime: nil, lastChecked: Date()))
                }
                return
            }
            let isAvailable = json["is_available"] as? Bool ?? false
            let balanceInfos = json["balance_infos"] as? [[String: Any]] ?? []
            var totalBalance: Double = 0
            for info in balanceInfos {
                totalBalance += (info["total_balance"] as? String).flatMap(Double.init) ?? 0
            }
            let info = QuotaInfo(provider: "DeepSeek", requestsRemaining: nil, requestsLimit: nil,
                                 tokensRemaining: isAvailable ? Int(totalBalance * 1000) : 0,
                                 tokensLimit: nil, resetTime: nil, lastChecked: Date())
            Task { @MainActor [weak self] in self?.updateQuota(info) }
        }
        task.resume()
    }

    // MARK: - GLM (Zhipu)

    func fetchGLM() {
        guard let apiKey = Self.loadAPIKey(for: "glm"), !apiKey.isEmpty else {
            updateQuota(QuotaInfo(provider: "GLM", requestsRemaining: nil, requestsLimit: nil,
                                  tokensRemaining: nil, tokensLimit: nil, resetTime: nil, lastChecked: Date()))
            return
        }

        let url = URL(string: "https://open.bigmodel.cn/api/paas/v4/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            guard let httpResponse = response as? HTTPURLResponse else { return }
            // GLM doesn't expose a public balance endpoint; a 200 means the key is valid/has quota.
            // 401/403/429 would indicate quota exhausted or invalid key.
            let isOk = httpResponse.statusCode == 200
            let info = QuotaInfo(provider: "GLM", requestsRemaining: isOk ? 1 : 0, requestsLimit: nil,
                                 tokensRemaining: nil, tokensLimit: nil, resetTime: nil, lastChecked: Date())
            Task { @MainActor [weak self] in self?.updateQuota(info) }
        }
        task.resume()
    }

    // MARK: - Keychain

    static let anthropicEnabledKey = "quotaTrackingAnthropicEnabled"
    static let openAIEnabledKey = "quotaTrackingOpenAIEnabled"
    static let kimiEnabledKey = "quotaTrackingKimiEnabled"
    static let deepseekEnabledKey = "quotaTrackingDeepseekEnabled"
    static let glmEnabledKey = "quotaTrackingGLMEnabled"

    static func saveAPIKey(_ key: String, for provider: String) -> Bool {
        let service = "com.xisland.apikeys"
        let account = provider
        let data = key.data(using: .utf8)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data
            ]
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func loadAPIKey(for provider: String) -> String? {
        let service = "com.xisland.apikeys"
        let account = provider
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteAPIKey(for provider: String) -> Bool {
        let service = "com.xisland.apikeys"
        let account = provider
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    // MARK: - Private

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fetchAll() }
        }
    }

    private func updateQuota(_ info: QuotaInfo) {
        if let index = quotas.firstIndex(where: { $0.provider == info.provider }) {
            quotas[index] = info
        } else {
            quotas.append(info)
        }
    }

    private nonisolated static func parseIntHeader(_ headers: [AnyHashable: Any], key: String) -> Int? {
        guard let value = headers[key] as? String ?? headers[key.lowercased()] as? String else { return nil }
        return Int(value)
    }

    private nonisolated static func parseDateHeader(_ headers: [AnyHashable: Any], key: String) -> Date? {
        guard let value = headers[key] as? String ?? headers[key.lowercased()] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
