import Foundation
import CoreLocation
import SwiftUI

// MARK: - Kaynak görünümü

/// Sağlayıcının listede görünen etiketi, bayrağı ve rengi. Etiket aynı zamanda
/// kaynak filtresinin anahtarıdır (`EarthquakeListViewModel.allSources`).
struct QuakeProviderStyle {
    let tag: String
    let flag: String
    let color: Color

    init(normalizedProvider: String, provider: String, title: String) {
        switch normalizedProvider {
        case "afad":
            (tag, flag, color) = ("AFAD", "🇹🇷", Color(red: 0.85, green: 0.30, blue: 0.30))
        case "kandilli":
            (tag, flag, color) = ("KANDİLLİ", "🇹🇷", Color(red: 0.80, green: 0.45, blue: 0.20))
        case "usgs":
            (tag, flag, color) = ("USGS", CountryFlag.emoji(forTitle: title), Color(red: 0.35, green: 0.62, blue: 0.40))
        case "emsc":
            (tag, flag, color) = ("EMSC", CountryFlag.emoji(forTitle: title), Color(red: 0.20, green: 0.62, blue: 0.62))
        case "noa":
            (tag, flag, color) = ("NOA", "🇬🇷", Color(red: 0.29, green: 0.42, blue: 0.82))
        case "jma":
            (tag, flag, color) = ("JMA", "🇯🇵", Color(red: 0.75, green: 0.25, blue: 0.45))
        case "cenc":
            (tag, flag, color) = ("CENC", CountryFlag.emoji(forTitle: title), Color(red: 0.70, green: 0.55, blue: 0.15))
        case "bmkg":
            (tag, flag, color) = ("BMKG", "🇮🇩", Color(red: 0.55, green: 0.35, blue: 0.75))
        case "geonet":
            (tag, flag, color) = ("GEONET", "🇳🇿", Color(red: 0.25, green: 0.50, blue: 0.70))
        default:
            (tag, flag, color) = (provider.uppercased(), CountryFlag.emoji(forTitle: title), Color(red: 0.55, green: 0.55, blue: 0.60))
        }
    }
}

// MARK: - Deprem Modeli

struct Earthquake: Identifiable, Decodable, Hashable {
    let id: String
    let provider: String
    let title: String
    let magnitude: Double
    let depth: Double
    let coordinate: Coordinate
    /// Sabit "yyyy-MM-dd HH:mm:ss" (İstanbul) gösterimi. Kayıt başına bir
    /// `DateFormatter` çağrısı 30 bin kayıtlık harita arşivinde ~45 ms tutuyordu ve
    /// değer arayüzde okunmuyordu; artık yalnızca istendiğinde hesaplanır.
    var dateTime: String { Earthquake.threadLocalTrFormatter.string(from: date) }
    /// Unix zaman damgası (SANİYE). Eskiden üç ayrı init'te elle atanıyordu ve
    /// biri yanlışlıkla milisaniye yazıyordu; bildirim filtreleri saniye
    /// beklediği için paylaşılan/bildirimden gelen kayıtlar "gelecekte"
    /// görünüp elenebiliyordu. Artık tek kaynaktan (`date`) türetilir.
    var createdAt: Int { Int(date.timeIntervalSince1970) }
    let locationProperties: LocationProperties

    /// Bir kez hesaplanıp saklanır (her erişimde DateFormatter yaratmamak için).
    let date: Date
    let clLocation: CLLocation

    // Precomputed stored properties (O(1) Main-Thread access)
    let displayTitle: String
    let flag: String
    let sourceTag: String
    let sourceColor: Color
    let magnitudeColor: Color
    let magnitudeString: String

