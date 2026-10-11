import Foundation

/// Artçı deprem olasılığı: Reasenberg & Jones (1989) genel modeli.
///
/// Ana şoktan `t` gün sonra, büyüklüğü `M` ve üzeri artçıların oranı
///
///     λ(t, M) = 10^(a + b·(Mₘ − M)) · (t + c)^(−p)
///
/// Bir zaman aralığındaki beklenen artçı sayısı bu oranın integrali, en az
/// bir artçı olma olasılığı ise Poisson varsayımıyla `1 − e^(−N)`. USGS'in
/// büyük depremlerden sonra yayımladığı artçı tahminleri de aynı modelin
/// bölgesel parametreli sürümüne dayanır.
///
/// Parametreler genel (dizi-özgü olmayan) değerlerdir; gözlenen artçılara göre
/// güncellenmez. Bu yüzden sonuç bir büyüklük sırası olarak okunmalı —
/// arayüz yuvarlanmış yüzde gösterir. Tamamen cihazda hesaplanır: sunucu
/// isteği ya da veritabanı okuması yoktur.
enum AftershockForecast {
    static let a = -1.67
    static let b = 0.91
    static let p = 1.08
    /// Gün cinsinden.
    static let c = 0.05

    /// Olasılığı sorulan en küçük artçı büyüklüğü: ana şoktan bir tam birim
    /// küçüğü, en az M4.0 (hissedilen, hasar potansiyeli taşıyan eşik).
    /// M6.3 → M5+, M5.4 → M4+.
    static func thresholdMagnitude(forMainshock magnitude: Double) -> Double {
        max(4.0, floor(magnitude) - 1)
    }

    /// Ana şoktan `elapsed` saniye sonra başlayan `window` süresinde en az bir
    /// `minimumMagnitude`+ artçı olma olasılığı (0...1).
    static func probability(
        mainshockMagnitude: Double,
        minimumMagnitude: Double,
        elapsed: TimeInterval,
        window: TimeInterval = 86_400
    ) -> Double {
        guard mainshockMagnitude.isFinite, minimumMagnitude.isFinite, window > 0 else { return 0 }
        let start = max(0, elapsed) / 86_400
        let end = start + window / 86_400
        let productivity = pow(10, a + b * (mainshockMagnitude - minimumMagnitude))
        let integral = (pow(start + c, 1 - p) - pow(end + c, 1 - p)) / (p - 1)
        let expected = max(0, productivity * integral)
        return 1 - exp(-expected)
    }
}
