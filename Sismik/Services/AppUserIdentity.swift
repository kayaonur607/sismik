import Foundation
import Security

/// Bu cihazdaki kurulumlar arasında Keychain'de korunan anonim kimlik.
/// Farklı cihazları bir kişi olarak birleştirmez; hesap sistemi olmadığı için
/// cihazlar arası satın alma erişimi RevenueCat restore/transfer ayarına bağlıdır.
@MainActor
enum AppUserIdentity {
    private static let service = "com.kayasoftware.sismik.identity"
    private static let account = "appUserID"
    private static var sessionIdentity: String?

    static var current: String {
        if let sessionIdentity { return sessionIdentity }
        let identity = read() ?? UUID().uuidString
        sessionIdentity = identity
        // A temporarily unavailable Keychain must not create a new identity
        // for every call within the same launch.
        write(identity)
        return identity
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func write(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Yedeklemeyle başka bir cihaza taşınmasın: kimlik cihazın kendisine
        // ait olmalı, aksi hâlde iki cihaz tek müşteri gibi görünür.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }
}
