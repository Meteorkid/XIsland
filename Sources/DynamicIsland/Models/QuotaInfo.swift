import Foundation

struct QuotaInfo: Sendable {
    let provider: String
    let requestsRemaining: Int?
    let requestsLimit: Int?
    let tokensRemaining: Int?
    let tokensLimit: Int?
    let resetTime: Date?
    let lastChecked: Date
}
