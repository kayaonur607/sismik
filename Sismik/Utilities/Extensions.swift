import Foundation
import SwiftUI

extension String {
    /// Türkçe yer adlarını düzgün büyük/küçük harfe çevirir (İ/ı dahil).
    var capitalizedTR: String {
        // AFAD adları Türkçe: dil ayarından bağımsız Türkçe kurallar (i → İ).
        // Parantez, tire ve eğik çizgiden sonraki harf de büyür:
        // "BATTALGAZI (MALATYA)" → "Battalgazi (Malatya)".
        let locale = Locale(identifier: "tr_TR")
        var result = ""
        result.reserveCapacity(count)
        var capitalizeNext = true
        for character in lowercased(with: locale) {
            if capitalizeNext, character.isLetter {
                result += String(character).uppercased(with: locale)
                capitalizeNext = false
            } else {
                result.append(character)
                if " (-/".contains(character) { capitalizeNext = true }
            }
        }
        return result
    }
}

/// Tüm servis/model katmanlarında paylaşılan ISO8601 tarih formatlayıcıları.
/// `ISO8601DateFormatter` desteklenen OS sürümlerinde thread-safe'tir ancak
/// Foundation tarafından `Sendable` işaretlenmemiştir; bu yüzden tek paylaşılan
/// örnek `nonisolated(unsafe)` ile tutulur (her katmanın kendi kopyasını
/// oluşturmasına gerek kalmaz).
enum ISO8601 {
    nonisolated(unsafe) static let formatter = ISO8601DateFormatter()
    nonisolated(unsafe) static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Standart biçimi dener, olmazsa kesirli saniyeli biçime düşer.
    static func date(from string: String) -> Date? {
        formatter.date(from: string) ?? fractionalFormatter.date(from: string)
    }
}

extension Date {
    private static var threadLocalRelativeFormatter: RelativeDateTimeFormatter {
        let key = "Sismik.RelativeDateTimeFormatter"
        if let formatter = Thread.current.threadDictionary[key] as? RelativeDateTimeFormatter {
            return formatter
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        Thread.current.threadDictionary[key] = f
        return f
    }

    private static var threadLocalClockFormatter: DateFormatter {
        let key = "Sismik.ClockFormatter"
        if let formatter = Thread.current.threadDictionary[key] as? DateFormatter {
            return formatter
        }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        Thread.current.threadDictionary[key] = f
        return f
    }

    /// "5 dk önce", "2 sa önce" gibi kısa göreli zaman.
    var relativeShort: String {
        let f = Date.threadLocalRelativeFormatter
        let identifier = AppLanguage.current.localeIdentifier
        if f.locale.identifier != identifier {
            f.locale = AppLanguage.locale(for: identifier)
        }
        return f.localizedString(for: self, relativeTo: Date())
    }


    var clockTime: String {
        let f = Date.threadLocalClockFormatter
        let identifier = AppLanguage.current.localeIdentifier
        if f.locale.identifier != identifier {
            f.locale = AppLanguage.locale(for: identifier)
        }
        return f.string(from: self)
    }
}

extension Double {
    /// Tek ondalıklı sayı biçimi. `.number.precision(...)` her çağrıda yeni bir
    /// stil değeri kuruyordu; derinlik metni liste satırlarında, harita
    /// balonlarında ve detay kartlarında saniyede yüzlerce kez okunuyor.
    private static let oneFractionDigit = FloatingPointFormatStyle<Double>
        .number
        .precision(.fractionLength(1))

    /// Deprem derinliği için uygulama genelinde tutarlı "X.X km" biçimi.
    var depthKmText: String {
        "\(formatted(Self.oneFractionDigit)) km"
    }

    /// Metre cinsinden bir mesafeyi en yakın km'ye yuvarlayıp "X km" olarak döndürür.
    var metersAsKmText: String {
        "\(Int((self / 1_000).rounded())) km"
    }

    /// Zaten km cinsinden olan bir mesafeyi en yakın tam sayıya yuvarlayıp "X km" olarak döndürür.
    var kmText: String {
        "\(Int(rounded()).formatted(.number.grouping(.automatic))) km"
    }
}

// MARK: - LazyView
struct LazyView<Content: View>: View {
    private let build: () -> Content
    
    init(_ build: @escaping () -> Content) {
        self.build = build
    }
    
    var body: Content {
        build()
    }
}
