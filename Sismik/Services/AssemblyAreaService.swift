import Foundation
import MapKit

struct AssemblyAreaSearchResult {
    let areas: [AssemblyArea]
    let sourceLabel: String
    let usesOfflineCache: Bool
}

/// Toplanma alanları ile temel sağlık noktalarını Google Places, Apple
/// Haritalar ve OpenStreetMap kaynaklarından getirir; son başarılı sonuçları
/// çevrimdışı kullanım için cihazda saklar.
@MainActor
final class AssemblyAreaService {
    static let shared = AssemblyAreaService()

    /// Verinin kaynağı (arayüzde göstermek için).
    private(set) var lastSourceLabel: String = ""

    private struct OpenStreetMapCacheEntry {
        let date: Date
        let areas: [AssemblyArea]
    }

    private struct SearchCacheEntry {
        let date: Date
        let center: CLLocationCoordinate2D
        let radius: CLLocationDistance
        let categories: Set<EmergencyPlaceCategory>
        let areas: [AssemblyArea]
        let sourceLabel: String
        let usesOfflineCache: Bool
    }

    private let minimumDesiredResultCount = 5
    private let openStreetMapCacheTTL: TimeInterval = 10 * 60
    private let searchCacheTTL: TimeInterval = 5 * 60
    private var openStreetMapCache: [String: OpenStreetMapCacheEntry] = [:]
    private var searchCache: [String: SearchCacheEntry] = [:]
    private let diskCache = SafetyPlaceDiskCache()
    private let connectivity = NetworkMonitor.shared

    /// Son başarılı sonuçları ağ durumundan bağımsız olarak ilk boyamada sunar.
    /// Çağıran hemen ardından `search` ile doğrulama yaparak SWR akışını tamamlar.
    func cachedSearch(
        near center: CLLocationCoordinate2D,
        radius: CLLocationDistance = 2_000,
        categories: Set<EmergencyPlaceCategory>
    ) async -> AssemblyAreaSearchResult? {
        guard !categories.isEmpty else { return nil }
        let tiers = [radius, 5_000, 12_000, 30_000].filter { $0 >= radius }
        let cached = await diskCache.load(
            near: center,
            radius: tiers.last ?? radius,
            categories: categories
        )
        guard !cached.isEmpty else { return nil }

        let scoped = scopedToSmallestUsefulRadius(
            cached,
            center: center,
            tiers: tiers,
            minimumCount: max(minimumDesiredResultCount, categories.count * 3)
        )
        return AssemblyAreaSearchResult(
            areas: sortedByDistance(scoped, center: center),
            sourceLabel: L("assembly.source.offline"),
            usesOfflineCache: true
        )
    }

