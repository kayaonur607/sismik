import Foundation
import CoreLocation
import Observation

/// Kullanıcının favorilere eklediği yer.
///
/// Kaydın kendisi bir kopya, referans değil: adı, adresi ve koordinatı içinde
/// taşır. Böylece favori, kaynağı (Apple Places / OpenStreetMap / yardım
/// noktası kaydı) erişilemez olduğunda bile eksiksiz kalır — ağ yokken yol
/// tarifi verebilmenin ön koşulu bu.
struct SavedPlace: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var address: String?
    var latitude: Double
    var longitude: Double
    var category: EmergencyPlaceCategory
    var phone: String?
    /// Kullanıcının kendi notu ("3. kapı", "anahtar komşuda" gibi).
    var note: String?
    let savedAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var clLocation: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    init(area: AssemblyArea, note: String? = nil, savedAt: Date = Date()) {
        id = area.id
        name = area.name
        address = area.address
        latitude = area.coordinate.latitude
        longitude = area.coordinate.longitude
        category = area.category
        phone = area.phone
        self.note = note
        self.savedAt = savedAt
    }

    /// Favoriyi haritada/kartta gösterilebilir yer temsiline çevirir.
    func asAssemblyArea(distanceFrom origin: CLLocation?) -> AssemblyArea {
        AssemblyArea(
            id: id,
            name: name,
            address: address,
            coordinate: coordinate,
            category: category,
            distance: origin.map { $0.distance(from: clLocation) },
            phone: phone,
            note: note
        )
    }
}

/// Bir favori ve kullanıcıya olan uzaklığı.
///
/// Uzaklık sıralama sırasında kayıt başına bir kez ölçülür; liste satırı aynı
/// değeri yeniden hesaplamak yerine buradan okur.
struct RankedSavedPlace: Identifiable, Equatable {
    let place: SavedPlace
    /// Konum izni yoksa `nil`.
    let distanceMeters: Double?

    var id: String { place.id }
}

/// Favori yerlerin kalıcı deposu.
///
/// Diskte Application Support altında tutulur (Caches DEĞİL): sistem yer
/// açmak için Caches'i habersizce silebilir ve kullanıcının kaydettiği acil
/// toplanma noktasının bir gün yok olması kabul edilemez. Dosya küçük ve
/// yazma seyrek olduğu için tüm liste tek seferde yazılır.
@MainActor
@Observable
final class SavedPlacesStore {
    static let shared = SavedPlacesStore()

    private(set) var places: [SavedPlace] = []

    /// En fazla bu kadar favori tutulur; üstü sessizce reddedilmez, arayüz
    /// uyarı gösterir.
    static let limit = 60

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    private init() {
        let directory = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = directory.appendingPathComponent("sismik_saved_places.json")
        load()
    }

    // MARK: Sorgular

    func isSaved(_ area: AssemblyArea) -> Bool {
        places.contains { $0.id == area.id }
    }

    func place(withID id: String) -> SavedPlace? {
        places.first { $0.id == id }
    }

    var isFull: Bool { places.count >= Self.limit }

    /// Favorileri kullanıcıya olan uzaklığa göre sıralar; konum yoksa en son
    /// eklenen başa gelir.
    ///
    /// Uzaklık, karşılaştırma gövdesinde değil önceden ölçülür: `clLocation`
    /// her okumada yeni bir `CLLocation` ayırıyor ve `distance(from:)`
    /// jeodezik bir hesap. Karşılaştırma başına iki kez yapmak bu ikisini de
    /// O(n log n) kez tekrarlıyordu; şimdi kayıt başına bir kez ölçülüyor.
    func ranked(from origin: CLLocation?) -> [RankedSavedPlace] {
        guard let origin else {
            return places
                .sorted { $0.savedAt > $1.savedAt }
                .map { RankedSavedPlace(place: $0, distanceMeters: nil) }
        }
        return places
            .map { (place: $0, distance: origin.distance(from: $0.clLocation)) }
            .sorted { $0.distance < $1.distance }
            .map { RankedSavedPlace(place: $0.place, distanceMeters: $0.distance) }
    }

    // MARK: Değişiklikler

    @discardableResult
    func toggle(_ area: AssemblyArea) -> Bool {
        if isSaved(area) {
            remove(id: area.id)
            return false
        }
        add(area)
        return true
    }

    func add(_ area: AssemblyArea) {
        guard !isSaved(area), !isFull else { return }
        places.append(SavedPlace(area: area))
        scheduleSave()
    }

    func remove(id: String) {
        guard let index = places.firstIndex(where: { $0.id == id }) else { return }
        places.remove(at: index)
        scheduleSave()
    }

    func updateNote(id: String, note: String?) {
        guard let index = places.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        places[index].note = (trimmed?.isEmpty == false) ? trimmed : nil
        scheduleSave()
    }

    // MARK: Kalıcılık

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        places = (try? decoder.decode([SavedPlace].self, from: data)) ?? []
    }

    /// Yazma bir tur ertelenir: bir favoriyi eklerken not ve isim düzenlemesi
    /// arka arkaya gelebiliyor, üç ayrı disk yazımı yapmanın anlamı yok.
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = places
        let url = fileURL
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot, to: url)
            self?.saveTask = nil
        }
    }

    private static func write(_ places: [SavedPlace], to url: URL) async {
        await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            guard let data = try? encoder.encode(places) else { return }
            try? data.write(to: url, options: .atomic)
        }.value
    }
}
