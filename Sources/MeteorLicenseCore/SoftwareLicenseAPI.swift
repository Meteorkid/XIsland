import Foundation

public struct SoftwareLicenseResponse: Codable, Sendable {
    public let lease: String
    public let deviceToken: String
}

public protocol SoftwareLicenseTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionLicenseTransport: SoftwareLicenseTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw SoftwareLicenseError.network("Invalid HTTP response")
        }
        return (data, response)
    }
}

public struct SoftwareLicenseAPI {
    private let baseURL: URL
    private let transport: any SoftwareLicenseTransport

    public init(baseURL: URL, transport: any SoftwareLicenseTransport = URLSessionLicenseTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func trial(productId: String, deviceId: String, deviceName: String) async throws -> SoftwareLicenseResponse {
        try await leaseRequest("trial", body: ["productId": productId, "deviceId": deviceId, "deviceName": String(deviceName.prefix(100))])
    }

    public func activate(productId: String, deviceId: String, deviceName: String, code: String) async throws -> SoftwareLicenseResponse {
        try await leaseRequest("activate", body: ["productId": productId, "deviceId": deviceId, "deviceName": String(deviceName.prefix(100)), "code": code])
    }

    public func refresh(productId: String, deviceId: String, deviceToken: String) async throws -> SoftwareLicenseResponse {
        try await leaseRequest("refresh", body: ["productId": productId, "deviceId": deviceId, "deviceToken": deviceToken])
    }

    public func deactivate(productId: String, deviceId: String, deviceToken: String) async throws {
        _ = try await request("deactivate", body: ["productId": productId, "deviceId": deviceId, "deviceToken": deviceToken])
    }

    private func leaseRequest(_ action: String, body: [String: String]) async throws -> SoftwareLicenseResponse {
        let data = try await request(action, body: body)
        guard let response = try? JSONDecoder().decode(SoftwareLicenseResponse.self, from: data),
              !response.deviceToken.isEmpty, response.deviceToken.count <= 4096 else {
            throw SoftwareLicenseError.invalidLease
        }
        return response
    }

    private func request(_ action: String, body: [String: String]) async throws -> Data {
        guard baseURL.scheme == "https", baseURL.user == nil, baseURL.password == nil else {
            throw SoftwareLicenseError.unconfigured
        }
        let url = baseURL.appendingPathComponent("api/software-licenses/\(action)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.send(request) }
        catch let error as SoftwareLicenseError { throw error }
        catch { throw SoftwareLicenseError.network(error.localizedDescription) }
        try Task.checkCancellation()
        guard data.count <= 65_536 else { throw SoftwareLicenseError.invalidLease }
        guard (200...299).contains(response.statusCode) else {
            struct Failure: Decodable { var code: String?; var error: String?; var message: String? }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw SoftwareLicenseError.server(status: response.statusCode,
                code: failure?.code ?? "request_failed",
                message: String((failure?.message ?? failure?.error ?? "授权服务暂时不可用，请稍后重试。").prefix(300)))
        }
        return data
    }
}
