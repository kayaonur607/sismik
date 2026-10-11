import CoreLocation
import Foundation
import Observation

/// Büyük olay modu (sunucu: functions/src/major-event.ts).
///
/// Türkiye'de M5.5+ ya da dünyada M7.0+ bir deprem olduğunda sunucu liste
/// yanıtına `X-Sismik-Major-Event` başlığını ekler. Uygulama yalnızca kimlik
/// değişince `/major-event` ucunu çağırır; olay süresince listede ayrı bir
/// olay kartı gösterilir, olayın detayında artçı takibi ve deprem analizi
/// herkese açılır.
@MainActor
@Observable
final class MajorEventCenter {
    static let shared = MajorEventCenter()
    nonisolated static let responseHeader = "X-Sismik-Major-Event"

    struct Event: Decodable, Equatable {
        let id: String
        let provider: String
        let title: String
        let magnitude: Double
        let depth: Double
        let lat: Double
        let lon: Double
        let date: String
        let region: String
        let expiresAt: Double
        /// Canlı Etkinlik yayın kanalları (2.1.4+ sunucu). Geliştirme derlemesi
        /// sandbox kanalına, diğerleri üretim kanalına abone olur.
        let liveChannels: LiveChannels?

        struct LiveChannels: Decodable, Equatable {
            let prod: String?
            let sandbox: String?
        }

        enum CodingKeys: String, CodingKey {
            case id, provider, title, magnitude, depth, lat, lon, date, region
            case expiresAt = "expires_at"
            case liveChannels = "live_channels"
        }

        /// Bu derlemenin abone olacağı kanal.
        var liveChannelID: String? {
            #if DEBUG
            liveChannels?.sandbox
            #else
            liveChannels?.prod
            #endif
        }

        var expiryDate: Date { Date(timeIntervalSince1970: expiresAt / 1000) }

        var occurredAt: Date { ISO8601.date(from: date) ?? Date() }
        var isExpired: Bool { Date().timeIntervalSince1970 * 1000 >= expiresAt }

        /// Liste henüz almadıysa olayın kendisinden kurulan kayıt.
        var earthquake: Earthquake {
            Earthquake(
                id: id,
                provider: provider,
                title: title,
                magnitude: magnitude,
                depth: depth,
                coordinate: Coordinate(longitude: lon, latitude: lat),
                date: occurredAt
            )
        }
    }

    private(set) var event: Event?
    private var lastID: String?
    private var fetchTask: Task<Void, Never>?

    private init() {}

    /// Liste yanıtının başlığı. Başlık yoksa olay kapanmıştır.
    func record(id raw: String?) {
        let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id, !id.isEmpty else {
            lastID = nil
            if event != nil { event = nil }
            return
        }
        guard id != lastID || event?.isExpired == true else { return }
        lastID = id
        fetchTask?.cancel()
        fetchTask = Task { await fetch() }
    }

    private func fetch() async {
        guard let url = URL(string: BackendConfig.baseURL + "/major-event") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        struct Response: Decodable { let event: Event? }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              !Task.isCancelled else { return }
        event = decoded.event.flatMap { $0.isExpired ? nil : $0 }
    }

    #if DEBUG
    /// Test: listedeki bir depremi büyük olay gibi gösterir (`sismik://debug-major`).
    func simulate(_ quake: Earthquake) {
        let iso = ISO8601DateFormatter().string(from: quake.date)
        event = Event(id: quake.id, provider: quake.provider, title: quake.title, magnitude: quake.magnitude,
                      depth: quake.depth, lat: quake.coordinate.latitude, lon: quake.coordinate.longitude,
                      date: iso, region: "turkiye", expiresAt: (Date().timeIntervalSince1970 + 3_600) * 1000,
                      liveChannels: nil)
    }
    #endif

    /// Bu deprem büyük olayın kendisi mi (ya da aynı olayın başka ajans kaydı)?
    func matches(_ quake: Earthquake) -> Bool {
        guard let event, !event.isExpired else { return false }
        if quake.id == event.id { return true }
        let sameTime = abs(quake.date.timeIntervalSince(event.occurredAt)) <= 120
        let distance = quake.clLocation.distance(from: CLLocation(latitude: event.lat, longitude: event.lon))
        return sameTime && distance <= 100_000
    }

    /// Eldeki listeden artçılar (detayla aynı kural: `AftershockSequence`).
    /// Kart, sunucu sonucu gelene kadar bunu gösterir.
    func aftershocks(in quakes: [Earthquake]) -> [Earthquake] {
        guard let event, !event.isExpired else { return [] }
        return AftershockSequence.select(mainshock: event.earthquake, from: quakes)
    }

    /// Detaydaki "Artçılar" kartıyla aynı kaynaktan yüklenen sayı. Olay
    /// değişince sıfırlanır; en sık 2 dakikada bir yenilenir.
    private(set) var loadedAftershockCount: (eventID: String, count: Int)?
    private var aftershockCountLoadedAt: Date?

    func refreshAftershockCount() async {
        guard let event, !event.isExpired else { return }
        if let loaded = loadedAftershockCount, loaded.eventID == event.id,
           let at = aftershockCountLoadedAt, Date().timeIntervalSince(at) < 120 {
            return
        }
        aftershockCountLoadedAt = Date()
        let aftershocks = await EarthquakeDetailView.loadRelatedAftershocks(for: event.earthquake)
        guard self.event?.id == event.id else { return }
        loadedAftershockCount = (event.id, aftershocks.count)
    }

    /// Kartta gösterilecek sayı: yüklenen sonuç, yoksa eldeki listeden.
    func aftershockCount(in quakes: [Earthquake]) -> Int {
        if let loaded = loadedAftershockCount, loaded.eventID == event?.id { return loaded.count }
        return aftershocks(in: quakes).count
    }
}
