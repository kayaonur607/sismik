import Foundation
import CoreLocation

/// Bir bildirim yerinin türü.
///
/// `current` yalnızca İSTEMCİDE anlamlıdır: sunucuya gönderilirken o anki
/// koordinat çözülüp sıradan bir yer olarak yazılır. Böylece sunucunun cihaz
/// konumunu ayrıca takip etmesi gerekmez ve `notificationMatch` tek tür görür.
enum PlaceKind: String, Codable, Sendable {
    case pinned
    case current
}

/// Kullanıcının deprem bildirimi almak için takip ettiği yer.
///
/// Her kayıt tek başına okunabilen tam bir kuraldır: *bu noktada, bu
/// yarıçapta, bu büyüklükten itibaren haber ver.* Büyüklük eşiği bilinçli
/// olarak yer başınadır — evdeki küçük sarsıntıyı duymak isteyip uzaktaki bir
/// şehir için yalnızca daha büyük olayları istemek doğal bir ihtiyaç ve
/// ayrı bir genel eşik kontrolüne olan gereği ortadan kaldırır.
struct NotificationPlace: Codable, Identifiable, Hashable, Sendable {
    /// Yarıçap sınırları. Üst sınır ülke ölçeğinde bir alanı tek yerle
    /// kapsayabilmek için geniş tutulur (eski `radius` ayarının üst sınırıyla
    /// aynı).
    static let minRadiusKm: Double = 5
    static let maxRadiusKm: Double = 1000
    /// Ücretsiz katmanın yarıçap sınırı (sunucu `FREE_MAX_RADIUS_KM` ile aynı):
    /// bir şehir ve yakın çevresi. Daha geniş alan premium.
    static let freeMaxRadiusKm: Double = 50
    static let minMagnitudeFloor: Double = 1.0
    static let minMagnitudeCeiling: Double = 7.0
    static let maxNameLength = 40
    /// Kritik uyarı eşiği sınırları. Alt sınır 3: daha küçük depremde telefonu
    /// sessiz moddan çalmak savunulamaz (sunucu da aynı sınırı uygular).
    static let criticalMagnitudeFloor: Double = 3.0
    static let criticalMagnitudeCeiling: Double = 8.0

    let id: String
    var name: String
    /// Kullanıcının seçtiği simge (15'lik set). Listede, haritada ve
    /// bildirimin sağında görünür; aynı simge iki yerde kullanılamaz.
    var icon: PlaceIcon
    var kind: PlaceKind
    var latitude: Double
    var longitude: Double
    var radiusKm: Double
    var minMagnitude: Double
    /// Bu büyüklük ve üstünde bildirim KRİTİK uyarı olarak gelir (sessiz modu
    /// ve Odak'ı aşar). `nil` = bu yer için kritik uyarı kapalı. Her zaman
    /// `minMagnitude`'dan büyük ya da eşittir.
    var criticalMagnitude: Double?
    /// "Hissedilecek depremlerde de haber ver" (2.1.4+): yerde tahmini şiddet
    /// bu MMI değerine (3, 4, 5) ulaşırsa deprem yarıçap dışında ya da
    /// büyüklük eşiğinin altında olsa bile bildirilir. `nil` = kapalı.
    var feltIntensity: Int?
    var enabled: Bool

    /// Hissedilir şiddet seçenekleri ve kuralın en küçük büyüklüğü (sunucu:
    /// `FELT_RULE_MIN_MAGNITUDE`).
    static let feltIntensityOptions = [3, 4, 5]
    static let feltRuleMinMagnitude = 3.0

    init(
        id: String = UUID().uuidString,
        name: String,
        icon: PlaceIcon = .other,
        kind: PlaceKind = .pinned,
        latitude: Double,
        longitude: Double,
        radiusKm: Double,
        minMagnitude: Double,
        criticalMagnitude: Double? = nil,
        feltIntensity: Int? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = String(name.prefix(Self.maxNameLength))
        self.icon = icon
        self.kind = kind
        self.latitude = latitude
        self.longitude = longitude
        self.radiusKm = min(Self.maxRadiusKm, max(Self.minRadiusKm, radiusKm))
        let clampedMinimum = min(Self.minMagnitudeCeiling, max(Self.minMagnitudeFloor, minMagnitude))
        self.minMagnitude = clampedMinimum
        self.criticalMagnitude = criticalMagnitude.map { Self.clampedCritical($0, minMagnitude: clampedMinimum) }
        self.feltIntensity = feltIntensity.flatMap { Self.feltIntensityOptions.contains($0) ? $0 : nil }
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        // Simge setinden önce kaydedilen yerler emoji taşır; en yakın simgeye
        // taşınır ve bir sonraki kayıtta `icon` olarak yazılır.
        if let stored = try? c.decode(PlaceIcon.self, forKey: .icon) {
            icon = stored
        } else {
            icon = PlaceIcon(legacyEmoji: (try? c.decode(String.self, forKey: .legacyEmoji)) ?? "")
        }
        kind = (try? c.decode(PlaceKind.self, forKey: .kind)) ?? .pinned
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        radiusKm = try c.decode(Double.self, forKey: .radiusKm)
        minMagnitude = try c.decode(Double.self, forKey: .minMagnitude)
        criticalMagnitude = try c.decodeIfPresent(Double.self, forKey: .criticalMagnitude)
        feltIntensity = try c.decodeIfPresent(Int.self, forKey: .feltIntensity)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, kind, latitude, longitude, radiusKm, minMagnitude, criticalMagnitude, feltIntensity, enabled
        case legacyEmoji = "emoji"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(icon, forKey: .icon)
        try c.encode(kind, forKey: .kind)
        try c.encode(latitude, forKey: .latitude)
        try c.encode(longitude, forKey: .longitude)
        try c.encode(radiusKm, forKey: .radiusKm)
        try c.encode(minMagnitude, forKey: .minMagnitude)
        try c.encodeIfPresent(criticalMagnitude, forKey: .criticalMagnitude)
        try c.encodeIfPresent(feltIntensity, forKey: .feltIntensity)
        try c.encode(enabled, forKey: .enabled)
    }

