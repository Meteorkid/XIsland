import Foundation

struct QuotaInfo: Sendable {
    let provider: String
    let requestsRemaining: Int?
    let requestsLimit: Int?
    let tokensRemaining: Int?
    let tokensLimit: Int?
    let resetTime: Date?
    let lastChecked: Date
    let tokensUsed: Int?
    let balances: [QuotaBalance]
    let apiAvailable: Bool?

    init(provider: String, requestsRemaining: Int? = nil, requestsLimit: Int? = nil,
         tokensRemaining: Int? = nil, tokensLimit: Int? = nil, resetTime: Date? = nil,
         lastChecked: Date = Date(), tokensUsed: Int? = nil, balances: [QuotaBalance] = [],
         apiAvailable: Bool? = nil) {
        self.provider = provider
        self.requestsRemaining = requestsRemaining
        self.requestsLimit = requestsLimit
        self.tokensRemaining = tokensRemaining
        self.tokensLimit = tokensLimit
        self.resetTime = resetTime
        self.lastChecked = lastChecked
        self.tokensUsed = tokensUsed
        self.balances = balances
        self.apiAvailable = apiAvailable
    }

    var balanceText: String? {
        guard !balances.isEmpty else { return nil }
        return balances.map { "\($0.currency) \(NSDecimalNumber(decimal: $0.amount).stringValue)" }
            .joined(separator: " · ")
    }
}

struct QuotaBalance: Equatable, Sendable {
    let amount: Decimal
    let currency: String
}
