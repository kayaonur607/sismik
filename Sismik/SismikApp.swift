import SwiftUI
import FirebaseCore
@preconcurrency import FirebaseMessaging
import RevenueCat

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        Messaging.messaging().delegate = self
        Self.configureRevenueCat()
        QuickActionRouter.install()
        // Konumla arka planda uyandırılınca da (launchOptions[.location])
        // önemli konum değişikliği izlemesi sürsün.
        SignificantLocationService.shared.refresh()
        return true
    }

    /// RevenueCat STANDART modda çalışır (`purchasesAreCompletedBy` varsayılanı
    /// `.revenueCat`): satın almayı RevenueCat yürütür ve işlemi kendisi
    /// tamamlar; premium yetkisinin tek kaynağı da RevenueCat entitlement'ıdır.
    /// StoreKit yalnızca ürün fiyatlarını göstermek ve RevenueCat'e hiç
    /// aktarılmamış eski aboneleri kurtarmak için okunur.
    ///
    /// Gözlemci modu (`.myApp`) bilinçli olarak KULLANILMIYOR: sunucu yetkiyi
    /// yalnızca RevenueCat'ten çözdüğü için, istemcinin StoreKit'e dayanarak
    /// premium sayılması ama RevenueCat'in aboneyi tanımaması cihaz kaydının
    /// sessizce reddedilmesine ve kullanıcının hiç bildirim alamamasına yol
    /// açıyordu.
    private static func configureRevenueCat() {
        let apiKey = AppKeys.revenueCatAppleKey
        // Debug derlemede ayrıntılı log: `warn` seviyesinde SDK, entitlement
        // eşleşmediğinde hiçbir şey yazmıyor ve "satın alma başarılı ama
        // premium açılmadı" durumunu teşhis etmek imkânsız hâle geliyor.
        // Sürüm derlemesi sessiz kalır.
        #if DEBUG
        Purchases.logLevel = .debug
        #else
        Purchases.logLevel = .warn
        #endif
        Purchases.configure(
            with: Configuration.Builder(withAPIKey: apiKey)
                .with(storeKitVersion: .storeKit2)
                // Kalıcı kimlik: kimlik verilmezse RevenueCat her kuruluma yeni
                // bir anonim müşteri açıyor ve aynı abone birden fazla müşteri
                // olarak sayılıyordu (bkz. AppUserIdentity).
                .with(appUserID: AppUserIdentity.current)
                .build()
        )
    }

    /// Ana ekran hızlı eylemlerini yakalayan sahne temsilcisi (bkz. QuickActions.swift).
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        // iPhone'da portre kilidi korunur: tek elle kullanılan, yukarıdan
        // aşağı okunan bir liste/harita akışı. iPad'de pencere her yönde
        // kullanılabildiği için kısıtlama kaldırılır.
        let idiom = window?.traitCollection.userInterfaceIdiom
            ?? UIDevice.current.userInterfaceIdiom
        return idiom == .pad ? .all : .portrait
    }

    // MARK: APNs cihaz token'ı

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Swizzling açık olsa da APNs → FCM eşlemesini açıkça vermek token
        // üretimini TestFlight ve Xcode derlemelerinde deterministik tutar.
        Messaging.messaging().apnsToken = deviceToken
        Task { @MainActor in
            NotificationManager.shared.handleDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Push kaydı başarısız (ör. yetkilendirme eksik): yerel bildirim yolu devrede kalır.
        AppLog.notifications.error("APNs kaydı başarısız: \(error.localizedDescription, privacy: .public)")
    }

    // FCM token ilk kurulumda ve Firebase token'ı yenilediğinde çağrılır.
    // Her değişiklik sunucuya yeniden gönderilerek cihaz kaydı güncel tutulur.
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken, !fcmToken.isEmpty else { return }
        Task { @MainActor in
            NotificationManager.shared.handleFCMToken(fcmToken)
        }
    }

}

#if swift(>=6)
extension AppDelegate: @preconcurrency MessagingDelegate {}
#else
extension AppDelegate: MessagingDelegate {}
#endif

