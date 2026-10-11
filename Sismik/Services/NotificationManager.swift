import Foundation
// UNNotificationRequest, UNNotificationResponse gibi tipler `Sendable`
// işaretlenmemiş. Bu dosya onları eşzamanlılık sınırlarından geçirmiyor —
// delegate geri çağrılarında ihtiyaç duyulan her şey senkron olarak değer
// tiplerine çıkarılıyor, `center.add(_:)` ise isteği aynı görev içinde
// kullanıyor. `@preconcurrency`, çerçevenin kendi ek açıklama eksikliğinden
// doğan uyarıları susturur; kendi kodumuzun eşzamanlılık denetimi aynen
// sürer.
@preconcurrency import UserNotifications
import BackgroundTasks
import CoreLocation
import UIKit
import CryptoKit
import FirebaseMessaging
import StoreKit
import RevenueCat

/// UIKit delegate callbacks are safe to transfer exactly once to the main
/// queue, but their Objective-C declarations are not annotated Sendable.
private final class SendableCallbackBox<Callback>: @unchecked Sendable {
    let callback: Callback

    init(_ callback: Callback) {
        self.callback = callback
    }
}

/// APNs/yerel bildirimleri ve arka plan tazelemeyi yönetir.
/// Bildirimler takip edilen yerler ve isteğe bağlı dünya geneli büyük deprem eşiğine göre filtrelenir.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    let refreshIdentifier = "com.kayasoftware.sismik.refresh"
    private let center = UNUserNotificationCenter.current()
    private var isConfigured = false
    enum Key {
        static let enabled        = "notif.enabled"
        /// V2'de yalnızca öncelikli sağlayıcıdır. `all` yalnızca eski sürümlerin
        /// sunucu kayıtlarını okuyabilmek için backend tarafında desteklenir.
        static let source         = "notif.source"
        static let minMagnitude   = "notif.minMagnitude"
        static let majorThreshold = "notif.majorThreshold"
        static let foregroundBanners = "notif.foregroundBanners"
        static let sound          = "notif.sound"
        static let criticalSound  = "notif.criticalSound"
        static let weeklyDigestEnabled = "notif.weeklyDigestEnabled"
        /// Bildirim biçimi (`NotificationStyle`); sunucu şablonu da buna göre seçer.
        static let style          = "notif.style"
        static let enabledSince   = "notif.enabledSince"
        static let notifiedIds    = "notif.notifiedIds"
        static let nearbyOnly     = "notif.nearbyOnly"
        static let radius         = "notif.radius"
        static let minimumEstimatedMMI = "notif.minimumEstimatedMMI"
        static let worldMajorEnabled = "notif.worldMajorEnabled"
        static let worldMajorThreshold = "notif.worldMajorThreshold"
        static let productUpdatesEnabled = "notif.productUpdatesEnabled"
        /// Sistemin bildirdiği kritik uyarı durumu (kullanıcı tercihi değil).
        static let criticalAlertsEnabled = "notif.criticalAlertsEnabled"
    }

    /// Arka planda bundan eski depremler bildirilmez — geciken arka plan
    /// görevi saatler önceki depremleri "yeni gibi" bildirmesin.
    private nonisolated static let backgroundMaxAge: TimeInterval = 3 * 60
    /// Ön planda yalnızca akışa gerçekten yeni katılan depremler değerlendirilir
    /// (ViewModel yalnızca ilk kez görülen kayıtları gönderir). Pencere, uygulama
    /// bir süre bekledikten sonra dönen kullanıcı için de bildirimi kaçırmayacak
    /// kadar geniş tutulur; mükerrerlik notifiedIds + push kontrolüyle engellenir.
    private nonisolated static let foregroundMaxAge: TimeInterval = 2 * 60

    /// Varsayılan ayarları kaydeder ve delegate'i bağlar.
    func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        UserDefaults.standard.register(defaults: [
            Key.enabled: false,
            Key.source: "afad",
            Key.minMagnitude: 4.0,
            Key.majorThreshold: 5.0,
            Key.foregroundBanners: false,
            Key.sound: NotificationSoundOption.defaultOption.rawValue,
            Key.criticalSound: NotificationSoundOption.defaultCriticalOption.rawValue,
            Key.weeklyDigestEnabled: true,
            Key.style: NotificationStyle.detailed.rawValue,
            Key.nearbyOnly: false,
            Key.radius: 250.0,
            Key.minimumEstimatedMMI: 0.0,
            Key.worldMajorEnabled: false,
            // Ücretsiz katmanın dünya eşiğiyle aynı (M6.0); premium değiştirebilir.
            Key.worldMajorThreshold: 6.0,
            Key.productUpdatesEnabled: false
        ])
        center.delegate = self
        registerFeedbackCategory()
        // İlk push kaydından ÖNCE hangi kuralın gönderileceğine karar ver:
        // güncelleyen kullanıcı ilk yerini kaydedene kadar eski kuralında
        // kalır. Uyarı, liste ekranı açılınca gösterilir.
        _ = NotificationPlacesStore.shared.migrateLegacySettingsIfNeeded()
    }

    // MARK: - "Hissettim / Hissetmedim" bildirim düğmeleri

    /// Sunucudaki `QUAKE_FEEDBACK_CATEGORY` ile aynı kimlik.
    nonisolated static let feedbackCategory = "QUAKE_FEEDBACK"
    nonisolated static let feltActionID = "QUAKE_FELT"
    nonisolated static let notFeltActionID = "QUAKE_NOT_FELT"

    /// Deprem bildirimlerinin altındaki iki düğme. Uygulamayı açmadan arka
    /// planda sayaç gönderir. Başlıklar kayıt anındaki uygulama dilindedir;
    /// dil değişince yeniden kaydedilir (`scheduleIfEnabled`).
    func registerFeedbackCategory() {
        let felt = UNNotificationAction(identifier: Self.feltActionID, title: L("notif.action.felt"), options: [])
        let notFelt = UNNotificationAction(identifier: Self.notFeltActionID, title: L("notif.action.notFelt"), options: [])
        let category = UNNotificationCategory(
            identifier: Self.feedbackCategory,
            actions: [felt, notFelt],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// Uygulama aktif olduğunda çağrılır: kullanıcı arka plana almadan kapatsa bile
    /// bekleyen bir tazeleme isteği kalsın. (`.backgroundTask` kaydından SONRA
    /// çağrılmalıdır; init içinde çağrılırsa BGTaskScheduler assert atar.)
    func scheduleIfEnabled() {
        let defaults = UserDefaults.standard
        let premium = PremiumStore.shared
        registerFeedbackCategory()

        // StoreKit / RevenueCat entitlement kontrolü bitmeden karar verme.
        guard premium.entitlementsLoaded else {
            entitlementCheckTask?.cancel()
            entitlementCheckTask = Task { @MainActor [weak self] in
                await premium.refreshEntitlements()
                guard !Task.isCancelled else { return }
                self?.scheduleIfEnabled()
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Entitlement controls eligibility, never the user's saved consent.
            let earthquakeEnabled = defaults.bool(forKey: Key.enabled)
            let productUpdatesEnabled = defaults.bool(forKey: Key.productUpdatesEnabled)

            // İki tercih de kapalıysa push token'ı alınmaz ve sunucu kaydı
            // silinir (`performPushRegistration`); böyle bir cihaz sürüm
            // duyurusu dahil hiçbir bildirim almaz.
            guard earthquakeEnabled || productUpdatesEnabled else {
                await self.syncPushRegistration(force: true)
                return
            }

            // Yerel yedek değerlendirme (arka plan yenilemesi) yalnızca premium
            // kurallarını işler; ücretsiz bildirimler yalnızca sunucu push'uyla gelir.
            if earthquakeEnabled, premium.isPremium { self.scheduleAppRefresh() }
            self.registerForRemoteNotifications()
            self.schedulePushSync()
        }
    }

    // MARK: - APNs Push Kaydı (sunucudan anlık bildirim)

    private static let workerBaseURL = BackendConfig.baseURL

    enum PushKey {
        static let deviceToken = "push.deviceToken"
        static let fcmToken = "push.fcmToken"
        static let lastSyncHash = "push.lastSyncHash"
        static let lastSyncAt = "push.lastSyncAt"
        static let registeredToken = "push.registeredToken"
        static let cleanupCompleted = "push.cleanupCompleted.v2"
        static let pendingQuake = "push.pendingQuake"
    }

    /// APNs cihaz token'ı ister; yalnızca kullanıcı deprem bildirimlerini ya
    /// da ürün güncellemelerini açtıysa.
    func registerForRemoteNotifications() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Key.enabled)
                || defaults.bool(forKey: Key.productUpdatesEnabled) else { return }
        Messaging.messaging().isAutoInitEnabled = true
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Premium olmayan kullanıcıların açık rızayla seçebildiği seyrek ürün
    /// güncellemeleri için push kaydını yönetir. Deprem bildirim yetkisini açmaz.
    func setProductUpdatesEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Key.productUpdatesEnabled)
        if enabled { registerForRemoteNotifications() }
        schedulePushSync(force: true)
    }

    // MARK: - TestFlight bildirim etkinleştirmesi

    /// TestFlight cihazlarında bildirim izni daha önce hiç açılmadıysa, Premium
    /// entitlement doğrulandıktan sonra tek seferlik sistem izin akışını başlatır.
    /// App Store sürümünde çalışmaz; her cihaz için yalnızca bir kez denenir.
    func activateTestFlightNotificationsIfNeeded() {
        #if DEBUG
        return
        #else
        Task { @MainActor in
            // iOS 18+ receipt dosya adına güvenmek yerine App Store imzalı
            // AppTransaction ortamını doğrula. TestFlight sandbox, App Store
            // üretim ortamıdır; ağ/StoreKit geçici hatasında daha sonra yeniden denenir.
            do {
                let verification = try await AppTransaction.shared
                guard case .verified(let transaction) = verification,
                      transaction.environment == .sandbox else { return }
            } catch {
                AppLog.notifications.error("TestFlight environment check failed=\(error.localizedDescription, privacy: .public)")
                return
            }

            let defaults = UserDefaults.standard
            let activationKey = "push.testflightActivationAttempted"
            guard !defaults.bool(forKey: activationKey) else { return }

            let premium = PremiumStore.shared
            if !premium.entitlementsLoaded { await premium.refreshEntitlements() }
            guard premium.isPremium, defaults.bool(forKey: Key.enabled) else { return }
            defaults.set(true, forKey: activationKey)
            let granted = await requestAuthorization()
            guard granted else { return }
            markEnabledNow()
            defaults.set(true, forKey: Key.enabled)
            registerForRemoteNotifications()
            await syncPushRegistration(force: true)
        }
        #endif
    }

    /// AppDelegate'ten gelen token: sakla ve tercihlerle birlikte sunucuya gönder.
    func handleDeviceToken(_ tokenData: Data) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: PushKey.deviceToken)
        AppLog.notifications.info("device token received bytes=\(tokenData.count, privacy: .public)")
        schedulePushSync()
    }

    /// Firebase tarafından üretilen/yenilenen kayıt token'ını saklar. APNs
    /// token'ı da payload'a eklenerek sunucudaki eski kayıt tek seferde silinir.
    func handleFCMToken(_ token: String) {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        UserDefaults.standard.set(normalized, forKey: PushKey.fcmToken)
        AppLog.notifications.info("FCM token received length=\(normalized.count, privacy: .public)")
        // Sunucu kaydı FCM token'ına bağlı; token yenilendiğinde (ilk kurulum,
        // yeniden yükleme, Firebase yenilemesi) kayıt yeni token'la tazelenir.
        schedulePushSync()
    }

    private var pushSyncTask: Task<Void, Never>?
    private var entitlementCheckTask: Task<Void, Never>?
    private var registrationRetryTask: Task<Void, Never>?
    private var registrationRetryAttempt = 0

    private func resetRegistrationRetry() {
        registrationRetryTask?.cancel()
        registrationRetryTask = nil
        registrationRetryAttempt = 0
    }

    private func retryRegistration(after minimumDelay: TimeInterval = 0) {
        guard registrationRetryTask == nil, registrationRetryAttempt < 5 else { return }
        let delay = max(minimumDelay, min(300, pow(2, Double(registrationRetryAttempt)) * 5))
            + Double.random(in: 0...3)
        registrationRetryAttempt += 1
        registrationRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.registrationRetryTask = nil
            await self.syncPushRegistration(force: true)
        }
    }
    private var deliveredIDsCache: [DeliveredQuake] = []
    private var deliveredIDsCheckedAt = Date.distantPast

    /// Ayar değişikliklerini tek istekte toplar (1 sn debounce).
    func schedulePushSync(force: Bool = false) {
        resetRegistrationRetry()
        pushSyncTask?.cancel()
        pushSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.syncPushRegistration(force: force)
        }
    }

    /// Token + güncel tercihleri worker'a kaydeder. Tercihler değişmediyse istek atmaz.
    private var registrationTask: Task<Void, Never>?
    private var registrationRequested = false
    private var registrationForceRequested = false

    func syncPushRegistration(force: Bool = false) async {
        registrationRequested = true
        registrationForceRequested = registrationForceRequested || force
        if let registrationTask { await registrationTask.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.registrationRequested {
                self.registrationRequested = false
                let force = self.registrationForceRequested
                self.registrationForceRequested = false
                await self.performPushRegistration(force: force)
            }
        }
        registrationTask = task
        await task.value
        registrationTask = nil
    }

    private func performPushRegistration(force: Bool) async {
        let d = UserDefaults.standard
        let earthquakeNotificationsEnabled = d.bool(forKey: Key.enabled)
        let productUpdatesEnabled = d.bool(forKey: Key.productUpdatesEnabled)

        guard earthquakeNotificationsEnabled || productUpdatesEnabled else {
            await unregisterPush()
            return
        }
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            await unregisterPush()
            return
        }

        let apnsToken = d.string(forKey: PushKey.deviceToken)
        let fcmToken = d.string(forKey: PushKey.fcmToken)
        // The backend sends through FCM. An APNs token is not an FCM target.
        guard let token = fcmToken, Messaging.messaging().apnsToken != nil else {
            registerForRemoteNotifications()
            return
        }
        let transport = "fcm"

        let premium = PremiumStore.shared
        if !premium.entitlementsLoaded {
            await premium.refreshEntitlements()
        }

        #if DEBUG
        let pushEnvironment = "sandbox"
        #else
        let pushEnvironment = "prod"
        #endif

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let placesStore = NotificationPlacesStore.shared
        var payload: [String: Any] = [
            "token": token,
            "transport": transport,
            // Doğrudan APNs (2.1.4+): sunucu bildirimi FCM'e uğramadan Apple'a
            // gönderir; FCM token'ı yedek olarak kalır.
            "apnsToken": apnsToken ?? "",
            "worldMajorEnabled": d.bool(forKey: Key.worldMajorEnabled),
            "worldMajorThreshold": d.double(forKey: Key.worldMajorThreshold),
            "tzOffset": TimeZone.current.secondsFromGMT() / 60,
            "lang": AppLanguage.currentLanguageCode,
            "env": pushEnvironment,
            // Arayüz kapısı (`isPremium`) değil gerçek abonelik: kapılar
            // kapalıyken herkes premium görünür, sunucu ise kanıtsız
            // premium iddiasında kaydı reddediyordu.
            "isPremium": premium.hasActiveSubscription,
            "earthquakeNotificationsEnabled": earthquakeNotificationsEnabled,
            "productUpdatesEnabled": productUpdatesEnabled,
            "notificationSound": selectedSound.fileName,
            // Yalnızca bu sürümden itibaren gönderilir: sunucu kritik sesi
            // bu alan varsa kullanır, eski sürümde dosya olmadığı için.
            "criticalNotificationSound": selectedCriticalSound.fileName,
            // Sunucu yalnızca premium cihaza ve bu alanı gönderen sürüme yollar.
            "weeklyDigestEnabled": d.bool(forKey: Key.weeklyDigestEnabled),
            "notificationStyle": NotificationStyle.current.rawValue,
            // Kritik uyarı sessiz modu ve Rahatsız Etmeyin'i aşar. Sunucu
            // bunu YALNIZCA kullanıcı izni varken ve büyük deprem eşiğinde
            // kullanır; her sarsıntıda kullanmak hem kullanıcıyı bezdirir hem
            // de Apple'ın yetkiyi geri almasına yol açar.
            "criticalAlertsEnabled": d.bool(forKey: Key.criticalAlertsEnabled),
            "appVersion": currentVersion,
            // RevenueCat'teki aboneyi bu cihazla eşleştirir. Yeniden kurulumda
            // push token'ı değiştiği için sunucuda yeni bir cihaz belgesi
            // oluşuyor; aboneliğinde değişiklik olmadığından RevenueCat webhook
            // atmıyor. Sunucu bu kimlikle yetkiyi kayıt anında çözüyor.
            "appUserId": Purchases.shared.appUserID
        ]
        // Sunucu belgesi iki kuraldan birindedir ve hangisi olduğunu bu yük
        // belirler (functions: `deviceUsesPlaces`):
        //
        //  - Eski kural: 2.0.9'dan güncelleyen, henüz yer kaydetmemiş kullanıcı.
        //    Alanlar 2.0.9'un gönderdiğinin aynısı; kullanıcı güncelledi diye
        //    tek bir bildirimini bile kaybetmez.
        //  - Yer modeli: `places` HER ZAMAN gönderilir, boş olsa bile. Boş
        //    dizi "yer yok" demektir ve sunucu eski alanları siler.
        //    Koordinatı henüz gelmemiş ya da kapatılmış yerler dizide yok;
        //    `current` türü de burada sıradan bir koordinata çözülür.
        if placesStore.usesLegacyRules {
            let legacy = NotificationPlacesStore.LegacyRules.stored(in: d)
            payload["source"] = legacy.source
            payload["sourceFallbackEnabled"] = true
            payload["minMagnitude"] = legacy.minMagnitude
            payload["majorThreshold"] = legacy.majorThreshold
            payload["minimumEstimatedMMI"] = legacy.minimumEstimatedMMI
            payload["nearbyOnly"] = legacy.nearbyOnly
            payload["radius"] = legacy.radiusKm
            if legacy.nearbyOnly || legacy.minimumEstimatedMMI > 0,
               let coordinate = LocationManager.cachedCoordinate {
                payload["latitude"] = coordinate.latitude
                payload["longitude"] = coordinate.longitude
            }
        } else {
            payload["places"] = placesStore.activePlaces.map(\.registrationPayload)
        }
        if let watch = AftershockTracker.shared.registrationPayload {
            payload["aftershockWatch"] = watch
        }
        if let signedTransaction = premium.signedTransactionJWS {
            // Sunucu `isPremium` bayrağına güvenmez; Apple imzalı StoreKit
            // işlemini doğrulayıp abonelik bitişini Firestore'a yazar.
            // RevenueCat'e henüz aktarılmamış ödeme yapan aboneyi kurtaran
            // emniyet ağı budur (`worker-utils.ts` → `decideDeviceEntitlement`
            // `appleActive` dalı); bu alan gönderilmezse o dal ölü kod olur.
            payload["signedTransaction"] = signedTransaction
        }

        // Koordinatsızlık artık kaydı ertelemek için sebep değil: yer listesi
        // boş olsa bile dünya geneli büyük deprem tercihi sunucuya gitmeli.
        // Kullanıcının sessizce bildirimsiz kalması, ayar ekranındaki
        // kapatılamaz uyarı şeridiyle görünür kılınıyor (bkz. NoActivePlaceWarning).
        let legacyTokens = Set([apnsToken, d.string(forKey: PushKey.registeredToken)]
            .compactMap { $0 }.filter { $0 != token })
        // Only migrate legacy tokens until this FCM registration is acknowledged.
        if d.string(forKey: PushKey.registeredToken) != token {
            payload["legacyTokens"] = legacyTokens.sorted()
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        var comparablePayload = payload
        comparablePayload.removeValue(forKey: "legacyTokens")
        let comparableBody = (try? JSONSerialization.data(withJSONObject: comparablePayload, options: [.sortedKeys])) ?? body
        let hash = SHA256.hash(data: comparableBody).map { String(format: "%02x", $0) }.joined()
        // Sunucu, 60 gün görülmeyen cihazları temizler. Tercihler değişmese de
        // haftalık doğrulama kaydı canlı tutar; sunucuda silinen kayıt en geç
        // yedi gün içinde kendiliğinden yeniden oluşur.
        let lastSyncAt = d.double(forKey: PushKey.lastSyncAt)
        let syncIsFresh = Date().timeIntervalSince1970 - lastSyncAt < 7 * 86_400
        if !force, syncIsFresh, d.string(forKey: PushKey.lastSyncHash) == hash { return }

        guard let url = URL(string: Self.workerBaseURL + "/register") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                AppLog.notifications.error("push registration invalid response")
                retryRegistration()
                return
            }
            if 200..<300 ~= http.statusCode {
                resetRegistrationRetry()
                d.set(token, forKey: PushKey.registeredToken)
                d.set(false, forKey: PushKey.cleanupCompleted)
                d.set(hash, forKey: PushKey.lastSyncHash)
                d.set(Date().timeIntervalSince1970, forKey: PushKey.lastSyncAt)
                AppLog.notifications.info("push registration synced status=\(http.statusCode, privacy: .public)")
            } else {
                AppLog.notifications.error("push registration failed status=\(http.statusCode, privacy: .public)")
                if http.statusCode == 429 || http.statusCode >= 500 {
                    let retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0
                    retryRegistration(after: min(3600, max(0, retryAfter)))
                }
            }
        } catch {
            AppLog.notifications.error("push registration network error=\(error.localizedDescription, privacy: .public)")
            retryRegistration()
        }
    }

    /// Sunucudaki cihaz kaydını kaldırır (bildirimler kapatıldığında).
    func unregisterPush() async {
        let d = UserDefaults.standard
        guard !d.bool(forKey: PushKey.cleanupCompleted)
                || d.string(forKey: PushKey.lastSyncHash) != nil else { return }
        guard let url = URL(string: Self.workerBaseURL + "/unregister") else { return }
        let tokens = Set([
            d.string(forKey: PushKey.fcmToken),
            d.string(forKey: PushKey.deviceToken),
            d.string(forKey: PushKey.registeredToken)
        ].compactMap { $0 })
        guard !tokens.isEmpty else { return }

        let removedAll = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for token in tokens {
                group.addTask {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
                    request.timeoutInterval = 15
                    do {
                        let (_, response) = try await URLSession.shared.data(for: request)
                        return (response as? HTTPURLResponse).map { 200..<300 ~= $0.statusCode } ?? false
                    } catch {
                        return false
                    }
                }
            }

            var allSucceeded = true
            for await succeeded in group where !succeeded { allSucceeded = false }
            return allSucceeded
        }
        if !removedAll {
            AppLog.notifications.error("one or more push unregister requests failed")
            retryRegistration()
        }
        if removedAll {
            resetRegistrationRetry()
            d.set(true, forKey: PushKey.cleanupCompleted)
            d.removeObject(forKey: PushKey.registeredToken)
            d.removeObject(forKey: PushKey.lastSyncHash)
            d.removeObject(forKey: PushKey.lastSyncAt)
            AppLog.notifications.info("push registrations removed count=\(tokens.count, privacy: .public)")
        }
    }

    // MARK: İzin

    /// Bildirim izni ister.
    ///
    /// Kritik uyarı YALNIZCA `includeCriticalAlert` ile istenir. Her istekte
    /// koşulsuz eklendiğinde "Bildirimlere izin ver" düğmesi normal izin
    /// diyaloğunun hemen ardından kritik uyarı diyaloğunu da açıyordu;
    /// kullanıcı sessiz modu aşan bir izni, istemediği bir anda veriyordu.
    /// Kritik uyarı artık izinler ekranındaki kendi düğmesinden istenir.
    func requestAuthorization(includeCriticalAlert: Bool = false) async -> Bool {
        var options: UNAuthorizationOptions = [.alert, .sound, .badge]
        if includeCriticalAlert { options.insert(.criticalAlert) }
        do {
            let granted = try await center.requestAuthorization(options: options)
            AppLog.notifications.info("authorization granted=\(granted, privacy: .public)")
            return granted
        } catch {
            AppLog.notifications.error("authorization failed error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Kritik uyarıların bu cihazdaki durumu.
    ///
    /// `.notSupported` iki şey demek olabilir: yetki henüz Apple tarafından
    /// verilmedi, ya da cihaz/işletim sistemi desteklemiyor. Arayüz ikisini
    /// ayırt etmeye çalışmaz; kullanıcıya "şu an kullanılamıyor" der.
    func criticalAlertSetting() async -> UNNotificationSetting {
        await center.notificationSettings().criticalAlertSetting
    }

    /// Kritik uyarı gerçekten açık mı? Sunucuya bu bayrak gönderilir; push
    /// yükünde `critical` sesi yalnızca açıkken kullanılır.
    func refreshCriticalAlertState() async {
        let enabled = await criticalAlertSetting() == .enabled
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Key.criticalAlertsEnabled) != enabled else { return }
        defaults.set(enabled, forKey: Key.criticalAlertsEnabled)
        schedulePushSync()
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    // MARK: Değerlendirme

    /// Verilen deprem listesinde, kullanıcı ayarlarına uyan YENİ depremler için bildirim gönderir.
    /// Sunucu push'u aktifken de çalışır: tek fark yaratan senaryo değil, güvenlik ağı olarak —
    /// worker push'u ulaştıramazsa (APNs hatası, rate limit, cron kesintisi vb.) kullanıcı sessiz
    /// kalmasın diye. Zaten push ile teslim edilmiş depremler `deliveredNotifications()`
    /// üzerinden tespit edilip atlanır, böylece çift bildirim üretilmez.
    private func deliveredQuakes() async -> [DeliveredQuake] {
        if Date().timeIntervalSince(deliveredIDsCheckedAt) < 30 {
            return deliveredIDsCache
        }
        let delivered = await center.deliveredNotifications().compactMap {
            DeliveredQuake(userInfo: $0.request.content.userInfo)
        }
        deliveredIDsCache = delivered
        deliveredIDsCheckedAt = Date()
        return delivered
    }

    /// Bildirim Merkezi'ndeki bir deprem bildirimi (push ya da yerel). Yük
    /// `quake` sözlüğünü taşır; aynı fiziksel depremin başka ajans kaydı
    /// bununla tanınır.
    struct DeliveredQuake: Sendable {
        let id: String
        let provider: String
        let time: TimeInterval
        let magnitude: Double
        let latitude: Double
        let longitude: Double

        init?(userInfo: [AnyHashable: Any]) {
            guard let id = userInfo["quakeId"] as? String else { return nil }
            let quake = userInfo["quake"] as? [String: Any]
            self.id = id
            provider = (quake?["provider"] as? String) ?? ""
            time = (quake?["date"] as? String).flatMap { ISO8601.date(from: $0) }?.timeIntervalSince1970 ?? 0
            magnitude = (quake?["magnitude"] as? NSNumber)?.doubleValue ?? .nan
            latitude = (quake?["lat"] as? NSNumber)?.doubleValue ?? .nan
            longitude = (quake?["lon"] as? NSNumber)?.doubleValue ?? .nan
        }

        /// Sunucudaki `isPushDuplicateOf` ile aynı eşikler: farklı ajans,
        /// 60 sn, 50 km, 1.0 büyüklük.
        func isSameEvent(as earthquake: Earthquake) -> Bool {
            if earthquake.id == id { return true }
            guard !provider.isEmpty, time > 0, magnitude.isFinite, latitude.isFinite, longitude.isFinite,
                  provider.caseInsensitiveCompare(earthquake.provider) != .orderedSame,
                  abs(earthquake.date.timeIntervalSince1970 - time) <= 60,
                  abs(earthquake.magnitude - magnitude) <= 1.0 else { return false }
            return NotificationManager.haversineKm(
                from: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                toLatitude: earthquake.coordinate.latitude,
                toLongitude: earthquake.coordinate.longitude
            ) <= 50
        }
    }

    private struct NotificationFilter: Sendable {
        let worldMajorEnabled: Bool
        let worldMajorThreshold: Double
        let enabledSince: Double
        let places: [NotificationPlace]
        /// Doluysa cihaz eski kuralda: yerler yok sayılır, 2.0.9 filtresi uygulanır.
        let legacy: NotificationPlacesStore.LegacyRules?
        let userCoordinate: CLLocationCoordinate2D?
        let maximumAge: TimeInterval
    }

    private enum NotificationReason: Sendable {
        case worldMajor
        case place(name: String, icon: PlaceIcon, distanceKm: Double, criticalMagnitude: Double?)
        // Yalnızca eski kural.
        case felt(distanceKm: Double)
        case nearby(distanceKm: Double)
        case general
    }

    private struct NotificationCandidate {
        let earthquake: Earthquake
        let reason: NotificationReason
    }

    func evaluate(_ quakes: [Earthquake], isBackground: Bool) async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Key.enabled), PremiumStore.shared.isPremium else { return }

        let filter = NotificationFilter(
            worldMajorEnabled: defaults.bool(forKey: Key.worldMajorEnabled),
            worldMajorThreshold: defaults.object(forKey: Key.worldMajorThreshold) != nil
                ? defaults.double(forKey: Key.worldMajorThreshold) : 6.0,
            enabledSince: defaults.double(forKey: Key.enabledSince),
            places: NotificationPlacesStore.shared.activePlaces,
            legacy: NotificationPlacesStore.shared.usesLegacyRules
                ? NotificationPlacesStore.LegacyRules.stored(in: defaults) : nil,
            userCoordinate: LocationManager.cachedCoordinate,
            maximumAge: isBackground ? Self.backgroundMaxAge : Self.foregroundMaxAge
        )
        let notifiedOrder = defaults.stringArray(forKey: Key.notifiedIds) ?? []

        // Push ile zaten teslim edilmiş depremleri Bildirim Merkezi'nden tespit et
        // (worker payload'ı `quakeId` alanını taşır — bkz. NotificationManager.post).
        // Bildirim merkezini her yenilemede taramak yerine 30 sn'lik küçük bir
        // cache kullanılır; bu yol yalnızca server push ile gelen ID'leri
        // yerel fallback'ten ayırmak için gereklidir.
        // Aynı fiziksel depremin başka ajans kaydı da elenir: sunucu EMSC
        // kaydını bildirdiyse AFAD kaydı ikinci bir yerel bildirim üretmez.
        let delivered = await deliveredQuakes()

        let candidates = await Task.detached(priority: .background) {
            Self.notificationCandidates(
                from: quakes,
                filter: filter,
                excluding: Set(notifiedOrder),
                delivered: delivered
            )
        }.value

        guard !candidates.isEmpty else { return }

        var updatedNotifiedOrder = notifiedOrder
        for candidate in candidates {
            if await post(candidate) {
                updatedNotifiedOrder.append(candidate.earthquake.id)
            }
        }

        // En fazla son 300 kimliği sakla.
        defaults.set(Array(updatedNotifiedOrder.suffix(300)), forKey: Key.notifiedIds)
    }

    private nonisolated static func notificationCandidates(
        from earthquakes: [Earthquake],
        filter: NotificationFilter,
        excluding excludedIDs: Set<String>,
        delivered: [DeliveredQuake]
    ) -> [NotificationCandidate] {
        let now = Date().timeIntervalSince1970
        var candidates: [NotificationCandidate] = []
        candidates.reserveCapacity(min(earthquakes.count, 8))

        for earthquake in earthquakes {
            guard Double(earthquake.createdAt) > filter.enabledSince,
                  !excludedIDs.contains(earthquake.id),
                  !delivered.contains(where: { $0.isSameEvent(as: earthquake) }),
                  now - Double(earthquake.createdAt) < filter.maximumAge else { continue }

            if let legacy = filter.legacy {
                if let reason = legacyReason(for: earthquake, rules: legacy, filter: filter) {
                    candidates.append(.init(earthquake: earthquake, reason: reason))
                }
                continue
            }

            // Sunucudaki `notificationMatch` ile aynı sıra: yerler, sonra
            // dünya geneli. Kaynak ve MMI filtresi yok.
            var best: (place: NotificationPlace, distanceKm: Double, critical: Double?)?
            for place in filter.places {
                guard let hit = place.match(earthquake) else { continue }
                if best.map({ hit.distanceKm < $0.distanceKm }) ?? true {
                    // Uzaktan hissedilir eşleşme kritik uyarı vermez (şiddet V altı);
                    // sunucudaki kural ile aynı.
                    let critical = hit.feltAtPlace && hit.mmi < 5 ? nil : place.criticalMagnitude
                    best = (place, hit.distanceKm, critical)
                }
            }

            let reason: NotificationReason
            if let best {
                reason = .place(
                    name: best.place.name,
                    icon: best.place.icon,
                    distanceKm: best.distanceKm,
                    criticalMagnitude: best.critical
                )
            } else if filter.worldMajorEnabled,
                      earthquake.magnitude >= filter.worldMajorThreshold {
                reason = .worldMajor
            } else {
                continue
            }
            candidates.append(.init(earthquake: earthquake, reason: reason))
        }

        return candidates
            .sorted { $0.earthquake.createdAt > $1.earthquake.createdAt }
            .prefix(1)
            .map { $0 }
    }

    /// 2.0.9'un yerel filtresinin aynısı (sunucuda `legacyNotificationMatch`).
    private nonisolated static func legacyReason(
        for earthquake: Earthquake,
        rules: NotificationPlacesStore.LegacyRules,
        filter: NotificationFilter
    ) -> NotificationReason? {
        let latitude = earthquake.coordinate.latitude
        let longitude = earthquake.coordinate.longitude
        let inTurkeyFastLane = latitude >= 34 && latitude <= 43 && longitude >= 23 && longitude <= 47
        let isRegionalMajor = earthquake.magnitude >= rules.majorThreshold && inTurkeyFastLane
        let isWorldMajor = filter.worldMajorEnabled
            && !inTurkeyFastLane
            && earthquake.magnitude >= filter.worldMajorThreshold
        if isWorldMajor { return .worldMajor }

        guard earthquake.magnitude >= rules.minMagnitude,
              earthquake.sourceTag.lowercased() == rules.source else { return nil }

        let distance = filter.userCoordinate.map {
            haversineKm(from: $0, toLatitude: latitude, toLongitude: longitude)
        }
        if rules.nearbyOnly, !isRegionalMajor {
            guard let distance, distance <= rules.radiusKm else { return nil }
        }
        if rules.minimumEstimatedMMI > 0 {
            guard let distance else { return nil }
            let hypocentral = hypot(max(0, distance), max(1, earthquake.depth))
            let logPGA = 0.58 * earthquake.magnitude - 1.25 * log10(hypocentral + 6) - 0.0021 * hypocentral - 2.20
            let pga = max(0.00001, pow(10, logPGA)) * 980.665
            let mmi = min(10, max(0, pga >= 80 ? 3.66 * log10(pga) - 1.66 : 2.20 * log10(pga) + 1))
            guard mmi >= rules.minimumEstimatedMMI else { return nil }
            return .felt(distanceKm: distance)
        }
        if rules.nearbyOnly, let distance { return .nearby(distanceKm: distance) }
        return .general
    }

    nonisolated static func haversineKm(
        from origin: CLLocationCoordinate2D,
        toLatitude: Double,
        toLongitude: Double
    ) -> Double {
        let radians = Double.pi / 180
        let latitudeDelta = (toLatitude - origin.latitude) * radians
        let longitudeDelta = (toLongitude - origin.longitude) * radians
        let haversine = pow(sin(latitudeDelta / 2), 2)
            + cos(origin.latitude * radians) * cos(toLatitude * radians) * pow(sin(longitudeDelta / 2), 2)
        return 6_371 * 2 * atan2(sqrt(haversine), sqrt(max(0, 1 - haversine)))
    }

    private func post(_ candidate: NotificationCandidate) async -> Bool {
        let quake = candidate.earthquake
        let content = UNMutableNotificationContent()
        // Sunucudaki şablonun aynısı (functions/src/notification-templates.ts):
        // ayrıntılı biçimde başlıkta renk + büyüklük + ne oldu, alt başlıkta
        // yer ve uzaklık, gövdede saat · derinlik · kaynak ve "hissedildi mi"
        // cümlesi; sade biçimde başlıkta büyüklük ve yer, gövdede uzaklık.
        let style = NotificationStyle.current
        let mag = String(format: "%.1f", quake.magnitude)
        let placeLabel = quake.displayTitle
        let clock = quake.date.clockTime
        let detailLine = "\(clock) · \(L("notif.v2.depth", Int(quake.depth.rounded()))) · \(quake.sourceTag)"
        let impact = SeismicImpactModel(earthquake: quake)
        var placeIcon: PlaceIcon?
        var opensAssembly = false
        var dot = Self.magnitudeDot(quake.magnitude)
        var headline = L("notif.v2.quake")
        var distanceText: String?
        var compactContext = ""
        var secondLine = ""

        switch candidate.reason {
        case .worldMajor:
            headline = L("notif.v2.worldMajor")
            compactContext = headline
            secondLine = L(NotificationPlacesStore.shared.places.isEmpty ? "notif.v2.tapDetails" : "notif.v2.farFromPlaces")
        case .place(let name, let icon, let distanceKm, _):
            let level = Self.feltLevel(impact.estimatedMMI(atEpicentralDistance: distanceKm))
            let displayName = name.isEmpty ? L("places.currentLocation") : name
            let strong = quake.magnitude >= 5
            opensAssembly = strong && Self.isTurkeyRegion(quake)
            dot = Self.intensityDot(level)
            headline = L(strong ? "notif.v2.nearStrong" : "notif.v2.near", displayName)
            distanceText = L("notif.v2.away", Int(distanceKm.rounded()))
            compactContext = "\(displayName): \(distanceText!)"
            secondLine = [L("notif.v2.felt\(level)"), opensAssembly ? L("notif.v2.assembly") : ""]
                .filter { !$0.isEmpty }.joined(separator: " ")
            placeIcon = icon
        case .felt(let distanceKm):
            let level = Self.feltLevel(impact.estimatedMMI(atEpicentralDistance: distanceKm))
            distanceText = L("notif.v2.away", Int(distanceKm.rounded()))
            compactContext = distanceText!
            secondLine = L("notif.v2.felt\(level)")
        case .nearby(let distanceKm):
            distanceText = L("notif.v2.away", Int(distanceKm.rounded()))
            compactContext = distanceText!
        case .general:
            break
        }

        switch style {
        case .detailed:
            content.title = "\(dot) M\(mag) · \(headline)"
            content.subtitle = [placeLabel, distanceText].compactMap { $0 }.joined(separator: " · ")
            content.body = [detailLine, secondLine].filter { !$0.isEmpty }.joined(separator: "\n")
        case .compact:
            content.title = "\(dot) M\(mag) · \(placeLabel)"
            content.body = [
                [compactContext, clock].filter { !$0.isEmpty }.joined(separator: " · "),
                opensAssembly ? L("notif.v2.assembly") : ""
            ].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        // Sunucu push'unda bu görseli bildirim uzantısı ekler; yerel bildirim
        // uzantıdan geçmediği için aynı görsel burada iliştirilir.
        if let placeIcon, let url = PlaceIconArtwork.writePNG(for: placeIcon),
           let attachment = try? UNNotificationAttachment(identifier: "placeIcon", url: url) {
            content.attachments = [attachment]
        }
        // Her olay ayrı bir bildirim olarak görünür. Tek ortak thread kimliği
        // kullanmak iOS'un farklı depremleri toplu bir yığın halinde sunmasına
        // neden oluyordu.
        content.threadIdentifier = quake.id
        content.interruptionLevel = quake.magnitude >= 5 ? .timeSensitive : .active
        // Kritik uyarı, sunucudaki `isCriticalDelivery` ile aynı kural: yalnızca
        // kullanıcının o yer için seçtiği eşikte ve iOS izni verilmişse.
        if case .place(_, _, _, let critical?) = candidate.reason,
           quake.magnitude >= critical,
           UserDefaults.standard.bool(forKey: Key.criticalAlertsEnabled) {
            content.sound = .criticalSoundNamed(
                UNNotificationSoundName(rawValue: selectedCriticalSound.fileName),
                withAudioVolume: 1.0
            )
            content.interruptionLevel = .critical
        } else {
            content.sound = selectedSound.notificationSound
        }
        content.relevanceScore = min(1.0, quake.magnitude / 8.0)
        // Deprem verisi payload'da taşınır: bildirime dokunulduğunda kayıt
        // listeden düşmüş olsa bile detay doğrudan açılabilir.
        var userInfo: [String: Any] = [
            "magnitude": quake.magnitude,
            "quakeId": quake.id,
            "quake": [
                "id": quake.id,
                "provider": quake.provider,
                "title": quake.title,
                "magnitude": quake.magnitude,
                "depth": quake.depth,
                "lat": quake.coordinate.latitude,
                "lon": quake.coordinate.longitude,
                "date": ISO8601.formatter.string(from: quake.date)
            ]
        ]
        if opensAssembly { userInfo["openTarget"] = "assembly" }
        content.userInfo = userInfo
        content.categoryIdentifier = Self.feedbackCategory

        let request = UNNotificationRequest(identifier: quake.id, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    // MARK: Şablon yardımcıları (sunucudaki notification-templates.ts ile aynı eşikler)

    /// Yerdeki tahmini şiddetin (MMI) "hissedildi mi" basamağı.
    nonisolated static func feltLevel(_ mmi: Double) -> Int {
        switch mmi {
        case ..<2: 0
        case ..<3.5: 1
        case ..<5: 2
        case ..<6.5: 3
        default: 4
        }
    }

    /// Uygulamanın büyüklük ölçeğiyle aynı: yalnızca yeşil, turuncu, kırmızı.
    nonisolated static func intensityDot(_ level: Int) -> String {
        switch level {
        case 4...: "🔴"
        case 2...: "🟠"
        default: "🟢"
        }
    }

    nonisolated static func magnitudeDot(_ magnitude: Double) -> String {
        switch magnitude {
        case 6...: "🔴"
        case 4...: "🟠"
        default: "🟢"
        }
    }

    /// Toplanma alanı verisi Türkiye'ye ait; başka yerde "dokun" denmez.
    nonisolated static func isTurkeyRegion(_ quake: Earthquake) -> Bool {
        let c = quake.coordinate
        return c.latitude >= 34 && c.latitude <= 43 && c.longitude >= 23 && c.longitude <= 47
    }

    /// Anlık test bildirimi.
    func sendTestNotification() async {
        let content = UNMutableNotificationContent()
        content.title = L("notif.test.title")
        content.body = L("notif.test.body")
        content.sound = selectedSound.notificationSound
        let request = UNNotificationRequest(
            identifier: "test-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        try? await center.add(request)
    }

    private var selectedSound: NotificationSoundOption {
        let stored = UserDefaults.standard.string(forKey: Key.sound) ?? ""
        guard let option = NotificationSoundOption(rawValue: stored), !option.isCritical else { return .defaultOption }
        return option
    }

    private var selectedCriticalSound: NotificationSoundOption {
        let stored = UserDefaults.standard.string(forKey: Key.criticalSound) ?? ""
        guard let option = NotificationSoundOption(rawValue: stored), option.isCritical else { return .defaultCriticalOption }
        return option
    }

    /// Bildirimler açıldığında çağrılır; geçmiş depremlerin bildirilmemesi için başlangıç zamanını işaretler.
    func markEnabledNow() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Key.enabledSince)
    }

    /// Onboarding'de bildirim izni verildi: deprem bildirimleri açık başlar —
    /// ücretsiz kullanıcı için de. Hiç yeri yoksa bulunduğu konum (ücretsiz
    /// sınır olan 50 km yarıçapla) ilk yer olarak eklenir; dünya genelindeki
    /// büyük depremler de açılır. Kullanıcının daha önce kendi verdiği karara
    /// (kalıcı alanda yazılı değer) dokunulmaz.
    func enableEarthquakeAlertsAfterPermission() {
        let d = UserDefaults.standard
        let stored = Bundle.main.bundleIdentifier.flatMap { d.persistentDomain(forName: $0) } ?? [:]
        if stored[Key.enabled] == nil {
            d.set(true, forKey: Key.enabled)
            markEnabledNow()
        }
        if stored[Key.worldMajorEnabled] == nil { d.set(true, forKey: Key.worldMajorEnabled) }
        NotificationPlacesStore.shared.addCurrentLocationPlaceIfEmpty()
        scheduleIfEnabled()
    }

    // MARK: Arka plan tazeleme

    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        // Erken tarih ver: sistem yine kendi bütçesine göre karar verir ama
        // ilk uygun pencerede çalışabilsin (15 dk sabitlemek en erken anı geciktirir).
        request.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// .backgroundTask modifier'ından çağrılır: verileri çek, değerlendir, yeniden planla.
    func handleAppRefresh() async {
        scheduleAppRefresh()
        let notificationsEnabled = UserDefaults.standard.bool(forKey: Key.enabled)
        // Widget'lar ağa kendileri çıkmaz; güncel kalmaları bu tek istekle
        // olur. Bildirimler kapalıysa istek yalnızca ana ekranda widget varsa
        // yapılır.
        let widgetsInstalled = await WidgetBridge.hasInstalledWidgets()
        guard notificationsEnabled || widgetsInstalled else { return }
        if let quakes = try? await EarthquakeService.shared.fetchRecent(limit: 100, forceRefresh: true) {
            if notificationsEnabled {
                await evaluate(quakes, isBackground: true)
            }
            // Widget'lar listenin aynısını gösterir: az önce çekilen canlı
            // listenin tamamından (önbellekten, yeni istek yok) aynı kurallarla.
            WidgetBridge.publishInBackground(await EarthquakeService.shared.liveSnapshot().quakes)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    // ÖNEMLİ — TestFlight 1.0.3 SIGABRT çökmesinin kalıcı çözümü:
    //
    // Bu delegate çağrıları sistem tarafından ARKA PLAN thread'inde yapılır.
    // `async` sürümler kullanıldığında Swift'in ürettiği Objective-C köprüsü,
    // UIKit'in tamamlanma bloğunu görevin bittiği executor'da çağırır — bu ana
    // thread OLMAYABİLİR. iOS 26, bildirim dokunuşuyla soğuk açılışta bu blok
    // içinde pencere anlık görüntüsü/durum geri yükleme güncellemesi yapar ve
    // ana thread dışında NSInternalInconsistencyException ile uygulamayı
    // sonlandırır.
    //
    // Bu yüzden burada `async` sürümler DEĞİL, tamamlanma bloklu (completion
    // handler) sürümler uygulanır ve blok HER ZAMAN açıkça ana kuyruğa
    // gönderilerek çağrılır. Bu metotları async'e çevirme.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let request = notification.request
        let userInfo = request.content.userInfo
        let notificationKind = userInfo["notificationKind"] as? String
        let isCorrection = notificationKind == "correction"
        let isAdminNotification = notificationKind == "admin_manual"
            || notificationKind == "admin_test"
            || notificationKind == "premium_offer"
            || userInfo["type"] as? String == "automation"
            || (userInfo["quakeId"] as? String)?.hasPrefix("test-") == true

        let options: UNNotificationPresentationOptions
        if isCorrection {
            // Büyüklük düzeltmesi sessizdir: açık uygulamada da banner çıkmaz,
            // eski bildirimin yerini Bildirim Merkezi'nde alır.
            options = [.list]
        } else if request.identifier.hasPrefix("test-") || isAdminNotification {
            // Yönetim paneli/test bildirimi uygulama açıkken de görünür.
            options = [.banner, .sound, .list]
        } else {
            // Uygulama açıkken liste zaten canlı: varsayılan olarak banner
            // gösterme, bildirimi sessizce Bildirim Merkezi'ne bırak. Büyük
            // depremler ve kullanıcı tercihine göre banner yine gösterilir.
            let d = UserDefaults.standard
            let showBanners = d.bool(forKey: Key.foregroundBanners)
            let majorThreshold = d.double(forKey: Key.majorThreshold)
            let rawMagnitude = userInfo["magnitude"]
            let magnitude = (rawMagnitude as? Double)
                ?? (rawMagnitude as? NSNumber)?.doubleValue
                ?? Double(rawMagnitude as? String ?? "")
                ?? 0
            options = (showBanners || magnitude >= majorThreshold)
                ? [.banner, .sound, .list]
                : [.list]
        }

        // Güncelleme duyurusu uygulama açıkken gelirse ana sayfa banner'ı da
        // hemen açılsın; bir sonraki liste yenilemesini beklemesin.
        let announcedVersion = (userInfo["announcement"] as? String) == "app_update"
            ? userInfo["latestVersion"] as? String
            : nil

        // Tamamlanma bloğu her zaman ana thread'de.
        let completion = SendableCallbackBox(completionHandler)
        DispatchQueue.main.async {
            if let announcedVersion {
                MainActor.assumeIsolated {
                    AppUpdateNotice.shared.record(latestVersion: announcedVersion)
                }
            }
            completion.callback(options)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let req = response.notification.request
        let userInfo = req.content.userInfo
        let notificationKind = userInfo["notificationKind"] as? String

        // "Hissettim / Hissetmedim": uygulama açılmaz, rapor arka planda
        // gönderilir; tamamlanma bloğu istek bitince çağrılır ki sistem
        // arka plan süresini erken kesmesin.
        if response.actionIdentifier == Self.feltActionID || response.actionIdentifier == Self.notFeltActionID {
            let felt = response.actionIdentifier == Self.feltActionID
            let reportedID = (userInfo["quakeId"] as? String) ?? req.identifier
            let completion = SendableCallbackBox(completionHandler)
            Task {
                await FeltReportService.report(reportedID, felt: felt)
                await MainActor.run { completion.callback() }
            }
            return
        }

        // Sendable olmayan bildirim nesnelerinden gerekli her şey burada,
        // senkron olarak çıkarılır; ana kuyruğa yalnızca değer tipleri taşınır.
        //
        // Deprem kimliği: sunucu push'unda payload'daki quakeId (sistem kimliği
        // rastgeledir); yerel bildirimde istek kimliğinin kendisi deprem id'sidir.
        let quakeID = (userInfo["quakeId"] as? String) ?? req.identifier
        // Türkiye'deki güçlü depremde bildirim "Toplanma alanları için dokun"
        // der; dokunuş deprem detayı yerine toplanma alanlarını açar.
        let opensAssembly = (userInfo["openTarget"] as? String) == "assembly"
        // Sürüm duyurusu: sunucu eski istemciler için `admin_manual` türüyle
        // gönderir (onlar dokununca yalnızca ana sayfayı açar); bu sürüm ve
        // sonrası `announcement` alanını tanıyıp doğrudan App Store'u açar.
        let isAppUpdateAnnouncement = (userInfo["announcement"] as? String) == "app_update"
        let announcedVersion = userInfo["latestVersion"] as? String
        // Otomasyon bildirimi: deprem değil. Bilgi kartı taşıyorsa onu açar.
        let isAutomation = (userInfo["type"] as? String) == "automation"
        let infoCardID = userInfo["infoCard"] as? String
        // Tsunami uyarısı (2.1.4+): dokununca yüksek/toplanma noktaları açılır.
        let isTsunami = userInfo["tsunami"] != nil

        // Payload'daki deprem verisi: kayıt akışta yoksa (eski deprem, soğuk
        // açılış) detay yine de bu veriden açılır.
        //
        // `let` olması önemli: aşağıdaki closure ana kuyrukta çalışıyor ve
        // değişken bir yakalama, derleyicinin veri yarışı denetiminde hata
        // sayılıyor (Swift 6). Değer burada bir kez üretilip sabitleniyor.
        let pendingQuakeData: Data? = {
            if let quakeDict = userInfo["quake"] as? [String: Any] {
                return try? JSONSerialization.data(withJSONObject: quakeDict)
            }
            if let quakeJSON = userInfo["quake"] as? String {
                return quakeJSON.data(using: .utf8)
            }
            return nil
        }()

        let completion = SendableCallbackBox(completionHandler)
        DispatchQueue.main.async {
            // Ana kuyruktayız; assumeIsolated derleyiciye bunu kanıtlar ve
            // MainActor API'lerine (UIApplication) erişim sağlar.
            MainActor.assumeIsolated {
                // Her koşulda tamamlanma bloğu ana thread'de çağrılır.
                defer { completion.callback() }

                if notificationKind == "weekly_digest" {
                    if let url = URL(string: "sismik://map") {
                        UIApplication.shared.open(url)
                    }
                    return
                }

                if notificationKind == "premium_offer" {
                    if let url = URL(string: "sismik://paywall") {
                        UIApplication.shared.open(url)
                    }
                    return
                }

                if isAutomation {
                    if let infoCardID,
                       let encoded = infoCardID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                       let url = URL(string: "sismik://info/\(encoded)") {
                        UIApplication.shared.open(url)
                    }
                    return
                }

                if isAppUpdateAnnouncement {
                    // Banner da hemen açılsın; liste isteğini beklemesin.
                    AppUpdateNotice.shared.record(latestVersion: announcedVersion)
                    UIApplication.shared.open(AppUpdateNotice.storeURL)
                    return
                }

                if isTsunami {
                    if let url = URL(string: "sismik://assembly") {
                        UIApplication.shared.open(url)
                    }
                    return
                }

                // Yönetim paneli/test bildirimini deprem detayına yönlendirme.
                guard !quakeID.hasPrefix("test-"),
                      notificationKind != "admin_manual",
                      notificationKind != "admin_test" else { return }

                if opensAssembly, let url = URL(string: "sismik://assembly") {
                    UIApplication.shared.open(url)
                    return
                }

                if let pendingQuakeData {
                    UserDefaults.standard.set(pendingQuakeData, forKey: PushKey.pendingQuake)
                }

                if let encoded = quakeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                   let url = URL(string: "sismik://quake/\(encoded)") {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    /// Bildirim payload'ından saklanan depremi (kimlik eşleşiyorsa) döndürür ve temizler.
    static func consumePendingQuake(id: String) -> Earthquake? {
        let d = UserDefaults.standard
        guard let data = d.data(forKey: PushKey.pendingQuake),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              dict["id"] as? String == id,
              let provider = dict["provider"] as? String,
              let title = dict["title"] as? String,
              let magnitude = dict["magnitude"] as? Double,
              let lat = dict["lat"] as? Double,
              let lon = dict["lon"] as? Double,
              let dateString = dict["date"] as? String else { return nil }

        d.removeObject(forKey: PushKey.pendingQuake)

        let date = ISO8601.date(from: dateString) ?? Date()

        return Earthquake(
            id: id,
            provider: provider,
            title: title,
            magnitude: magnitude,
            depth: dict["depth"] as? Double ?? 0,
            coordinate: Coordinate(longitude: lon, latitude: lat),
            date: date
        )
    }
}
