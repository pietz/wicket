import Foundation
import Security

/// Extension secrets in the login keychain: one generic password per extension id and secret name.
/// The file-based login keychain, not the data-protection one, which needs a provisioned team
/// entitlement that ad hoc and development builds don't have.
public enum Keychain {
    public static func secret(_ name: String, extension id: String) -> String? {
        var query = item(name, extension: id)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func setSecret(_ value: String, name: String, extension id: String) throws(KeychainError) {
        let query = item(name, extension: id)
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            add[kSecAttrLabel] = "Wicket extension \(id): \(name)"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private static func item(_ name: String, extension id: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword, kSecAttrService: "app.wicket.extension.\(id)",
            kSecAttrAccount: name,
        ]
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain: \(message) (\(status))"
    }
}
