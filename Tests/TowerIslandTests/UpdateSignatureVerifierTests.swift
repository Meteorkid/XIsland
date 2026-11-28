import CryptoKit
import Foundation
import XCTest
import UpdateSecurity

final class UpdateSignatureVerifierTests: XCTestCase {
    private let keyID = "xisland-update-test"

    private func temporaryFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try contents.write(to: url)
        return url
    }

    private func manifestData(
        version: String,
        dmg: String = "XIsland-2.3.4.dmg",
        sha256: String,
        keyID: String? = nil
    ) -> Data {
        Data(
            """
            {"schema":1,"version":"\(version)","dmg":"\(dmg)","sha256":"\(sha256)","key_id":"\(keyID ?? self.keyID)"}
            """.utf8
        )
    }

    private func signature(for data: Data, using key: Curve25519.Signing.PrivateKey) throws -> String {
        try key.signature(for: data).base64EncodedString()
    }

    func testVerifiesSignedManifestAndNormalizesVersion() throws {
        let key = Curve25519.Signing.PrivateKey()
        let dmg = try temporaryFile(contents: Data("dmg".utf8))
        defer { try? FileManager.default.removeItem(at: dmg) }
        let hash = try UpdateSignatureVerifier.sha256Hex(of: dmg)
        let data = manifestData(version: "2.3.4", sha256: hash)
        let signed = try signature(for: data, using: key)

        let manifest = try UpdateSignatureVerifier.verify(
            manifestData: data,
            signatureBase64: signed,
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
            expectedVersion: "v2.3.4",
            expectedDMGFilename: "XIsland-2.3.4.dmg",
            expectedKeyID: keyID,
            actualDMGSHA256: hash
        )

        XCTAssertEqual(manifest.version, "2.3.4")
    }

    func testRejectsManifestChangedAfterSigning() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = manifestData(version: "2.3.4", sha256: String(repeating: "a", count: 64))
        let signed = try signature(for: data, using: key)
        let tampered = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "2.3.4", with: "2.3.5").utf8)

        XCTAssertThrowsError(try UpdateSignatureVerifier.verifySignature(
            manifestData: tampered,
            signatureBase64: signed,
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()
        )) { error in
            XCTAssertEqual(error as? UpdateManifestError, .invalidSignature)
        }
    }

    func testRejectsVersionMismatch() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = manifestData(version: "2.3.4", sha256: String(repeating: "a", count: 64))

        XCTAssertThrowsError(try UpdateSignatureVerifier.verify(
            manifestData: data,
            signatureBase64: try signature(for: data, using: key),
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
            expectedVersion: "2.3.5",
            expectedDMGFilename: "XIsland-2.3.4.dmg",
            expectedKeyID: keyID,
            actualDMGSHA256: String(repeating: "a", count: 64)
        )) { error in
            XCTAssertEqual(
                error as? UpdateManifestError,
                .versionMismatch(expected: "2.3.5", actual: "2.3.4")
            )
        }
    }

    func testRejectsChecksumMismatch() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = manifestData(version: "2.3.4", sha256: String(repeating: "a", count: 64))

        XCTAssertThrowsError(try UpdateSignatureVerifier.verify(
            manifestData: data,
            signatureBase64: try signature(for: data, using: key),
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
            expectedVersion: "2.3.4",
            expectedDMGFilename: "XIsland-2.3.4.dmg",
            expectedKeyID: keyID,
            actualDMGSHA256: String(repeating: "b", count: 64)
        )) { error in
            XCTAssertEqual(error as? UpdateManifestError, .checksumMismatch)
        }
    }

    func testRejectsUnknownKeyID() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = manifestData(version: "2.3.4", sha256: String(repeating: "a", count: 64), keyID: "other-key")

        XCTAssertThrowsError(try UpdateSignatureVerifier.verify(
            manifestData: data,
            signatureBase64: try signature(for: data, using: key),
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
            expectedVersion: "2.3.4",
            expectedDMGFilename: "XIsland-2.3.4.dmg",
            expectedKeyID: keyID,
            actualDMGSHA256: String(repeating: "a", count: 64)
        )) { error in
            XCTAssertEqual(
                error as? UpdateManifestError,
                .keyIDMismatch(expected: self.keyID, actual: "other-key")
            )
        }
    }

    func testRejectsMalformedSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = manifestData(version: "2.3.4", sha256: String(repeating: "a", count: 64))

        XCTAssertThrowsError(try UpdateSignatureVerifier.verifySignature(
            manifestData: data,
            signatureBase64: "not-base64",
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()
        )) { error in
            XCTAssertEqual(error as? UpdateManifestError, .invalidSignatureEncoding)
        }
    }
}
