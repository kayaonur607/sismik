import CoreLocation
import SwiftUI
import UserNotifications

// MARK: - Liste başı bilgilendirmeleri
//
// Listenin tepesinde AYNI ANDA EN FAZLA BİR bilgilendirme kartı durur:
// uzak duyuru, kapalı izinler (bildirim, konum, kritik uyarı), takip edilen
// yer yok uyarısı, kendiliğinden eklenen yer ve güncelleme. Hissedilir/büyük
// deprem kartı görünürken hiçbiri gösterilmez — deprem anında kullanıcının
// dikkati tek karttadır; kart kapanınca sıradaki bilgilendirme geri gelir.

/// Tepede gösterilebilecek bilgilendirmeler, öncelik sırasıyla.
enum ListNotice: Equatable {
    case remote(RemoteClientConfig.Notice)
    case notifications(denied: Bool)
    /// iOS izni var ama deprem bildirimleri uygulama içinden kapatılmış.
    case earthquakeAlertsOff
    case location(denied: Bool)
    case noActivePlace
    case autoPlace(NotificationPlace)
    case criticalAlerts(settingsRequired: Bool)
    case appUpdate

    /// Sayfa geçişi (animasyon) için kararlı kimlik.
    var id: String {
        switch self {
        case .remote(let notice): "remote-\(notice.id)"
        case .notifications: "notifications"
        case .earthquakeAlertsOff: "earthquakeAlerts"
        case .location: "location"
        case .noActivePlace: "noActivePlace"
        case .autoPlace: "autoPlace"
        case .criticalAlerts: "criticalAlerts"
        case .appUpdate: "appUpdate"
        }
    }
}

/// Bildirim ve kritik uyarı izinlerinin güncel durumu (konum izni
/// `LocationManager`'dan gözlenir). Uygulama ön plana her döndüğünde tazelenir:
/// kullanıcı Ayarlar'dan izni açıp döndüğünde kart kendiliğinden kaybolur.
@MainActor
@Observable
final class PermissionNoticeCenter {
    static let shared = PermissionNoticeCenter()

    /// `nil`: henüz okunmadı (açılışta yanlış kart yanıp sönmesin).
    private(set) var notificationStatus: UNAuthorizationStatus?
    private(set) var criticalSetting: UNNotificationSetting?
    /// Uygulama içi "Deprem bildirimleri" anahtarı. UserDefaults gözlenmediği
    /// için burada tutulur; Ayarlar'da değişince kart hemen güncellenir.
    private(set) var earthquakeAlertsEnabled = UserDefaults.standard.bool(forKey: NotificationManager.Key.enabled)
    /// Bu oturumda ✕ ile kapatılan kartlar. Kalıcı değildir: kapatılan kart
    /// uygulama bir sonraki açılışta ya da arka planda en az 10 dakika
    /// kaldıktan sonra geri gelir. Kapalı izin önemli bir eksik; eskiden 7 gün
    /// gizleniyordu ve kullanıcı kartı bir daha hiç görmüyordu.
    private var dismissedThisSession: Set<String> = []
    private var backgroundedAt: Date?
    private static let sessionGap: TimeInterval = 10 * 60

