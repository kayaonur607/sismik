import CoreLocation
import Foundation

/// ORFEUS RRSM (Rapid Raw Strong-Motion): Avrupa–Akdeniz'de M3.5+ depremlerde
/// istasyonlarda ÖLÇÜLEN yer ivmesi (PGA, cm/s²) ve hızı (PGV, cm/s).
///
/// - Kapsam: 27°–81° K, 32° B–51° D ve M3.5+ (RRSM'in kendi kuralı). Olaylar
///   EMSC kataloğundan gelir; kimlikleri EMSC'ninkiyle aynıdır
///   (`emsc-20260916_0000171` → `20260916_0000171`).
/// - Veri depremden genellikle 5–20 dk sonra hazır olur; RRSM ilk 2 günde
///   birkaç kez yeniden işler. Kart yalnızca ölçüm yayımlanmışsa görünür.
/// - Doğrudan ORFEUS'a gidilir: Sismik sunucusu ve veritabanı kullanılmaz.
///   Sonuç olay başına bellekte tutulur.
///
/// RRSM verisi otomatik işlenmiştir ve ORFEUS'a göre araştırma amaçlıdır;
/// arayüz bunu ve kaynağı açıkça belirtir.
enum RRSMService {
    struct Station: Identifiable, Hashable, Sendable {
        var id: String { "\(network).\(code)" }
        let network: String
        let code: String
        let latitude: Double
        let longitude: Double
        let distanceKm: Double
        /// Yatay bileşenlerin en büyüğü (cm/s²); yatay kanal yoksa tüm kanallar.
        let pga: Double
        /// cm/s
        let pgv: Double
        /// Merkez üssünden istasyona yön (0 = kuzey, saat yönünde derece).
        let bearing: Double

        var pgaPercentG: Double { pga / 980.665 * 100 }
        /// Sekiz ana yönden biri: 0 K, 1 KD, 2 D, … 7 KB.
        var directionIndex: Int { Int(((bearing + 22.5).truncatingRemainder(dividingBy: 360)) / 45) % 8 }
    }

    struct Result: Sendable {
        let eventID: String
        /// PGA'ya göre büyükten küçüğe.
        let stations: [Station]

        var peak: Station? { stations.first }
        var eventURL: URL? { URL(string: "https://www.orfeus-eu.org/rrsm/event/\(eventID)/") }
    }

    enum Availability: Sendable {
        /// Kapsam dışı (bölge ya da büyüklük): istek atılmaz.
        case outOfScope
        /// Kapsamda ama ölçümler henüz yayımlanmadı (ilk ~30 dk).
        case pending
        /// RRSM bu olay için ölçüm yayımlamadı.
        case unavailable
        /// Ağ hatası: ORFEUS'a ulaşılamadı (önbelleğe yazılmaz).
        case unreachable
        case available(Result)
    }

    private static let base = "https://orfeus-eu.org/odcws/rrsm/1"
    /// RRSM kuralı M3.5; ajanslar arası büyüklük farkı için biraz esnek.
    private static let minimumMagnitude = 3.3
    /// Veri gecikmesi: bu süreden genç olayda "henüz yok" beklenen durumdur.
    static let pendingWindow: TimeInterval = 45 * 60

    private static let cache = ResultCache()

    static func isInScope(_ quake: Earthquake) -> Bool {
        let lat = quake.coordinate.latitude
        let lon = quake.coordinate.longitude
        return (27...81).contains(lat) && (-32...51).contains(lon) && quake.magnitude >= minimumMagnitude
    }

    static func availability(for quake: Earthquake) async -> Availability {
        guard isInScope(quake) else { return .outOfScope }
        let age = Date().timeIntervalSince(quake.date)
        if let cached = await cache.value(for: quake.id) { return cached }

        let result: Availability
        do {
            if let found = try await measurements(for: quake), !found.stations.isEmpty {
                result = .available(found)
            } else {
                result = age < pendingWindow ? .pending : .unavailable
            }
        } catch {
            // Ağ hatası kalıcı sonuç sayılmaz: önbelleğe yazılmaz, tekrar denenir.
            return .unreachable
        }
        // Bekleyen sonuç kısa ömürlü; kart dakikada bir yeniden sorar.
        await cache.store(result, for: quake.id, ttl: { if case .pending = result { return 50 } else { return 3_600 } }())
        return result
    }

    // MARK: - Olay eşleştirme

