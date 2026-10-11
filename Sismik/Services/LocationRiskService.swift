import CoreLocation
import Foundation
import MapKit

/// Bir konumun deprem riskini gerçek verilerle özetler. Tamamı cihazda ya da
/// doğrudan USGS'ten hesaplanır; Sismik sunucusu ve veritabanı kullanılmaz.
///
/// Kaynaklar:
/// - **Aktif faylar** — uygulamaya gömülü GEM Global Active Faults (haritadaki
///   fay katmanıyla aynı): ad, fay türü, kayma hızı ve geometri. Olası en büyük
///   deprem fay uzunluğundan Wells & Coppersmith (1994) ile, o depremin bu
///   konumdaki sarsıntısı uygulamanın azalım + Wald zinciriyle tahmin edilir.
/// - **Deprem geçmişi** — USGS kataloğu: 1900'den bu yana 150 km içindeki M5+
///   liste (en büyükler, on yıllar, burada hissedilmiş en güçlü sarsıntı) ve
///   100 km içindeki M4+ sayıları (uzun dönem ve son 12 ay).
/// - **Olasılık** — gözlenen yıllık sıklıktan Poisson modeliyle önümüzdeki 1,
///   10 ve 50 yılda 100 km içinde M5+ / M6+ olma olasılığı.
/// - **Bina** — kullanıcının seçtiği yapım dönemi.
///
/// Resmî tehlike haritasının yerini tutmaz; arayüz bunu açıkça söyler.
struct LocationRiskProfile: Sendable, Equatable {
    struct NearbyFault: Sendable, Equatable, Identifiable {
        var id: String { "\(name)-\(Int(distanceKm))" }
        let name: String
        let distanceKm: Double
        let risk: FaultRisk
        let slipType: FaultSlipType
        let slipRate: Double?
        let lengthKm: Double
        /// Fay uzunluğundan kaba en büyük deprem tahmini.
        let maxMagnitude: Double
        /// O deprem olursa bu konumda tahmini şiddet (MMI).
        let scenarioIntensity: Double
    }

    struct HistoricQuake: Sendable, Equatable, Identifiable {
        var id: String { "\(year)-\(magnitude)-\(Int(distanceKm))" }
        let magnitude: Double
        let place: String
        let year: Int
        let distanceKm: Double
        let depthKm: Double
        /// Bu depremde bu konumdaki tahmini şiddet.
        let intensityHere: Double
    }

    struct History: Sendable, Equatable {
        /// 100 km içinde M4+ (1973–bugün, USGS'in bölgesel tam kayıt dönemi).
        let m4Since1973: Int
        /// 100 km içinde 1900'den bu yana.
        let m5: Int
        let m6: Int
        let m7: Int
        /// 100 km içinde 1964'ten bu yana M5+ (olasılık için tam kayıt dönemi).
        let m5Since1964: Int
        /// 150 km içindeki M5+ depremler, büyükten küçüğe.
        let largest: [HistoricQuake]
        /// On yıl başlangıcı → 100 km içinde M5+ sayısı (1900'den bugüne, boşlar 0).
        let decades: [Decade]
        /// Burada hissedilmiş en güçlü sarsıntıyı üreten deprem.
        let strongestFelt: HistoricQuake?
        /// 100 km içinde son 12 ayda M4+.
        let m4LastYear: Int
        /// 100 km içinde son 20 yılda yıllık ortalama M4+.
        let m4YearlyAverage: Double
    }

    struct Decade: Sendable, Equatable, Identifiable {
        var id: Int { start }
        let start: Int
        let count: Int
    }

    enum Level: Int, Sendable, CaseIterable {
        case low, moderate, high, veryHigh

        init(score: Int) {
            switch score {
            case ..<30: self = .low
            case ..<50: self = .moderate
            case ..<70: self = .high
            default: self = .veryHigh
            }
        }
    }

