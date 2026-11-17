import Foundation
import Security

/// Kleiner Wrapper um den Schlüsselbund. Alles bleibt auf diesem Gerät
/// (`AfterFirstUnlockThisDeviceOnly`), damit Sessions auch im Hintergrund
/// nach dem ersten Entsperren auf Schlüssel zugreifen können.
enum KeychainStore {
    static let servicePrefix = "de.marck.shellwave"

    static func set(_ data: Data, service: String, account: String) {
        delete(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix).\(service)",
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix).\(service)",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix).\(service)",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Bequeme Zugriffe für Text

    static func setString(_ value: String, service: String, account: String) {
        if value.isEmpty {
            delete(service: service, account: account)
        } else {
            set(Data(value.utf8), service: service, account: account)
        }
    }

    static func string(service: String, account: String) -> String {
        get(service: service, account: account).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
