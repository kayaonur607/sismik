import CoreLocation
import Foundation
import Observation

/// Liste başındaki deprem kartının kararı: kullanıcının HİSSETMİŞ OLABİLECEĞİ
/// deprem. Kural herkes için aynı, ülkeye özel eşik yok; kart kullanıcının
/// konumuna, kayıtlı yerlerine ve seçtiği kaynaklara göre çıkar:
///
/// - **Yakınında:** konumunun ya da kayıtlı bir yerinin 30 km yakınında M3.0+
///   (3 saat boyunca).
/// - **Uzakta ama hissedilir:** M5.0+ ve tahmini şiddet konumunda en az MMI 3
///   (Akkar-Bommer + Wald, `SeismicImpactModel`; 12 saat boyunca). Örnek:
///   24 Eyl 2026 Şanlıurfa M5.4 yüzlerce km'de hissedildi.
/// - **Büyük olay** (sunucu: Türkiye M5.5+, dünya M7+, GDACS turuncu/kırmızı):
///   yalnızca kullanıcıya hissedilebilir ise (aynı kural), olay süresince.
///
/// Kart kapatılabilir; kapatılan olay (fiziksel olarak: zaman + konum) bir daha
/// gösterilmez. Büyüklük her zaman listedeki GÜNCEL resmî kayıttan gelir
/// (bölgenin ajansı önce): ilk yayımlanan M5.8, AFAD'ın M5.4'üne revize
/// edilince kart da 5.4 gösterir.
@MainActor
@Observable
final class FeltEventCenter {
    static let shared = FeltEventCenter()

    enum Kind: Equatable {
        case major
        case nearby(distanceKm: Double)
        case felt(distanceKm: Double, mmi: Double)
    }

    struct Card: Equatable {
        /// Olayın güncel resmî kaydı (bölgenin ajansı önce).
        let quake: Earthquake
        let kind: Kind
        /// Olaya en yakın kayıtlı yerin adı; konuma göre ise nil.
        let placeName: String?
        /// Büyük olaysa sunucudaki olay (canlı takip kanalı için).
        let majorEvent: MajorEventCenter.Event?
    }

    private(set) var card: Card?

    // Eşikler uzak yapılandırmadan değiştirilebilir (`felt_card`); her
    // `update` başında bir kez okunur.
    private struct Rules {
        let nearbyRadiusKm: Double
        let nearbyMinMagnitude: Double
        let nearbyWindow: TimeInterval
        let feltMinMagnitude: Double
        let feltMinMMI: Double
        let feltWindow: TimeInterval

        static var current: Rules {
            Rules(
                nearbyRadiusKm: RemoteConfig.number(\.feltCard, "nearby_radius_km", default: 30, in: 5...200),
                nearbyMinMagnitude: RemoteConfig.number(\.feltCard, "nearby_min_magnitude", default: 3, in: 1...7),
                nearbyWindow: RemoteConfig.number(\.feltCard, "nearby_window_hours", default: 3, in: 0.5...48) * 3_600,
                feltMinMagnitude: RemoteConfig.number(\.feltCard, "felt_min_magnitude", default: 5, in: 3...9),
                feltMinMMI: RemoteConfig.number(\.feltCard, "felt_min_mmi", default: 3, in: 2...8),
                feltWindow: RemoteConfig.number(\.feltCard, "felt_window_hours", default: 12, in: 1...72) * 3_600
            )
        }
    }
    private static let dismissedKey = "feltCard.dismissed.v1"

    private struct DismissedEvent: Codable {
        let time: Double
        let lat: Double
        let lon: Double
    }

    private var dismissed: [DismissedEvent]

    private init() {
        let stored = UserDefaults.standard.data(forKey: Self.dismissedKey)
            .flatMap { try? JSONDecoder().decode([DismissedEvent].self, from: $0) } ?? []
        // 3 günden eski kapatma kayıtları gereksiz.
        let cutoff = Date().timeIntervalSince1970 - 3 * 86_400
        dismissed = stored.filter { $0.time >= cutoff }
    }

    var isEnabled: Bool {
        return (UserDefaults.standard.object(forKey: AppPreference.feltCardEnabled) as? Bool ?? true)
            && RemoteConfig.isEnabled(.feltCard)
    }

    /// Liste her yenilendiğinde çağrılır.
    func update(quakes: [Earthquake], enabledSources: Set<String>, now: Date = Date()) {
        guard isEnabled else {
            if card != nil { card = nil }
            return
        }
        let points = referencePoints()
        let rules = Rules.current
        // Kart eşik altına hiç çıkmaz; gruplama yalnızca adaylarla yapılır.
        let recent = quakes.filter {
            $0.magnitude >= rules.nearbyMinMagnitude
                && enabledSources.contains($0.sourceTag) && now.timeIntervalSince($0.date) <= 86_400
        }
        let representatives = Self.physicalEvents(recent)
        let next = majorCard(representatives: representatives, points: points, rules: rules)
            ?? feltCard(representatives: representatives, points: points, rules: rules, now: now)
        if next != card { card = next }
    }