    let coordinate: CLLocationCoordinate2D
    /// 150 km içindeki en yakın (en fazla 3) farklı aktif fay.
    let faults: [NearbyFault]
    let history: History
    let buildingEra: BuildingEra

    var nearestFault: NearbyFault? { faults.first }

    // MARK: Olasılık

    /// Yıllık gözlenen sıklık (100 km içinde).
    var annualRateM5: Double { Double(history.m5Since1964) / LocationRiskScoring.years(since: 1964) }
    var annualRateM6: Double { Double(history.m6) / LocationRiskScoring.years(since: 1900) }

    func probability(minimumMagnitude: Double, years: Double) -> Double {
        let rate = minimumMagnitude >= 6 ? annualRateM6 : annualRateM5
        return 1 - exp(-rate * years)
    }

    // MARK: Puan (0–100)

    var faultScore: Int { LocationRiskScoring.faultScore(nearestFault) }
    var hazardScore: Int {
        LocationRiskScoring.hazardScore(
            probabilityM6In50Years: probability(minimumMagnitude: 6, years: 50),
            strongestFeltIntensity: history.strongestFelt?.intensityHere
        )
    }
    var historyScore: Int { LocationRiskScoring.historyScore(m5Count: history.m5) }
    var buildingScore: Int { buildingEra.score }
    var score: Int { min(100, faultScore + hazardScore + historyScore + buildingScore) }
    var level: Level { Level(score: score) }

    /// Konumun ülkesi (ISO 3166, ters jeokodlamayla). Bulunamazsa nil;
    /// o zaman kaba Türkiye kutusuna düşülür.
    var countryCode: String? = nil

    /// Türkiye'ye özgü öneri ve kaynaklar (AFAD, DASK) yalnızca burada.
    /// Kutu (34–43°K, 23–47°D) Yunan adalarını ve Kıbrıs'ı da içerdiği için
    /// ülke kodu varsa o esas alınır.
    var isInTurkeyRegion: Bool {
        if let countryCode { return countryCode == "TR" }
        return (35.8...42.2).contains(coordinate.latitude) && (25.6...44.9).contains(coordinate.longitude)
    }

    /// Resmî tehlike haritası bu ülkenin yetkili kurumundan; ulusal harita
    /// yoksa GEM'in küresel haritası.
    var hazardAuthority: HazardAuthority {
        if isInTurkeyRegion { return .turkey }
        switch countryCode {
        case "US", "PR", "GU": return .unitedStates
        case "JP": return .japan
        case "NZ": return .newZealand
        case "IT": return .italy
        default: return .global
        }
    }

    /// Son 12 ayın uzun dönem ortalamasına oranı; ortalama çok küçükse nil.
    var recentActivityRatio: Double? {
        guard history.m4YearlyAverage >= 0.5 else { return nil }
        return Double(history.m4LastYear) / history.m4YearlyAverage
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.faults == rhs.faults
            && lhs.history == rhs.history
            && lhs.buildingEra == rhs.buildingEra
            && lhs.countryCode == rhs.countryCode
    }

    func with(buildingEra: BuildingEra) -> LocationRiskProfile {
        LocationRiskProfile(coordinate: coordinate, faults: faults, history: history,
                            buildingEra: buildingEra, countryCode: countryCode)
    }
}

/// Resmî deprem tehlike haritasını yayımlayan kurum.
enum HazardAuthority: String, Sendable {
    case turkey, unitedStates, japan, newZealand, italy, global

    var url: URL {
        switch self {
        case .turkey: URL(string: "https://tdth.afad.gov.tr")!
        case .unitedStates: URL(string: "https://www.usgs.gov/programs/earthquake-hazards/science/national-seismic-hazard-model")!
        case .japan: URL(string: "https://www.j-shis.bosai.go.jp/en/")!
        case .newZealand: URL(string: "https://nshm.gns.cri.nz")!
        case .italy: URL(string: "https://zonesismiche.mi.ingv.it")!
        case .global: URL(string: "https://maps.openquake.org/map/global-seismic-hazard-map/")!
        }
    }