    /// İstenen yarıçaptan başlar; yeterli sonuç çıkmazsa kademeli genişletir.
    func search(near center: CLLocationCoordinate2D,
                radius: CLLocationDistance = 2000,
                categories: Set<EmergencyPlaceCategory> = [.assemblyArea]) async throws -> AssemblyAreaSearchResult {
        guard !categories.isEmpty else {
            return AssemblyAreaSearchResult(areas: [], sourceLabel: "", usesOfflineCache: false)
        }

        let cacheKey = searchCacheKey(center: center, radius: radius, categories: categories)
        if let cached = searchCache[cacheKey],
           Date().timeIntervalSince(cached.date) < searchCacheTTL {
            lastSourceLabel = cached.sourceLabel
            return AssemblyAreaSearchResult(
                areas: sortedByDistance(cached.areas, center: center),
                sourceLabel: cached.sourceLabel,
                usesOfflineCache: cached.usesOfflineCache
            )
        }

        // Aynı konumda daha kapsamlı bir arama daha önce yapıldıysa filtre
        // değişiklikleri için tekrar ağa çıkmadan o sonucu süz.
        if let cached = reusableCacheEntry(
            center: center,
            radius: radius,
            categories: categories
        ) {
            let filtered = cached.areas.filter { categories.contains($0.category) }
            lastSourceLabel = cached.sourceLabel
            return AssemblyAreaSearchResult(
                areas: sortedByDistance(filtered, center: center),
                sourceLabel: cached.sourceLabel,
                usesOfflineCache: cached.usesOfflineCache
            )
        }

        let apiKey = Secrets.googlePlacesKey
        // 2 km'lik ilk sorgu çoğu sağlayıcıda az sonuç üretip ikinci bir ağ
        // turunu zorunlu kılıyordu. 5 km'den başlamak, sonuçlar yine mesafeye
        // göre daraltıldığı için doğruluğu bozmadan çoğu aramayı tek tura indirir.
        let initialRadius = max(radius, 5_000)
        let tiers = [initialRadius, 12_000, 30_000]
        let scopeTiers = [radius, 5_000, 12_000, 30_000].filter { $0 >= radius }
        let maximumRadius = tiers.last ?? radius
        let locale = searchLocale(for: center, categories: categories)
        let desiredResultCount = max(minimumDesiredResultCount, categories.count * 3)
        let offlineAreas = await diskCache.load(
            near: center,
            radius: maximumRadius,
            categories: categories
        )
        if connectivity.isOffline, !offlineAreas.isEmpty {
            let offlineLabel = L("assembly.source.offline")
            let sorted = sortedByDistance(offlineAreas, center: center)
            lastSourceLabel = offlineLabel
            searchCache[cacheKey] = SearchCacheEntry(
                date: Date(),
                center: center,
                radius: radius,
                categories: categories,
                areas: sorted,
                sourceLabel: offlineLabel,
                usesOfflineCache: true
            )
            return AssemblyAreaSearchResult(
                areas: sorted,
                sourceLabel: offlineLabel,
                usesOfflineCache: true
            )
        }

        // Sunucudaki ortak önbellek (OpenStreetMap, 0,1°'lik hücreler):
        // aynı mahalleyi daha önce biri istediyse CDN'den ~100 ms'de gelir.
        // Yeterliyse Google/Apple sorgularına hiç çıkılmaz — hem hızlı hem
        // Google kotasını yemez. Yetmezse aşağıdaki akış onu tamamlar.
        let sharedAreas = (try? await fetchSharedSafetyPlaces(near: center, categories: categories)) ?? []
        let sharedScoped = scopedToSmallestUsefulRadius(
            sharedAreas, center: center, tiers: scopeTiers, minimumCount: desiredResultCount
        )
        if sharedScoped.count >= desiredResultCount,
           Set(sharedScoped.map(\.category)).isSuperset(of: categories) {
            let label = "OpenStreetMap"
            lastSourceLabel = label
            let sorted = sortedByDistance(sharedScoped, center: center)
            searchCache[cacheKey] = SearchCacheEntry(
                date: Date(), center: center, radius: radius, categories: categories,
                areas: sorted, sourceLabel: label, usesOfflineCache: false
            )
            await diskCache.save(sharedAreas)
            return AssemblyAreaSearchResult(areas: sorted, sourceLabel: label, usesOfflineCache: false)
        }

        // OSM sorgusunu ana sağlayıcıyla paralel başlat. Yeterli Google/Apple
        // sonucu varsa OSM hiçbir zaman kullanıcıyı bekletmez; az/boş sonuçta
        // yalnızca sınırlı bir ek süre tanınır.
        let openStreetMapTask = Task { [self] in
            // Sunucu önbelleği yanıt verdiyse Overpass'a doğrudan gidilmez.
            if !sharedAreas.isEmpty { return sharedAreas }
            return (try? await fetchOpenStreetMap(
                near: center,
                radius: maximumRadius,
                categories: categories
            )) ?? []
        }

        var result: [AssemblyArea] = []
        var sourceLabels: [String] = []

        if !apiKey.isEmpty {
            // Google Places'ı dene
            do {
                for tier in tiers {
                    let googleResult = try await fetchGooglePlaces(
                        near: center,
                        radius: tier,
                        queries: locale.googleQueries,
                        language: locale.language
                    )
                    if !googleResult.isEmpty {
                        result = deduplicate(result + googleResult)
                        if result.count >= desiredResultCount,
                           Set(result.map(\.category)).isSuperset(of: categories) {
                            break
                        }
                    }
                }
                if !result.isEmpty { sourceLabels.append("Google Places") }
            } catch {
                // Hata durumunda Apple Haritalar'a düş.
                result = []
            }
        }

        // Eğer Google Places kullanılmadıysa veya sonuç dönmediyse Apple Haritalar'a düş (fallback)
        // Tier'lar arasında biriktirilir (önceki dar yarıçapın sonuçları atılmaz).
        if result.isEmpty {
            for tier in tiers {
                let tierResult = try await fetchAppleMaps(
                    near: center,
                    radius: tier,
                    queries: locale.appleQueries
                )
                result = deduplicate(result + tierResult)
                if result.count >= desiredResultCount,
                   Set(result.map(\.category)).isSuperset(of: categories) {
                    break
                }
            }
            if !result.isEmpty { sourceLabels.append("Apple Maps") }
        }

        let osmWait: Duration
        if result.count >= desiredResultCount,
           Set(result.map(\.category)).isSuperset(of: categories) {
            osmWait = .zero
        } else if result.isEmpty {
            osmWait = .seconds(6)
        } else {
            osmWait = .seconds(2)
        }
        let openStreetMapAreas = await value(of: openStreetMapTask, timeout: osmWait) ?? []
        if !openStreetMapAreas.isEmpty { sourceLabels.append("OpenStreetMap") }

        let liveAreas = deduplicate(result + openStreetMapAreas)
        let liveCategories = Set(liveAreas.map(\.category))
        let missingCategories = categories.subtracting(liveCategories)
        let offlineSupplement = offlineAreas.filter { missingCategories.contains($0.category) }
        let usesOfflineCache = liveAreas.isEmpty ? !offlineAreas.isEmpty : !offlineSupplement.isEmpty
        if usesOfflineCache { sourceLabels.append(L("assembly.source.offline")) }

        let combined = liveAreas.isEmpty
            ? offlineAreas
            : deduplicate(liveAreas + offlineSupplement)
        let scoped = scopedToSmallestUsefulRadius(
            combined,
            center: center,
            tiers: scopeTiers,
            minimumCount: desiredResultCount
        )
        lastSourceLabel = sourceLabels.joined(separator: " · ")
        let sorted = sortedByDistance(scoped, center: center)
        searchCache[cacheKey] = SearchCacheEntry(
            date: Date(),
            center: center,
            radius: radius,
            categories: categories,
            areas: sorted,
            sourceLabel: lastSourceLabel,
            usesOfflineCache: usesOfflineCache
        )
        if !liveAreas.isEmpty {
            await diskCache.save(liveAreas)
        }
        return AssemblyAreaSearchResult(
            areas: sorted,
            sourceLabel: lastSourceLabel,
            usesOfflineCache: usesOfflineCache
        )
    }

