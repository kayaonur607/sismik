import Foundation
@preconcurrency import ActivityKit
import SwiftUI

// ÖNEMLİ: Bu öznitelik tanımı SismikWidget/AftershockLiveActivity.swift
// içindekiyle BİREBİR AYNI tutulmalıdır (ActivityKit eşleştirmesi tip adı ve
// Codable şemasıyla yapılır; iki hedef aynı dosyayı paylaşmadığı için kopya).
struct AftershockActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var aftershockCount: Int
        var maxAftershockMagnitude: Double
        var lastMagnitude: Double
        var lastTitle: String
        var lastDate: Date
        var updatedAt: Date
        /// Önümüzdeki 24 saatte en az bir `forecastMagnitude`+ artçı olasılığı
        /// (0...1, `AftershockForecast`). İsteğe bağlı: eski sürümün başlattığı
        /// etkinliğin durumu bu alanlar olmadan da çözülür.
        var forecastProbability: Double?
        var forecastMagnitude: Double?
    }

    var mainshockID: String
    var regionTitle: String
    var mainshockMagnitude: Double
    var mainshockDate: Date
    var latitude: Double
    var longitude: Double
}

private struct PersistedAftershockWatch: Codable, Equatable {
    let mainshockID: String
    let title: String
    let magnitude: Double
    let latitude: Double
    let longitude: Double
    let startedAt: Date
    let expiresAt: Date
    let radiusKm: Double
    let minimumMagnitude: Double
    /// Büyük olayın APNs yayın kanalı (2.1.4+). Doluysa etkinliği sunucu
    /// günceller; uygulama yerel güncelleme yapmaz. Eski kayıtta alan yok.
    var channelID: String?
    /// Ana şokun kaynağı ve derinliği (2.1.5+): yeniden başlatmada ana şok
    /// kaydı ortak artçı kuralı için yeniden kurulur.
    var provider: String?
    var depth: Double?
    /// Kullanıcı etkinliği kilit ekranından kaydırıp kapattı: takip (sunucu
    /// artçı bildirimi) sürer ama Canlı Etkinlik yeniden açılmaz.
    var dismissedByUser: Bool?
}

/// Artçı deprem Canlı Etkinliği: büyük bir depremin artçılarını kilit ekranı
/// + Dynamic Island üzerinde takip eder.
///
/// İki kip var:
/// - Büyük olay (herkese açık): etkinlik olayın APNs yayın kanalına abone
///   başlar; artçı sayısı, en büyük artçı ve olasılık sunucudan tek yayınla
///   gelir (functions/src/live-activity.ts). Uygulama kapalıyken de güncellenir.
/// - Diğer depremler (Premium): uygulama veri yeniledikçe yerel güncellenir.
///
/// Artçılar detay ekranı ve büyük olay kartıyla AYNI kuralla sayılır
/// (`AftershockSequence`: Gardner–Knopoff alanı, ajans kopyaları tek). Eskiden
/// sabit 150 km çember ve ajans kopyalarıyla sayılıyor, aynı artçı AFAD +
/// Kandilli + EMSC'den üç kez geliyordu; ada detaydakinden farklı sayı
/// gösteriyordu.
///
/// Sistem bir Canlı Etkinliği en fazla ~8 saat açık tutar. Takip süresi
/// dolmadıysa uygulama ön plana geldiğinde etkinlik yeniden kurulur (yalnızca
/// kullanıcı kendisi kapatmadıysa).
@MainActor
@Observable
final class AftershockTracker {
    static let shared = AftershockTracker()

    private(set) var trackedMainshockID: String?
    private var activity: Activity<AftershockActivityAttributes>?
    private var mainshockQuake: Earthquake?
    private var persistedWatch: PersistedAftershockWatch?
    /// Ortak kuralla seçilmiş artçılar (katalog + canlı liste birikimi).
    private var knownAftershocks: [Earthquake] = []
    private var lastCatalogRefresh: Date = .distantPast
    private var catalogTask: Task<Void, Never>?
    private var stateObservation: Task<Void, Never>?
    private var lastPublishedState: AftershockActivityAttributes.ContentState?
    private var lastPublishedAt: Date = .distantPast

