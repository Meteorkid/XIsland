import Foundation

/// 更新清单。清单本体按原样字节签名，解析只用于读取字段，不能用“重新编码后的 JSON”
/// 代替签名原文，否则空白和字段顺序变化会导致合法签名被误判。
public struct UpdateManifest: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public let schema: Int
    public let version: String
    public let dmg: String
    public let sha256: String
    public let keyID: String

    public init(
        schema: Int = UpdateManifest.currentSchema,
        version: String,
        dmg: String,
        sha256: String,
        keyID: String
    ) {
        self.schema = schema
        self.version = version
        self.dmg = dmg
        self.sha256 = sha256
        self.keyID = keyID
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case version
        case dmg
        case sha256
        case keyID = "key_id"
    }
}

public enum UpdateManifestError: LocalizedError, Equatable, Sendable {
    case malformedManifest
    case unsupportedSchema(Int)
    case versionMismatch(expected: String, actual: String)
    case dmgNameMismatch(expected: String, actual: String)
    case checksumMismatch
    case invalidPublicKey
    case invalidSignatureEncoding
    case invalidSignature
    case keyIDMismatch(expected: String, actual: String)
    case dmgReadFailed

    public var errorDescription: String? {
        switch self {
        case .malformedManifest:
            return "The update manifest is malformed."
        case .unsupportedSchema(let schema):
            return "Unsupported update manifest schema: \(schema)."
        case .versionMismatch(let expected, let actual):
            return "Update manifest version mismatch: expected \(expected), got \(actual)."
        case .dmgNameMismatch(let expected, let actual):
            return "Update manifest DMG name mismatch: expected \(expected), got \(actual)."
        case .checksumMismatch:
            return "The downloaded update does not match the signed checksum."
        case .invalidPublicKey:
            return "The embedded update public key is invalid."
        case .invalidSignatureEncoding:
            return "The update signature is not valid base64."
        case .invalidSignature:
            return "The update manifest signature is invalid."
        case .keyIDMismatch(let expected, let actual):
            return "Update signing key mismatch: expected \(expected), got \(actual)."
        case .dmgReadFailed:
            return "Unable to read the downloaded DMG for checksum verification."
        }
    }
}
