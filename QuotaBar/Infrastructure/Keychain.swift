import Foundation
import Security

enum Keychain {
    /// Reads a generic password by service name. Returns nil when the item
    /// does not exist or access was denied — never throws into the UI.
    static func genericPassword(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Replaces the payload of an existing item, leaving its access control
    /// untouched — unlike `security add-generic-password -U`, which recreates
    /// the item and resets who may read it.
    @discardableResult
    static func updateGenericPassword(service: String, data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
    }

    /// Writes our own item, creating it on first use. We own it, so reading it
    /// back never prompts.
    @discardableResult
    static func setOwnPassword(service: String, data: Data) -> Bool {
        if updateGenericPassword(service: service, data: data) { return true }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName(),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Removes an item we own. Used when its payload is known to be stale.
    @discardableResult
    static func deleteOwnPassword(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