    func dismiss() {
        guard let quake = card?.quake else { return }
        dismissed.append(DismissedEvent(time: quake.date.timeIntervalSince1970,
                                        lat: quake.coordinate.latitude,
                                        lon: quake.coordinate.longitude))
        if let data = try? JSONEncoder().encode(dismissed) {
            UserDefaults.standard.set(data, forKey: Self.dismissedKey)
        }
        card = nil
    }

    // MARK: - Karar

    private struct Point { let location: CLLocation; let name: String? }

    private func referencePoints() -> [Point] {
        var points: [Point] = []
        if let coordinate = LocationManager.cachedCoordinate {
            points.append(Point(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), name: nil))
        }
        for place in NotificationPlacesStore.shared.activePlaces where place.kind == .pinned {
            points.append(Point(location: CLLocation(latitude: place.latitude, longitude: place.longitude), name: place.name))
        }
        return points
    }

    /// Aynı fiziksel depremin ajans kayıtlarından biri: bölgenin resmî ajansı
    /// önce, sonra büyüklük (liste "Tümü" görünümüyle aynı kural).
    private nonisolated static func physicalEvents(_ quakes: [Earthquake]) -> [Earthquake] {
        let ranked = quakes.sorted {
            let lhs = EarthquakeListViewModel.authorityRank($0)
            let rhs = EarthquakeListViewModel.authorityRank($1)
            return lhs != rhs ? lhs < rhs : $0.magnitude > $1.magnitude
        }
        var result: [Earthquake] = []
        for quake in ranked where !result.contains(where: { Self.sameEvent($0, quake) }) {
            result.append(quake)
        }
        return result
    }

    private nonisolated static func sameEvent(_ a: Earthquake, _ b: Earthquake) -> Bool {
        abs(a.date.timeIntervalSince(b.date)) <= 90 && a.clLocation.distance(from: b.clLocation) <= 90_000
    }

    private func isDismissed(_ quake: Earthquake) -> Bool {
        dismissed.contains { item in
            abs(item.time - quake.date.timeIntervalSince1970) <= 120
                && CLLocation(latitude: item.lat, longitude: item.lon).distance(from: quake.clLocation) <= 90_000
        }
    }

    /// Olayın kullanıcıya etkisi: en yakın nokta, uzaklık ve tahmini şiddet.
    private func impact(of quake: Earthquake, points: [Point]) -> (point: Point, distanceKm: Double, mmi: Double)? {
        points.map { point -> (point: Point, distanceKm: Double, mmi: Double) in
            let distanceKm = point.location.distance(from: quake.clLocation) / 1_000
            let mmi = SeismicImpactModel.estimatedMMI(magnitude: quake.magnitude, depthKm: quake.depth, epicentralDistanceKm: distanceKm)
            return (point, distanceKm, mmi)
        }.max { $0.mmi < $1.mmi }
    }

    private func majorCard(representatives: [Earthquake], points: [Point], rules: Rules) -> Card? {
        guard RemoteConfig.isEnabled(.majorEventCard) else { return nil }
        let center = MajorEventCenter.shared
        guard let event = center.event, !event.isExpired else { return nil }
        let quake = representatives.first(where: { center.matches($0) }) ?? event.earthquake
        guard !isDismissed(quake) else { return nil }
        // Büyük olay da yalnızca kullanıcıya hissedilebilir ise çıkar (herkes
        // için aynı kural).
        let effect = impact(of: quake, points: points)
        let felt = effect.map { $0.mmi >= rules.feltMinMMI || $0.distanceKm <= rules.nearbyRadiusKm } ?? false
        guard felt else { return nil }
        return Card(quake: quake, kind: .major, placeName: effect?.point.name, majorEvent: event)
    }

    private func feltCard(representatives: [Earthquake], points: [Point], rules: Rules, now: Date) -> Card? {
        guard !points.isEmpty else { return nil }
        var best: (card: Card, score: Double)?
        for quake in representatives where quake.magnitude >= rules.nearbyMinMagnitude {
            let age = now.timeIntervalSince(quake.date)
            guard age >= 0, let effect = impact(of: quake, points: points) else { continue }
            let kind: Kind
            if effect.distanceKm <= rules.nearbyRadiusKm, age <= rules.nearbyWindow {
                kind = .nearby(distanceKm: effect.distanceKm)
            } else if quake.magnitude >= rules.feltMinMagnitude, effect.mmi >= rules.feltMinMMI, age <= rules.feltWindow {
                kind = .felt(distanceKm: effect.distanceKm, mmi: effect.mmi)
            } else {
                continue
            }
            guard !isDismissed(quake) else { continue }
            // En güçlü hissedilen; eşitlikte en yeni.
            let score = effect.mmi - age / 86_400
            if best == nil || score > best!.score {
                best = (Card(quake: quake, kind: kind, placeName: effect.point.name, majorEvent: nil), score)
            }
        }
        return best?.card
    }
}
