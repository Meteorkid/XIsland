import XCTest
import Security
@testable import XIsland

final class QuotaTruthfulnessTests: XCTestCase {
    func testQuotaReaderNeverCreatesAnInferenceRequest() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent("Sources/DynamicIsland/Managers/QuotaTracker.swift"))

        XCTAssertFalse(source.contains("request.httpMethod = \"POST\""),
                       "读取额度不能自动创建付费推理请求")
    }

    func testDisabledOpenAIDoesNotReadDatabaseOrKeychainWhileKimiIsEnabled() async throws {
        let suite = "QuotaTruthfulnessTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "quotaTrackingKimiEnabled")
        defaults.set(false, forKey: "quotaTrackingOpenAIEnabled")
        let fixture = QuotaReadFixture()

        let infos = await QuotaTracker.collectQuotas(
            enabledProviders: QuotaTracker.enabledProviders(in: defaults), readers: fixture.readers
        )

        XCTAssertEqual(infos.map(\.provider), ["Kimi"])
        XCTAssertEqual(fixture.keyReads, ["kimi"])
        XCTAssertEqual(fixture.databaseReads, 0)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testDisablingAllProvidersPerformsNoReads() async {
        let fixture = QuotaReadFixture()
        let infos = await QuotaTracker.collectQuotas(enabledProviders: [], readers: fixture.readers)

        XCTAssertTrue(infos.isEmpty)
        XCTAssertTrue(fixture.keyReads.isEmpty)
        XCTAssertEqual(fixture.databaseReads, 0)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testOpenAIRecordsUsedTokensWithoutClaimingRemainingQuotaOrLoadingKey() async throws {
        let fixture = QuotaReadFixture()
        let infos = await QuotaTracker.collectQuotas(enabledProviders: ["openai"], readers: fixture.readers)
        let info = try XCTUnwrap(infos.first)

        XCTAssertEqual(info.tokensUsed, 12345)
        XCTAssertNil(info.tokensRemaining)
        XCTAssertNil(info.tokensLimit)
        XCTAssertTrue(info.balances.isEmpty)
        XCTAssertTrue(fixture.keyReads.isEmpty)
        XCTAssertEqual(fixture.databaseReads, 1)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testAnthropicReportsUnknownWithoutLoadingKeyOrIssuingInference() async throws {
        let fixture = QuotaReadFixture()
        let infos = await QuotaTracker.collectQuotas(enabledProviders: ["anthropic"], readers: fixture.readers)
        let info = try XCTUnwrap(infos.first)

        assertUnknownQuota(info)
        XCTAssertTrue(fixture.keyReads.isEmpty)
        XCTAssertEqual(fixture.databaseReads, 0)
        XCTAssertTrue(fixture.requests.isEmpty)
        XCTAssertNil(QuotaTracker.balanceRequest(for: "anthropic", apiKey: "fixture"))
    }

    func testKimiPreservesAvailableBalanceWithCurrencyAndFractionalPrecision() {
        let info = parse("kimi", #"{"code":0,"status":true,"data":{"available_balance":49.58894,"voucher_balance":46.58893,"cash_balance":3.00001}}"#)

        XCTAssertEqual(info.balances, [QuotaBalance(amount: Decimal(string: "49.58894")!, currency: "CNY")])
        XCTAssertEqual(info.balanceText, "CNY 49.58894")
        XCTAssertNil(info.tokensRemaining)
        XCTAssertNil(info.tokensUsed)
        XCTAssertNil(info.requestsRemaining)
    }

    func testKimiZeroBalanceRemainsVisible() {
        let info = parse("kimi", #"{"code":0,"status":true,"data":{"available_balance":0}}"#)

        XCTAssertEqual(info.balanceText, "CNY 0")
        XCTAssertNil(info.tokensRemaining)
    }

    func testKimiErrorOrMalformedPayloadCannotBecomeBalance() {
        for payload in [
            #"{"code":40100,"status":false,"data":{"available_balance":10}}"#,
            #"{"code":0,"status":false,"data":{"available_balance":10}}"#,
            #"{"code":0,"status":true,"data":{"balance":10}}"#,
            #"{"code":0,"status":true,"data":{"available_balance":"NaN"}}"#,
            "not JSON"
        ] {
            assertUnknownQuota(parse("kimi", payload))
        }
        assertUnknownQuota(parse("kimi", #"{"code":0,"status":true,"data":{"available_balance":10}}"#, status: 401))
    }

    func testDeepSeekKeepsEachCurrencySeparateAndNeverEstimatesTokens() {
        let info = parse("deepseek", #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.25"},{"currency":"USD","total_balance":"1.50"}]}"#)

        XCTAssertEqual(info.balances, [
            QuotaBalance(amount: Decimal(string: "110.25")!, currency: "CNY"),
            QuotaBalance(amount: Decimal(string: "1.50")!, currency: "USD")
        ])
        XCTAssertEqual(info.balanceText, "CNY 110.25 · USD 1.5")
        XCTAssertNil(info.tokensRemaining)
        XCTAssertNil(info.requestsRemaining)
    }

    func testDeepSeekUnavailableDoesNotReplaceReportedBalanceWithFakeZeroTokens() {
        let info = parse("deepseek", #"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"-0.10"}]}"#)

        XCTAssertEqual(info.balanceText, "CNY -0.1")
        XCTAssertNil(info.tokensRemaining)
    }

    func testDeepSeekRejectsInvalidAmountsAndMissingCurrency() {
        for payload in [
            #"{"balance_infos":[{"currency":"CNY","total_balance":"10oops"}]}"#,
            #"{"balance_infos":[{"currency":"CNY","total_balance":"NaN"}]}"#,
            #"{"balance_infos":[{"total_balance":"10"}]}"#,
            #"{"balance_infos":[{"currency":"TOKEN","total_balance":"10"}]}"#,
            #"{"error":{"message":"Unauthorized"}}"#
        ] {
            assertUnknownQuota(parse("deepseek", payload))
        }
        assertUnknownQuota(parse("deepseek", #"{"balance_infos":[{"currency":"CNY","total_balance":"10"}]}"#, status: 500))
    }

    func testGLMModelResponseOnlyDescribesAPIRequestAvailability() {
        for status in [200, 401, 403, 429, 500] {
            let info = parse("glm", #"{"data":[]}"#, status: status)
            XCTAssertEqual(info.apiAvailable, status == 200)
            XCTAssertNil(info.requestsRemaining)
            XCTAssertNil(info.tokensRemaining)
            XCTAssertTrue(info.balances.isEmpty)
        }
    }

    func testRemoteReadsUseOnlyGetAndHaveNoInferenceBody() async {
        let fixture = QuotaReadFixture()
        _ = await QuotaTracker.collectQuotas(enabledProviders: ["kimi", "deepseek", "glm"], readers: fixture.readers)

        XCTAssertEqual(fixture.requests.count, 3)
        for request in fixture.requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertFalse(request.url!.path.contains("messages"))
            XCTAssertFalse(request.url!.path.contains("completions"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        }
    }

    func testFailedReadProducesUnknownInsteadOfExhaustedQuota() async throws {
        let readers = QuotaTracker.Readers(apiKey: { _ in "fixture-key" }, openAITokens: { nil },
                                          data: { _ in throw URLError(.timedOut) })
        let infos = await QuotaTracker.collectQuotas(enabledProviders: ["kimi", "deepseek", "glm"], readers: readers)

        XCTAssertEqual(infos.count, 3)
        for info in infos {
            assertUnknownQuota(info)
            XCTAssertNil(info.apiAvailable)
        }
    }

    func testKeychainMigrationUpdatesOnlyAccessibilityAndPreservesItemsOnFailure() {
        let originalItems = ["anthropic": Data("keep-this-key".utf8), "openai": Data("other-key".utf8)]
        var items = originalItems
        var updatedAccounts: [String] = []
        let statuses = QuotaTracker.migrateKeychainAccessibility { query, attributes in
            let account = query[kSecAttrAccount as String] as! String
            updatedAccounts.append(account)
            XCTAssertEqual(query[kSecAttrService as String] as? String, "com.xisland.apikeys")
            XCTAssertEqual(Set(attributes.keys), [kSecAttrAccessible as String])
            XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                           kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            // 模拟只接受原地属性更新的存储；失败时原密钥保持不变。
            if attributes[kSecValueData as String] != nil { items[account] = nil }
            return account == "anthropic" ? errSecAuthFailed : errSecItemNotFound
        }

        XCTAssertEqual(items, originalItems)
        XCTAssertEqual(updatedAccounts, ["anthropic", "openai", "kimi", "deepseek", "glm"])
        XCTAssertEqual(statuses["anthropic"], errSecAuthFailed)
        XCTAssertEqual(statuses["openai"], errSecItemNotFound)
    }

    private func parse(_ provider: String, _ payload: String, status: Int = 200) -> QuotaInfo {
        QuotaTracker.parseResponse(provider: provider, data: Data(payload.utf8), statusCode: status)
    }

    private func assertUnknownQuota(_ info: QuotaInfo, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(info.tokensUsed, file: file, line: line)
        XCTAssertNil(info.tokensRemaining, file: file, line: line)
        XCTAssertNil(info.requestsRemaining, file: file, line: line)
        XCTAssertTrue(info.balances.isEmpty, file: file, line: line)
    }
}

private final class QuotaReadFixture: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var keyReads: [String] = []
    private(set) var databaseReads = 0
    private(set) var requests: [URLRequest] = []

    var readers: QuotaTracker.Readers {
        QuotaTracker.Readers(apiKey: { self.readKey($0) }, openAITokens: { self.readTokens() },
                            data: { self.readResponse($0) })
    }

    private func readKey(_ provider: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        keyReads.append(provider)
        return "fixture-key"
    }

    private func readTokens() -> Int {
        lock.lock()
        defer { lock.unlock() }
        databaseReads += 1
        return 12345
    }

    private func readResponse(_ request: URLRequest) -> (Data, URLResponse) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(#"{"code":0,"status":true,"data":{"available_balance":1.25}}"#.utf8), response)
    }
}
