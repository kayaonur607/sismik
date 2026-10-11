import Foundation
import MapKit

// MARK: - Google Places API Response Models

struct GooglePlacesResponse: Decodable {
    struct Result: Decodable {
        struct Geometry: Decodable {
            struct Location: Decodable {
                let lat: Double
                let lng: Double
            }
            let location: Location
        }
        let name: String
        let vicinity: String?
        let place_id: String
        let geometry: Geometry
    }
    let results: [Result]
    let status: String
}

struct OpenStreetMapResponse: Decodable {
    struct Element: Decodable {
        struct Center: Decodable {
            let lat: Double
            let lon: Double
        }

        let type: String
        let id: Int64
        let lat: Double?
        let lon: Double?
        let center: Center?
        let tags: [String: String]?

        var coordinate: CLLocationCoordinate2D? {
            if let lat, let lon {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            if let center {
                return CLLocationCoordinate2D(latitude: center.lat, longitude: center.lon)
            }
            return nil
        }
    }

    let elements: [Element]
}

// MARK: - Kalıcı çevrimdışı önbellek

actor SafetyPlaceDiskCache {
    private struct CachedPlace: Codable {
        let id: String
        let name: String
        let address: String?
        let latitude: Double
        let longitude: Double
        let category: EmergencyPlaceCategory
        let savedAt: Date

        init(area: AssemblyArea, savedAt: Date = Date()) {
            id = area.id
            name = area.name
            address = area.address
            latitude = area.coordinate.latitude
            longitude = area.coordinate.longitude
            category = area.category
            self.savedAt = savedAt
        }

        var area: AssemblyArea {
            AssemblyArea(
                id: id,
                name: name,
                address: address,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                category: category,
                distance: nil
            )
        }
    }

    private let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    private let maximumEntryCount = 5_000
    private var entries: [CachedPlace]?
    /// `save`'in her çağrıda tüm diziden yeniden Dictionary kurmaması için
    /// kalıcı, kimlikle indekslenmiş çalışma kopyası — yalnızca ilk erişimde
    /// diskten doldurulur, sonrasında yeni/değişen kayıtlarla artımlı güncellenir.
    private var entriesByID: [String: CachedPlace]?

    func load(near center: CLLocationCoordinate2D,
              radius: CLLocationDistance,
              categories: Set<EmergencyPlaceCategory>) -> [AssemblyArea] {
        let now = Date()
        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let validEntries = loadedEntries().filter {
            now.timeIntervalSince($0.savedAt) < maximumAge
        }
        entries = validEntries

        return validEntries.lazy.filter { categories.contains($0.category) }.compactMap { cached in
            let area = cached.area
            guard centerLocation.distance(from: area.clLocation) <= radius else { return nil }
            return area
        }
    }

    func save(_ areas: [AssemblyArea]) {
        guard !areas.isEmpty else { return }
        let now = Date()
        if entriesByID == nil {
            entriesByID = Dictionary(uniqueKeysWithValues: loadedEntries().map { ($0.id, $0) })
        }
        for area in areas { entriesByID?[area.id] = CachedPlace(area: area, savedAt: now) }
        guard let merged = entriesByID else { return }

        let fresh = Array(
            merged.values
                .filter { now.timeIntervalSince($0.savedAt) < maximumAge }
                .sorted { $0.savedAt > $1.savedAt }
                .prefix(maximumEntryCount)
        )
        entries = fresh
        entriesByID = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        persist()
    }

    private func loadedEntries() -> [CachedPlace] {
        if let entries { return entries }
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([CachedPlace].self, from: data) else {
            entries = []
            return []
        }
        entries = decoded
        return decoded
    }

    private func persist() {
        guard let entries,
              let data = try? JSONEncoder().encode(entries) else { return }
        let folder = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Sismik", isDirectory: true)
            .appendingPathComponent("nearby-safety-places.json")
    }
}
