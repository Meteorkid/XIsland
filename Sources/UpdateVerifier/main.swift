import Darwin
import Foundation
import UpdateSecurity

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Update verification failed: \(message)\n".utf8))
    exit(1)
}

private let arguments = CommandLine.arguments
guard arguments.count >= 6 else {
    fail("usage: xisland-update-verify <manifest> <signature> <dmg> <version> <public-key-base64> [key-id]")
}

let manifestPath = arguments[1]
let signaturePath = arguments[2]
let dmgPath = arguments[3]
let expectedVersion = arguments[4]
let publicKey = arguments[5]
let expectedKeyID = arguments.count > 6 ? arguments[6] : nil

do {
    let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
    let signature = try String(contentsOf: URL(fileURLWithPath: signaturePath), encoding: .utf8)
    let actualSHA256 = try UpdateSignatureVerifier.sha256Hex(of: URL(fileURLWithPath: dmgPath))
    let expectedDMG = "XIsland-\(UpdateSignatureVerifier.normalize(version: expectedVersion)).dmg"

    let manifest = try UpdateSignatureVerifier.verify(
        manifestData: manifestData,
        signatureBase64: signature,
        publicKeyBase64: publicKey,
        expectedVersion: expectedVersion,
        expectedDMGFilename: expectedDMG,
        expectedKeyID: expectedKeyID,
        actualDMGSHA256: actualSHA256
    )

    print("Update manifest verified: v\(manifest.version), \(manifest.dmg), \(manifest.sha256)")
} catch {
    fail(error.localizedDescription)
}
