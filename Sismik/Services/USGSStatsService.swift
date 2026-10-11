import Foundation

/// Seçili zaman aralığı için USGS küresel verisinden hesaplanan istatistikler.
struct GlobalStats: Decodable, Sendable, Equatable {
    struct MagDist: Decodable, Sendable, Equatable {
        let micro, light, moderate, strong, major: Int
    }
    struct DepthDist: Decodable, Sendable, Equatable {
        let shallow, intermediate, deep: Int
    }
    struct TopQuake: Decodable, Sendable, Identifiable, Equatable {
        let id: String
        let provider: String?
        let magnitude: Double
        let place: String
        let time: Date?
        let lat: Double?
        let lon: Double?
        let depth: Double?

        init(id: String, provider: String? = nil, magnitude: Double, place: String, time: Date?, lat: Double?, lon: Double?, depth: Double?) {
            self.id = id
            self.provider = provider
            self.magnitude = magnitude
            self.place = place
            self.time = time
            self.lat = lat
            self.lon = lon
            self.depth = depth
        }
    }
    struct Region: Decodable, Sendable, Equatable {
        let name: String
        let count: Int
    }
    struct SourceCounts: Decodable, Sendable, Equatable {
        let afad, emsc, usgs: Int
        let noa: Int?
    }

    let updatedAt: Date?
    let rangeHours: Int
    let total7d: Int
    let last24h: Int
    let felt24h: Int
    let maxMagnitude: Double
    let strongestTitle: String
    let strongestTime: Date?
    let m45plus: Int
    let m60plus: Int
    let avgMagnitude: Double
    let avgDepth: Double
    /// Yeni istatistik alanları opsiyoneldir; önceki sürümün disk/CDN
    /// önbellekleri de sorunsuz açılmaya devam eder.
    let medianMagnitude: Double?
    let medianDepth: Double?
    let magnitudeStdDev: Double?
    let totalEnergyJoules: Double?
    let bucketStarts: [Date]
    let dailyCounts: [Int]
    let dailyMaxMag: [Double]
    let magDist: MagDist
    let depthDist: DepthDist
    let topQuakes: [TopQuake]
    let topCountries: [Region]
    let sourceCounts: SourceCounts
}

