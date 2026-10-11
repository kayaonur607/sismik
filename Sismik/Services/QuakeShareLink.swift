import Foundation

/// Deprem paylaşım bağlantıları (Universal Link).
///
/// Bağlantı `https://<BackendConfig.host>/quake/<id>?...` biçimindedir:
/// Sismik yüklü cihazda doğrudan uygulamada (detay sayfası) açılır; yüklü
/// değilse Firebase Hosting'deki yedek sayfa deprem bilgisini ve App Store
/// bağlantısını gösterir. Deprem verisi sorgu parametrelerinde taşındığı için
/// 24 saatlik listeden düşmüş bir deprem bile alıcıda açılabilir.
enum QuakeShareLink {
    /// Yeni bağlantılar herkese açık tanıtım sitesiyle üretilir. API başka bir
    /// sunucu adında (`BackendConfig.apiHost`) durur; paylaşılan bir bağlantıyı
    /// açan kişi hiçbir API ucuna denk gelmez.
    static var host: String { BackendConfig.linkHost }

    /// Açılabilecek tüm sunucu adları: yeni adres ve daha önce paylaşılmış
    /// bağlantıların eski adresi.
    private static var acceptedHosts: Set<String> {
        [BackendConfig.linkHost, BackendConfig.legacyHost]
    }

    /// Paylaşılacak https bağlantısını üretir.
    static func url(for quake: Earthquake) -> URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.path = "/quake/\(quake.id)"
        comps.queryItems = [
            URLQueryItem(name: "mag", value: String(format: "%.1f", quake.magnitude)),
            URLQueryItem(name: "depth", value: String(format: "%.1f", quake.depth)),
            URLQueryItem(name: "lat", value: String(quake.coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(quake.coordinate.longitude)),
            URLQueryItem(name: "t", value: String(Int(quake.date.timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "title", value: quake.displayTitle),
            URLQueryItem(name: "src", value: quake.provider)
        ]
        return comps.url
    }

    /// Gelen Universal Link'ten deprem nesnesi kurar; Sismik bağlantısı
    /// değilse nil döner.
    static func earthquake(from url: URL) -> Earthquake? {
        guard let incoming = url.host?.lowercased(),
              acceptedHosts.contains(incoming) else { return nil }
        let parts = url.pathComponents
        guard parts.count >= 3, parts[1] == "quake" else { return nil }
        let id = parts.dropFirst(2).joined(separator: "/")
        guard !id.isEmpty else { return nil }

        var query: [String: String] = [:]
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.forEach {
            query[$0.name] = $0.value
        }

        let magnitude = Double(query["mag"] ?? "") ?? 0
        let depth = Double(query["depth"] ?? "") ?? 0
        let lat = Double(query["lat"] ?? "") ?? 0
        let lon = Double(query["lon"] ?? "") ?? 0
        let millis = Double(query["t"] ?? "")
        let date = millis.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let title = query["title"] ?? id
        let provider = query["src"] ?? Self.provider(fromID: id)

        return Earthquake(
            id: id,
            provider: provider,
            title: title,
            magnitude: magnitude,
            depth: depth,
            coordinate: Coordinate(longitude: lon, latitude: lat),
            date: date
        )
    }

    /// Bağlantıdaki depremi, bildirim akışının kullandığı bekleyen-deprem
    /// deposuna yazar — `NotificationManager.consumePendingQuake(id:)` ile
    /// aynen tüketilir, detay soğuk açılışta bile açılır.
    static func stash(_ quake: Earthquake) {
        let dict: [String: Any] = [
            "id": quake.id,
            "provider": quake.provider,
            "title": quake.title,
            "magnitude": quake.magnitude,
            "depth": quake.depth,
            "lat": quake.coordinate.latitude,
            "lon": quake.coordinate.longitude,
            "date": ISO8601.formatter.string(from: quake.date)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            UserDefaults.standard.set(data, forKey: NotificationManager.PushKey.pendingQuake)
        }
    }

    private static func provider(fromID id: String) -> String {
        if id.hasPrefix("afad-") { return "AFAD" }
        if id.hasPrefix("emsc-") { return "EMSC" }
        if id.hasPrefix("usgs-") { return "USGS" }
        return "EMSC"
    }
}