    /// EMSC kaydı RRSM'de aynı kimlikle durur. Diğer ajansların (AFAD, USGS,
    /// NOA) kaydı için olay saatinin ±2 dk çevresindeki tüm ölçümler tek
    /// istekte alınır ve zaman, konum ve büyüklükçe en yakın RRSM olayı seçilir.
    /// Tarih sınırı yoktur: eski depremler de eşleşir.
    private static func measurements(for quake: Earthquake) async throws -> Result? {
        var components = URLComponents(string: "\(base)/peak-motion")!
        if quake.id.hasPrefix("emsc-") {
            components.queryItems = [URLQueryItem(name: "eventid", value: String(quake.id.dropFirst("emsc-".count)))]
        } else {
            let formatter = ISO8601DateFormatter()
            components.queryItems = [
                URLQueryItem(name: "starttime", value: formatter.string(from: quake.date.addingTimeInterval(-120))),
                URLQueryItem(name: "endtime", value: formatter.string(from: quake.date.addingTimeInterval(120)))
            ]
        }
        guard let records: [PeakMotionDTO] = try await fetch(components.url!), !records.isEmpty else { return nil }

        let origin = CLLocation(latitude: quake.coordinate.latitude, longitude: quake.coordinate.longitude)
        let formatter = ISO8601DateFormatter()
        let best = Dictionary(grouping: records, by: \.eventID)
            .compactMap { id, group -> (id: String, score: Double, records: [PeakMotionDTO])? in
                guard let event = group.first else { return nil }
                if quake.id.hasPrefix("emsc-") { return (id, 0, group) }
                guard let time = formatter.date(from: event.eventTime) else { return nil }
                let dt = abs(time.timeIntervalSince(quake.date))
                let km = origin.distance(from: CLLocation(latitude: event.eventLatitude, longitude: event.eventLongitude)) / 1_000
                let dm = abs(event.eventMagnitude - quake.magnitude)
                guard dt <= 90, km <= 100, dm <= 1.0 else { return nil }
                return (id, dt / 90 + km / 100 + dm, group)
            }
            .min { $0.score < $1.score }
        guard let best, let event = best.records.first else { return nil }
        let epicenter = (lat: event.eventLatitude, lon: event.eventLongitude)
        let stations = best.records
            .compactMap { record -> Station? in
                let horizontal = record.channels.filter { $0.isHorizontal }
                let channels = horizontal.isEmpty ? record.channels : horizontal
                guard let pga = channels.compactMap(\.pga).max(), pga > 0 else { return nil }
                return Station(
                    network: record.network,
                    code: record.station,
                    latitude: record.latitude,
                    longitude: record.longitude,
                    distanceKm: record.distanceKm,
                    pga: pga,
                    pgv: channels.compactMap(\.pgv).max() ?? 0,
                    bearing: bearing(fromLat: epicenter.lat, lon: epicenter.lon, toLat: record.latitude, lon: record.longitude)
                )
            }
            .sorted { $0.pga > $1.pga }
        return Result(eventID: best.id, stations: stations)
    }

    private static func bearing(fromLat lat1: Double, lon lon1: Double, toLat lat2: Double, lon lon2: Double) -> Double {
        let φ1 = lat1 * .pi / 180, φ2 = lat2 * .pi / 180
        let Δλ = (lon2 - lon1) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// 404 "veri yok" demektir (nil); diğer hatalar fırlatılır.
    private static func fetch<T: Decodable>(_ url: URL) async throws -> T? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 || http.statusCode == 204 { return nil }
        guard 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Yanıt biçimleri

    private struct PeakMotionDTO: Decodable {
        struct Channel: Decodable {
            let code: String
            let pga: Double?
            let pgv: Double?
            /// E/N/1/2 yatay, Z düşey.
            var isHorizontal: Bool { !code.hasSuffix("Z") }

            enum CodingKeys: String, CodingKey {
                case code = "channel-code", pga = "pga-value", pgv = "pgv-value"
            }
        }

        let eventID: String
        let eventTime: String
        let eventMagnitude: Double
        let eventLatitude: Double
        let eventLongitude: Double
        let network: String
        let station: String
        let latitude: Double
        let longitude: Double
        let distanceKm: Double
        let channels: [Channel]

        enum CodingKeys: String, CodingKey {
            case eventID = "event-id", eventTime = "event-time", eventMagnitude = "event-magnitude"
            case eventLatitude = "event-latitude", eventLongitude = "event-longitude"
            case network = "network-code", station = "station-code"
            case latitude = "station-latitude", longitude = "station-longitude"
            case distanceKm = "epicentral-distance", channels = "sensor-channels"
        }
    }

    private actor ResultCache {
        private var entries: [String: (value: Availability, expires: Date)] = [:]

        func value(for key: String) -> Availability? {
            guard let entry = entries[key], entry.expires > Date() else { return nil }
            return entry.value
        }

        func store(_ value: Availability, for key: String, ttl: TimeInterval) {
            if entries.count > 60 { entries.removeAll() }
            entries[key] = (value, Date().addingTimeInterval(ttl))
        }
    }
}
