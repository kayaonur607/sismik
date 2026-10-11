import Foundation
import CoreLocation
import Observation

/// Takip edilen bildirim yerlerinin kalıcı deposu.
///
/// Yerler Keychain'de durur ve her değişiklikte sunucu kaydını debounce ile
/// tazeler — `NotificationSettings` deseninin aynısı.
@MainActor
@Observable
final class NotificationPlacesStore {
    static let shared = NotificationPlacesStore()

    /// Sekiz yer: cihaz belgesinde ~1,2 KB eder (1 MiB sınırının binde üçü).
    /// Dakikalık push görevinde maliyet yer sayısıyla doğrusal büyüyor ama
    /// kontrollerin ~%95'i haversine'a hiç girmeden derece bazlı sınırda
    /// eleniyor: 35 bin premium cihazda tur başına ~20 ms (bkz. spec §7).
    static let premiumLimit = 8
    /// Ücretsiz katman tek yer takip eder (sunucu `FREE_PLACE_LIMIT`). Premium
    /// bitince fazladan yerler silinmez: sunucu yalnızca ilkini kullanır,
    /// yeniden abone olunca hepsi geri gelir.
    static let freeLimit = 1
    static var limit: Int { PremiumStore.shared.isPremium ? premiumLimit : freeLimit }

    private enum Key {
        /// Eski konum: UserDefaults. Yalnızca Keychain'e taşımak için okunur.
        static let legacyPlaces = "notif.places"
        /// V1 eski kuralı yer listesine çeviriyordu; V2 çevirmez, eski kuralı
        /// kullanıcı ilk yerini kaydedene kadar olduğu gibi işletir.
        static let rulesMigrated = "notif.rulesMigratedV2"
        static let legacyRulesActive = "notif.legacyRulesActive"
        /// Göç configure() sırasında da çalışır; uyarı kartı ilk liste
        /// görünümüne kadar bekletilir.
        static let noticePending = "notif.placesMigratedNoticePending"
        /// Bildirim izni verildi ama konum henüz yoktu: ilk konumda
        /// "Bulunduğum yer" kendiliğinden eklenir.
        static let pendingCurrentPlace = "notif.pendingCurrentPlace"
        /// Kendiliğinden eklenen yer için liste başındaki bilgi kartı.
        static let autoPlaceNotice = "notif.autoPlaceNoticePending"
    }

    /// Yerler Keychain'de saklanır: UserDefaults uygulama silindiğinde gider,
    /// Keychain kaydı kurulumlar arasında yaşar. Kullanıcı uygulamayı silip
    /// yeniden kurduğunda takip ettiği yerleri yeniden kurmak zorunda kalmaz.
    private static let keychainService = "com.kayasoftware.sismik.notifications"
    private static let keychainAccount = "places"

    private(set) var places: [NotificationPlace] = [] {
        didSet {
            guard places != oldValue else { return }
            persist()
            NotificationManager.shared.schedulePushSync()
            // "Bulunduğum yer" eklenip çıkarılınca arka plan izlemesi de uyar.
            SignificantLocationService.shared.refresh()
        }
    }

    /// 2.0.9 ve öncesinden güncelleyen kullanıcı, ilk yerini kaydedene kadar
    /// eski kuralında (kaynak + eşik + isteğe bağlı yarıçap) kalır.
    ///
    /// Eski kural yer listesine çevrilemiyor: kullanıcıların çoğu "tüm
    /// bölgeler" ayarında ve koordinat paylaşmamış. Çeviri, onları haber
    /// vermeden bildirimsiz bırakırdı. Bu modda istemci sunucuya eski alanları
    /// göndermeye devam eder; kullanıcı ilk yerini kaydettiğinde yer modeline
    /// geçilir ve bir daha geri dönülmez.
    private(set) var usesLegacyRules: Bool {
        didSet {
            guard usesLegacyRules != oldValue else { return }
            UserDefaults.standard.set(usesLegacyRules, forKey: Key.legacyRulesActive)
            NotificationManager.shared.schedulePushSync()
        }
    }

    /// "Bulunduğum yer" kendiliğinden eklendi ve kullanıcı henüz bilgi kartını
    /// kapatmadı: listede ne takip edildiği ve nasıl değiştirileceği yazar.
    private(set) var showsAutoPlaceNotice: Bool {
        didSet { UserDefaults.standard.set(showsAutoPlaceNotice, forKey: Key.autoPlaceNotice) }
    }