@main
struct SismikApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var locationManager = LocationManager()
    @Environment(\.scenePhase) private var scenePhase

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSplash = true

    /// Tanıtım sürümü: artırıldığında mevcut kullanıcılar tanıtımı bir kez daha görür.
    /// v5: Çevrem (bölgesel analiz) sayfası eklendi.
    /// v6: İzin isteği artık ayrı bir ekran değil, tanıtımın son sayfası.
    private static let onboardingVersion = 6
    @AppStorage("onboardingSeenVersion") private var onboardingSeenVersion = 0
    /// Zorunlu güncelleme ekranı bu oturumda ertelendi mi?
    @State private var updateDeferredThisSession = false
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue
    @AppStorage("appAppearance") private var appAppearance = AppAppearance.system.rawValue

    init() {
        // Tanıtımı hiç görmemiş cihaz yeni kurulumdur: "yenilikler" kartı gösterilmez.
        InfoCardCenter.bootstrap(isFreshInstall: UserDefaults.standard.integer(forKey: "onboardingSeenVersion") == 0)
        NotificationManager.shared.configure()
        Self.configureAppearance()
    }

    /// Navigasyon çubuğu ve alt sekme çubuğunun (dock) altında/üstünde
    /// beliren ince ayraç çizgisini kaldırır. Yalnızca gölge rengini
    /// sıfırlar; native blur/materyal arka plan aynen korunur — Acil
    /// Durum sekmesi gibi renkli arka planlı ekranlarda bu çizgi belirgin
    /// bir dikiş gibi görünüyordu.
    private static func configureAppearance() {
        // iOS 27+: gezinme çubuğuna da özel görünüm ATANMAZ (sekme çubuğundaki
        // gerekçeyle aynı). Özel bir UINavigationBarAppearance atandığında
        // iOS 27 çubuğu "kendi zemini olan" eski çubuk sayıyor; içerik altına
        // kayarken oluşan yumuşak kaydırma kenarı efekti çubuğun altına
        // uzanmıyor, yalnızca durum çubuğu bölgesinde kalıyordu. Yeni çubukta
        // ayraç çizgisi yok. iOS 26 ve öncesi aynen korunur.
        if #unavailable(iOS 27.0) {
            let navAppearance = UINavigationBarAppearance()
            navAppearance.configureWithDefaultBackground()
            navAppearance.shadowColor = .clear
            UINavigationBar.appearance().standardAppearance = navAppearance
            UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
            UINavigationBar.appearance().compactAppearance = navAppearance
        }

        // iOS 26+: sekme çubuğuna özel görünüm ATANMAZ. Özel bir
        // UITabBarAppearance atandığı anda UIKit eski (sabit, kenardan kenara)
        // çubuğa düşer; yüzen yuvarlak Liquid Glass dock ve aşağı kaydırınca
        // küçülme davranışı devre dışı kalır. Yeni çubukta zaten o dikiş
        // çizgisi yok, dolayısıyla düzeltmeye de gerek yok.
        if #unavailable(iOS 26.0) {
            let tabAppearance = UITabBarAppearance()
            tabAppearance.configureWithDefaultBackground()
            tabAppearance.shadowColor = .clear
            UITabBar.appearance().standardAppearance = tabAppearance
            UITabBar.appearance().scrollEdgeAppearance = tabAppearance
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                Group {
                    if onboardingSeenVersion < Self.onboardingVersion {
                        OnboardingView(locationManager: locationManager) {
                            withAnimation(reduceMotion ? nil : SismikDesign.Motion.entranceSpring) {
                                onboardingSeenVersion = Self.onboardingVersion
                            }
                        }
                    } else {
                        RootView()
                            .transition(.opacity)
                            .environment(locationManager)
                            .task {
                                locationManager.requestLocation()
                                await PremiumStore.shared.refreshEntitlements()
                                NotificationManager.shared.scheduleIfEnabled()
                                NotificationManager.shared.activateTestFlightNotificationsIfNeeded()
                            }
                    }
                }

                // Uzak yapılandırma: desteklenmeyen sürüm (`min_version`).
                if RemoteConfigCenter.shared.requiresUpdate && !updateDeferredThisSession && !showSplash {
                    RemoteUpdateRequiredView {
                        withAnimation(.snappy) { updateDeferredThisSession = true }
                    }
                    .zIndex(0.5)
                    .transition(.opacity)
                }

                if showSplash {
                    SplashView {
                        withAnimation(reduceMotion ? nil : SismikDesign.Motion.entranceSpring) {
                            showSplash = false
                        }
                    }
                    .zIndex(1)
                    .transition(.opacity)
                }
            }
            .environment(\.locale, AppLanguage.locale(for: selectedLanguage.localeIdentifier))
            .environment(\.layoutDirection, selectedLanguage.layoutDirection)
            .id(appLanguage)
            .preferredColorScheme(selectedAppearance.colorScheme)
            .sismikScrollEdgeEffect()
            // Kaydırma çubukları hiçbir ekranda gösterilmez: `.never`, sistemin
            // kendiliğinden göstereceği durumlarda da gizler. Kökten verildiği
            // için tüm ScrollView/List/Form'lara ve açılır sayfalara geçer.
            .scrollIndicators(.never)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                NotificationManager.shared.scheduleAppRefresh()
                locationManager.stopUpdating()
            } else if phase == .active {
                // Uygulama açıldığında sürekli GPS dinlemek yerine tekil konum
                // iste; konum gerektiren ekranlar ayrıca requestLocation() çağırıyor.
                locationManager.requestLocation()
                // "Sistem dili" seçiliyken cihaz dili değişmiş olabilir.
                WidgetBridge.syncLanguage()
                Task { @MainActor in
                    await PremiumStore.shared.refreshEntitlements()
                    NotificationManager.shared.scheduleIfEnabled()
                    NotificationManager.shared.activateTestFlightNotificationsIfNeeded()
                }
            }
        }
        .onChange(of: appLanguage) { WidgetBridge.syncLanguage() }
        .backgroundTask(.appRefresh("com.kayasoftware.sismik.refresh")) {
            await NotificationManager.shared.handleAppRefresh()
        }
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguage) ?? .system
    }

    private var selectedAppearance: AppAppearance {
        AppAppearance(rawValue: appAppearance) ?? .system
    }
}
