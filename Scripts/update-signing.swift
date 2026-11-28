import CryptoKit
import Darwin
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("update-signing: \(message)\n".utf8))
    exit(1)
}

private func readRequired(_ path: String) -> Data {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        fail("cannot read \(path)")
    }
    return data
}

private func writePrivate(_ data: Data, to path: String) {
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    } catch {
        fail("cannot write private key: \(error.localizedDescription)")
    }
}

private func writePublic(_ data: Data, to path: String) {
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: url.path
        )
    } catch {
        fail("cannot write public key: \(error.localizedDescription)")
    }
}

private func decodeKey(_ data: Data) -> Data {
    let text = String(decoding: data, as: UTF8.self)
        .split(whereSeparator: { $0.isWhitespace })
        .joined()
    guard let decoded = Data(base64Encoded: text), decoded.count == 32 else {
        fail("key must be base64-encoded 32-byte Ed25519 material")
    }
    return decoded
}

private func base64(_ data: Data) -> String {
    data.base64EncodedString()
}

private let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fail("usage: update-signing.swift generate|sign|public-key|verify ...")
}

switch arguments[1] {
case "generate":
    guard arguments.count == 4 else {
        fail("usage: update-signing.swift generate <private-key> <public-key>")
    }
    let privateURL = URL(fileURLWithPath: arguments[2])
    guard !FileManager.default.fileExists(atPath: privateURL.path) else {
        fail("private key already exists at \(privateURL.path); refusing to overwrite")
    }

    let privateKey = Curve25519.Signing.PrivateKey()
    let privateData = privateKey.rawRepresentation
    let publicData = privateKey.publicKey.rawRepresentation
    writePrivate(Data(base64(privateData).utf8), to: arguments[2])
    writePublic(Data(base64(publicData).utf8), to: arguments[3])
    print(base64(publicData))

case "sign":
    guard arguments.count == 5 else {
        fail("usage: update-signing.swift sign <private-key> <manifest> <signature>")
    }
    let privateData = decodeKey(readRequired(arguments[2]))
    let manifest = readRequired(arguments[3])
    let privateKey: Curve25519.Signing.PrivateKey
    do {
        privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateData)
    } catch {
        fail("invalid private key: \(error.localizedDescription)")
    }
    do {
        let signature = try privateKey.signature(for: manifest)
        let signatureText = base64(signature) + "\n"
        try Data(signatureText.utf8).write(
            to: URL(fileURLWithPath: arguments[4]),
            options: [.atomic]
        )
        print("signed \(arguments[3])")
    } catch {
        fail("cannot sign manifest: \(error.localizedDescription)")
    }

case "public-key":
    guard arguments.count == 3 else {
        fail("usage: update-signing.swift public-key <private-key>")
    }
    let privateData = decodeKey(readRequired(arguments[2]))
    do {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateData)
        print(base64(privateKey.publicKey.rawRepresentation))
    } catch {
        fail("invalid private key: \(error.localizedDescription)")
    }

case "verify":
    guard arguments.count == 5 else {
        fail("usage: update-signing.swift verify <public-key> <manifest> <signature>")
    }
    let publicArg = arguments[2]
    let publicInput: Data
    if FileManager.default.fileExists(atPath: publicArg) {
        publicInput = readRequired(publicArg)
    } else {
        publicInput = Data(publicArg.utf8)
    }
    let publicData = decodeKey(publicInput)
    let manifest = readRequired(arguments[3])
    let signatureText = String(decoding: readRequired(arguments[4]), as: UTF8.self)
    let compact = signatureText.split(whereSeparator: { $0.isWhitespace }).joined()
    guard let signature = Data(base64Encoded: compact), signature.count == 64 else {
        fail("signature must be base64-encoded 64-byte Ed25519 signature")
    }
    do {
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
        guard publicKey.isValidSignature(signature, for: manifest) else {
            fail("manifest signature did not verify")
        }
        print("manifest signature verified")
    } catch {
        fail("invalid public key: \(error.localizedDescription)")
    }

default:
    fail("unknown command: \(arguments[1])")
}