    private init() {
        places = Self.load()
        usesLegacyRules = UserDefaults.standard.bool(forKey: Key.legacyRulesActive)
        showsAutoPlaceNotice = UserDefaults.standard.bool(forKey: Key.autoPlaceNotice)
    }

    /// Kendiliğinden eklenen "Bulunduğum yer" (bilgi kartı için).
    var autoCreatedPlace: NotificationPlace? {
        showsAutoPlaceNotice ? places.first { $0.kind == .current } : nil
    }

    func dismissAutoPlaceNotice() {
        showsAutoPlaceNotice = false
    }

    // MARK: - Sorgular

    var isFull: Bool { places.count >= Self.limit }

    /// Kayıtlı yerler ücretsiz sınırı aşıyor mu (premium'dan kalma)?
    var exceedsFreeLimits: Bool {
        places.count > Self.freeLimit
            || places.prefix(Self.freeLimit).contains { $0.radiusKm > NotificationPlace.freeMaxRadiusKm }
    }

    /// Sunucuya gidecek ve bildirim üretebilecek yerler.
    var activePlaces: [NotificationPlace] { places.filter(\.isActive) }

    /// Bildirimler açık ama tek bir etkin yer yoksa kullanıcı sessizce
    /// bildirimsiz kalır. Arayüz bu durumu kapatılamaz bir uyarı şeridiyle
    /// görünür kılar.
    var hasNoActivePlace: Bool { activePlaces.isEmpty }

    /// Yeni yer için ilk boş simge. İlk yer "Ev" ile açılır; simgeler
    /// benzersiz olduğu için başka yerde kullanılan simge önerilmez.
    func nextFreeIcon(excluding placeID: String? = nil) -> PlaceIcon {
        let used = Set(places.filter { $0.id != placeID }.map(\.icon))
        return PlaceIcon.allCases.first { !used.contains($0) } ?? .other
    }

    func usedIcons(excluding placeID: String? = nil) -> Set<PlaceIcon> {
        Set(places.filter { $0.id != placeID }.map(\.icon))
    }

    // MARK: - Düzenleme

    @discardableResult
    func add(_ place: NotificationPlace) -> Bool {
        guard !isFull else { return false }
        places.append(place)
        // İlk yer kaydı, yer modeline geçişin tek tetikleyicisi.
        if usesLegacyRules { finishLegacyRules() }
        return true
    }

    /// Bildirimleri ilk kez açan (ya da onboarding'de izin veren) kullanıcının
    /// hiç yeri yoksa bulunduğu konumu ilk yer olarak ekler: "Bulunduğum yer"
    /// cihazla birlikte hareket eder. Yarıçap ücretsiz sınırdır (50 km), eşik
    /// M3.0 (genellikle hissedilen). Konum henüz yoksa hiçbir şey eklenmez;
    /// boş durum kartı kullanıcıyı yer eklemeye yönlendirir.
    func addCurrentLocationPlaceIfEmpty() {
        guard places.isEmpty, !usesLegacyRules else { return }
        guard let coordinate = LocationManager.cachedCoordinate else {
            // Konum izni henüz verilmedi ya da ilk konum gelmedi: ilk konumda
            // (`refreshCurrentLocation`) eklenir.
            UserDefaults.standard.set(true, forKey: Key.pendingCurrentPlace)
            return
        }
        addCurrentLocationPlace(at: coordinate)
    }

    private func addCurrentLocationPlace(at coordinate: CLLocationCoordinate2D) {
        UserDefaults.standard.removeObject(forKey: Key.pendingCurrentPlace)
        guard places.isEmpty, !usesLegacyRules else { return }
        let added = add(NotificationPlace(
            name: "",
            icon: nextFreeIcon(),
            kind: .current,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusKm: NotificationPlace.freeMaxRadiusKm,
            minMagnitude: 3.0
        ))
        if added { showsAutoPlaceNotice = true }
    }

    func update(_ place: NotificationPlace) {
        guard let index = places.firstIndex(where: { $0.id == place.id }) else { return }
        places[index] = place
    }