    /// Yerelleştirilmiş harita adı.
    var mapName: String { L("risk.authority.\(rawValue)") }
}

/// GEM `slip_type` değerlerinin halk diline indirgenmiş hâli.
enum FaultSlipType: String, Sendable {
    case strikeSlip, reverse, normal, unknown

    init(gem value: String) {
        let lower = value.lowercased()
        if lower.contains("dextral") || lower.contains("sinistral") || lower.contains("strike") {
            self = .strikeSlip
        } else if lower.contains("reverse") || lower.contains("thrust") {
            self = .reverse
        } else if lower.contains("normal") {
            self = .normal
        } else {
            self = .unknown
        }
    }
}

/// Binanın yapım dönemi. Türkiye'de 1998/2007 yönetmelikleri ve 2018 Türkiye
/// Bina Deprem Yönetmeliği (TBDY) dönüm noktalarıdır.
enum BuildingEra: String, CaseIterable, Identifiable, Sendable {
    case unknown, before2000, between2000And2018, after2018

    var id: String { rawValue }

    /// Bina göstergesinin puanı (en fazla 15).
    var score: Int {
        switch self {
        case .before2000: 15
        case .unknown, .between2000And2018: 8
        case .after2018: 3
        }
    }
}

/// Saf puanlama ve tahmin kuralları (ağ ve arayüzden bağımsız).
enum LocationRiskScoring {
    static func years(since year: Int) -> Double {
        let now = Calendar(identifier: .gregorian).component(.year, from: Date())
        return Double(max(1, now - year))
    }

    /// Fay göstergesi, en fazla 30. Uzaklık bantları GEM verisinin çözünürlüğü
    /// (km mertebesi) düşünülerek kaba tutuldu; yavaş kayan fay aynı uzaklıkta
    /// daha az puan alır.
    static func faultScore(_ fault: LocationRiskProfile.NearbyFault?) -> Int {
        guard let fault else { return 2 }
        let base: Double
        switch fault.distanceKm {
        case ..<5: base = 30
        case ..<15: base = 25
        case ..<30: base = 19
        case ..<60: base = 10
        case ..<100: base = 5
        default: base = 2
        }
        let weight: Double
        switch fault.risk {
        case .high: weight = 1.0
        case .mediumHigh: weight = 0.8
        case .unknown: weight = 0.65
        case .medium: weight = 0.55
        }
        return Int((base * weight).rounded())
    }

    /// Tehlike göstergesi, en fazla 40: 50 yılda 100 km içinde M6+ olasılığı
    /// (en fazla 22) + burada tarihte hissedilmiş en güçlü sarsıntı (en fazla 18).
    static func hazardScore(probabilityM6In50Years p: Double, strongestFeltIntensity mmi: Double?) -> Int {
        let probabilityScore: Int
        switch p {
        case 0.9...: probabilityScore = 22
        case 0.6...: probabilityScore = 17
        case 0.3...: probabilityScore = 11
        case 0.1...: probabilityScore = 6
        default: probabilityScore = 2
        }
        let feltScore: Int
        switch mmi ?? 0 {
        case 8...: feltScore = 18
        case 7...: feltScore = 14
        case 6...: feltScore = 9
        case 5...: feltScore = 5
        default: feltScore = 0
        }
        return probabilityScore + feltScore
    }

    /// Geçmiş göstergesi, en fazla 15: 1900'den bu yana 100 km içindeki M5+ sayısı.
    static func historyScore(m5Count: Int) -> Int {
        Int(min(15, log2(Double(max(0, m5Count)) + 1) * 3).rounded())
    }