    /// Sunucu artçı bildirimi yarıçapı (bildirim kapsamı; sayım değil).
    private static let notificationRadiusKm: Double = 150
    /// Takip, BAŞLATMA anından itibaren sürer: eskiden ana şok zamanından
    /// sayılıyordu ve 24 saatten eski bir depremde başlatılan etkinlik ilk
    /// veri yenilemesinde "süresi doldu" diye kapanıyordu.
    private static let trackingWindow: TimeInterval = 24 * 3_600
    /// Sunucu kataloğundan (merkeze özel sorgu) tazeleme aralığı.
    private static let catalogRefreshInterval: TimeInterval = 120
    /// Olasılık zamanla azalır; içerik değişmese de en geç bu aralıkla yenilenir.
    private static let forecastRefreshInterval: TimeInterval = 15 * 60
    private static let staleInterval: TimeInterval = 3 * 3_600
    private static let storageKey = "notif.aftershockWatch.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let watch = try? JSONDecoder().decode(PersistedAftershockWatch.self, from: data),
           watch.expiresAt > Date() {
            persistedWatch = watch
            trackedMainshockID = watch.mainshockID
            mainshockQuake = Self.mainshock(from: watch)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        }
    }

    /// Push kayıt isteğine eklenen, JSON uyumlu ve süreli artçı takip kuralı.
    var registrationPayload: [String: Any]? {
        guard let watch = persistedWatch, watch.expiresAt > Date() else { return nil }
        return [
            "mainshockId": watch.mainshockID,
            "title": watch.title,
            "magnitude": watch.magnitude,
            "latitude": watch.latitude,
            "longitude": watch.longitude,
            "startedAt": Int(watch.startedAt.timeIntervalSince1970 * 1_000),
            "expiresAt": Int(watch.expiresAt.timeIntervalSince1970 * 1_000),
            "radiusKm": watch.radiusKm,
            "minimumMagnitude": watch.minimumMagnitude
        ]
    }

    var activitiesEnabled: Bool {
        // Uzak yapılandırmayla kapatılabilir (`features.live_activity`).
        ActivityAuthorizationInfo().areActivitiesEnabled && RemoteConfigCenter.shared.config.isEnabled(.liveActivity)
    }

    func isTracking(_ quakeID: String) -> Bool {
        trackedMainshockID == quakeID
    }

    /// Etkinliği sunucu yayın kanalından mı güncelleniyor?
    var isChannelBacked: Bool { persistedWatch?.channelID != nil }

    /// Uygulama açılışında, sistemde yaşamaya devam eden etkinliğe yeniden bağlanır.
    func restore() {
        guard activity == nil else { return }
        let live = Activity<AftershockActivityAttributes>.activities
        let usable = live.filter { $0.activityState == .active || $0.activityState == .stale }

        guard let watch = persistedWatch, watch.expiresAt > Date() else {
            // Takip yok ya da süresi doldu: kalan etkinlikler toparlanır.
            if persistedWatch != nil { clearPersistedWatch() }
            trackedMainshockID = nil
            mainshockQuake = nil
            for leftover in live { Task { await leftover.end(nil, dismissalPolicy: .immediate) } }
            return
        }

        // Aynı ana şoka ait canlı etkinliğe bağlan; kopyaları ve başka ana
        // şoka ait artıkları kapat (aynı anda tek etkinlik).
        let match = usable.first { $0.attributes.mainshockID == watch.mainshockID }
        for leftover in live where leftover.id != match?.id {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
        if let match {
            attach(match)
            lastPublishedState = match.content.state
        }
    }

    /// Verilen ana şok için takip başlatır (aynı anda tek etkinlik).
    /// `channelID` verilirse etkinlik büyük olayın yayın kanalına abone olur ve
    /// `expiresAt`e kadar sunucudan güncellenir.
    func start(for quake: Earthquake, channelID: String? = nil, expiresAt: Date? = nil) async {
        await endActivity()

        let expiry = expiresAt ?? Date().addingTimeInterval(Self.trackingWindow)
        saveWatch(PersistedAftershockWatch(
            mainshockID: quake.id,
            title: quake.displayTitle,
            magnitude: quake.magnitude,
            latitude: quake.coordinate.latitude,
            longitude: quake.coordinate.longitude,
            startedAt: quake.date,
            expiresAt: expiry,
            radiusKm: Self.notificationRadiusKm,
            minimumMagnitude: 2.5,
            channelID: channelID,
            provider: quake.provider,
            depth: quake.depth,
            dismissedByUser: false
        ))
        mainshockQuake = quake
        knownAftershocks = []
        lastCatalogRefresh = .distantPast
        NotificationManager.shared.schedulePushSync(force: true)

        // Canlı Etkinlik kapalı olsa bile sunucu tarafındaki artçı bildirimi
        // devam eder; yalnızca Kilit Ekranı yüzeyi oluşturulmaz.
        requestActivity(state: makeState(aftershocks: []))
        refreshCatalog()
    }

    func stop() async {
        trackedMainshockID = nil
        mainshockQuake = nil
        knownAftershocks = []
        catalogTask?.cancel()
        catalogTask = nil
        clearPersistedWatch()
        NotificationManager.shared.schedulePushSync(force: true)
        await endActivity()
    }

    /// Her veri yenilemesinde (uygulama ön plandayken) çağrılır: ana şokun
    /// artçılarını ortak kuralla süzüp etkinliği tazeler.
    func update(with quakes: [Earthquake]) {
        guard let watch = persistedWatch, let mainshock = mainshockQuake else { return }

        // Takip penceresi doldu: etkinliği kapat.
        guard Date() < watch.expiresAt else {
            Task { await stop() }
            return
        }

        knownAftershocks = AftershockSequence.select(mainshock: mainshock, from: knownAftershocks + quakes)

        // Sistem 8 saat sınırında kapattıysa (ya da hiç açılamadıysa) yeniden kur.
        if activity == nil, watch.dismissedByUser != true {
            requestActivity(state: isChannelBacked ? lastPublishedState ?? makeState(aftershocks: knownAftershocks)
                                                   : makeState(aftershocks: knownAftershocks))
        }
        // Yayın kanalına bağlı etkinliği sunucu günceller; yerel güncelleme
        // farklı bir sayımla onun üzerine yazmasın.
        guard !isChannelBacked else { return }

        if Date().timeIntervalSince(lastCatalogRefresh) >= Self.catalogRefreshInterval {
            refreshCatalog()
        }
        publish(makeState(aftershocks: knownAftershocks))
    }

    // MARK: - Etkinlik yaşam döngüsü

    private func requestActivity(state: AftershockActivityAttributes.ContentState) {
        guard activity == nil, activitiesEnabled,
              let watch = persistedWatch, let quake = mainshockQuake else { return }
        let attributes = AftershockActivityAttributes(
            mainshockID: watch.mainshockID,
            regionTitle: watch.title,
            mainshockMagnitude: watch.magnitude,
            mainshockDate: quake.date,
            latitude: watch.latitude,
            longitude: watch.longitude
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleInterval))
        do {
            let created: Activity<AftershockActivityAttributes>
            if let channelID = watch.channelID {
                created = try Activity.request(attributes: attributes, content: content, pushType: .channel(channelID))
            } else {
                created = try Activity.request(attributes: attributes, content: content)
            }
            attach(created)
            lastPublishedState = state
            lastPublishedAt = Date()
        } catch {
            AppLog.notifications.error("live activity start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Etkinliği bağlar ve durumunu izler: kullanıcı kapatırsa yeniden
    /// açılmaz; sistem süresi dolunca kapatırsa sonraki ön planda yeniden kurulur.
    private func attach(_ activity: Activity<AftershockActivityAttributes>) {
        self.activity = activity
        stateObservation?.cancel()
        stateObservation = Task { [weak self] in
            var previous = activity.activityState
            for await state in activity.activityStateUpdates {
                guard let self, !Task.isCancelled else { return }
                switch state {
                case .dismissed:
                    // Etkin bir etkinliği kilit ekranından kaydıran kullanıcıdır;
                    // sistemin bitirdiği etkinlik önce `.ended` olur.
                    if previous == .active || previous == .stale { self.markDismissedByUser() }
                    self.detach(activity)
                    return
                case .ended:
                    // Sistem (8 saat sınırı): ekranda donmuş kalmasın, kaldır;
                    // takip sürüyorsa sonraki yenilemede yenisi kurulur.
                    self.detach(activity)
                    await activity.end(nil, dismissalPolicy: .immediate)
                    return
                default:
                    previous = state
                }
            }
        }
    }

    private func detach(_ ended: Activity<AftershockActivityAttributes>) {
        guard activity?.id == ended.id else { return }
        activity = nil
        stateObservation = nil
    }

    private func endActivity() async {
        stateObservation?.cancel()
        stateObservation = nil
        lastPublishedState = nil
        guard let activity else { return }
        self.activity = nil
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    /// İçerik değişmediyse etkinlik güncellenmez (eskiden her ~25 sn'lik
    /// yenilemede yalnızca saat damgası değişen bir güncelleme gidiyordu).
    private func publish(_ state: AftershockActivityAttributes.ContentState) {
        guard let activity else { return }
        if let last = lastPublishedState, Self.sameContent(last, state),
           Date().timeIntervalSince(lastPublishedAt) < Self.forecastRefreshInterval {
            return
        }
        lastPublishedState = state
        lastPublishedAt = Date()
        Task {
            await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(Self.staleInterval)))
        }
    }

    /// Merkeze özel sunucu kataloğu: 24 saatlik listede olmayan eski artçıları
    /// da getirir (detaydaki "Artçılar" kartıyla aynı kaynak).
    private func refreshCatalog() {
        guard catalogTask == nil, let mainshock = mainshockQuake, !isChannelBacked else { return }
        lastCatalogRefresh = Date()
        catalogTask = Task { [weak self] in
            let fetched = await EarthquakeDetailView.loadRelatedAftershocks(for: mainshock)
            guard let self, !Task.isCancelled, self.mainshockQuake?.id == mainshock.id else { return }
            self.catalogTask = nil
            self.knownAftershocks = AftershockSequence.select(mainshock: mainshock, from: self.knownAftershocks + fetched)
            self.publish(self.makeState(aftershocks: self.knownAftershocks))
        }
    }

    private func makeState(aftershocks: [Earthquake]) -> AftershockActivityAttributes.ContentState {
        let magnitude = persistedWatch?.magnitude ?? mainshockQuake?.magnitude ?? 0
        let mainshockDate = mainshockQuake?.date ?? persistedWatch?.startedAt ?? Date()
        let latest = aftershocks.max { $0.date < $1.date }
        let forecast = Self.forecast(mainshockMagnitude: magnitude, mainshockDate: mainshockDate)
        return AftershockActivityAttributes.ContentState(
            aftershockCount: aftershocks.count,
            maxAftershockMagnitude: aftershocks.map(\.magnitude).max() ?? 0,
            lastMagnitude: latest?.magnitude ?? 0,
            lastTitle: latest?.displayTitle ?? "",
            lastDate: latest?.date ?? mainshockDate,
            updatedAt: Date(),
            forecastProbability: forecast.probability,
            forecastMagnitude: forecast.magnitude
        )
    }

    private static func sameContent(
        _ a: AftershockActivityAttributes.ContentState,
        _ b: AftershockActivityAttributes.ContentState
    ) -> Bool {
        a.aftershockCount == b.aftershockCount
            && a.maxAftershockMagnitude == b.maxAftershockMagnitude
            && a.lastMagnitude == b.lastMagnitude
            && a.lastDate == b.lastDate
            && a.forecastMagnitude == b.forecastMagnitude
            && abs((a.forecastProbability ?? 0) - (b.forecastProbability ?? 0)) < 0.01
    }

    // MARK: - Kalıcı takip kaydı

    private func saveWatch(_ watch: PersistedAftershockWatch) {
        persistedWatch = watch
        trackedMainshockID = watch.mainshockID
        if let data = try? JSONEncoder().encode(watch) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func markDismissedByUser() {
        guard var watch = persistedWatch else { return }
        watch.dismissedByUser = true
        saveWatch(watch)
    }

    private func clearPersistedWatch() {
        persistedWatch = nil
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    private static func mainshock(from watch: PersistedAftershockWatch) -> Earthquake {
        Earthquake(
            id: watch.mainshockID,
            provider: watch.provider ?? "",
            title: watch.title,
            magnitude: watch.magnitude,
            depth: watch.depth ?? 10,
            coordinate: Coordinate(longitude: watch.longitude, latitude: watch.latitude),
            date: watch.startedAt
        )
    }

    /// Şu andan itibaren 24 saatlik artçı olasılığı. Zamanla azaldığı için
    /// yenilemelerde yeniden hesaplanır.
    private static func forecast(mainshockMagnitude: Double, mainshockDate: Date) -> (probability: Double, magnitude: Double) {
        let threshold = AftershockForecast.thresholdMagnitude(forMainshock: mainshockMagnitude)
        let probability = AftershockForecast.probability(
            mainshockMagnitude: mainshockMagnitude,
            minimumMagnitude: threshold,
            elapsed: Date().timeIntervalSince(mainshockDate)
        )
        return (probability, threshold)
    }
}
