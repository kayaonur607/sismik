import Foundation

/// Gizli anahtarları kaynak dosyaya gömmeden build yapılandırmasından okur.
enum Secrets {
    /// Yerel geliştirmede Info.plist'e `GOOGLE_PLACES_API_KEY` olarak eklenebilir.
    /// Boşsa uygulama güvenli biçimde yalnızca Apple Haritalar ile devam eder.
    static var googlePlacesKey: String {
        let plistValue = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_PLACES_API_KEY") as? String ?? ""
        if isUsable(plistValue) { return plistValue }

        let defaultsValue = UserDefaults.standard.string(forKey: "GOOGLE_PLACES_API_KEY") ?? ""
        return isUsable(defaultsValue) ? defaultsValue : ""
    }


    private static func isUsable(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("$(")
    }
}