    private init() {
        // Eski sürümün 7 günlük kalıcı gizleme kaydı temizlenir.
        UserDefaults.standard.removeObject(forKey: "listNotice.snoozedUntil")
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in PermissionNoticeCenter.shared.backgroundedAt = Date() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let shared = PermissionNoticeCenter.shared
                if let since = shared.backgroundedAt, Date().timeIntervalSince(since) >= Self.sessionGap {
                    shared.dismissedThisSession.removeAll()
                }
                shared.backgroundedAt = nil
                await shared.refresh()
            }
        }
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in PermissionNoticeCenter.shared.syncEarthquakeAlertsFlag() }
        }
    }

    func syncEarthquakeAlertsFlag() {
        let enabled = UserDefaults.standard.bool(forKey: NotificationManager.Key.enabled)
        if enabled != earthquakeAlertsEnabled { earthquakeAlertsEnabled = enabled }
    }

    func refresh() async {
        let manager = NotificationManager.shared
        let status = await manager.authorizationStatus()
        let critical = await manager.criticalAlertSetting()
        if status != notificationStatus { notificationStatus = status }
        if critical != criticalSetting { criticalSetting = critical }
        syncEarthquakeAlertsFlag()
    }

    func isSnoozed(_ id: String) -> Bool {
        dismissedThisSession.contains(id)
    }

    func snooze(_ id: String) {
        dismissedThisSession.insert(id)
    }

    /// Sıradaki bilgilendirme. Deprem kartı varken hiçbiri.
    func topNotice(locationStatus: CLAuthorizationStatus, hasFeltCard: Bool) -> ListNotice? {
        guard !hasFeltCard else { return nil }
        if let notice = RemoteConfigCenter.shared.activeNotice { return .remote(notice) }

        let defaults = UserDefaults.standard
        let places = NotificationPlacesStore.shared
        let alertsEnabled = earthquakeAlertsEnabled

        if let status = notificationStatus, !isSnoozed("notifications") {
            switch status {
            case .notDetermined: return .notifications(denied: false)
            // Kullanıcı bildirimleri uygulama içinden açmış ama iOS izni
            // kapalıysa hiçbir deprem bildirimi gelmez.
            case .denied: return .notifications(denied: true)
            default: break
            }
        }

        let notificationsAllowed = [.authorized, .provisional, .ephemeral].contains(notificationStatus)
        if notificationsAllowed, !alertsEnabled, !isSnoozed("earthquakeAlerts") {
            return .earthquakeAlertsOff
        }

        if !isSnoozed("location") {
            switch locationStatus {
            case .notDetermined: return .location(denied: false)
            case .denied, .restricted: return .location(denied: true)
            default: break
            }
        }

        let notificationsGranted = [.authorized, .provisional, .ephemeral].contains(notificationStatus)
        if notificationsGranted, alertsEnabled, places.hasNoActivePlace { return .noActivePlace }
        if let place = places.autoCreatedPlace { return .autoPlace(place) }

        // Kritik uyarı: yalnızca bildirimler açıkken ve yetki bu cihazda
        // gerçekten kullanılabiliyorsa (sorulduktan sonra hâlâ `.notSupported`
        // ise yetki yok; kart hiç çıkmaz).
        if notificationsGranted, alertsEnabled, !isSnoozed("criticalAlerts"), let critical = criticalSetting {
            let requested = defaults.bool(forKey: "notif.criticalAlertRequested")
            switch critical {
            case .disabled: return .criticalAlerts(settingsRequired: requested)
            case .notSupported where !requested: return .criticalAlerts(settingsRequired: false)
            default: break
            }
        }

        return AppUpdateNotice.shared.showBanner ? .appUpdate : nil
    }

    // MARK: Eylemler

    func requestNotifications() async {
        let manager = NotificationManager.shared
        if await manager.requestAuthorization() {
            manager.markEnabledNow()
            manager.setProductUpdatesEnabled(true)
            manager.enableEarthquakeAlertsAfterPermission()
        }
        await refresh()
    }

    /// Uygulama içi deprem bildirimlerini yeniden açar (Ayarlar'daki anahtarla
    /// aynı etki); hiç yer yoksa bulunduğu konum eklenir.
    func enableEarthquakeAlerts() {
        let manager = NotificationManager.shared
        UserDefaults.standard.set(true, forKey: NotificationManager.Key.enabled)
        manager.markEnabledNow()
        manager.registerForRemoteNotifications()
        NotificationPlacesStore.shared.addCurrentLocationPlaceIfEmpty()
        manager.schedulePushSync()
        syncEarthquakeAlertsFlag()
    }

    func requestCriticalAlerts() async {
        UserDefaults.standard.set(true, forKey: "notif.criticalAlertRequested")
        let manager = NotificationManager.shared
        if await manager.requestAuthorization(includeCriticalAlert: true) {
            manager.markEnabledNow()
        }
        await manager.refreshCriticalAlertState()
        await refresh()
    }
}

/// Liste başı bilgilendirme kartı: simge, başlık, açıklama, tek ana eylem ve
/// (varsa) kapatma. Kendiliğinden eklenen yer, izin ve "yer yok" kartları
/// aynı görünümü paylaşır.
struct ListInfoCard: View {
    let icon: String
    var tint: Color = .appAction
    let title: String
    let message: String
    let actionTitle: String
    var actionIcon: String?
    let action: () -> Void
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color(.tertiarySystemGroupedBackground), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("feltcard.dismiss"))
                }
            }

            Button(action: action) {
                if let actionIcon {
                    Label(actionTitle, systemImage: actionIcon)
                } else {
                    Text(actionTitle)
                }
            }
            .buttonStyle(.sismikPrimary(height: 42, tint: tint))
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous))
    }
}
