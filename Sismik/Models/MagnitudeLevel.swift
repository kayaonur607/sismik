import SwiftUI
import UIKit

/// Deprem büyüklüğüne göre renk ve etiket.
///
/// Sınıflar yaygın büyüklük tanımlarına dayanır (mikro < 2; 2–3,9 küçük,
/// burada hissedilme farkı büyük olduğu için ikiye bölünür; 4 orta; 5
/// kuvvetli; 6 büyük; 7+ çok büyük). Renkler yalnızca yeşil → turuncu →
/// kırmızı tonlarında, tek yönlü bir tehlike rampası: açık yeşilden koyu
/// bordoya; büyüdükçe hem ton ısınır hem renk koyulaşır.
///
/// Widget aynı eşik ve renkleri kopyalar (`WidgetMagnitude`); değişiklik iki
/// yerde yapılmalı.
enum MagnitudeLevel: CaseIterable {
    case micro      // < 2.0
    case minor      // 2.0 – 2.9
    case light      // 3.0 – 3.9
    case moderate   // 4.0 – 4.9
    case strong     // 5.0 – 5.9
    case major      // 6.0 – 6.9
    case great      // ≥ 7.0

    init(magnitude: Double) {
        switch magnitude {
        case ..<2.0: self = .micro
        case ..<3.0: self = .minor
        case ..<4.0: self = .light
        case ..<5.0: self = .moderate
        case ..<6.0: self = .strong
        case ..<7.0: self = .major
        default:     self = .great
        }
    }

    var color: Color {
        switch self {
        case .micro:    Color(red: 0.49, green: 0.75, blue: 0.45) // açık yeşil
        case .minor:    Color(red: 0.20, green: 0.60, blue: 0.29) // yeşil
        case .light:    Color(red: 0.55, green: 0.68, blue: 0.11) // sarımsı yeşil
        case .moderate: Color(red: 0.97, green: 0.62, blue: 0.09) // açık turuncu
        case .strong:   Color(red: 0.91, green: 0.40, blue: 0.05) // koyu turuncu
        case .major:    Color(red: 0.85, green: 0.15, blue: 0.13) // kırmızı
        case .great:    Color(red: 0.55, green: 0.05, blue: 0.08) // bordo
        }
    }

    /// Dolu renk zemin üstündeki yazı rengi. Açık zeminlerde (açık yeşil,
    /// sarımsı yeşil, açık turuncu) beyaz okunmuyor; siyah da zemine
    /// yabancı duruyordu. Zeminle aynı tonun çok koyusu kullanılır, koyu
    /// zeminlerde beyaz.
    var foregroundOnColor: Color {
        switch self {
        case .micro:    Color(red: 0.08, green: 0.27, blue: 0.08)
        case .light:    Color(red: 0.20, green: 0.25, blue: 0.00)
        case .moderate: Color(red: 0.36, green: 0.18, blue: 0.00)
        default:        .white
        }
    }

    /// Açık ton zemin (`color.opacity(0.15)`) ya da kart zemini üstünde
    /// rakam olarak kullanılan renk; açık/koyu görünüme göre ayarlanır.
    /// Açık görünümde aynı tonun koyusu (açık tonlar beyaz zeminde soluk
    /// kalıyordu), koyu görünümde açığı (koyu tonlar siyah zeminde
    /// kayboluyordu).
    var textColor: Color {
        switch self {
        case .micro:    .adaptive(light: (0.25, 0.53, 0.23), dark: (0.58, 0.85, 0.54))
        case .minor:    .adaptive(light: (0.16, 0.50, 0.23), dark: (0.40, 0.80, 0.46))
        case .light:    .adaptive(light: (0.40, 0.51, 0.04), dark: (0.72, 0.84, 0.30))
        case .moderate: .adaptive(light: (0.82, 0.47, 0.00), dark: (1.00, 0.72, 0.28))
        case .strong:   .adaptive(light: (0.86, 0.36, 0.03), dark: (1.00, 0.56, 0.24))
        case .major:    .adaptive(light: (0.80, 0.12, 0.10), dark: (1.00, 0.42, 0.38))
        case .great:    .adaptive(light: (0.55, 0.05, 0.08), dark: (0.92, 0.36, 0.38))
        }
    }

    var label: String {
        switch self {
        case .micro:    L("magnitude.micro")
        case .minor:    L("magnitude.minor")
        case .light:    L("magnitude.light")
        case .moderate: L("magnitude.moderate")
        case .strong:   L("magnitude.strong")
        case .major:    L("magnitude.major")
        case .great:    L("magnitude.great")
        }
    }

    var range: String {
        switch self {
        case .micro:    "< 2"
        case .minor:    "2–3"
        case .light:    "3–4"
        case .moderate: "4–5"
        case .strong:   "5–6"
        case .major:    "6–7"
        case .great:    "7+"
        }
    }

    /// Bölge oynatımında kullanılan nokta ölçeği. Eşikler renk
    /// kategorileriyle aynı enum'da tutulduğu için lejant ve MapKit renderer'ı
    /// birbirinden kopamaz.
    var playbackMarkerRadius: CGFloat {
        switch self {
        case .micro: 7.5
        case .minor: 9
        case .light: 11
        case .moderate: 13
        case .strong: 15.5
        case .major: 18.5
        case .great: 22
        }
    }

    var playbackLegendDiameter: CGFloat {
        switch self {
        case .micro: 6
        case .minor: 7.5
        case .light: 9
        case .moderate: 11
        case .strong: 13
        case .major: 15.5
        case .great: 18
        }
    }

    /// Çizim sırası: küçükler önce, büyükler üstte.
    var sortIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

private extension Color {
    /// Açık/koyu görünüme göre değişen renk (RGB 0…1).
    static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

extension Earthquake {
    var level: MagnitudeLevel { MagnitudeLevel(magnitude: magnitude) }
}