    /// Wells & Coppersmith (1994), tüm fay türleri: M = 5.08 + 1.16·log10(L km).
    /// GEM parçaları bazen fayın yalnızca bir bölümü olduğu için sonuç kaba
    /// bir üst sınır tahminidir; 5.5–8.0 arasına sıkıştırılır.
    static func maxMagnitude(forRuptureLengthKm length: Double) -> Double {
        guard length > 0 else { return 5.5 }
        return min(8.0, max(5.5, 5.08 + 1.16 * log10(length)))
    }
}

enum LocationRiskService {
    static let historyRadiusKm: Double = 100
    static let listRadiusKm: Double = 150
    /// Fay araması bu uzaklıktan ötesine bakmaz; ötesi "yakında fay yok".
    static let faultSearchRadiusKm: Double = 150

    private static let historyCache = HistoryCache()

    /// Profili üretir. Fay verisi yüklü değilse yükler (gömülü dosya).
    @MainActor
    static func profile(for coordinate: CLLocationCoordinate2D, buildingEra: BuildingEra) async throws -> LocationRiskProfile {
        let faultsModel = FaultLinesViewModel.shared
        await faultsModel.load()
        let segments = faultsModel.segments
        async let faults = Task.detached(priority: .userInitiated) {
            nearbyFaults(to: coordinate, in: segments)
        }.value
        async let country = countryCode(for: coordinate)
        let history = try await history(around: coordinate)
        return LocationRiskProfile(
            coordinate: coordinate,
            faults: await faults,
            history: history,
            buildingEra: buildingEra,
            countryCode: await country
        )
    }

    // MARK: Ülke

    private static var countryCache: [String: String] = [:]