    /// Kritik eşik bildirim eşiğinin altına inemez: kritik uyarı, zaten
    /// bildirilen depremlerin bir alt kümesidir.
    static func clampedCritical(_ value: Double, minMagnitude: Double) -> Double {
        min(criticalMagnitudeCeiling, max(criticalMagnitudeFloor, minMagnitude, value))
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Koordinatı geçerli mi? `current` türü, cihaz henüz konum sabitlemesi
    /// almadıysa (0,0) ile durabilir — o hâlde bildirim üretemez.
    var hasValidCoordinate: Bool {
        latitude.isFinite && longitude.isFinite
            && abs(latitude) <= 90 && abs(longitude) <= 180
            && !(latitude == 0 && longitude == 0)
    }

    /// Sunucuya gönderilebilir ve bildirim üretebilir durumda mı?
    var isActive: Bool { enabled && hasValidCoordinate }

    /// Verilen deprem bu yerin kuralını karşılıyor mu? Karşılıyorsa mesafeyi
    /// döndürür.
    ///
    /// Sıralama sunucudaki `matchPlace` ile birebir aynıdır: önce büyüklük
    /// (en ucuz eleme), sonra derece bazlı hızlı sınır, en sonda haversine.
    /// İki taraf ayrışırsa arka plan bildirimi ile push bildirimi çelişir.
    /// Enlem: bir derece 110,574 km (ekvator) ile 111,694 km (kutup) arasında
    /// değişir; en KÜÇÜĞÜ alınır ki sınır mesafeyi fazla gösterip yarıçap
    /// içindeki depremi elemesin.
    private static let kmPerDegreeLatitude = 110.574
    private static let kmPerDegreeLongitudeAtEquator = 111.320
    /// Boylam ön elemesinin güvenli olduğu üst enlem sınırı: üstünde gerçek
    /// yol kutup üzerinden kısalıyor, paralel boyunca ölçen sınır bunu göremiyor.
    private static let longitudePrefilterMaxAbsLatitude = 60.0
    /// Paralel boyunca ölçülen mesafe gerçek büyük çember mesafesinden her
    /// zaman biraz uzundur; pay konmazsa sınıra yakın deprem elenir.
    private static let longitudePrefilterSafety = 1.01

    /// İki boylam arasındaki en kısa açısal fark. 180. meridyen sarması
    /// olmadan, 179,9°D ile 179,9°B arası 359,8° çıkıyor ve 21 km uzaktaki
    /// deprem eleniyordu.
    static func longitudeDelta(_ a: Double, _ b: Double) -> Double {
        let raw = abs(a - b).truncatingRemainder(dividingBy: 360)
        return raw > 180 ? 360 - raw : raw
    }

    func match(latitude quakeLat: Double, longitude quakeLon: Double, magnitude: Double) -> Double? {
        guard isActive, magnitude >= minMagnitude else { return nil }
        guard abs(self.latitude - quakeLat) * Self.kmPerDegreeLatitude <= radiusKm else { return nil }

        let maxAbsLat = max(abs(self.latitude), abs(quakeLat))
        if maxAbsLat <= Self.longitudePrefilterMaxAbsLatitude {
            let lonScale = Self.kmPerDegreeLongitudeAtEquator * cos(maxAbsLat * .pi / 180)
            guard Self.longitudeDelta(self.longitude, quakeLon) * lonScale
                <= radiusKm * Self.longitudePrefilterSafety else { return nil }
        }

        let distance = CLLocation(latitude: self.latitude, longitude: self.longitude)
            .distance(from: CLLocation(latitude: quakeLat, longitude: quakeLon)) / 1000
        return distance <= radiusKm ? distance : nil
    }

    /// Tam kural (sunucudaki `matchPlace` ile aynı): yarıçap + büyüklük eşiği,
    /// ya da açıksa hissedilir şiddet kuralı (yerde tahmini MMI eşiği aşar).
    /// `feltAtPlace` yalnızca yarıçap dışında hissedilir kuralla eşleşince true.
    func match(_ quake: Earthquake) -> (distanceKm: Double, feltAtPlace: Bool, mmi: Double)? {
        if let distance = match(latitude: quake.coordinate.latitude, longitude: quake.coordinate.longitude, magnitude: quake.magnitude) {
            return (distance, false, 0)
        }
        guard isActive, let feltIntensity, quake.magnitude >= Self.feltRuleMinMagnitude,
              abs(latitude - quake.coordinate.latitude) * Self.kmPerDegreeLatitude <= 600 else { return nil }
        let distance = CLLocation(latitude: latitude, longitude: longitude).distance(from: quake.clLocation) / 1000
        let mmi = SeismicImpactModel.estimatedMMI(magnitude: quake.magnitude, depthKm: quake.depth, epicentralDistanceKm: distance)
        return mmi >= Double(feltIntensity) ? (distance, true, mmi) : nil
    }

    /// `/register` yükünde gönderilecek biçim. `current` türü burada çözülür:
    /// sunucuya tür bilgisi gitmez.
    var registrationPayload: [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "name": name,
            "icon": icon.rawValue,
            "lat": latitude,
            "lon": longitude,
            "radiusKm": radiusKm,
            "minMagnitude": minMagnitude
        ]
        if let criticalMagnitude { payload["criticalMagnitude"] = criticalMagnitude }
        if let feltIntensity { payload["feltIntensity"] = feltIntensity }
        return payload
    }
}
