import Foundation

/// Cihaz bölgesine göre yerel acil çağrı numarası (Acil sekmesi, deprem anı
/// modu, enkaz modu ortak kullanır).
enum EmergencyNumber {
    static var local: String {
        switch (Locale.current.region?.identifier ?? "TR").uppercased() {
        case "US", "CA": "911"
        case "GB": "999"
        case "AU": "000"
        case "NZ": "111"
        case "JP": "119"
        case "CN": "120"
        default: "112"
        }
    }

    static var callURL: URL? { URL(string: "tel://\(local)") }
}
