import Foundation
import CryptoKit

public enum SoftwareLicenseKind: String, Codable, Sendable {
    case trial, monthly, annual, lifetime
}

public struct SoftwareLicensePayload: Codable, Equatable, Sendable {
    public let version: Int
    public let productId: String
    public let deviceId: String
    public let licenseId: String
    public let kind: SoftwareLicenseKind
    public let issuedAt: TimeInterval
    public let expiresAt: TimeInterval
    public let entitlementExpiresAt: TimeInterval?

    public var deadline: Date {
        Date(timeIntervalSince1970: min(expiresAt, entitlementExpiresAt ?? expiresAt))
    }
}

public enum SoftwareLicenseState: Equatable, Sendable {
    case unconfigured
    case needsConnection
    case active(SoftwareLicensePayload)
    case expired
    case blocked(String)

    public var allowsAccess: Bool {
        if case .active = self { return true }
        return false
    }
}

public enum SoftwareLicenseError: Error, LocalizedError, Equatable {
    case unconfigured, invalidLease, expired, legacyCode, busy
    case server(status: Int, code: String, message: String)
    case storage(Int32)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .unconfigured: return "此版本尚未配置授权公钥，请联系开发者获取正式版本。"
        case .invalidLease: return "授权凭证校验失败，请联网重新验证。"
        case .expired: return "授权或离线使用期限已到，请联网验证或续费。"
        case .legacyCode: return "此邀请码属于旧版离线授权，请联系管理员迁移为新版授权。"
        case .busy: return "正在处理授权请求，请稍后再试。"
        case .server(_, _, let message): return message
        case .storage: return "无法安全保存授权，请检查钥匙串访问权限后重试。"
        case .network: return "暂时无法连接授权服务；已有授权可在离线期限内继续使用。"
        }
    }
}

public struct SoftwareLicenseVerifier {
    private let key: Curve25519.Signing.PublicKey

    public init(publicKeyBase64: String) throws {
        guard let data = Data(base64Encoded: publicKeyBase64), data.count == 32,
              data.contains(where: { $0 != 0 }),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) else {
            throw SoftwareLicenseError.unconfigured
        }
        self.key = key
    }

    /// 先验签，再使用任何服务端时间或授权字段。
    public func verify(_ lease: String, productId: String, deviceId: String) throws -> SoftwareLicensePayload {
        let parts = lease.split(separator: ".", omittingEmptySubsequences: false)
        guard lease.utf8.count <= 16_384, parts.count == 3, parts[0] == "MSL1",
              let body = Self.decodeURLBase64(String(parts[1])),
              let signature = Self.decodeURLBase64(String(parts[2])), signature.count == 64,
              key.isValidSignature(signature, for: Data("MSL1.\(parts[1])".utf8)),
              let payload = try? JSONDecoder().decode(SoftwareLicensePayload.self, from: body),
              payload.version == 1, payload.productId == productId, payload.deviceId == deviceId,
              !payload.licenseId.isEmpty, payload.licenseId.count <= 200,
              payload.issuedAt.isFinite, payload.expiresAt.isFinite,
              payload.issuedAt > 0, payload.expiresAt > payload.issuedAt,
              payload.expiresAt - payload.issuedAt <= 7 * 86_400 else {
            throw SoftwareLicenseError.invalidLease
        }
        if payload.kind == .lifetime {
            guard payload.entitlementExpiresAt == nil else { throw SoftwareLicenseError.invalidLease }
        } else {
            guard let end = payload.entitlementExpiresAt, end.isFinite,
                  end > payload.issuedAt, payload.expiresAt <= end else {
                throw SoftwareLicenseError.invalidLease
            }
            if payload.kind == .trial, end - payload.issuedAt > 14 * 86_400 {
                throw SoftwareLicenseError.invalidLease
            }
        }
        return payload
    }

    private static func decodeURLBase64(_ value: String) -> Data? {
        guard !value.isEmpty, value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { return nil }
        let encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4))
    }
}
