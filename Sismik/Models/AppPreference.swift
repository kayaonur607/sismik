import Foundation

/// Premium'dan bağımsız, tüm kullanıcılara açık uygulama tercihlerinin
/// `UserDefaults` anahtarları. Ayarlar ekranı yazar, ilgili ekran açılışta okur.
enum AppPreference {
    /// Liste kaynağı: `"all"` ya da bir kaynak etiketi (`QuakeProviderStyle.tag`).
    /// Liste filtresindeki kaynak menüsü yazar ve seçim kalıcıdır. Eski
    /// "auto" değeri (2.1.3 ve öncesi) "all" sayılır.
    static let defaultListSource = "listDefaultSource"

    static let allListSources = "all"

    /// "Hissedilir deprem" kartı (liste başı) açık mı? Varsayılan açık.
    static let feltCardEnabled = "feltCard.enabled"
}
