import Foundation

/// Bildirimin görünümü. Sunucu şablonu (`notification-templates.ts`) ve
/// yerel yedek bildirim aynı biçimi kullanır.
enum NotificationStyle: String, CaseIterable, Identifiable, Sendable {
    /// Büyüklük ve ne olduğu başlıkta; yer, uzaklık, saat, derinlik, kaynak
    /// ve "hissedildi mi" cümlesi.
    case detailed
    /// Tek bakış: büyüklük ve yer başlıkta, gövdede uzaklık ve saat.
    case compact

    var id: String { rawValue }

    static var current: NotificationStyle {
        NotificationStyle(rawValue: UserDefaults.standard.string(forKey: NotificationManager.Key.style) ?? "") ?? .detailed
    }
}

/// Bildirim ayarlarını UserDefaults üzerinde tutan gözlemlenebilir depo.
/// Her değişiklik, sunucudaki push kaydını da (debounce ile) günceller.
///
/// Kural ayarları (yer, yarıçap, eşik) `NotificationPlacesStore`'da. Eski
/// tekil kuralın alanları (kaynak, eşik, yakınlık, MMI) burada artık yok:
/// arayüzleri kaldırıldı, güncelleme sonrası geçişte gereken değerleri
/// `NotificationPlacesStore.LegacyRules` doğrudan UserDefaults'tan okur.
@MainActor
@Observable
final class NotificationSettings {
    /// Deprem bildirimleri herkese açık: ücretsiz kullanıcı tek bir yeri
    /// (50 km'ye kadar) ve dünyadaki M6.0+ depremleri takip eder. Daha fazla
    /// yer, geniş yarıçap, dünya eşiği ayarı ve kritik uyarı premium'dur.
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: NotificationManager.Key.enabled)
            if enabled {
                NotificationManager.shared.markEnabledNow()
                NotificationManager.shared.registerForRemoteNotifications()
            }
            NotificationManager.shared.schedulePushSync()
        }
    }
    /// Takip edilen yerlerin dışındaki büyük depremleri ayrıca bildirir.
    var worldMajorEnabled: Bool {
        didSet {
            UserDefaults.standard.set(worldMajorEnabled, forKey: NotificationManager.Key.worldMajorEnabled)
            NotificationManager.shared.schedulePushSync()
        }
    }
    var worldMajorThreshold: Double {
        didSet {
            UserDefaults.standard.set(worldMajorThreshold, forKey: NotificationManager.Key.worldMajorThreshold)
            NotificationManager.shared.schedulePushSync()
        }
    }
    var sound: NotificationSoundOption {
        didSet {
            UserDefaults.standard.set(sound.rawValue, forKey: NotificationManager.Key.sound)
            NotificationManager.shared.schedulePushSync()
        }
    }
    /// Pazartesi sabahı kayıtlı yerlerin haftalık deprem özeti (premium).
    var weeklyDigestEnabled: Bool {
        didSet {
            UserDefaults.standard.set(weeklyDigestEnabled, forKey: NotificationManager.Key.weeklyDigestEnabled)
            NotificationManager.shared.schedulePushSync()
        }
    }
    var style: NotificationStyle {
        didSet {
            UserDefaults.standard.set(style.rawValue, forKey: NotificationManager.Key.style)
            NotificationManager.shared.schedulePushSync()
        }
    }
    /// Kritik uyarıda (sessiz modu aşan) çalan ses; olağan sesten ayrı seçilir.
    var criticalSound: NotificationSoundOption {
        didSet {
            UserDefaults.standard.set(criticalSound.rawValue, forKey: NotificationManager.Key.criticalSound)
            NotificationManager.shared.schedulePushSync()
        }
    }

    /// Bildirimleri ilk kez açan kullanıcıda dünya genelindeki büyük depremler
    /// açık başlar ve yeri yoksa bulunduğu konum eklenir; kullanıcının daha
    /// önce kapattığı bir tercihe dokunulmaz.
    func enableMajorAlertsIfUnset() {
        // `object(forKey:)` kayıtlı varsayılanı da döndürür; kullanıcının
        // gerçekten yazdığı değer yalnızca kalıcı alanda görünür.
        let stored = Bundle.main.bundleIdentifier
            .flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
        if stored[NotificationManager.Key.worldMajorEnabled] == nil { worldMajorEnabled = true }
        NotificationPlacesStore.shared.addCurrentLocationPlaceIfEmpty()
    }

    init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: NotificationManager.Key.enabled)
        worldMajorEnabled = d.bool(forKey: NotificationManager.Key.worldMajorEnabled)
        worldMajorThreshold = d.object(forKey: NotificationManager.Key.worldMajorThreshold) != nil
            ? d.double(forKey: NotificationManager.Key.worldMajorThreshold) : 6.0
        sound = NotificationSoundOption(rawValue: d.string(forKey: NotificationManager.Key.sound) ?? "")
            .flatMap { $0.isCritical ? nil : $0 } ?? .defaultOption
        weeklyDigestEnabled = d.bool(forKey: NotificationManager.Key.weeklyDigestEnabled)
        style = NotificationStyle.current
        criticalSound = NotificationSoundOption(rawValue: d.string(forKey: NotificationManager.Key.criticalSound) ?? "")
            .flatMap { $0.isCritical ? $0 : nil } ?? .defaultCriticalOption
    }
}
