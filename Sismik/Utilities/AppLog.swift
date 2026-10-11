import Foundation
import OSLog

/// Hafif ve merkezi uygulama tanılaması. Token, konum ve kullanıcı içeriği
/// loglanmaz; yalnızca olay/latency/status gibi üretimde işe yarayan sinyaller
/// tutulur.
enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.kayasoftware.sismik"

    static let network = Logger(subsystem: subsystem, category: "network")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    static let performance = Logger(subsystem: subsystem, category: "performance")
    static let ai = Logger(subsystem: subsystem, category: "ai")
}