    // Kaynağın sağladığı zengin alanlar (opsiyonel; kaynağa göre değişir)
    /// Büyüklük türü: ML, Mw, mb, Md...
    let magType: String?
    /// USGS inceleme durumu: "automatic" | "reviewed"
    let status: String?
    /// USGS tsunami bayrağı.
    let tsunami: Bool
    /// USGS "Did You Feel It?" bildirim sayısı.
    let feltReports: Int?
    /// AFAD ilçe bilgisi.
    let district: String?
    /// AFAD ülke bilgisi.
    let country: String?
    /// AFAD revize kaydı mı (ilksel çözüm güncellendi)?
    let revised: Bool
    /// Sağlayıcının olayı son güncellediği zaman.
    let updatedAt: Date?
    /// Sağlayıcının kullanıcıya açık olay sayfası ve makine-okur detay bağlantısı.
    let sourceURL: URL?
    let detailURL: URL?
    /// Kaynakta yayımlanan sismik ağ, olay kodu, olay türü ve katalog bilgisi.
    let network: String?
    let eventCode: String?
    let eventType: String?
    let author: String?
    let catalog: String?
    /// Kaynağın sağladığı kalite/etki parametreleri. Eksik değerler tahmin edilmez.
    let significance: Int?
    let stationCount: Int?
    let minimumDistance: Double?
    let rms: Double?
    let gap: Double?
    let communityIntensity: Double?
    let maximumIntensity: Double?
    let alertLevel: String?

    private static var threadLocalTrFormatter: DateFormatter {
        let key = "Sismik.EarthquakeTrFormatter"
        if let formatter = Thread.current.threadDictionary[key] as? DateFormatter {
            return formatter
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Europe/Istanbul")
        Thread.current.threadDictionary[key] = f
        return f
    }

    enum CodingKeys: String, CodingKey {
        case id, provider, title, magnitude, depth
        case lat, lon, date
        case closestCity, epiCenter
        case magType, status, tsunami, felt, district, country, revised
        case updatedAt, sourceURL, detailURL, network, code, eventType, significance
        case stationCount, minimumDistance, rms, gap, communityIntensity, maximumIntensity
        case alertLevel, author, catalog
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decode(String.self, forKey: .provider)
        title = try c.decode(String.self, forKey: .title)
        magnitude = try c.decode(Double.self, forKey: .magnitude)
        depth = try c.decode(Double.self, forKey: .depth)

        let lat = try c.decode(Double.self, forKey: .lat)
        let lon = try c.decode(Double.self, forKey: .lon)
        coordinate = Coordinate(longitude: lon, latitude: lat)
        clLocation = CLLocation(latitude: lat, longitude: lon)

        let dateString = try c.decode(String.self, forKey: .date)
        // Tahsissiz çözümleyici önce denenir; tanımadığı bir biçim gelirse
        // Foundation formatter'ları yedek olarak devrede kalır. Çözülemez
        // tarih "şimdi" sayılmaz — aksi halde kayıt listenin tepesine çıkar.
        guard let parsedDate = FastISODate.date(from: dateString)
                ?? ISO8601.date(from: dateString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .date,
                in: c,
                debugDescription: "Unparseable earthquake date: \(dateString)"
            )
        }
        date = parsedDate

        let closestCityName = try c.decodeIfPresent(String.self, forKey: .closestCity)
        let epiCenterName = try c.decodeIfPresent(String.self, forKey: .epiCenter)

        magType = try c.decodeIfPresent(String.self, forKey: .magType)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        tsunami = (try c.decodeIfPresent(Bool.self, forKey: .tsunami)) ?? false
        feltReports = try c.decodeIfPresent(Int.self, forKey: .felt)
        district = try c.decodeIfPresent(String.self, forKey: .district)
        country = try c.decodeIfPresent(String.self, forKey: .country)
        revised = (try c.decodeIfPresent(Bool.self, forKey: .revised)) ?? false
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt).flatMap {
            FastISODate.date(from: $0) ?? ISO8601.date(from: $0)
        }
        sourceURL = try c.decodeIfPresent(URL.self, forKey: .sourceURL)
        detailURL = try c.decodeIfPresent(URL.self, forKey: .detailURL)
        network = try c.decodeIfPresent(String.self, forKey: .network)
        eventCode = try c.decodeIfPresent(String.self, forKey: .code)
        eventType = try c.decodeIfPresent(String.self, forKey: .eventType)
        significance = try c.decodeIfPresent(Int.self, forKey: .significance)
        stationCount = try c.decodeIfPresent(Int.self, forKey: .stationCount)
        minimumDistance = try c.decodeIfPresent(Double.self, forKey: .minimumDistance)
        rms = try c.decodeIfPresent(Double.self, forKey: .rms)
        gap = try c.decodeIfPresent(Double.self, forKey: .gap)
        communityIntensity = try c.decodeIfPresent(Double.self, forKey: .communityIntensity)
        maximumIntensity = try c.decodeIfPresent(Double.self, forKey: .maximumIntensity)
        alertLevel = try c.decodeIfPresent(String.self, forKey: .alertLevel)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        catalog = try c.decodeIfPresent(String.self, forKey: .catalog)

