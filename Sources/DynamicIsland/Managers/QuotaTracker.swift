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
    private let allowsLiveAccess: Bool
    var isPolling: Bool { timer?.isValid == true }

    init(testConfiguration: AppTestConfiguration = .current()) {
        allowsLiveAccess = !testConfiguration.isEnabled && !AppPreferences.isIsolated
        guard allowsLiveAccess else { return }
        Self.migrateKeychainAccessibility()
        fetchAll()
        startTimer()
    }

    deinit {
        timer?.invalidate()
    }

    // Read dependencies are explicit so fixtures never access a user's secrets or databases.
    struct Readers: Sendable {
        let apiKey: @Sendable (String) -> String?
        let openAITokens: @Sendable () -> Int?
        let data: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    }

    nonisolated private static var liveReaders: Readers {
        Readers(apiKey: { loadAPIKey(for: $0) }, openAITokens: { fetchOpenAITokenCount() },
                data: { try await URLSession.shared.data(for: $0) })
    }

    nonisolated private static let providerSettings: [(key: String, identifier: String, name: String)] = [
        ("quotaTrackingAnthropicEnabled", "anthropic", "Anthropic"),
        ("quotaTrackingOpenAIEnabled", "openai", "OpenAI"),
        ("quotaTrackingKimiEnabled", "kimi", "Kimi"),
        ("quotaTrackingDeepseekEnabled", "deepseek", "DeepSeek"),
        ("quotaTrackingGLMEnabled", "glm", "GLM"),
    ]

    nonisolated static func enabledProviders(in defaults: UserDefaults) -> [String] {
        providerSettings.filter { defaults.bool(forKey: $0.key) }.map(\.identifier)
    }

    func fetchAll() {
        guard allowsLiveAccess else { return }
        let providers = Self.enabledProviders(in: AppPreferences.defaults)
        quotas.removeAll { info in
            !Self.providerSettings.contains { $0.name == info.provider && providers.contains($0.identifier) }
        }
        guard !providers.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self] in
            let infos = await Self.collectQuotas(enabledProviders: providers, readers: Self.liveReaders)
            await MainActor.run { [weak self] in
                for info in infos { self?.updateQuota(info) }
            }
        }
    }

    // Only providers explicitly enabled by the caller may read a key, database, or network.
    nonisolated static func collectQuotas(enabledProviders: [String], readers: Readers) async -> [QuotaInfo] {
        var infos: [QuotaInfo] = []
        for provider in providerSettings where enabledProviders.contains(provider.identifier) {
            if provider.identifier == "anthropic" {
                // Rate-limit headers from inference are not a read-only quota API.
                infos.append(QuotaInfo(provider: provider.name))
                continue
            }
            if provider.identifier == "openai" {
                infos.append(QuotaInfo(provider: provider.name, tokensUsed: readers.openAITokens()))
                continue
            }
            guard let key = readers.apiKey(provider.identifier), !key.isEmpty,
                  let request = balanceRequest(for: provider.identifier, apiKey: key) else {
                infos.append(QuotaInfo(provider: provider.name))
                continue
            }
            do {
                let (data, response) = try await readers.data(request)
                infos.append(parseResponse(provider: provider.identifier, data: data,
                                           statusCode: (response as? HTTPURLResponse)?.statusCode))
            } catch {
                // A failed read gives no evidence that an account is exhausted.
                infos.append(QuotaInfo(provider: provider.name))
            }
        }
        return infos
    }

    nonisolated static func balanceRequest(for provider: String, apiKey: String) -> URLRequest? {
        let endpoint: String
        switch provider {
        case "kimi": endpoint = "https://api.moonshot.cn/v1/users/me/balance"
        case "deepseek": endpoint = "https://api.deepseek.com/user/balance"
        case "glm": endpoint = "https://open.bigmodel.cn/api/paas/v4/models"
        default: return nil
        }
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    nonisolated static func parseResponse(provider: String, data: Data, statusCode: Int?) -> QuotaInfo {
        let name = providerSettings.first { $0.identifier == provider }?.name ?? provider
        let unknown = QuotaInfo(provider: name)
        guard let statusCode else { return unknown }
        if provider == "glm" {
            // /models only establishes whether this API request succeeded, not available quota.
            return QuotaInfo(provider: name, apiAvailable: statusCode == 200)
        }
        guard statusCode == 200 else { return unknown }
        let decoder = JSONDecoder()
        switch provider {
        case "kimi":
            // https://platform.kimi.com/docs/api/balance — available_balance is CNY, not tokens.
            guard let response = try? decoder.decode(KimiBalanceResponse.self, from: data),
                  response.code == 0, response.status,
                  !response.data.available_balance.isNaN else { return unknown }
            return QuotaInfo(provider: name, balances: [
                QuotaBalance(amount: response.data.available_balance, currency: "CNY")
            ])
        case "deepseek":
            // https://api-docs.deepseek.com/api/get-user-balance/ — keep each currency separate.
            guard let response = try? decoder.decode(DeepSeekBalanceResponse.self, from: data) else { return unknown }
            var balances: [QuotaBalance] = []
            for entry in response.balance_infos {
                guard ["CNY", "USD"].contains(entry.currency),
                      entry.total_balance.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                      let amount = Decimal(string: entry.total_balance, locale: Locale(identifier: "en_US_POSIX")),
                      !amount.isNaN else { return unknown }
                balances.append(QuotaBalance(amount: amount, currency: entry.currency))
            }
            return QuotaInfo(provider: name, balances: balances)
        default:
            return unknown
        }
    }

    private struct KimiBalanceResponse: Decodable {
        let code: Int
        let status: Bool
        let data: BalanceData
        struct BalanceData: Decodable { let available_balance: Decimal }
    }

    private struct DeepSeekBalanceResponse: Decodable {
        let balance_infos: [BalanceData]
        struct BalanceData: Decodable {
            let currency: String
            let total_balance: String
        }
    }

    func fetchAnthropic(apiKey: String? = nil) { fetchProvider("anthropic", apiKey: apiKey) }
    func fetchOpenAI() { fetchProvider("openai") }
    func fetchKimi(apiKey: String? = nil) { fetchProvider("kimi", apiKey: apiKey) }
    func fetchDeepSeek(apiKey: String? = nil) { fetchProvider("deepseek", apiKey: apiKey) }
    func fetchGLM(apiKey: String? = nil) { fetchProvider("glm", apiKey: apiKey) }

    private func fetchProvider(_ provider: String, apiKey: String? = nil) {
        guard allowsLiveAccess, Self.enabledProviders(in: AppPreferences.defaults).contains(provider) else { return }
        let readers = Readers(apiKey: { _ in apiKey }, openAITokens: Self.liveReaders.openAITokens,
                              data: Self.liveReaders.data)
        Task.detached(priority: .utility) { [weak self] in
            let infos = await Self.collectQuotas(enabledProviders: [provider], readers: readers)
            await MainActor.run { [weak self] in
                for info in infos { self?.updateQuota(info) }
            }
        }
    }

    nonisolated private static func fetchOpenAITokenCount() -> Int? {
        let dbPath = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/state_5.sqlite")
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database = db else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(database) }

        let query = "SELECT SUM(tokens_used) FROM threads;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            sqlite3_finalize(statement); return nil
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) == SQLITE_INTEGER else { return nil }
        let total = sqlite3_column_int64(stmt, 0)
        return total >= 0 ? Int(exactly: total) : nil
    }

    // MARK: - Keychain

    static let anthropicEnabledKey = "quotaTrackingAnthropicEnabled"
    static let openAIEnabledKey = "quotaTrackingOpenAIEnabled"
    static let kimiEnabledKey = "quotaTrackingKimiEnabled"
    static let deepseekEnabledKey = "quotaTrackingDeepseekEnabled"
    static let glmEnabledKey = "quotaTrackingGLMEnabled"

    static func saveAPIKey(_ key: String, for provider: String) -> Bool {
        guard !AppPreferences.isIsolated else { return false }
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
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    nonisolated static func loadAPIKey(for provider: String) -> String? {
        guard !AppPreferences.isIsolated else { return nil }
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

    static func migrateKeychainAccessibility() {
        guard !AppPreferences.isIsolated else { return }
        _ = migrateKeychainAccessibility { query, attributes in
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
    }

    @discardableResult
    nonisolated static func migrateKeychainAccessibility(
        update: ([String: Any], [String: Any]) -> OSStatus
    ) -> [String: OSStatus] {
        var statuses: [String: OSStatus] = [:]
        for provider in providerSettings {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.xisland.apikeys",
                kSecAttrAccount as String: provider.identifier
            ]
            // An unsuccessful in-place update preserves the original keychain item.
            let attributes = [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            statuses[provider.identifier] = update(query, attributes)
        }
        return statuses
    }

    static func deleteAPIKey(for provider: String) -> Bool {
        guard !AppPreferences.isIsolated else { return false }
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
        // Ignore an in-flight response if tracking was disabled while the read was running.
        guard Self.providerSettings.contains(where: {
            $0.name == info.provider && AppPreferences.defaults.bool(forKey: $0.key)
        }) else {
            quotas.removeAll { $0.provider == info.provider }
            return
        }
        if let index = quotas.firstIndex(where: { $0.provider == info.provider }) {
            quotas[index] = info
        } else {
            quotas.append(info)
        }
    }

}
