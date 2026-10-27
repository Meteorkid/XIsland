import Foundation
import Security
import IOKit
import CryptoKit

public protocol LicenseCredentialStore {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

public struct KeychainLicenseStore: LicenseCredentialStore {
    private let service: String
    private let account: String

    public init(service: String, account: String = "session") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    public func load() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SoftwareLicenseError.storage(status) }
        return data
    }

    public func save(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(item as CFDictionary, nil)
            guard result == errSecSuccess else { throw SoftwareLicenseError.storage(result) }
        } else if status != errSecSuccess {
            throw SoftwareLicenseError.storage(status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SoftwareLicenseError.storage(status) }
    }
}

public enum LicenseDeviceIdentity {
    /// 只将硬件 UUID 的哈希发往服务端；硬件信息不可得时保存随机身份。
    public static func resolve(store: any LicenseCredentialStore, hardwareUUID: () -> String? = platformUUID) throws -> String {
        if let raw = hardwareUUID(), !raw.isEmpty { return hash(raw.lowercased()) }
        if let data = try store.load(), let raw = String(data: data, encoding: .utf8), !raw.isEmpty { return hash(raw) }
        let raw = UUID().uuidString.lowercased()
        try store.save(Data(raw.utf8))
        return hash(raw)
    }

    public static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