    func remove(id: String) {
        places.removeAll { $0.id == id }
    }

    func remove(atOffsets offsets: IndexSet) {
        places.remove(atOffsets: offsets)
    }

    /// Cihaz konumu değiştiğinde "Bulunduğum yer" kaydının koordinatını
    /// tazeler. `LocationManager` bunu yalnızca 1 km'den fazla hareket
    /// olduğunda çağırır; gereksiz sunucu yazımı üretmemek için burada da
    /// değişiklik kontrolü yapılır (`places` didSet zaten eşitse atlar).
    func refreshCurrentLocation(_ coordinate: CLLocationCoordinate2D) {
        // Eski kuraldaki yakınlık filtresi de konumu kullanıyor. Yük kayıtlı
        // olanla aynıysa (yakınlık kapalı) `NotificationManager` istek atmaz.
        if usesLegacyRules {
            NotificationManager.shared.schedulePushSync()
            return
        }
        // Bildirim izni konumdan önce verildiyse ilk konumda yer eklenir.
        if UserDefaults.standard.bool(forKey: Key.pendingCurrentPlace) {
            addCurrentLocationPlace(at: coordinate)
            return
        }
        guard let index = places.firstIndex(where: { $0.kind == .current }) else { return }
        var updated = places[index]
        guard updated.latitude != coordinate.latitude || updated.longitude != coordinate.longitude else { return }
        // Yarıçapın %10'undan küçük hareket bildirim kapsamını anlamlı
        // değiştirmez; her küçük hareket sunucuda kayıt yazımı ve push
        // önbelleği tazelemesi demekti. 50 km'lik ücretsiz yerde eşik 5 km.
        let moved = CLLocation(latitude: updated.latitude, longitude: updated.longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        guard moved >= max(1_000, updated.radiusKm * 100) else { return }
        updated.latitude = coordinate.latitude
        updated.longitude = coordinate.longitude
        places[index] = updated
    }

    // MARK: - Kalıcılık

    private func persist() {
        guard let data = try? JSONEncoder().encode(places) else { return }
        KeychainStore.write(data, service: Self.keychainService, account: Self.keychainAccount)
    }

    private static func load() -> [NotificationPlace] {
        if let data = KeychainStore.read(service: keychainService, account: keychainAccount),
           let decoded = try? JSONDecoder().decode([NotificationPlace].self, from: data) {
            return Array(decoded.prefix(limit))
        }
        // UserDefaults'ta kalmış kayıt varsa Keychain'e taşı (tek seferlik).
        guard let legacy = UserDefaults.standard.data(forKey: Key.legacyPlaces),
              let decoded = try? JSONDecoder().decode([NotificationPlace].self, from: legacy) else {
            return []
        }
        let migrated = Array(decoded.prefix(limit))
        if let data = try? JSONEncoder().encode(migrated) {
            KeychainStore.write(data, service: keychainService, account: keychainAccount)
        }
        UserDefaults.standard.removeObject(forKey: Key.legacyPlaces)
        return migrated
    }

    // MARK: - Göç

    /// Sürüm yükseltmesinde bir kez çalışır.
    ///
    /// Bildirimleri açık olan ve henüz yeri olmayan kullanıcı eski kuralında
    /// kalır (`usesLegacyRules`); hiçbir şey çevrilmez, hiçbir bildirim
    /// kaybolmaz. Keychain'den yer geldiyse (yeniden kurulum) ya da kullanıcı
    /// bildirimleri hiç açmamışsa taşınacak bir kural yoktur.
    ///
    /// Geriye, "bildirimler değişti" uyarısının gösterilip gösterilmeyeceğini
    /// döndürür. Göç `configure()` sırasında da çalıştığı için bayrak ayrıca
    /// saklanır; uyarı ilk liste görünümüne kadar bekler.
    @discardableResult
    func migrateLegacySettingsIfNeeded() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Key.rulesMigrated) {
            return defaults.bool(forKey: Key.noticePending)
        }
        defaults.set(true, forKey: Key.rulesMigrated)
        guard places.isEmpty,
              defaults.bool(forKey: NotificationManager.Key.enabled) else { return false }
        usesLegacyRules = true
        defaults.set(true, forKey: Key.noticePending)
        return true
    }

    func acknowledgeMigrationNotice() {
        UserDefaults.standard.set(false, forKey: Key.noticePending)
    }

    /// Eski kuraldan yer modeline geçer ve eski kuralın artık okunmayacak
    /// ayarlarını siler. `majorThreshold` kalır: ön planda hangi büyüklükte
    /// banner gösterileceğini hâlâ o belirliyor.
    private func finishLegacyRules() {
        usesLegacyRules = false
        let defaults = UserDefaults.standard
        for key in LegacyRules.storageKeys { defaults.removeObject(forKey: key) }
    }

    /// Eski kuralın ayarları — sunucu kaydı, ayar ekranındaki özet ve yerel
    /// yedek bildirim filtresi bunları okur. Değerler 2.0.9'un kaydettiği
    /// UserDefaults anahtarlarından gelir.
    struct LegacyRules: Sendable {
        let source: String
        let minMagnitude: Double
        let majorThreshold: Double
        let nearbyOnly: Bool
        let radiusKm: Double
        let minimumEstimatedMMI: Double

        static let storageKeys = [
            NotificationManager.Key.source,
            NotificationManager.Key.minMagnitude,
            NotificationManager.Key.nearbyOnly,
            NotificationManager.Key.radius,
            NotificationManager.Key.minimumEstimatedMMI
        ]

        static func stored(in defaults: UserDefaults = .standard) -> LegacyRules {
            let rawSource = (defaults.string(forKey: NotificationManager.Key.source) ?? "afad").lowercased()
            return LegacyRules(
                // 2.0.9 "all" değerini sunucuya AFAD olarak gönderiyordu.
                source: rawSource == "all" ? "afad" : rawSource,
                minMagnitude: defaults.double(forKey: NotificationManager.Key.minMagnitude),
                majorThreshold: defaults.double(forKey: NotificationManager.Key.majorThreshold),
                nearbyOnly: defaults.bool(forKey: NotificationManager.Key.nearbyOnly),
                radiusKm: defaults.double(forKey: NotificationManager.Key.radius),
                minimumEstimatedMMI: defaults.double(forKey: NotificationManager.Key.minimumEstimatedMMI)
            )
        }

        /// Kayıtlı ayarları yeni bir yerin başlangıç değerlerine taşır:
        /// yakınlık kullanan kullanıcı aynı yarıçap ve eşikle başlar.
        func draftPlace(at coordinate: CLLocationCoordinate2D?, icon: PlaceIcon) -> NotificationPlace {
            NotificationPlace(
                name: "",
                icon: icon,
                kind: .current,
                latitude: coordinate?.latitude ?? 39.0,
                longitude: coordinate?.longitude ?? 35.0,
                radiusKm: nearbyOnly
                    ? min(NotificationPlace.maxRadiusKm, max(NotificationPlace.minRadiusKm, radiusKm))
                    : 100,
                minMagnitude: min(9, max(1, minMagnitude))
            )
        }
    }

    // MARK: - Beklenen bildirim sayısı

    /// Verilen ayarla, elimizdeki arşivde kaç bildirim üretileceğini sayar.
    ///
    /// Kullanıcı M1.0 + 1000 km seçip bildirim yağmuruna tutulmadan ÖNCE
    /// sonucu görebilsin diye. Tamamen istemci içi: uygulama zaten 34 günlük
    /// harita arşivini tutuyor, ek istek yok.
    /// Son dönemde bu kurala uyan depremler (ajans kopyaları tek).
    nonisolated static func matchedQuakes(
        for place: NotificationPlace,
        in quakes: [Earthquake],
        since: Date
    ) -> [Earthquake] {
        AftershockSequence.deduplicatedAgencyCopies(quakes.filter { $0.date >= since })
            .filter { place.match($0) != nil }
    }

    nonisolated static func estimatedNotificationCount(
        for place: NotificationPlace,
        in quakes: [Earthquake],
        since: Date
    ) -> Int {
        // Aynı depremin ajans kopyaları tek sayılır (AFAD, Kandilli, EMSC…):
        // eskiden her kopya ayrı bildirim sayılıyordu.
        AftershockSequence.deduplicatedAgencyCopies(quakes.filter { $0.date >= since })
            .reduce(into: 0) { total, quake in
                if place.match(quake) != nil { total += 1 }
            }
    }
}
