import CoreLocation
import Foundation
import Observation

/// Deprem anı modu: kullanıcının konumuna ya da kayıtlı bir yerine yakın
/// güçlü bir deprem olduysa uygulama açılışta listeyi değil, o an gereken
/// ekranı gösterir (bkz. `QuakeResponseView`).
///
/// Karar tamamen cihazda, eldeki listeyle verilir; ağ gerekmez. Aynı deprem
/// bir kez gösterilir (kapatılan kimlikler saklanır) ve yakın zamanda
/// gösterilmiş bir olayın ajans kopyası ikinci kez açılmaz.
@MainActor
@Observable
final class StrongQuakeMonitor {
    static let shared = StrongQuakeMonitor()

    struct Event: Identifiable, Equatable {
        let quake: Earthquake
        /// Kullanıcıya ya da yerlerinden birine uzaklık.
        let distanceKm: Double
        /// Mesafenin ölçüldüğü yerin adı; `nil` = kullanıcının bulunduğu konum.
        let placeName: String?
        var id: String { quake.id }

        static func == (lhs: Event, rhs: Event) -> Bool { lhs.id == rhs.id }
    }

    /// Gösterilecek olay (tam ekran açılır).
    var active: Event?

    // Eşikler uzak yapılandırmadan değiştirilebilir (`strong_quake`).
    static var minimumMagnitude: Double {
        RemoteConfig.number(\.strongQuake, "min_magnitude", default: 5.0, in: 3...9)
    }
    static var maximumDistanceKm: Double {
        RemoteConfig.number(\.strongQuake, "max_distance_km", default: 200, in: 10...1000)
    }
    /// Olaydan bu kadar sonra açılışta artık "deprem anı" sayılmaz.
    static var maximumAge: TimeInterval {
        RemoteConfig.number(\.strongQuake, "max_age_hours", default: 3, in: 0.25...24) * 3_600
    }

    private static let shownKey = "strongQuake.shownIDs"
    private static let lastShownKey = "strongQuake.lastShownAt"
    private static let lastShownCoordinateKey = "strongQuake.lastShownCoordinate"

    private init() {}

    /// Liste yenilendiğinde çağrılır.
    func evaluate(_ quakes: [Earthquake], now: Date = Date()) {
        guard active == nil, RemoteConfig.isEnabled(.strongQuakeScreen) else { return }
        let defaults = UserDefaults.standard
        let minimumMagnitude = Self.minimumMagnitude
        let maximumAge = Self.maximumAge
        let maximumDistanceKm = Self.maximumDistanceKm
        let shown = Set(defaults.stringArray(forKey: Self.shownKey) ?? [])
        let references = referencePoints()
        guard !references.isEmpty else { return }

        let candidates = quakes.filter {
            $0.magnitude >= minimumMagnitude
                && now.timeIntervalSince($0.date) <= maximumAge
                && $0.date <= now.addingTimeInterval(60)
                && !shown.contains($0.id)
        }
        .sorted { $0.magnitude > $1.magnitude }

        for quake in candidates {
            guard let nearest = references
                .map({ (name: $0.name, distanceKm: $0.location.distance(from: quake.clLocation) / 1_000) })
                .min(by: { $0.distanceKm < $1.distanceKm }),
                  nearest.distanceKm <= maximumDistanceKm else { continue }
            // Aynı fiziksel olayın başka ajans kaydı: az önce gösterilen olaya
            // 90 sn / 90 km içindeyse yeniden açılmaz.
            if isDuplicateOfLastShown(quake) {
                markShown(quake)
                continue
            }
            // Yapılacaklar listesi her yeni olayda baştan başlar.
            defaults.removeObject(forKey: "response.checked")
            active = Event(quake: quake, distanceKm: nearest.distanceKm, placeName: nearest.name)
            markShown(quake)
            return
        }
    }

    func dismiss() {
        active = nil
    }

    private func referencePoints() -> [(name: String?, location: CLLocation)] {
        var points: [(name: String?, location: CLLocation)] = []
        if let coordinate = LocationManager.cachedCoordinate {
            points.append((nil, CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)))
        }
        for place in NotificationPlacesStore.shared.places where place.enabled && place.hasValidCoordinate && place.kind != .current {
            points.append((place.name, CLLocation(latitude: place.latitude, longitude: place.longitude)))
        }
        return points
    }

    private func isDuplicateOfLastShown(_ quake: Earthquake) -> Bool {
        let defaults = UserDefaults.standard
        let lastAt = defaults.double(forKey: Self.lastShownKey)
        guard lastAt > 0, let stored = defaults.array(forKey: Self.lastShownCoordinateKey) as? [Double], stored.count == 2 else {
            return false
        }
        let last = CLLocation(latitude: stored[0], longitude: stored[1])
        return abs(quake.date.timeIntervalSince1970 - lastAt) <= 90
            && last.distance(from: quake.clLocation) <= 90_000
    }

    private func markShown(_ quake: Earthquake) {
        let defaults = UserDefaults.standard
        var shown = defaults.stringArray(forKey: Self.shownKey) ?? []
        shown.append(quake.id)
        defaults.set(Array(shown.suffix(50)), forKey: Self.shownKey)
        defaults.set(quake.date.timeIntervalSince1970, forKey: Self.lastShownKey)
        defaults.set([quake.clLocation.coordinate.latitude, quake.clLocation.coordinate.longitude], forKey: Self.lastShownCoordinateKey)
    }
}
