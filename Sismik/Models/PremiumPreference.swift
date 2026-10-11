import Foundation

/// Premium kullanıcıya açık açılış tercihlerinin `UserDefaults` anahtarları.
/// Ayarlar ekranı bu anahtarları yazar; harita ve deprem detayı ekranları
/// ilk görünümlerinde okuyup uygular. Anahtarların tek bir yerde tanımlı
/// olması, yazan ve okuyan tarafın birbirinden kopmasını engeller.
enum PremiumPreference {
    /// Uygulama liste yerine doğrudan harita modunda açılır.
    static let defaultMapMode = "prefDefaultMapMode"
    /// Harita standart yerine uydu katmanıyla açılır.
    static let defaultSatellite = "prefDefaultSatellite"
    /// GEM aktif fay katmanı harita açılırken etkin gelir.
    static let defaultFaults = "prefDefaultFaults"
    /// Deprem detayı açıldığında Sismolog AI analizi kendiliğinden yüklenir.
    static let autoAIAnalysis = "prefAutoAIAnalysis"
}
