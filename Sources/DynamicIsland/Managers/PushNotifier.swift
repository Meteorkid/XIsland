import Foundation

enum PushError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case requestConstructionFailed
    case httpStatus(Int)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Invalid channel configuration"
        case .requestConstructionFailed: return "Could not build request"
        case .httpStatus(let code): return "HTTP \(code)"
        case .transport(let message): return message
        }
    }
}

/// A3：外部推送发送层。策略与请求构造都是纯函数，这里只负责发网络。
@MainActor
final class PushNotifier {
    static let shared = PushNotifier()

    static var isAvailable: Bool { !AppPreferences.isIsolated }

    private let session: URLSession

    /// 默认用带超时的 ephemeral 会话：推送是"尽力而为"，弱网时不能把请求无限挂起。
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    /// 常规投递：结果只写日志，不打扰用户，也不重试（避免网络抖动造成重复轰炸）。
    func deliver(config: PushConfiguration, event: IslandEvent, redactedDetail: String) {
        guard Self.isAvailable,
              let request = PushChannelRequestBuilder.makeRequest(
                  config: config, event: event, redactedDetail: redactedDetail) else { return }
        session.dataTask(with: request) { _, _, _ in }.resume()
    }

    /// 设置页「发送测试」：返回真实 HTTP 回包状态，不以本地构造成功冒充送达。
    func sendTest(config: PushConfiguration,
                  completion: @escaping @MainActor (Result<Int, PushError>) -> Void) {
        guard Self.isAvailable, config.isValid else {
            completion(.failure(.invalidConfiguration)); return
        }
        let event = IslandEvent(
            kind: .completed,
            sessionId: "diagnostic-test",
            requestId: nil,
            stableToken: "test",
            title: "X Island",
            detail: "Test delivery",
            workingDirectory: "",
            isSubagent: false,
            occurredAt: Date()
        )
        guard let request = PushChannelRequestBuilder.makeRequest(
            config: config, event: event, redactedDetail: "Test delivery from X Island") else {
            completion(.failure(.requestConstructionFailed)); return
        }
        session.dataTask(with: request) { [weak self] _, response, error in
            _ = self
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let result: Result<Int, PushError>
            if let error {
                result = .failure(.transport(error.localizedDescription))
            } else if (200..<300).contains(status) {
                result = .success(status)
            } else {
                result = .failure(.httpStatus(status))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }.resume()
    }
}