        locationProperties = LocationProperties(
            closestCity: closestCityName.map { City(name: $0, cityCode: nil, distance: nil, population: nil) },
            epiCenter: epiCenterName.map { City(name: $0, cityCode: nil, distance: nil, population: nil) },
            closestCities: []
        )

        // Sağlayıcı adı aşağıda üç kez karşılaştırılıyor; her `lowercased()`
        // ayrı bir dize tahsisi demek. Yenileme başına yüzlerce kayıt
        // çözümlendiği için bir kez hesaplanır.
        let normalizedProvider = provider.lowercased()

        // Precompute displayTitle
        displayTitle = Self.displayTitle(for: title, provider: normalizedProvider)

        let style = QuakeProviderStyle(normalizedProvider: normalizedProvider, provider: provider, title: title)
        flag = style.flag
        sourceTag = style.tag
        sourceColor = style.color

        // Precompute magnitudeColor
        magnitudeColor = MagnitudeLevel(magnitude: magnitude).color
        
        // Precompute magnitudeString
        magnitudeString = String(format: "%.1f", magnitude)
    }

    /// Farklı kaynaklardan nesne oluşturmak veya test etmek için.
    init(id: String, provider: String, title: String, magnitude: Double, depth: Double,
         coordinate: Coordinate, date: Date,
         locationProperties: LocationProperties = LocationProperties(),
         magType: String? = nil, status: String? = nil, tsunami: Bool = false,
         feltReports: Int? = nil, district: String? = nil, country: String? = nil,
         revised: Bool = false, updatedAt: Date? = nil, sourceURL: URL? = nil,
         detailURL: URL? = nil, network: String? = nil, eventCode: String? = nil,
         eventType: String? = nil, significance: Int? = nil, stationCount: Int? = nil,
         minimumDistance: Double? = nil, rms: Double? = nil, gap: Double? = nil,
         communityIntensity: Double? = nil, maximumIntensity: Double? = nil,
         alertLevel: String? = nil, author: String? = nil, catalog: String? = nil) {
        self.id = id
        self.provider = provider
        self.title = title
        self.magnitude = magnitude
        self.depth = depth
        self.coordinate = coordinate
        self.clLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        self.date = date
        self.locationProperties = locationProperties
        self.magType = magType
        self.status = status
        self.tsunami = tsunami
        self.feltReports = feltReports
        self.district = district
        self.country = country
        self.revised = revised
        self.updatedAt = updatedAt
        self.sourceURL = sourceURL
        self.detailURL = detailURL
        self.network = network
        self.eventCode = eventCode
        self.eventType = eventType
        self.significance = significance
        self.stationCount = stationCount
        self.minimumDistance = minimumDistance
        self.rms = rms
        self.gap = gap
        self.communityIntensity = communityIntensity
        self.maximumIntensity = maximumIntensity
        self.alertLevel = alertLevel
        self.author = author
        self.catalog = catalog

        // Precompute displayTitle
        self.displayTitle = Self.displayTitle(for: title, provider: provider.lowercased())

        let style = QuakeProviderStyle(normalizedProvider: provider.lowercased(), provider: provider, title: title)
        self.flag = style.flag
        self.sourceTag = style.tag
        self.sourceColor = style.color

        // Precompute magnitudeColor
        self.magnitudeColor = MagnitudeLevel(magnitude: magnitude).color
        
        // Precompute magnitudeString
        self.magnitudeString = String(format: "%.1f", magnitude)
    }


    /// İçerik duyarlı eşitlik: AFAD bir kaydı revize ettiğinde (aynı kimlik,
    /// yeni büyüklük/derinlik) SwiftUI satırı yeniden çizebilsin. Yalnızca
    /// kimlik karşılaştıran eski sürüm, revize değerlerin arayüzde eski
    /// kalmasına neden oluyordu. Hash kimlikte kalır (eşit nesnelerin hash'i
    /// aynı olma kuralı korunur).
    /// Listede gösterilen başlık. AFAD Türkçe büyük harfle, EMSC (Flinn-Engdahl
    /// bölge adları) İngilizce büyük harfle yayımlıyor: "ISLAND OF HAWAII,
    /// HAWAII". Tamamı büyük harf olan başlık okunur biçime çevrilir; karışık
    /// harfli başlığa (USGS "4 km SSE of …") dokunulmaz, kısaltmaları bozmasın.
    nonisolated static func displayTitle(for title: String, provider normalizedProvider: String) -> String {
        if normalizedProvider == "afad" { return title.capitalizedTR }
        guard title.contains(where: \.isLetter), !title.contains(where: \.isLowercase) else { return title }
        let minorWords: Set<String> = ["of", "the", "and", "near", "off", "in"]
        return title
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .split(separator: " ", omittingEmptySubsequences: true)
            .enumerated()
            .map { index, word in
                let text = String(word)
                return index > 0 && minorWords.contains(text) ? text : text.capitalized(with: Locale(identifier: "en_US_POSIX"))
            }
            .joined(separator: " ")
    }

    static func == (lhs: Earthquake, rhs: Earthquake) -> Bool {
        lhs.id == rhs.id
            && lhs.magnitude == rhs.magnitude
            && lhs.depth == rhs.depth
            && lhs.date == rhs.date
            && lhs.title == rhs.title
            && lhs.revised == rhs.revised
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init(id: String, provider: String, title: String, magnitude: Double, depth: Double, coordinate: Coordinate, date: Date) {
        self.id = id
        self.provider = provider
        self.title = title
        self.magnitude = magnitude
        self.depth = depth
        self.coordinate = coordinate
        self.date = date
        self.clLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        let cleanTitle = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Bildirim/paylaşım/büyük olaydan kurulan kayıt da listedekiyle aynı
        // başlığı göstersin (AFAD/EMSC büyük harf düzeltmesi).
        self.displayTitle = Self.displayTitle(for: cleanTitle, provider: provider.lowercased())
        self.flag = "📍"
        let style = QuakeProviderStyle(normalizedProvider: provider.lowercased(), provider: provider, title: cleanTitle)
        self.sourceTag = style.tag
        self.sourceColor = style.color
        self.magnitudeColor = MagnitudeLevel(magnitude: magnitude).color
        self.magnitudeString = magnitude.formatted(.number.precision(.fractionLength(1)))
        self.locationProperties = LocationProperties(closestCity: nil, epiCenter: nil, closestCities: [])

        self.magType = nil
        self.status = nil
        self.tsunami = false
        self.feltReports = nil
        self.district = nil
        self.country = nil
        self.revised = false
        self.updatedAt = nil
        self.sourceURL = nil
        self.detailURL = nil
        self.network = nil
        self.eventCode = nil
        self.eventType = nil
        self.significance = nil
        self.stationCount = nil
        self.minimumDistance = nil
        self.rms = nil
        self.gap = nil
        self.communityIntensity = nil
        self.maximumIntensity = nil
        self.alertLevel = nil
        self.author = nil
        self.catalog = nil
    }
}

struct Coordinate: Hashable {
    let longitude: Double
    let latitude: Double

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Konum Özellikleri

struct LocationProperties: Decodable, Hashable {
    let closestCity: City?
    let epiCenter: City?
    let closestCities: [City]

    init(closestCity: City? = nil, epiCenter: City? = nil, closestCities: [City] = []) {
        self.closestCity = closestCity
        self.epiCenter = epiCenter
        self.closestCities = closestCities
    }
}

struct City: Decodable, Hashable, Identifiable {
    var id: String { "\(name)|\(cityCode ?? 0)|\(distance ?? -1)|\(population ?? -1)" }
    let name: String
    let cityCode: Int?
    let distance: Double?
    let population: Int?
}
