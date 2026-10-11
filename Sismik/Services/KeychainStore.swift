import Foundation
import Security

/// Küçük değerleri Keychain'de saklayan ince sarmalayıcı.
///
/// Neden UserDefaults değil: UserDefaults uygulama silindiğinde gider.
/// Keychain kaydı kurulumlar arasında yaşar, dolayısıyla kullanıcı
/// uygulamayı silip yeniden kurduğunda takip ettiği yerler kaybolmaz.
///
/// `AppUserIdentity` aynı deseni kullanır ama bilinçli olarak
/// `...ThisDeviceOnly` erişilebilirliğiyle: o kayıt cihaza aittir, yedekle
/// başka cihaza taşınırsa iki cihaz tek müşteri gibi görünür. Kullanıcı
/// TERCİHLERİ için bunun tersi doğru — yeni telefona geçen kullanıcı
/// yerlerini yanında götürmeli — bu yüzden burada varsayılan
/// `kSecAttrAccessibleAfterFirstUnlock` (yedekle taşınabilir).
enum KeychainStore {
    static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, !data.isEmpty
        else { return nil }
        return data
    }

    @discardableResult
    static func write(
        _ data: Data,
        service: String,
        account: String,
        accessible: CFString = kSecAttrAccessibleAfterFirstUnlock
    ) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