    // MARK: - Google Places API

    private func fetchGooglePlaces(near center: CLLocationCoordinate2D,
                                   radius: Double,
                                   queries: [PlaceQuery],
                                   language: String) async throws -> [AssemblyArea] {
        await withTaskGroup(of: [AssemblyArea].self) { group in
            for query in queries {
                group.addTask { [self] in
                    (try? await fetchGooglePlaces(
                        near: center,
                        radius: radius,
                        query: query,
                        language: language
                    )) ?? []
                }
            }

            var areas: [AssemblyArea] = []
            for await result in group { areas.append(contentsOf: result) }
            return deduplicate(areas)
        }
    }

    private func fetchGooglePlaces(near center: CLLocationCoordinate2D,
                                   radius: Double,
                                   query: PlaceQuery,
                                   language: String) async throws -> [AssemblyArea] {
        let apiKey = Secrets.googlePlacesKey
        guard !apiKey.isEmpty else { return [] }

        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/place/nearbysearch/json")
        components?.queryItems = [
            URLQueryItem(name: "location", value: "\(center.latitude),\(center.longitude)"),
            URLQueryItem(name: "radius", value: "\(Int(radius))"),
            URLQueryItem(name: "keyword", value: query.text),
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "language", value: language)
        ]

        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(GooglePlacesResponse.self, from: data)
        guard decoded.status == "OK" || decoded.status == "ZERO_RESULTS" else {
            throw NSError(domain: "GooglePlaces", code: -1, userInfo: [NSLocalizedDescriptionKey: "Google Places API error: \(decoded.status)"])
        }