    /// Konumun ISO ülke kodu. Profil her ülkede çalışır; ülke yalnızca resmî
    /// kaynak bağlantısını ve ülkeye özgü önerileri (DASK, AFAD) seçer.
    /// Ağ yoksa ya da bulunamazsa nil — profil yine üretilir.
    @MainActor
    static func countryCode(for coordinate: CLLocationCoordinate2D) async -> String? {
        let key = String(format: "%.2f,%.2f", coordinate.latitude, coordinate.longitude)
        if let cached = countryCache[key] { return cached }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var code: String?
        if #available(iOS 26.0, *) {
            if let request = MKReverseGeocodingRequest(location: location),
               let item = try? await request.mapItems.first {
                code = item.addressRepresentations?.region?.identifier
            }
        } else {
            code = try? await CLGeocoder().reverseGeocodeLocation(location).first?.isoCountryCode
        }
        if let code { countryCache[key] = code.uppercased() }
        return code?.uppercased()
    }

    // MARK: Faylar

    /// 150 km içindeki en yakın 3 farklı fay (aynı adın parçaları tek fay
    /// sayılır; uzunlukları olası en büyük deprem için toplanır).
    nonisolated static func nearbyFaults(
        to coordinate: CLLocationCoordinate2D,
        in segments: [FaultSegment]
    ) -> [LocationRiskProfile.NearbyFault] {
        let origin = MKMapPoint(coordinate)
        let metersPerPoint = MKMetersPerMapPointAtLatitude(coordinate.latitude)
        // Uzunluk toplamı için daha geniş bir çevreye bakılır: fayın uzak kısmı
        // da aynı depremde kırılabilir.
        let lengthWindowPoints = (faultSearchRadiusKm * 2) * 1_000 / metersPerPoint
        let lengthRect = MKMapRect(
            x: origin.x - lengthWindowPoints, y: origin.y - lengthWindowPoints,
            width: lengthWindowPoints * 2, height: lengthWindowPoints * 2
        )

        struct Group {
            var distance = Double.greatestFiniteMagnitude
            var lengthKm = 0.0
            var segment: FaultSegment
        }
        var groups: [String: Group] = [:]
        for segment in segments {
            let polyline = segment.polyline
            guard polyline.boundingMapRect.intersects(lengthRect), polyline.pointCount > 0 else { continue }
            let points = polyline.points()
            var nearest = Double.greatestFiniteMagnitude
            var length = 0.0
            if polyline.pointCount == 1 {
                nearest = hypot(points[0].x - origin.x, points[0].y - origin.y)
            } else {
                for index in 0..<(polyline.pointCount - 1) {
                    nearest = min(nearest, distance(from: origin, toSegment: points[index], points[index + 1]))
                    length += points[index].distance(to: points[index + 1])
                }
            }
            // Adsız parçalar birbirine eklenmez; her biri ayrı fay sayılır.
            let key = segment.name.isEmpty ? segment.id.uuidString : segment.name
            var group = groups[key] ?? Group(segment: segment)
            group.lengthKm += length / 1_000
            if nearest < group.distance {
                group.distance = nearest
                group.segment = segment
            }
            groups[key] = group
        }

        var ranked: [(km: Double, group: Group)] = []
        for group in groups.values {
            let km = group.distance * metersPerPoint / 1_000
            if km <= faultSearchRadiusKm { ranked.append((km, group)) }
        }
        ranked.sort { $0.km < $1.km }

        var result: [LocationRiskProfile.NearbyFault] = []
        for item in ranked.prefix(3) {
            let segment = item.group.segment
            let maxMagnitude = LocationRiskScoring.maxMagnitude(forRuptureLengthKm: item.group.lengthKm)
            let intensity = SeismicImpactModel.estimatedMMI(
                magnitude: maxMagnitude, depthKm: 10, epicentralDistanceKm: item.km
            )
            result.append(LocationRiskProfile.NearbyFault(
                name: segment.name,
                distanceKm: item.km,
                risk: segment.risk,
                slipType: FaultSlipType(gem: segment.slipType),
                slipRate: segment.slipRate,
                lengthKm: item.group.lengthKm,
                maxMagnitude: maxMagnitude,
                scenarioIntensity: intensity
            ))
        }
        return result
    }

    private nonisolated static func distance(from p: MKMapPoint, toSegment a: MKMapPoint, _ b: MKMapPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: Deprem geçmişi (USGS)

    private static let usgsBase = "https://earthquake.usgs.gov/fdsnws/event/1"

    private static func history(around coordinate: CLLocationCoordinate2D) async throws -> LocationRiskProfile.History {
        // ~1 km'lik ızgara: aynı yerin tekrar açılışı ağa gitmez.
        let key = String(format: "%.2f,%.2f", coordinate.latitude, coordinate.longitude)
        if let cached = await historyCache.value(for: key) { return cached }

        let now = Date()
        let oneYearAgo = now.addingTimeInterval(-365 * 86_400)
        let twentyYearsAgo = now.addingTimeInterval(-20 * 365.25 * 86_400)
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]

        async let list = significantQuakes(around: coordinate)
        async let m4Long = count(around: coordinate, minMagnitude: 4, start: "1973-01-01")
        async let m4Year = count(around: coordinate, minMagnitude: 4, start: day.string(from: oneYearAgo))
        async let m4Twenty = count(around: coordinate, minMagnitude: 4, start: day.string(from: twentyYearsAgo))

        let quakes = try await list
        let within100 = quakes.filter { $0.distanceKm <= historyRadiusKm }
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: now)
        let decadeCounts = Dictionary(grouping: within100, by: { ($0.year / 10) * 10 }).mapValues(\.count)
        let decades = stride(from: 1900, through: (currentYear / 10) * 10, by: 10).map {
            LocationRiskProfile.Decade(start: $0, count: decadeCounts[$0] ?? 0)
        }

        let history = LocationRiskProfile.History(
            m4Since1973: try await m4Long,
            m5: within100.count,
            m6: within100.filter { $0.magnitude >= 6 }.count,
            m7: within100.filter { $0.magnitude >= 7 }.count,
            m5Since1964: within100.filter { $0.year >= 1964 }.count,
            largest: Array(quakes.sorted { $0.magnitude > $1.magnitude }.prefix(5)),
            decades: decades,
            strongestFelt: quakes.max { $0.intensityHere < $1.intensityHere },
            m4LastYear: try await m4Year,
            m4YearlyAverage: Double(try await m4Twenty) / 20
        )
        await historyCache.store(history, for: key)
        return history
    }

    private static func significantQuakes(around coordinate: CLLocationCoordinate2D) async throws -> [LocationRiskProfile.HistoricQuake] {
        var components = URLComponents(string: "\(usgsBase)/query")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "geojson"),
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(name: "maxradiuskm", value: String(Int(listRadiusKm))),
            URLQueryItem(name: "minmagnitude", value: "5"),
            URLQueryItem(name: "starttime", value: "1900-01-01"),
            URLQueryItem(name: "orderby", value: "magnitude"),
            URLQueryItem(name: "limit", value: "1000")
        ]
        let data = try await get(components.url!)
        let feed = try JSONDecoder().decode(USGSFeed.self, from: data)
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let calendar = Calendar(identifier: .gregorian)
        return feed.features.compactMap { feature -> LocationRiskProfile.HistoricQuake? in
            let coordinates = feature.geometry.coordinates
            guard let magnitude = feature.properties.mag, coordinates.count >= 2,
                  let longitude = coordinates[0], let latitude = coordinates[1] else { return nil }
            let distanceKm = origin.distance(from: CLLocation(latitude: latitude, longitude: longitude)) / 1_000
            // Derinliği bilinmeyen tarihî depremde sığ kabuk depremi varsayılır.
            let depthKm = coordinates.count > 2 ? max(1, coordinates[2] ?? 10) : 10
            let date = Date(timeIntervalSince1970: TimeInterval(feature.properties.time ?? 0) / 1_000)
            return LocationRiskProfile.HistoricQuake(
                magnitude: magnitude,
                place: feature.properties.place ?? "",
                year: calendar.component(.year, from: date),
                distanceKm: distanceKm,
                depthKm: depthKm,
                intensityHere: SeismicImpactModel.estimatedMMI(
                    magnitude: magnitude, depthKm: depthKm, epicentralDistanceKm: distanceKm
                )
            )
        }
    }

    /// USGS `count` ucu: yalnızca sayı döner, liste indirilmez.
    private static func count(around coordinate: CLLocationCoordinate2D, minMagnitude: Double, start: String) async throws -> Int {
        var components = URLComponents(string: "\(usgsBase)/count")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "geojson"),
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(name: "maxradiuskm", value: String(Int(historyRadiusKm))),
            URLQueryItem(name: "minmagnitude", value: String(minMagnitude)),
            URLQueryItem(name: "starttime", value: start)
        ]
        let data = try await get(components.url!)
        struct CountResponse: Decodable { let count: Int }
        return try JSONDecoder().decode(CountResponse.self, from: data).count
    }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private actor HistoryCache {
        private var entries: [String: (value: LocationRiskProfile.History, at: Date)] = [:]

        func value(for key: String) -> LocationRiskProfile.History? {
            guard let entry = entries[key], Date().timeIntervalSince(entry.at) < 86_400 else { return nil }
            return entry.value
        }

        func store(_ value: LocationRiskProfile.History, for key: String) {
            if entries.count > 50 { entries.removeAll() }
            entries[key] = (value, Date())
        }
    }

    private struct USGSFeed: Decodable {
        struct Feature: Decodable {
            struct Properties: Decodable {
                let mag: Double?
                let place: String?
                let time: Int64?
            }
            struct Geometry: Decodable {
                /// Tarihî kayıtlarda derinlik `null` gelir (ör. 1906 öncesi
                /// Kaliforniya); `[Double]` tek bir boş değerde bütün yanıtı
                /// çözümlenemez yapıyor, profil "bağlantı hatası" veriyordu.
                let coordinates: [Double?]
            }
            let properties: Properties
            let geometry: Geometry
        }
        let features: [Feature]
    }
}
