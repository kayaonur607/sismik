import Foundation

/// Depremleri uzak serverless proxy servisimiz (Firebase Cloud Functions v2) üzerinden çeker.
/// Tekilleştirme, birleştirme ve önbelleğe alma işlemlerinin tamamı sunucuda gerçekleştirilir.
actor EarthquakeService {
    static let shared = EarthquakeService()

    struct SourceStatus: Identifiable, Hashable {
        enum State: Hashable {
            case available
            case unavailable
        }

        var id: String { source }
        let source: String
        let count: Int
        let state: State
        let message: String?
    }

    private(set) var latestSourceStatuses: [SourceStatus] = []
    private var latestQuakes: [Earthquake] = []
    private var latestFetchDate: Date?
    /// Son TAM liste isteği. Aradaki otomatik yenilemeler yalnızca son saati
    /// (`/recent`, ~2-3 KB) çekip elindeki listeyle birleştirir; tam liste
    /// (~45 KB) açılışta, çekerek yenilemede ve bu aralıkla bir istenir —
    /// bir saatten eski kayıtların büyüklük düzeltmeleri de böyle gelir.
    private var lastFullFetchDate: Date?
    /// Tam liste en sık bu aralıkta çekilir (uzak yapılandırma: `refresh.full_interval_seconds`).
    private var fullRefreshInterval: TimeInterval {
        RemoteConfig.number(\.refresh, "full_interval_seconds", default: 600, in: 120...3600)
    }
    /// Liste penceresi (sunucu ile aynı): son 24 saat.
    private static let listWindow: TimeInterval = 86_400
    /// Bu süreden yeni kayıtlar YALNIZCA `/recent` yanıtından alınır (sunucu
    /// penceresi 65 dk): kaynağı değişen ya da tekilleştirmede düşen bir kayıt
    /// listede takılı kalmaz.
    private static let recentAuthorityWindow: TimeInterval = 60 * 60
    private var inFlightSnapshot: Task<(quakes: [Earthquake], statuses: [SourceStatus]), Never>?
    /// Aktif ekranda 30 sn'lik yenileme döngüsünü eski bellek görüntüsüyle
    /// karşılamamak için istemci önbelleği döngüden kısa tutulur.
    private let memoryCacheInterval: TimeInterval = 20
    private let mapCacheInterval: TimeInterval = 300

    private struct MapDataCacheKey: Hashable {
        let days: Int
        let minimumMagnitudeThousandths: Int
    }

    private struct MapRangeCacheKey: Hashable {
        let startMinute: Int
        let endMinute: Int
        let latitudeThousandths: Int
        let longitudeThousandths: Int
        let radiusTenths: Int
        let minimumMagnitudeTenths: Int
        let source: String?
    }

    private struct TimedQuakeCache {
        let earthquakes: [Earthquake]
        let fetchedAt: Date
    }

    private var mapDataCache: [MapDataCacheKey: TimedQuakeCache] = [:]
    private var inFlightMapData: [MapDataCacheKey: Task<[Earthquake], Never>] = [:]
    private var mapRangeCache: [MapRangeCacheKey: TimedQuakeCache] = [:]
    private var inFlightMapRange: [MapRangeCacheKey: Task<[Earthquake]?, Never>] = [:]

    /// Geçici ağ hatalarına karşı tek yeniden denemeli istek.
    /// Hücresel ağda anlık kopmalar sık görülür; tek retry, kullanıcının
    /// "çevrimdışı" uyarısı görme olasılığını belirgin azaltır.
    private nonisolated static func dataWithRetry(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            // İptal edilen görevi yeniden deneme.
            if (error as? URLError)?.code == .cancelled { throw error }
            try await Task.sleep(for: .milliseconds(700))
            return try await URLSession.shared.data(for: request)
        }
    }

    func liveSnapshot(minMagnitude: Double = 0, forceRefresh: Bool = false) async -> (quakes: [Earthquake], statuses: [SourceStatus]) {
        if !forceRefresh,
           let latestFetchDate,
           Date().timeIntervalSince(latestFetchDate) < memoryCacheInterval,
           !latestQuakes.isEmpty {
            return (latestQuakes, latestSourceStatuses)
        }

        // Zorunlu yenileme önbelleği atlar, ancak başlamış gerçek bir ağ
        // isteğini çoğaltmaz. Pull-to-refresh ile otomatik yenileme aynı ana
        // denk geldiğinde tek yanıtı paylaşırlar.
        if let inFlightSnapshot {
            return await inFlightSnapshot.value
        }

        let usesRecent = !forceRefresh
            && !latestQuakes.isEmpty
            && lastFullFetchDate.map { Date().timeIntervalSince($0) < fullRefreshInterval } == true
        let base = latestQuakes
        let task = Task { () -> (quakes: [Earthquake], statuses: [SourceStatus]) in
            if usesRecent, let merged = await fetchRecentMerged(into: base) {
                return merged
            }
            let full = await fetchLiveSnapshot()
            if !full.quakes.isEmpty { markFullFetch() }
            return full
        }
        inFlightSnapshot = task
        let snapshot = await task.value
        inFlightSnapshot = nil

        if !snapshot.quakes.isEmpty {
            latestQuakes = snapshot.quakes
            latestFetchDate = Date()
        }
        latestSourceStatuses = snapshot.statuses
        return snapshot
    }

    private func markFullFetch() { lastFullFetchDate = Date() }

    /// Son saati çekip `base` ile birleştirir. `/recent` yoksa (sunucu henüz
    /// güncellenmedi) ya da istek başarısızsa `nil` döner; çağıran tam listeye
    /// düşer.
    private func fetchRecentMerged(into base: [Earthquake]) async -> (quakes: [Earthquake], statuses: [SourceStatus])? {
        // `sources=all`: 2.1.4+ tüm kaynakları ister; eski sürümlere sunucu eski
        // dört kaynaklı listeyi döndürür (bkz. earthquake-routes `listVariantOf`).
        guard let url = URL(string: BackendConfig.baseURL + "/recent?sources=all") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.cachePolicy = .useProtocolCachePolicy
        do {
            let (data, response) = try await Self.dataWithRetry(for: req)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return nil }
            let latestVersion = http.value(forHTTPHeaderField: AppUpdateNotice.responseHeader)
            let infoRevision = http.value(forHTTPHeaderField: InfoCardCenter.responseHeader)
            let majorEventID = http.value(forHTTPHeaderField: MajorEventCenter.responseHeader)
            let configRevision = http.value(forHTTPHeaderField: RemoteConfigCenter.responseHeader)
            await MainActor.run {
                AppUpdateNotice.shared.record(latestVersion: latestVersion)
                InfoCardCenter.shared.record(revision: infoRevision)
                MajorEventCenter.shared.record(id: majorEventID)
                RemoteConfigCenter.shared.record(revision: configRevision)
            }
            let recent = try Self.sharedDecoder.decode([Earthquake].self, from: data)
            let merged = Self.merge(recent: recent, into: base, now: Date())
            AppLog.network.info("recent count=\(recent.count, privacy: .public) merged=\(merged.count, privacy: .public)")
            if merged != base {
                await QuakeCache.shared.save(merged)
            }
            return (merged, Self.statuses(for: merged))
        } catch {
            AppLog.network.error("recent failed error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Son saat `recent`'ten, daha eskisi `base`'ten; 24 saati geçenler düşer.
    static func merge(recent: [Earthquake], into base: [Earthquake], now: Date) -> [Earthquake] {
        let authorityCutoff = now.addingTimeInterval(-recentAuthorityWindow)
        let listCutoff = now.addingTimeInterval(-listWindow)
        let recentIDs = Set(recent.map(\.id))
        let older = base.filter { $0.date < authorityCutoff && $0.date >= listCutoff && !recentIDs.contains($0.id) }
        return (recent + older).sorted { $0.date > $1.date }
    }

    private static func statuses(for quakes: [Earthquake]) -> [SourceStatus] {
        var counts: [String: Int] = [:]
        for quake in quakes { counts[quake.sourceTag, default: 0] += 1 }
        return EarthquakeListViewModel.allSources.map {
            SourceStatus(source: $0, count: counts[$0] ?? 0, state: .available, message: nil)
        }
    }

    private func fetchLiveSnapshot() async -> (quakes: [Earthquake], statuses: [SourceStatus]) {
        guard let url = URL(string: BackendConfig.baseURL + "?sources=all") else {
            return ([], latestSourceStatuses)
        }
        let startedAt = Date()
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.cachePolicy = .useProtocolCachePolicy
        
        do {
            let (data, response) = try await Self.dataWithRetry(for: req)
            guard let http = response as? HTTPURLResponse else {
                AppLog.network.error("live invalid response")
                let statuses = [
                    SourceStatus(source: "Sismik Server", count: 0, state: .unavailable, message: "Geçersiz yanıt")
                ]
                return ([], statuses)
            }
            // Yayındaki App Store sürümü bu yanıtın başlığında gelir; ana
            // sayfa güncelleme banner'ı ayrı bir istek atmadan buradan açılır.
            let latestVersion = http.value(forHTTPHeaderField: AppUpdateNotice.responseHeader)
            let infoRevision = http.value(forHTTPHeaderField: InfoCardCenter.responseHeader)
            let majorEventID = http.value(forHTTPHeaderField: MajorEventCenter.responseHeader)
            let configRevision = http.value(forHTTPHeaderField: RemoteConfigCenter.responseHeader)
            await MainActor.run {
                AppUpdateNotice.shared.record(latestVersion: latestVersion)
                InfoCardCenter.shared.record(revision: infoRevision)
                MajorEventCenter.shared.record(id: majorEventID)
                RemoteConfigCenter.shared.record(revision: configRevision)
            }
            guard 200..<300 ~= http.statusCode else {
                AppLog.network.error("live http=\(http.statusCode, privacy: .public)")
                let statuses = [
                    SourceStatus(source: "Sismik Server", count: 0, state: .unavailable, message: "HTTP \(http.statusCode)")
                ]
                return ([], statuses)
            }
            
            let decoded = try Self.sharedDecoder.decode([Earthquake].self, from: data)
            AppLog.network.info("live status=\(http.statusCode, privacy: .public) count=\(decoded.count, privacy: .public) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000), privacy: .public)")

            let statuses = Self.statuses(for: decoded)
            
            if !decoded.isEmpty {
                await QuakeCache.shared.save(decoded)
            }
            
            return (decoded, statuses)
        } catch {
            AppLog.network.error("live failed error=\(error.localizedDescription, privacy: .public)")
            let statuses = [
                SourceStatus(source: "Sismik Server", count: 0, state: .unavailable, message: error.localizedDescription)
            ]
            return ([], statuses)
        }
    }

    private static let sharedDecoder = JSONDecoder()

    /// Verilen tarihten ÖNCEKİ depremleri sayfalı çeker (sonsuz kaydırma).
    /// `source` verilirse o kaynağın kendi arşivi sorgulanır
    /// (Türkiye → resmî AFAD arşivi, EMSC/USGS/NOA → FDSN).
    func fetchHistory(before: Date, limit: Int = 100, source: String? = nil) async -> [Earthquake] {
        var comps = URLComponents(string: BackendConfig.baseURL + "/history")
        var items = [
            URLQueryItem(name: "before", value: ISO8601.formatter.string(from: before)),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        if let source { items.append(URLQueryItem(name: "source", value: source.lowercased())) }
        comps?.queryItems = items
        guard let url = comps?.url else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.cachePolicy = .useProtocolCachePolicy

        do {
            let (data, response) = try await Self.dataWithRetry(for: req)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                AppLog.network.error("history http failure")
                return []
            }
            let decoded = (try? Self.sharedDecoder.decode([Earthquake].self, from: data)) ?? []
            AppLog.network.info("history count=\(decoded.count, privacy: .public)")
            return decoded
        } catch {
            AppLog.network.error("history failed error=\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Harita için yoğun veri seti: son `days` günün tüm kaynaklardan birleşik
    /// görünümü. Liste sayfalamasından tamamen bağımsızdır.
    func fetchMapData(
        days: Int = 7,
        minMagnitude: Double = 0,
        forceRefresh: Bool = false
    ) async -> [Earthquake] {
        let key = MapDataCacheKey(
            days: days,
            minimumMagnitudeThousandths: Int((minMagnitude * 1_000).rounded())
        )
        if !forceRefresh,
           let cached = mapDataCache[key],
           Date().timeIntervalSince(cached.fetchedAt) < mapCacheInterval {
            return cached.earthquakes
        }
        if let task = inFlightMapData[key] {
            return await task.value
        }

        let task = Task<[Earthquake], Never> { [weak self] in
            guard let self else { return [Earthquake]() }
            return await self.requestMapData(days: days, minMagnitude: minMagnitude)
        }
        inFlightMapData[key] = task
        let earthquakes = await task.value
        inFlightMapData[key] = nil
        if !earthquakes.isEmpty {
            mapDataCache[key] = TimedQuakeCache(earthquakes: earthquakes, fetchedAt: Date())
        }
        return earthquakes
    }

    /// Harita arşivinin (30 gün, tüm büyüklükler) son ETag'i. Arşiv ~1,25 MB
    /// sıkıştırılmış / ~10 MB açık geliyor; URLCache'in tek yanıt sınırını
    /// aştığı için sistem önbelleği onu hiç saklamıyor ve her harita açılışı
    /// arşivi baştan indiriyordu. ETag ile değişmemiş arşiv 0 baytlık 304 döner;
    /// gövde bellekteki ya da diskteki son arşivden gelir.
    private static let mapArchiveETagKey = "mapArchive.etag.v1"

    private func requestMapData(days: Int, minMagnitude: Double) async -> [Earthquake] {
        var comps = URLComponents(string: BackendConfig.baseURL + "/map")
        comps?.queryItems = [
            URLQueryItem(name: "days", value: "\(days)"),
            URLQueryItem(name: "minmag", value: "\(minMagnitude)")
        ]
        guard let url = comps?.url else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.cachePolicy = .useProtocolCachePolicy

        // Koşullu istek yalnızca diske kaydedilen arşiv için (30 gün, tüm
        // büyüklükler): 304 gelirse gösterilecek gövde elimizde olmalı.
        let isArchive = days == 30 && minMagnitude <= 0
        var storedArchive: [Earthquake] = []
        if isArchive, let etag = UserDefaults.standard.string(forKey: Self.mapArchiveETagKey) {
            let key = MapDataCacheKey(days: days, minimumMagnitudeThousandths: 0)
            storedArchive = mapDataCache[key]?.earthquakes ?? []
            if storedArchive.isEmpty { storedArchive = await QuakeCache.shared.loadMapArchive() }
            if !storedArchive.isEmpty {
                req.setValue(etag, forHTTPHeaderField: "If-None-Match")
                req.cachePolicy = .reloadIgnoringLocalCacheData
            }
        }

        do {
            let (data, response) = try await Self.dataWithRetry(for: req)
            guard let http = response as? HTTPURLResponse else { return [] }
            if http.statusCode == 304, !storedArchive.isEmpty {
                AppLog.network.info("map not modified count=\(storedArchive.count, privacy: .public)")
                return storedArchive
            }
            guard 200..<300 ~= http.statusCode else {
                AppLog.network.error("map http failure")
                return []
            }
            let decoded = (try? Self.sharedDecoder.decode([Earthquake].self, from: data)) ?? []
            if isArchive, !decoded.isEmpty {
                UserDefaults.standard.set(http.value(forHTTPHeaderField: "ETag"), forKey: Self.mapArchiveETagKey)
            }
            AppLog.network.info("map days=\(days, privacy: .public) count=\(decoded.count, privacy: .public)")
            return decoded
        } catch {
            AppLog.network.error("map failed error=\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Bölge oynatımı için yalnızca seçilen tarih ve coğrafi çemberi ister.
    /// Eski aralıklar sunucuda tarih destekli sağlayıcı kataloglarından sorgulanır;
    /// istemcinin tüm tarihsel kataloğu indirmesi gerekmez.
    func fetchMapRange(
        start: Date,
        end: Date,
        latitude: Double,
        longitude: Double,
        radiusKm: Double,
        minMagnitude: Double = 0,
        source: String? = nil
    ) async -> [Earthquake] {
        let key = MapRangeCacheKey(
            startMinute: Int(start.timeIntervalSince1970 / 60),
            endMinute: Int(end.timeIntervalSince1970 / 60),
            latitudeThousandths: Int((latitude * 1_000).rounded()),
            longitudeThousandths: Int((longitude * 1_000).rounded()),
            radiusTenths: Int((radiusKm * 10).rounded()),
            minimumMagnitudeTenths: Int((minMagnitude * 10).rounded()),
            source: source
        )
        if let cached = mapRangeCache[key],
           Date().timeIntervalSince(cached.fetchedAt) < mapCacheInterval {
            return cached.earthquakes
        }
        if let task = inFlightMapRange[key] {
            return await task.value ?? []
        }

        let task = Task<[Earthquake]?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.requestMapRange(
                start: start,
                end: end,
                latitude: latitude,
                longitude: longitude,
                radiusKm: radiusKm,
                minMagnitude: minMagnitude,
                source: source
            )
        }
        inFlightMapRange[key] = task
        let decoded = await task.value
        inFlightMapRange[key] = nil
        guard let decoded else { return [] }

        if mapRangeCache.count >= 24,
           let oldestKey = mapRangeCache.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
            mapRangeCache.removeValue(forKey: oldestKey)
        }
        mapRangeCache[key] = TimedQuakeCache(earthquakes: decoded, fetchedAt: Date())
        return decoded
    }

    private func requestMapRange(
        start: Date,
        end: Date,
        latitude: Double,
        longitude: Double,
        radiusKm: Double,
        minMagnitude: Double,
        source: String? = nil
    ) async -> [Earthquake]? {
        var components = URLComponents(string: BackendConfig.baseURL + "/map-range")
        var items = [
            URLQueryItem(name: "start", value: ISO8601.formatter.string(from: start)),
            URLQueryItem(name: "end", value: ISO8601.formatter.string(from: end)),
            URLQueryItem(name: "lat", value: "\(latitude)"),
            URLQueryItem(name: "lon", value: "\(longitude)"),
            URLQueryItem(name: "radius", value: "\(radiusKm)"),
            URLQueryItem(name: "minmag", value: "\(minMagnitude)")
        ]
        if let source { items.append(URLQueryItem(name: "source", value: source)) }
        components?.queryItems = items
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .useProtocolCachePolicy

        do {
            let (data, response) = try await Self.dataWithRetry(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                AppLog.network.error("map range http failure")
                return nil
            }
            let decoded = try Self.sharedDecoder.decode([Earthquake].self, from: data)
            AppLog.network.info("map range count=\(decoded.count, privacy: .public)")
            return decoded
        } catch {
            AppLog.network.error("map range failed error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Ana şokun zaman ve konum penceresine özel katalog. Genel dünya haritası
    /// sonuç limitine ulaşsa bile büyük depremlerin artçı dizisi eksik kalmaz.
    func fetchAftershockCandidates(
        for mainshock: Earthquake,
        radiusKm: Double,
        windowDays: Int = 30
    ) async -> [Earthquake] {
        let now = Date()
        let end = min(now, mainshock.date.addingTimeInterval(Double(windowDays) * 86_400))
        let effectiveEnd = max(end, mainshock.date.addingTimeInterval(60))

        var components = URLComponents(string: BackendConfig.baseURL + "/aftershocks")
        components?.queryItems = [
            URLQueryItem(name: "lat", value: "\(mainshock.coordinate.latitude)"),
            URLQueryItem(name: "lon", value: "\(mainshock.coordinate.longitude)"),
            URLQueryItem(name: "radius", value: "\(radiusKm)"),
            URLQueryItem(name: "minmag", value: "0"),
            URLQueryItem(name: "start", value: ISO8601.formatter.string(from: mainshock.date)),
            URLQueryItem(name: "end", value: ISO8601.formatter.string(from: effectiveEnd))
        ]
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.cachePolicy = .useProtocolCachePolicy

        do {
            let (data, response) = try await Self.dataWithRetry(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                AppLog.network.error("aftershock catalog http failure")
                return []
            }
            let decoded = (try? Self.sharedDecoder.decode([Earthquake].self, from: data)) ?? []
            AppLog.network.info("aftershock candidates count=\(decoded.count, privacy: .public)")
            return decoded
        } catch {
            AppLog.network.error("aftershock catalog failed error=\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Arka plan/bildirim için — hafif anlık görüntü.
    func fetchRecent(limit: Int = 100, forceRefresh: Bool = false) async throws -> [Earthquake] {
        let userMinMag = UserDefaults.standard.double(forKey: "notif.minMagnitude")
        let minMag = userMinMag > 0 ? userMinMag : 4.0
        return Array((await liveSnapshot(minMagnitude: minMag, forceRefresh: forceRefresh)).quakes.prefix(max(0, limit)))
    }
}