actor GlobalStatsService {
    static let shared = GlobalStatsService()

    private struct CacheEntry {
        let stats: GlobalStats
        let date: Date
    }

    private let backendStatsURL = URL(string: BackendConfig.baseURL + "/stats")!
    private let cacheInterval: TimeInterval = 120
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<GlobalStats?, Never>] = [:]

    /// Diskte saklanan son başarılı yanıt: istatistik sekmesi açılır açılmaz
    /// ağ beklenmeden gösterilir, taze veri arkada gelince yerine geçer.
    private nonisolated static func diskURL(for key: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("sismik_stats_\(key).json")
    }

    /// Bellek veya diskteki son istatistik (tazelik şartı yok — anında ilk
    /// boyama için; çağıran zaten arkasından ağ tazelemesi yapar).
    func lastKnownStats(range: EarthquakeListViewModel.TimeRange, region: String?) -> GlobalStats? {
        let key = "\(range.hours)-\(region ?? "GL")"
        if let entry = cache[key] { return entry.stats }
        guard let data = try? Data(contentsOf: Self.diskURL(for: key)) else { return nil }
        guard let decoded = try? Self.decoder().decode(GlobalStats.self, from: data) else { return nil }
        // Disk sonucu belleğe alınır fakat bayat kabul edilir; `stats` çağrısı
        // aynı decode'u tekrarlamadan arka planda yeniden doğrular.
        cache[key] = CacheEntry(stats: decoded, date: .distantPast)
        return decoded
    }

    func stats(
        range: EarthquakeListViewModel.TimeRange,
        region: String? = nil,
        forceRefresh: Bool = false
    ) async -> GlobalStats? {
        let hours = range.hours
        let key = "\(hours)-\(region ?? "GL")"
        if !forceRefresh, let cached = cache[key],
           Date().timeIntervalSince(cached.date) < cacheInterval {
            return cached.stats
        }
        if !forceRefresh, let task = inFlight[key] {
            return await task.value
        }

        let backendStatsURL = backendStatsURL
        let task = Task<GlobalStats?, Never> {
            do {
                return try await Self.fetchBackendStats(
                    from: backendStatsURL,
                    hours: hours,
                    region: region,
                    forceRefresh: forceRefresh
                )
            } catch {
                return try? await Self.fetchUSGSFallbackStats(hours: hours)
            }
        }
        inFlight[key] = task
        let result = await task.value
        if let result { cache[key] = CacheEntry(stats: result, date: Date()) }
        // Yalnızca KENDİ görevini kaydırır. Zorlamalı yenileme `inFlight`
        // kontrolünü atladığı için aynı anahtarda ikinci bir görev
        // başlayabiliyor; koşulsuz `nil` ataması o sırada hâlâ çalışan yeni
        // görevi haritadan siliyor ve arkadan gelen çağrılar onu bekleyip
        // sonucunu paylaşmak yerine üçüncü bir istek açıyordu.
        if inFlight[key] == task { inFlight[key] = nil }
        return result
    }

    private nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = ISO8601.fractionalFormatter.date(from: string) ?? ISO8601.formatter.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Geçersiz tarih: \(string)")
        }
        return decoder
    }

    private nonisolated static func fetchBackendStats(
        from baseURL: URL,
        hours: Int,
        region: String?,
        forceRefresh: Bool
    ) async throws -> GlobalStats {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "hours", value: "\(hours)")]
        if let region {
            items.append(URLQueryItem(name: "region", value: region))
        }
        if forceRefresh {
            items.append(URLQueryItem(name: "r", value: "\(Int(Date().timeIntervalSince1970))"))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.cachePolicy = forceRefresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        let stats = try decoder().decode(GlobalStats.self, from: data)
        // Başarıyla çözülen yanıtı diske yaz — bir sonraki açılış anında boyanır.
        try? data.write(to: diskURL(for: "\(hours)-\(region ?? "GL")"), options: .atomic)
        return stats
    }

    private struct USGSFeed: Decodable {
        struct Feature: Decodable {
            struct Properties: Decodable {
                let mag: Double?
                let place: String?
                let time: Double?
            }
            /// USGS eski kayıtlarda derinliği `null` yazabilir.
            struct Geometry: Decodable { let coordinates: [Double?]? }
            let id: String
            let properties: Properties
            let geometry: Geometry?
        }
        let features: [Feature]
    }

    private nonisolated static func fetchUSGSFallbackStats(hours: Int) async throws -> GlobalStats {
        let now = Date()
        let start = now.addingTimeInterval(-Double(hours) * 3_600)
        var components = URLComponents(string: "https://earthquake.usgs.gov/fdsnws/event/1/query")
        components?.queryItems = [
            URLQueryItem(name: "format", value: "geojson"),
            URLQueryItem(name: "orderby", value: "time"),
            URLQueryItem(name: "minmagnitude", value: "2"),
            URLQueryItem(name: "limit", value: "20000"),
            URLQueryItem(name: "starttime", value: ISO8601.formatter.string(from: start))
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadRevalidatingCacheData
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return aggregate(try JSONDecoder().decode(USGSFeed.self, from: data), hours: hours, now: now)
    }

    private nonisolated static func aggregate(_ feed: USGSFeed, hours: Int, now: Date) -> GlobalStats {
        let duration = Double(hours) * 3_600
        let bucketDuration: TimeInterval = hours <= 24 ? 3_600 : 86_400
        let bucketCount = max(1, Int(ceil(duration / bucketDuration)))
        let rangeStart = now.addingTimeInterval(-duration)
        let bucketStarts = (0..<bucketCount).map {
            rangeStart.addingTimeInterval(Double($0) * bucketDuration)
        }

        var total = 0, last24hCount = 0, felt = 0, m45 = 0, m60 = 0
        let last24hStart = now.addingTimeInterval(-86_400)
        var maxMagnitude = 0.0, strongestTitle = ""
        var strongestTime: Date?
        var magSum = 0.0, depthSum = 0.0
        var depthCount = 0
        var magnitudes: [Double] = []
        var depths: [Double] = []
        var totalEnergyJoules = 0.0
        var counts = Array(repeating: 0, count: bucketCount)
        var maxima = Array(repeating: 0.0, count: bucketCount)
        var mag = [0, 0, 0, 0, 0]
        var depth = [0, 0, 0]
        var top: [GlobalStats.TopQuake] = []

        for feature in feed.features {
            guard let magnitude = feature.properties.mag,
                  let milliseconds = feature.properties.time,
                  magnitude.isFinite else { continue }
            let time = Date(timeIntervalSince1970: milliseconds / 1_000)
            let offset = time.timeIntervalSince(rangeStart)
            guard offset >= 0, offset <= duration else { continue }

            total += 1
            if time >= last24hStart { last24hCount += 1 }
            magSum += magnitude
            magnitudes.append(magnitude)
            totalEnergyJoules += pow(10, 1.5 * magnitude + 4.8)
            if magnitude >= 3 { felt += 1 }
            if magnitude >= 4.5 { m45 += 1 }
            if magnitude >= 6 { m60 += 1 }
            if magnitude > maxMagnitude {
                maxMagnitude = magnitude
                strongestTitle = feature.properties.place ?? ""
                strongestTime = time
            }

            let bucket = min(bucketCount - 1, max(0, Int(offset / bucketDuration)))
            counts[bucket] += 1
            maxima[bucket] = max(maxima[bucket], magnitude)
            if magnitude < 3 { mag[0] += 1 }
            else if magnitude < 4 { mag[1] += 1 }
            else if magnitude < 5 { mag[2] += 1 }
            else if magnitude < 6 { mag[3] += 1 }
            else { mag[4] += 1 }

            let coordinates = feature.geometry?.coordinates ?? []
            let eventDepth = coordinates.count > 2 ? (coordinates[2] ?? .nan) : 0
            if eventDepth.isFinite {
                depthSum += eventDepth
                depthCount += 1
                depths.append(eventDepth)
                if eventDepth < 70 { depth[0] += 1 }
                else if eventDepth < 300 { depth[1] += 1 }
                else { depth[2] += 1 }
            }
            if magnitude >= 4.5 {
                top.append(.init(
                    id: "usgs-\(feature.id)",
                    provider: "USGS",
                    magnitude: magnitude,
                    place: feature.properties.place ?? "",
                    time: time,
                    lat: coordinates.count > 1 ? (coordinates[1] ?? 0) : 0,
                    lon: (coordinates.first ?? 0) ?? 0,
                    depth: eventDepth.isFinite ? eventDepth : 0
                ))
            }
        }
        top.sort { $0.magnitude == $1.magnitude ? ($0.time ?? .distantPast) > ($1.time ?? .distantPast) : $0.magnitude > $1.magnitude }

        let sortedMagnitudes = magnitudes.sorted()
        let sortedDepths = depths.sorted()
        let medianMagnitude = median(of: sortedMagnitudes)
        let medianDepth = median(of: sortedDepths)
        let meanMagnitude = total > 0 ? magSum / Double(total) : 0
        let variance = magnitudes.isEmpty
            ? 0
            : magnitudes.reduce(0) { $0 + pow($1 - meanMagnitude, 2) } / Double(magnitudes.count)

        return GlobalStats(
            updatedAt: now,
            rangeHours: hours,
            total7d: total,
            last24h: last24hCount,
            felt24h: felt,
            maxMagnitude: maxMagnitude,
            strongestTitle: strongestTitle,
            strongestTime: strongestTime,
            m45plus: m45,
            m60plus: m60,
            avgMagnitude: total > 0 ? (magSum / Double(total) * 10).rounded() / 10 : 0,
            avgDepth: depthCount > 0 ? (depthSum / Double(depthCount) * 10).rounded() / 10 : 0,
            medianMagnitude: medianMagnitude,
            medianDepth: medianDepth,
            magnitudeStdDev: sqrt(variance),
            totalEnergyJoules: totalEnergyJoules,
            bucketStarts: bucketStarts,
            dailyCounts: counts,
            dailyMaxMag: maxima,
            magDist: .init(micro: mag[0], light: mag[1], moderate: mag[2], strong: mag[3], major: mag[4]),
            depthDist: .init(shallow: depth[0], intermediate: depth[1], deep: depth[2]),
            topQuakes: Array(top.prefix(5)),
            topCountries: [],
            sourceCounts: .init(afad: 0, emsc: 0, usgs: total, noa: 0)
        )
    }

    private nonisolated static func median(of sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
