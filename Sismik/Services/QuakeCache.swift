import Foundation

/// Eşzamanlı okuma/yazma (data race) risklerini engellemek için `actor` olarak tanımlanmıştır.
actor QuakeCache {
    static let shared = QuakeCache()
    private init() {}

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("sismik_quakes_cache.json")
    }

    private var mapFileURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("sismik_map_archive_cache.json")
    }

    private var memoryCache: [Earthquake] = []
    private var isLoaded = false
    private var mapMemoryCache: [Earthquake] = []
    private var isMapLoaded = false
    /// `save`'in her ~30 saniyelik pollde tüm diziyi alan alan derinlemesine
    /// karşılaştırmaması için ucuz bir özet — yalnızca değişebilecek alanları
    /// (kimlik, büyüklük, derinlik, güncellenme zamanı) hash'ler.
    private var lastSavedSignature: Int?

    private func signature(for quakes: [Earthquake]) -> Int {
        var hasher = Hasher()
        hasher.combine(quakes.count)
        for quake in quakes {
            hasher.combine(quake.id)
            hasher.combine(quake.magnitude)
            hasher.combine(quake.depth)
            hasher.combine(quake.updatedAt)
        }
        return hasher.finalize()
    }

    /// En güncel anlık görüntüyü kaydeder (en fazla 800 kayıt yeterli).
    /// Actor yazımları sıraya koyduğu için eski bir detached yazımın daha yeni
    /// veriyi sonradan ezmesi mümkün değildir. Çağıran ana aktör bu sırada askıda
    /// kalır; disk erişimi UI thread'ini bloke etmez.
    func save(_ quakes: [Earthquake]) {
        let prefixQuakes = Array(quakes.prefix(800))
        // Aynı kimlikteki büyüklük/derinlik revizyonları da diske yansısın.
        let signature = signature(for: prefixQuakes)
        guard !isLoaded || signature != lastSavedSignature else { return }
        self.memoryCache = prefixQuakes
        self.isLoaded = true
        self.lastSavedSignature = signature

        let dtos = prefixQuakes.map(CachedQuake.init)
        guard let data = try? JSONEncoder().encode(dtos) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Diskteki son anlık görüntüyü okur (yoksa boş). Bellek önbelleği varsa disk okuma yapmaz.
    func load() -> [Earthquake] {
        if isLoaded {
            return memoryCache
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            isLoaded = true
            return []
        }
        guard let dtos = try? JSONDecoder().decode([CachedQuake].self, from: data) else {
            // Yarım kalmış/eski şemalı dosyayı her açılışta tekrar decode etmeyelim.
            try? FileManager.default.removeItem(at: fileURL)
            isLoaded = true
            return []
        }
        let quakes = dtos.map(\.earthquake)
        self.memoryCache = quakes
        self.isLoaded = true
        self.lastSavedSignature = signature(for: quakes)
        return quakes
    }

    /// Haritanın yoğun 30 günlük arşivini ayrı dosyada saklar. Canlı
    /// liste önbelleğinin 800 kayıtlık sınırı harita verisine uygulanmaz;
    /// böylece sonraki harita açılışında ağ sonucu beklenmez.
    func saveMapArchive(_ quakes: [Earthquake]) {
        guard !quakes.isEmpty else { return }
        mapMemoryCache = quakes
        isMapLoaded = true

        let archive = CachedMapArchive(
            savedAt: Date(),
            quakes: quakes.map(CachedQuake.init)
        )
        guard let data = try? JSONEncoder().encode(archive) else { return }
        try? data.write(to: mapFileURL, options: .atomic)
    }

    /// Bayat veri de anında döndürülür; ViewModel bunu ekranda gösterirken
    /// sunucuyu arka planda tazeleyerek stale-while-revalidate uygular.
    func loadMapArchive() -> [Earthquake] {
        if isMapLoaded { return mapMemoryCache }
        defer { isMapLoaded = true }

        guard let data = try? Data(contentsOf: mapFileURL),
              let archive = try? JSONDecoder().decode(CachedMapArchive.self, from: data) else {
            try? FileManager.default.removeItem(at: mapFileURL)
            return []
        }
        mapMemoryCache = archive.quakes.map(\.earthquake)
        return mapMemoryCache
    }
}

private struct CachedMapArchive: Codable {
    let savedAt: Date
    let quakes: [CachedQuake]
}

/// Diske yazılabilir hafif deprem temsili.
private struct CachedQuake: Codable {
    let id, provider, title: String
    let mag, depth, lat, lon: Double
    let date: Date
    let closestCity, epiCenter: String?
    let magType, status, district, country: String?
    let tsunami, revised: Bool
    let feltReports: Int?
    let updatedAt: Date?
    let sourceURL, detailURL: URL?
    let network, eventCode, eventType, author, catalog, alertLevel: String?
    let significance, stationCount: Int?
    let minimumDistance, rms, gap, communityIntensity, maximumIntensity: Double?

    init(_ q: Earthquake) {
        id = q.id; provider = q.provider; title = q.title
        mag = q.magnitude; depth = q.depth
        lat = q.coordinate.latitude; lon = q.coordinate.longitude
        date = q.date
        closestCity = q.locationProperties.closestCity?.name
        epiCenter = q.locationProperties.epiCenter?.name
        magType = q.magType; status = q.status
        district = q.district; country = q.country
        tsunami = q.tsunami; revised = q.revised
        feltReports = q.feltReports; updatedAt = q.updatedAt
        sourceURL = q.sourceURL; detailURL = q.detailURL
        network = q.network; eventCode = q.eventCode; eventType = q.eventType
        author = q.author; catalog = q.catalog; alertLevel = q.alertLevel
        significance = q.significance; stationCount = q.stationCount
        minimumDistance = q.minimumDistance; rms = q.rms; gap = q.gap
        communityIntensity = q.communityIntensity; maximumIntensity = q.maximumIntensity
    }

    var earthquake: Earthquake {
        Earthquake(
            id: id, provider: provider, title: title,
            magnitude: mag, depth: depth,
            coordinate: Coordinate(longitude: lon, latitude: lat),
            date: date,
            locationProperties: LocationProperties(
                closestCity: closestCity.map { City(name: $0, cityCode: nil, distance: nil, population: nil) },
                epiCenter: epiCenter.map { City(name: $0, cityCode: nil, distance: nil, population: nil) }),
            magType: magType, status: status, tsunami: tsunami,
            feltReports: feltReports, district: district, country: country,
            revised: revised, updatedAt: updatedAt, sourceURL: sourceURL,
            detailURL: detailURL, network: network, eventCode: eventCode,
            eventType: eventType, significance: significance, stationCount: stationCount,
            minimumDistance: minimumDistance, rms: rms, gap: gap,
            communityIntensity: communityIntensity, maximumIntensity: maximumIntensity,
            alertLevel: alertLevel, author: author, catalog: catalog)
    }
}