        return decoded.results.map { item in
            AssemblyArea(
                id: "google-\(item.place_id)",
                name: item.name,
                address: item.vicinity,
                coordinate: CLLocationCoordinate2D(latitude: item.geometry.location.lat, longitude: item.geometry.location.lng),
                category: query.category,
                distance: nil
            )
        }
    }

    // MARK: - Apple Haritalar (MKLocalSearch)

    private func fetchAppleMaps(near center: CLLocationCoordinate2D,
                                radius: CLLocationDistance,
                                queries: [PlaceQuery]) async throws -> [AssemblyArea] {
        let region = MKCoordinateRegion(center: center,
                                        latitudinalMeters: radius * 2,
                                        longitudinalMeters: radius * 2)
        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)

        // Üç sorgu birbirinden bağımsız: sıraya sokup her birini ayrı ayrı
        // beklemek yerine paralel çalıştırmak, tier başına gecikmeyi ~3'te
        // bire indirir (harita ekranındaki "kasma" hissinin ana kaynağıydı).
        return await withTaskGroup(of: [AssemblyArea].self) { group in
            for query in queries {
                group.addTask {
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = query.text
                    request.region = region
                    request.resultTypes = [.pointOfInterest]
                    guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
                    return response.mapItems.compactMap { item in
                        let coord: CLLocationCoordinate2D
                        let address: String?
                        if #available(iOS 26.0, *) {
                            coord = item.location.coordinate
                            address = item.address?.fullAddress ?? item.name
                        } else {
                            // iOS 18–25 MapKit uyumluluğu. `location` ve
                            // `address` alanları yalnızca iOS 26'da var.
                            coord = item.placemark.coordinate
                            address = item.placemark.title ?? item.name
                        }

                        // MKLocalSearch için region yalnızca bir ipucudur; uzak
                        // ülkelerdeki benzer adlı sonuçların haritaya karışmasını
                        // kesin mesafe kontrolüyle engelle.
                        let itemLocation = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                        guard centerLocation.distance(from: itemLocation) <= radius * 1.15 else {
                            return nil
                        }

                        return AssemblyArea(
                            id: "apple-\(coord.latitude.rounded(toPlaces: 5)),\(coord.longitude.rounded(toPlaces: 5))",
                            name: item.name ?? L("assembly.area.subtitle"),
                            address: address,
                            coordinate: coord,
                            category: query.category,
                            distance: nil
                        )
                    }
                }
            }
            var areas: [AssemblyArea] = []
            for await result in group { areas.append(contentsOf: result) }
            return areas
        }
    }

    // MARK: - OpenStreetMap / Overpass

    /// Yalnızca OSM'de açıkça `emergency=assembly_point` veya deprem için
    /// uygun toplanma alanı olarak işaretlenen kayıtlarla seçili sağlık
    /// noktalarını getirir. Genel park ve meydanlar güvenli alan varsayımıyla
    /// sonuca eklenmez.
    private func fetchOpenStreetMap(near center: CLLocationCoordinate2D,
                                    radius: CLLocationDistance,
                                    categories: Set<EmergencyPlaceCategory>) async throws -> [AssemblyArea] {
        let categoryKey = categories.map(\.rawValue).sorted().joined(separator: ",")
        let cacheKey = "\(center.latitude.rounded(toPlaces: 2)):\(center.longitude.rounded(toPlaces: 2)):\(Int(radius)):\(categoryKey)"
        if let cached = openStreetMapCache[cacheKey],
           Date().timeIntervalSince(cached.date) < openStreetMapCacheTTL {
            return cached.areas
        }

        let bounds = boundingBox(around: center, radius: radius)
        let bbox = "\(bounds.south),\(bounds.west),\(bounds.north),\(bounds.east)"
        let clauses = openStreetMapClauses(categories: categories, bbox: bbox)
        let query = """
        [out:json][timeout:12];
        (
        \(clauses)
        );
        out center tags 300;
        """

        let endpoints = [
            "https://lz4.overpass-api.de/api/interpreter",
            "https://overpass-api.de/api/interpreter",
            "https://overpass.kumi.systems/api/interpreter"
        ]

        var lastError: Error = URLError(.cannotLoadFromNetwork)
        for endpoint in endpoints {
            try Task.checkCancellation()
            do {
                guard let url = URL(string: endpoint) else { continue }
                var form = URLComponents()
                form.queryItems = [URLQueryItem(name: "data", value: query)]

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
                request.timeoutInterval = 15
                request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("Sismik-iOS/\(appVersion)", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse,
                      200..<300 ~= http.statusCode else {
                    throw URLError(.badServerResponse)
                }

                let decoded = try JSONDecoder().decode(OpenStreetMapResponse.self, from: data)
                let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
                let areas = decoded.elements.compactMap { element -> AssemblyArea? in
                    guard let coordinate = element.coordinate else { return nil }

                    let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    guard centerLocation.distance(from: location) <= radius else { return nil }

                    let tags = element.tags ?? [:]
                    guard let category = category(from: tags), categories.contains(category) else {
                        return nil
                    }
                    if category == .assemblyArea,
                       tags["assembly_point:earthquake"]?.lowercased() == "no" {
                        return nil
                    }
                    let ref = tags["ref"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let categoryName = fallbackName(for: category)
                    let fallbackName = ref.flatMap { $0.isEmpty ? nil : "\(categoryName) \($0)" }
                        ?? categoryName
                    let name = preferredName(from: tags) ?? fallbackName

                    return AssemblyArea(
                        id: "osm-\(element.type)-\(element.id)",
                        name: name,
                        address: address(from: tags),
                        coordinate: coordinate,
                        category: category,
                        distance: nil
                    )
                }

                let deduped = deduplicate(areas)
                openStreetMapCache[cacheKey] = OpenStreetMapCacheEntry(date: Date(), areas: deduped)
                return deduped
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    // MARK: - Sunucu önbelleği (functions/src/safety-places.ts)

    private struct SharedSafetyResponse: Decodable {
        struct Place: Decodable {
            let id: String
            let c: String
            let lat: Double
            let lon: Double
            let n: String
            let nl: [String: String]?
            let a: String?
            let r: String?
        }
        let places: [Place]
    }

    /// Hücre bazlı ortak önbellekten yerleri getirir. Konum ~1 km'ye
    /// yuvarlanır: aynı mahalledeki herkes CDN'deki aynı yanıtı alır;
    /// uzaklık sıralaması cihazda gerçek konumla yeniden yapılır.
    private func fetchSharedSafetyPlaces(
        near center: CLLocationCoordinate2D,
        categories: Set<EmergencyPlaceCategory>
    ) async throws -> [AssemblyArea] {
        var components = URLComponents(string: BackendConfig.baseURL + "/safety-places")
        components?.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.2f", center.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.2f", center.longitude)),
            URLQueryItem(name: "radius", value: "12000")
        ]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        // Soğuk hücrede sunucu Overpass'ı bekler; kullanıcı beklemez, eski
        // akışa düşer. Sunucu hücreyi yine de doldurur, sonraki açılış hızlı.
        request.timeoutInterval = 3.5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(SharedSafetyResponse.self, from: data)
        let language = String(AppLanguage.currentLanguageCode.prefix(2))
        return decoded.places.compactMap { place -> AssemblyArea? in
            guard let category = EmergencyPlaceCategory(rawValue: place.c),
                  categories.contains(category) else { return nil }
            let categoryName = fallbackName(for: category)
            let name = [place.nl?[language], place.nl?["en"], place.n]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
                ?? place.r.map { "\(categoryName) \($0)" }
                ?? categoryName
            return AssemblyArea(
                id: place.id,
                name: name,
                address: place.a,
                coordinate: CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon),
                category: category,
                distance: nil
            )
        }
    }

    // MARK: - Yardımcılar

    /// Bir zenginleştirme görevinin sonucu belirtilen sürede gelmezse görevi
    /// iptal eder. Böylece yavaş Overpass uç noktaları ana arama süresini
    /// belirleyemez.
    private func value<T>(of task: Task<T, Never>, timeout: Duration) async -> T? {
        guard timeout > .zero else {
            task.cancel()
            return nil
        }

        let result = await withTaskGroup(of: T?.self, returning: T?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: timeout)
                task.cancel()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        if result == nil { task.cancel() }
        return result
    }

    private func searchCacheKey(center: CLLocationCoordinate2D,
                                radius: CLLocationDistance,
                                categories: Set<EmergencyPlaceCategory>) -> String {
        // Yaklaşık 1,1 km'lik hücre: aynı mahallede küçük GPS oynamaları yeni
        // ağ isteği başlatmaz, fakat farklı bölgeleri aynı sonuca bağlamaz.
        let categoryKey = categories.map(\.rawValue).sorted().joined(separator: ",")
        return "\(center.latitude.rounded(toPlaces: 2)):\(center.longitude.rounded(toPlaces: 2)):\(Int(radius)):\(categoryKey)"
    }

    private func reusableCacheEntry(center: CLLocationCoordinate2D,
                                    radius: CLLocationDistance,
                                    categories: Set<EmergencyPlaceCategory>) -> SearchCacheEntry? {
        let now = Date()
        let requestedCenter = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return searchCache.values
            .filter {
                now.timeIntervalSince($0.date) < searchCacheTTL
                    && $0.radius == radius
                    && $0.categories.isSuperset(of: categories)
                    && requestedCenter.distance(from: CLLocation(
                        latitude: $0.center.latitude,
                        longitude: $0.center.longitude
                    )) < 1_200
                    && Set($0.areas.map(\.category)).isSuperset(of: categories)
            }
            .max { $0.date < $1.date }
    }

    /// ~60 m içindeki kayıtları tek sayar (aynı alan birden çok sorgudan gelebilir).
    private func deduplicate(_ areas: [AssemblyArea]) -> [AssemblyArea] {
        var kept: [AssemblyArea] = []
        // Aynı tesis birden fazla sorgudan geldiyse daha özgül sağlık
        // kategorisini koru (ör. hastane, sağlık merkezi sonucuna üstün gelir).
        for area in areas.sorted(by: { $0.category.searchPriority > $1.category.searchPriority }) {
            let isDuplicate = kept.contains { existing in
                existing.clLocation.distance(from: area.clLocation) < 60
            }
            if !isDuplicate { kept.append(area) }
        }
        return kept
    }

    private func scopedToSmallestUsefulRadius(_ areas: [AssemblyArea],
                                              center: CLLocationCoordinate2D,
                                              tiers: [CLLocationDistance],
                                              minimumCount: Int) -> [AssemblyArea] {
        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        for tier in tiers {
            let withinTier = areas.filter {
                centerLocation.distance(from: $0.clLocation) <= tier
            }
            if withinTier.count >= minimumCount || tier == tiers.last {
                return withinTier
            }
        }
        return areas
    }

    private func sortedByDistance(_ areas: [AssemblyArea], center: CLLocationCoordinate2D) -> [AssemblyArea] {
        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return areas
            .map { area -> AssemblyArea in
                var areaWithDistance = area
                areaWithDistance.distance = areaWithDistance.clLocation.distance(from: centerLocation)
                return areaWithDistance
            }
            .sorted { ($0.distance ?? .greatestFiniteMagnitude) < ($1.distance ?? .greatestFiniteMagnitude) }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
    }

    private func searchLocale(for center: CLLocationCoordinate2D,
                              categories: Set<EmergencyPlaceCategory>) -> SearchLocale {
        // Türkiye'nin yaklaşık coğrafi sınırı. Sınır bölgelerinde OSM sorgusu
        // zaten dilden bağımsız çalıştığı için yanlış negatif oluşturmaz.
        let isLikelyInTürkiye = (35.7...42.2).contains(center.latitude)
            && (25.5...45.0).contains(center.longitude)

        if isLikelyInTürkiye {
            return SearchLocale(
                language: "tr",
                googleQueries: localizedQueries(turkish: true, categories: categories, compact: true),
                appleQueries: localizedQueries(turkish: true, categories: categories, compact: false)
            )
        }

        return SearchLocale(
            language: "en",
            googleQueries: localizedQueries(turkish: false, categories: categories, compact: true),
            appleQueries: localizedQueries(turkish: false, categories: categories, compact: false)
        )
    }

    private func localizedQueries(turkish: Bool,
                                  categories: Set<EmergencyPlaceCategory>,
                                  compact: Bool) -> [PlaceQuery] {
        var queries: [PlaceQuery] = []
        for category in EmergencyPlaceCategory.allCases where categories.contains(category) {
            let texts: [String]
            switch (turkish, category) {
            case (true, .assemblyArea):
                texts = compact
                    ? ["acil durum toplanma alanı"]
                    : ["acil durum toplanma alanı", "deprem toplanma alanı", "toplanma alanı"]
            case (true, .pharmacy): texts = ["eczane"]
            case (true, .clinic): texts = compact ? ["aile sağlığı merkezi"] : ["aile sağlığı merkezi", "sağlık ocağı"]
            case (true, .hospital): texts = ["hastane"]
            case (true, .grocery): texts = compact ? ["süpermarket"] : ["süpermarket", "market"]
            case (false, .assemblyArea):
                texts = compact
                    ? ["emergency assembly point"]
                    : ["emergency assembly point", "earthquake assembly point", "evacuation assembly point"]
            case (false, .pharmacy): texts = ["pharmacy"]
            case (false, .clinic): texts = compact ? ["health clinic"] : ["health clinic", "medical center"]
            case (false, .hospital): texts = ["hospital"]
            case (false, .grocery): texts = compact ? ["supermarket"] : ["supermarket", "grocery store"]
            }
            queries.append(contentsOf: texts.map { PlaceQuery(text: $0, category: category) })
        }
        return queries
    }

    private func openStreetMapClauses(categories: Set<EmergencyPlaceCategory>,
                                      bbox: String) -> String {
        var clauses: [String] = []
        if categories.contains(.assemblyArea) {
            clauses += [
                "  nwr[\"emergency\"=\"assembly_point\"](\(bbox));",
                "  nwr[\"assembly_point:earthquake\"=\"yes\"](\(bbox));"
            ]
        }
        if categories.contains(.pharmacy) {
            clauses.append("  nwr[\"amenity\"=\"pharmacy\"](\(bbox));")
        }
        if categories.contains(.clinic) {
            clauses += [
                "  nwr[\"amenity\"~\"clinic|doctors\"](\(bbox));",
                "  nwr[\"healthcare\"~\"clinic|doctor|centre\"](\(bbox));"
            ]
        }
        if categories.contains(.hospital) {
            clauses += [
                "  nwr[\"amenity\"=\"hospital\"](\(bbox));",
                "  nwr[\"healthcare\"=\"hospital\"](\(bbox));"
            ]
        }
        if categories.contains(.grocery) {
            clauses.append("  nwr[\"shop\"~\"supermarket|convenience|grocery\"](\(bbox));")
        }
        return clauses.joined(separator: "\n")
    }

    private func category(from tags: [String: String]) -> EmergencyPlaceCategory? {
        let amenity = tags["amenity"]?.lowercased()
        let healthcare = tags["healthcare"]?.lowercased()
        let shop = tags["shop"]?.lowercased()
        if amenity == "hospital" || healthcare == "hospital" { return .hospital }
        if amenity == "clinic" || amenity == "doctors"
            || healthcare == "clinic" || healthcare == "doctor" || healthcare == "centre" {
            return .clinic
        }
        if amenity == "pharmacy" { return .pharmacy }
        if shop == "supermarket" || shop == "convenience" || shop == "grocery" { return .grocery }
        if tags["emergency"] == "assembly_point"
            || tags["assembly_point:earthquake"]?.lowercased() == "yes" { return .assemblyArea }
        return nil
    }

    private func fallbackName(for category: EmergencyPlaceCategory) -> String {
        switch category {
        case .assemblyArea: L("assembly.category.assembly")
        case .pharmacy: L("assembly.category.pharmacy")
        case .clinic: L("assembly.category.clinic")
        case .hospital: L("assembly.category.hospital")
        case .grocery: L("assembly.category.grocery")
        }
    }

    private func boundingBox(around center: CLLocationCoordinate2D,
                             radius: CLLocationDistance) -> (south: Double, west: Double, north: Double, east: Double) {
        let latitudeDelta = radius / 111_320
        let longitudeScale = max(0.2, cos(center.latitude * .pi / 180))
        let longitudeDelta = radius / (111_320 * longitudeScale)
        return (
            south: max(-90, center.latitude - latitudeDelta),
            west: max(-180, center.longitude - longitudeDelta),
            north: min(90, center.latitude + latitudeDelta),
            east: min(180, center.longitude + longitudeDelta)
        )
    }

    /// OSM etiketlerinden ada karar verir. Önce seçili uygulama dilinin
    /// `name:<kod>` etiketi denenir; uygulama dokuz dili desteklediği hâlde
    /// burada yalnızca `name:tr` ve `name:en` sorgulanıyordu, dolayısıyla
    /// Almanca ya da Japonca bir kullanıcı OSM'de karşılığı olsa bile hep
    /// İngilizce/yerel adı görüyordu. Karşılığı yoksa İngilizce, o da yoksa
    /// verinin kendi dilindeki `name` etiketi kullanılır.
    private func preferredName(from tags: [String: String]) -> String? {
        let candidates = [
            "name:\(AppLanguage.currentLanguageCode)",
            "name:en",
            "name"
        ]
        return candidates
            .compactMap { tags[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func address(from tags: [String: String]) -> String? {
        if let full = tags["addr:full"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !full.isEmpty {
            return full
        }

        let street = tags["addr:street"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let houseNumber = tags["addr:housenumber"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let city = tags["addr:city"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let addressParts: [String] = [street, houseNumber, city].compactMap { (value: String?) -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        if !addressParts.isEmpty { return addressParts.joined(separator: ", ") }

        if let operatorName = tags["operator"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !operatorName.isEmpty {
            return operatorName
        }
        return nil
    }
}

private struct SearchLocale {
    let language: String
    let googleQueries: [PlaceQuery]
    let appleQueries: [PlaceQuery]
}

private struct PlaceQuery: Sendable {
    let text: String
    let category: EmergencyPlaceCategory
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
