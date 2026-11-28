import CryptoKit
import Foundation

public enum UpdateSignatureVerifier {
    /// 解析清单字段；验签必须使用原始 `manifestData`，而不是这里的解析结果。
    public static func decodeManifest(_ data: Data) throws -> UpdateManifest {
        do {
            return try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch {
            throw UpdateManifestError.malformedManifest
        }
    }

    /// 同时校验清单签名、schema、版本、DMG 文件名、密钥 ID 和实际 DMG SHA256。
    public static func verify(
        manifestData: Data,
        signatureBase64: String,
        publicKeyBase64: String,
        expectedVersion: String,
        expectedDMGFilename: String,
        expectedKeyID: String?,
        actualDMGSHA256: String
    ) throws -> UpdateManifest {
        try verifySignature(
            manifestData: manifestData,
            signatureBase64: signatureBase64,
            publicKeyBase64: publicKeyBase64
        )

        let manifest = try decodeManifest(manifestData)
        guard manifest.schema == UpdateManifest.currentSchema else {
            throw UpdateManifestError.unsupportedSchema(manifest.schema)
        }

        let normalizedExpectedVersion = normalize(version: expectedVersion)
        let normalizedActualVersion = normalize(version: manifest.version)
        guard normalizedActualVersion == normalizedExpectedVersion else {
            throw UpdateManifestError.versionMismatch(
                expected: normalizedExpectedVersion,
                actual: normalizedActualVersion
            )
        }
        guard manifest.dmg == expectedDMGFilename else {
            throw UpdateManifestError.dmgNameMismatch(
                expected: expectedDMGFilename,
                actual: manifest.dmg
            )
        }
        guard isSHA256(manifest.sha256) else {
            throw UpdateManifestError.malformedManifest
        }
        guard manifest.sha256.lowercased() == actualDMGSHA256.lowercased() else {
            throw UpdateManifestError.checksumMismatch
        }

        if let expectedKeyID {
            let expected = expectedKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !expected.isEmpty, manifest.keyID != expected {
                throw UpdateManifestError.keyIDMismatch(
                    expected: expected,
                    actual: manifest.keyID
                )
            }
        }

        return manifest
    }

    /// 只验签，不解释清单字段。调用方必须在验签通过后再读取字段。
    public static func verifySignature(
        manifestData: Data,
        signatureBase64: String,
        publicKeyBase64: String
    ) throws {
        let publicKeyData = try decodeBase64(publicKeyBase64)
        guard publicKeyData.count == 32 else {
            throw UpdateManifestError.invalidPublicKey
        }

        let signatureData = try decodeBase64(signatureBase64)
        guard signatureData.count == 64 else {
            throw UpdateManifestError.invalidSignatureEncoding
        }

        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        } catch {
            throw UpdateManifestError.invalidPublicKey
        }

        guard publicKey.isValidSignature(signatureData, for: manifestData) else {
            throw UpdateManifestError.invalidSignature
        }
    }

    public static func sha256Hex(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw UpdateManifestError.dmgReadFailed
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while true {
                let chunk = try autoreleasepool { try handle.read(upToCount: 64 * 1024) }
                guard let chunk, !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
        } catch {
            throw UpdateManifestError.dmgReadFailed
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func normalize(version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "v" || first == "V" else {
            return trimmed
        }
        return String(trimmed.dropFirst())
    }

    private static func decodeBase64(_ value: String) throws -> Data {
        let compact = value.split(whereSeparator: { $0.isWhitespace }).joined()
        guard let data = Data(base64Encoded: compact) else {
            throw UpdateManifestError.invalidSignatureEncoding
        }
        return data
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }
}
