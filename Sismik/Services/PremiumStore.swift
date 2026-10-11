import Foundation
import RevenueCat
import StoreKit

/// Sismik Premium abonelik durumu ve satın alma işlemleri (StoreKit 2 + RevenueCat).
///
/// Premium'un açtığı özellikler: yapay zeka analizi, istatistik ekranı,
/// harita görünümü. Tek yetki kaynağı RevenueCat'in `premium` entitlement'ıdır
/// (`Purchases.shared.customerInfo()`); StoreKit yalnızca RevenueCat'e hiç
/// aktarılmamış eski aboneleri kurtaran, premium veren ama asla kaldırmayan
/// tek yönlü bir yedek yoldur. Sonuç hızlı açılış için UserDefaults'a
/// önbelleklenir.
@MainActor
@Observable
final class PremiumStore {
    static let shared = PremiumStore()

    /// Premium kapıları etkin mi? Her derlemede açık.
    static let gatingEnabled = true

    static let monthlyID = "com.kayasoftware.sismik.premium.monthly"
    static let yearlyID = "com.kayasoftware.sismik.premium.yearly"
    /// Tek seferlik ömür boyu satın alma (tüketilmeyen ürün). RevenueCat'te
    /// aynı `premium` yetkisine bağlıdır; yetkinin bitiş tarihi yoktur.
    static let lifetimeID = "com.kayasoftware.sismik.lifetime"
    static let productIDs: Set<String> = [monthlyID, yearlyID, lifetimeID]
    private static let entitlementID = "premium"

    private static let cacheKey = "premium.cached"
    private static let expirationCacheKey = "premium.cachedExpiration"
    /// Yetki aktif ve bitiş tarihi YOK (ömür boyu / süresiz promosyon).
    /// Açılışta önbellekten premium sayılmak için bitiş tarihinin gelecekte
    /// olması gerekiyordu; bitişsiz yetki her soğuk açılışta birkaç saniye
    /// ücretsiz görünüyor, açılış tercihleri de o anda harcanıyordu.
    private static let lifetimeCacheKey = "premium.cachedLifetime"
    private static let revenueCatSyncedKey = "premium.revenueCatReceiptSynced"
    /// Widget uzantısıyla paylaşılan App Group. Widget RevenueCat SDK'sını
    /// yapılandırmıyor; tek yetki kaynağının sonucunu buradan okuyor.
    private static let appGroupID = "group.com.kayasoftware.sismik"

    private(set) var products: [Product] = []
    /// App Store'un bu hesap için ücretsiz giriş teklifine uygun bulduğu ürünler.
    /// Gerçek abonelik durumu — RevenueCat'in `premium` entitlement'ından okunur;
    /// yalnızca kurtarma yolunda (bkz. `legacyStoreKitEntitlement()`) StoreKit'ten gelir.
    private(set) var hasActiveSubscription: Bool
    private(set) var subscriptionExpirationDate: Date?
    /// Aktif yetkinin bitişi yok: ömür boyu satın alma. Ayarlar'da abonelik
    /// yönetimi yerine "Ömür boyu" durumu gösterilir.
    private(set) var hasLifetimeAccess: Bool
    /// Firebase cihaz kaydının Apple tarafında doğrulanabilmesi için
    /// yalnızca App Store imzalı JWS gönderilir; ham makbuz veya Apple hesabı yoktur.
    private(set) var signedTransactionJWS: String?
    /// İlk StoreKit kontrolü tamamlanmadan premium ayarları kapatılmasın.
    /// Böylece daha önce satın almış kullanıcılar, açılışta kısa süreli cache
    /// gecikmesi nedeniyle bildirim filtrelerini kaybetmez.
    private(set) var entitlementsLoaded = false
    private(set) var isPurchasing = false
    /// Abonelik yeni sona erdi: uygulama açılışında bir kez paywall gösterilir.
    private(set) var entitlementJustExpired = false
    var errorMessage: String?

    /// Paywall gösterildikten sonra çağrılır; bayrak tekrar tetiklenmez.
    func acknowledgeEntitlementExpiry() {
        entitlementJustExpired = false
    }

    /// Arayüz kapıları bunu okur: kapılar devre dışıyken herkes premium sayılır.
    var isPremium: Bool {
        #if DEBUG
        // Simülatörde premium ekranları incelemek için: `-SismikForcePremium`.
        if ProcessInfo.processInfo.arguments.contains("-SismikForcePremium") { return true }
        #endif
        return !Self.gatingEnabled || hasActiveSubscription
    }

    /// `Transaction.updates`in RevenueCat karşılığı: yenilenme, iade, iptal
    /// ve uygulama dışında yapılan satın almalar oturum ortasında da yansır.
    /// `purchasesAreCompletedBy: .revenueCat` olduğundan StoreKit'i artık biz
    /// dinlemiyoruz — tek gerçek kaynak bu akış. `shared` bir singleton
    /// olduğundan `init` süreç başına bir kez çalışır; bu yüzden akış da bir
    /// kez başlar ve sızıntı/yinelenen abonelik riski yoktur.
    private var customerInfoObservationTask: Task<Void, Never>?

    private init() {
        // Açılışta son bilinen durumu anında göster. StoreKit kontrolünü uygulama
        // yaşam döngüsü başlatır; ürünler ise yalnızca paywall açıldığında yüklenir.
        // Böylece soğuk açılışta aynı sorgu birkaç yerden yinelenmez.
        let cachedExpiration = UserDefaults.standard.object(forKey: Self.expirationCacheKey) as? Date
        let cachedLifetime = UserDefaults.standard.bool(forKey: Self.lifetimeCacheKey)
        let cachedActive = UserDefaults.standard.bool(forKey: Self.cacheKey)
            && (cachedExpiration.map { $0 > Date() } ?? cachedLifetime)
        subscriptionExpirationDate = cachedExpiration
        hasActiveSubscription = cachedActive
        hasLifetimeAccess = cachedActive && cachedExpiration == nil && cachedLifetime

        customerInfoObservationTask = Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                await self?.applyStreamedCustomerInfo(info)
            }
        }
    }

    /// `customerInfoStream`den gelen güncellemeyi `performEntitlementRefresh()`
    /// ile aynı alanlara yazar, iki farkla: (1) o an sürmekte olan bir
    /// `refreshEntitlements()` ile yarışmamak için yenileme sürerken akıştan
    /// gelen güncelleme atlanır — yenileme zaten aynı veriyi az sonra daha
    /// güncel biçimde yazacaktır. (2) `entitlementJustExpired` burada HİÇ
    /// set edilmez: o bayrak yalnızca açılış/foreground yenilemesinde
    /// tetiklenir ki kullanıcı premium bir ekranın ortasındayken (ör. harita)
    /// paywall aniden açılmasın. Buna karşın kesin "yetki yok" cevabı yine de
    /// anında `hasActiveSubscription`'ı düşürür: iptal/iade oturum ortasında
    /// yansır, sadece "az önce bitti" bildirimi ertelenir.
    ///
    /// KRİTİK: "kesin yetki yok" cevabı yalnızca yenileme yolundakiyle AYNI
    /// kurtarma taramasından sonra kesindir. RevenueCat'e hiç aktarılmamış
    /// eski abone için SDK'nın kendi `customerInfo` tazelemesi de "yetki yok"
    /// yayınlar; kurtarma olmadan bu yayın, açılışta kurtarılmış aboneyi
    /// birkaç dakika sonra free'ye düşürür ve `NotificationManager` deprem
    /// bildirimlerini kapatıp cihaz kaydını sunucudan siler. Bu yüzden
    /// kurtarma burada da çalışır ve `entitlementsLoaded` yalnızca kurtarmayı
    /// yapmış bir geçişin sonunda işaretlenir.
    private func applyStreamedCustomerInfo(_ info: CustomerInfo) async {
        guard refreshTask == nil else { return }

        var active: Bool
        var latestExpiration: Date?
        if let entitlement = info.entitlements[Self.entitlementID], entitlement.isActive {
            UserDefaults.standard.set(true, forKey: Self.revenueCatSyncedKey)
            active = true
            latestExpiration = entitlement.expirationDate
        } else {
            active = false
            latestExpiration = nil
        }

        // RevenueCat yetki görmüyorsa, doğrudan Apple StoreKit 2 kontrolü yapılır.
        // Böylece geçici senkron gecikmelerinde kullanıcı asla haksız yere free'ye düşürülmez.
        if !active, let rescued = await checkStoreKitEntitlement(triggerMigration: false) {
            active = true
            latestExpiration = rescued.expiration
        }

        guard refreshTask == nil else { return }

        if !active { signedTransactionJWS = nil }
        persistEntitlement(active: active, expiration: latestExpiration)
        entitlementsLoaded = true
        NotificationManager.shared.schedulePushSync()
    }

    /// Yetkiyi bellek + önbellek + widget App Group'una tek yerden yazar.
    /// Aktif ve bitişsiz yetki ömür boyu sayılır.
    private func persistEntitlement(active: Bool, expiration: Date?) {
        let lifetime = active && expiration == nil
        hasActiveSubscription = active
        hasLifetimeAccess = lifetime
        subscriptionExpirationDate = expiration
        UserDefaults.standard.set(active, forKey: Self.cacheKey)
        UserDefaults.standard.set(expiration, forKey: Self.expirationCacheKey)
        UserDefaults.standard.set(lifetime, forKey: Self.lifetimeCacheKey)
        UserDefaults(suiteName: Self.appGroupID)?.set(active, forKey: Self.cacheKey)
    }

    /// Ürünleri App Store'dan yükler (paywall açılmadan önce de çağrılabilir).
    func loadProducts() async {
        guard products.isEmpty else { return }
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            products = loaded.sorted { $0.price < $1.price }

            // Teşhis: App Store hata FIRLATMADAN boş dizi döndürebilir. Bu,
            // "ağ yok" değil "bu ürünler bu ortamda satın alınabilir değil"
            // demektir — App Store Connect'te ürün durumu eksik, Paid
            // Applications sözleşmesi yürürlükte değil ya da paket kimliği
            // eşleşmiyor olabilir. Sessizce yutulunca paywall yalnızca
            // "ürünler kullanılamıyor" diyor ve sebep hiçbir yerde görünmüyordu.
            if loaded.isEmpty {
                AppLog.network.error("""
                [Subscription] App Store hiç ürün döndürmedi. İstenen: \(Self.productIDs.joined(separator: ", "), privacy: .public). \
                Kontrol: App Store Connect ürün durumu, Paid Applications sözleşmesi, paket kimliği.
                """)
            } else {
                let missing = Self.productIDs.subtracting(loaded.map(\.id))
                if !missing.isEmpty {
                    AppLog.network.error("[Subscription] Eksik ürün: \(missing.joined(separator: ", "), privacy: .public)")
                }
                AppLog.network.info("[Subscription] \(loaded.count, privacy: .public) ürün yüklendi")
            }
        } catch {
            // Gerçek hata (ağ, StoreKit): artık sessizce yutulmuyor.
            AppLog.network.error("""
            [Subscription] Ürün yükleme hatası: \(String(describing: error), privacy: .public)
            """)
        }
    }

    /// Seçili aboneliği satın alır: önce RevenueCat, o başarısız olursa
    /// doğrudan StoreKit 2.
    func purchase(_ product: Product) async {
        guard !isPurchasing else { return }
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        var purchaseSucceeded = false

        // 1. Hat: RevenueCat üzerinden satın alma
        do {
            let result = try await Purchases.shared.purchase(
                product: StoreProduct(sk2Product: product)
            )
            if result.userCancelled {
                AppLog.network.info("[Subscription] Purchase cancelled by user")
                return
            }
            purchaseSucceeded = true
            AppLog.network.info("[Subscription] RevenueCat purchase completed")
        } catch {
            // `localizedDescription` RevenueCat hatalarında çoğu zaman genel bir
            // cümle veriyor; asıl sebep alttaki kod ve `userInfo`'da. Teşhis
            // için tamamı yazılır.
            AppLog.network.error("""
            [Subscription] RevenueCat satın alma başarısız: \(String(describing: error), privacy: .public). \
            Doğrudan StoreKit 2 yoluna geçiliyor...
            """)

            // 2. Hat: Doğrudan Apple StoreKit 2 üzerinden satın alma (Fallback)
            do {
                let skResult = try await product.purchase()
                switch skResult {
                case .success(let verification):
                    guard case .verified(let transaction) = verification else {
                        errorMessage = AppLanguage.isTurkish ? "Satın alma işlemi doğrulanamadı." : "Transaction could not be verified."
                        return
                    }
                    await transaction.finish()
                    signedTransactionJWS = verification.jwsRepresentation
                    purchaseSucceeded = true
                    AppLog.network.info("[Subscription] Direct StoreKit 2 purchase succeeded")
                    // RevenueCat ile senkronize et
                    _ = try? await Purchases.shared.syncPurchases()
                case .userCancelled:
                    return
                case .pending:
                    errorMessage = AppLanguage.isTurkish ? "Satın alma işlemi onay bekliyor." : "Purchase is pending approval."
                    return
                @unknown default:
                    break
                }
            } catch let skError {
                AppLog.network.error("[Subscription] Direct StoreKit 2 purchase failed: \(skError.localizedDescription, privacy: .public)")
                errorMessage = friendlyErrorMessage(for: skError)
            }
        }

        await refreshEntitlements()

        if purchaseSucceeded || hasActiveSubscription {
            errorMessage = nil
            NotificationManager.shared.schedulePushSync(force: true)
        }
    }

    /// StoreKit'te aktif abonelik var mı? Yalnızca kurtarma yolunda
    /// çağrılır: RevenueCat'e aktarılmamış eski aboneyi bulur.
    private func legacyStoreKitEntitlement() async -> (expiration: Date?, jws: String)? {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  (transaction.expirationDate ?? .distantFuture) > Date() else { continue }

            #if !DEBUG
            guard transaction.environment != .xcode else { continue }
            #endif

            return (transaction.expirationDate, result.jwsRepresentation)
        }
        return nil
    }

    /// Doğrudan StoreKit 2 kontrolü: RevenueCat yetki göstermiyorsa veya senkronize
    /// gecikmesi varsa Apple'ın doğrudan cihazda imzaladığı işlemi doğrular.
    /// Böylece RevenueCat sunucusunda gecikme olsa bile kullanıcı asla mağdur olmaz.
    private func checkStoreKitEntitlement(
        triggerMigration: Bool
    ) async -> (expiration: Date?, jws: String)? {
        guard let valid = await legacyStoreKitEntitlement() else { return nil }
        signedTransactionJWS = valid.jws
        if triggerMigration { await migrateLegacyPurchaseToRevenueCat() }
        return valid
    }

    /// RevenueCat'ten önce abone olmuş kullanıcıyı RevenueCat'e tanıtır.
    /// Bayrak yalnızca RevenueCat yetkiyi gerçekten gösterdiğinde yazılır;
    /// aksi hâlde bir sonraki açılışta yeniden denenir.
    private func migrateLegacyPurchaseToRevenueCat() async {
        do {
            let info = try await Purchases.shared.syncPurchases()
            if info.entitlements[Self.entitlementID]?.isActive == true {
                UserDefaults.standard.set(true, forKey: Self.revenueCatSyncedKey)
                AppLog.network.info("[Subscription] Legacy migration completed")
            }
        } catch {
            AppLog.network.error("[Subscription] Legacy migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Satın alımları RevenueCat üzerinden geri yükler.
    ///
    /// `AppStore.sync()` BİLEREK çağrılmıyor: RevenueCat zaten makbuzu
    /// tazeliyor, ikisini arka arkaya çağırmak kullanıcıya iki ayrı Apple
    /// kimlik doğrulama istemi gösteriyordu.
    func restorePurchases() async {
        guard !isPurchasing else { return }
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }
        do {
            _ = try await Purchases.shared.restorePurchases()
            AppLog.network.info("[Subscription] Restore completed")
        } catch {
            AppLog.network.error("[Subscription] Restore failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = friendlyErrorMessage(for: error)
        }
        await refreshEntitlements()
        if errorMessage == nil && !isPremium {
            errorMessage = AppLanguage.isTurkish
                ? "Geri yüklenecek aktif bir abonelik bulunamadı."
                : "No active subscription found to restore."
        }
    }

    /// Kullanıcı dostu, açıklayıcı hata mesajları üretir. `nil` dönmesi
    /// "kullanıcı vazgeçti, uyarı gösterme" anlamına gelir.
    private func friendlyErrorMessage(for error: Error) -> String? {
        let isTR = AppLanguage.isTurkish

        // RevenueCat satın almayı kendisi yürüttüğü için hatalar önce
        // `RevenueCat.ErrorCode` olarak gelir.
        if let rcError = error as? RevenueCat.ErrorCode {
            switch rcError {
            case .purchaseCancelledError:
                return nil
            case .networkError, .offlineConnectionError:
                return isTR
                    ? "İnternet bağlantısı kurulamadı. Lütfen bağlantınızı kontrol edip tekrar deneyin."
                    : "Network connection failed. Please check your connection and try again."
            case .storeProblemError:
                return isTR
                    ? "App Store ile geçici bir iletişim sorunu oluştu. Lütfen birkaç dakika sonra tekrar deneyin."
                    : "App Store is temporarily unavailable. Please try again in a few minutes."
            case .purchaseNotAllowedError:
                return isTR
                    ? "Bu cihazda uygulama içi satın alma kısıtlanmış."
                    : "In-app purchases are not allowed on this device."
            case .purchaseInvalidError, .invalidAppleSubscriptionKeyError:
                return isTR
                    ? "Ödeme bilgileri doğrulanamadı. Lütfen App Store hesap bilgilerinizi kontrol edin."
                    : "Payment invalid. Please check your App Store account settings."
            case .productNotAvailableForPurchaseError:
                return isTR
                    ? "Bu abonelik seçili App Store bölgesinde kullanılamıyor."
                    : "This subscription is not available in your region."
            case .paymentPendingError:
                return isTR
                    ? "Satın alma işlemi onay bekliyor. Onaylandığında premium özellikler otomatik olarak açılacaktır."
                    : "Purchase is pending approval. Premium unlocks automatically once it is approved."
            default:
                break
            }
        }

        // Kurtarma yolundaki doğrudan StoreKit taraması hâlâ bu hataları üretebilir.
        if let storeKitError = error as? StoreKitError {
            switch storeKitError {
            case .userCancelled:
                return nil
            case .networkError:
                return isTR
                    ? "İnternet bağlantısı kurulamadı. Lütfen bağlantınızı kontrol edip tekrar deneyin."
                    : "Network connection failed. Please check your connection and try again."
            case .systemError:
                return isTR
                    ? "App Store ile geçici bir iletişim sorunu oluştu. Lütfen birkaç dakika sonra tekrar deneyin."
                    : "App Store is temporarily unavailable. Please try again in a few minutes."
            case .notAvailableInStorefront:
                return isTR
                    ? "Bu abonelik seçili App Store bölgesinde kullanılamıyor."
                    : "This subscription is not available in your region."
            case .notEntitled:
                return isTR
                    ? "Apple Hesap Yetki Hatası: Bu hesabın uygulama içi satın alma izni yok. App Store Connect'te Sandbox Test Kullanıcısı oluşturduğunuzdan veya Ücretli Uygulama Sözleşmesi'nin aktif olduğundan emin olun."
                    : "Account Not Authorized: This Apple account is not authorized for in-app purchases. Please check Sandbox Testers in App Store Connect."
            default:
                // `.unknown`, `.unsupported` ve ileride eklenecek durumlar
                // aşağıdaki genel mesaja düşer.
                break
            }
        }

        let desc = error.localizedDescription
        let lowerDesc = desc.lowercased()
        if lowerDesc.contains("cancel") { return nil }

        // Sandbox hesap yetki hatası
        if lowerDesc.contains("not authorized") || lowerDesc.contains("yetkiniz yok") || lowerDesc.contains("izin yok") {
            return isTR
                ? "Apple Sandbox Yetki Hatası: Bu Apple hesabının Sandbox test satın alma yetkisi yok. App Store Connect > Users and Access > Sandbox Testers bölümünden bir test hesabı tanımlayıp Ayarlar > App Store > Sandbox Hesabı kısmından giriş yapın."
                : "Sandbox Authorization Error: This Apple account does not have permission to make In-App Purchases. Please add a Sandbox Tester in App Store Connect."
        }

        #if DEBUG
        return "Satın alma hatası: \(desc)"
        #else
        return isTR
            ? "Satın alma işlemi tamamlanamadı. Lütfen internet bağlantınızı ve App Store hesabınızı kontrol edip tekrar deneyin."
            : desc
        #endif
    }

    /// Aktif abonelik var mı? (iade/iptal edilenler hariç)
    /// Aynı anda yürüyen yetki taramasını tekilleştirir.
    private var refreshTask: Task<Void, Never>?

    func refreshEntitlements() async {
        if let inFlight = refreshTask {
            await inFlight.value
            return
        }
        let task = Task { @MainActor [weak self] in
            await self?.performEntitlementRefresh()
            return ()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performEntitlementRefresh() async {
        // Önceki bilinen durumla başlanır
        var active = hasActiveSubscription
        var latestExpiration = subscriptionExpirationDate

        do {
            let info = try await Purchases.shared.customerInfo()
            if let entitlement = info.entitlements[Self.entitlementID], entitlement.isActive {
                UserDefaults.standard.set(true, forKey: Self.revenueCatSyncedKey)
                active = true
                latestExpiration = entitlement.expirationDate
            } else {
                active = false
                latestExpiration = nil
            }
        } catch {
            AppLog.network.error("[Subscription] RevenueCat customerInfo fetch failed: \(error.localizedDescription, privacy: .public)")
            // Offline cache may only preserve a known, unexpired subscription
            // (or a lifetime entitlement, which has no expiry).
            // StoreKit below can still recover a verified current entitlement.
            active = active && (latestExpiration.map { $0 > Date() } ?? hasLifetimeAccess)
        }

        // Doğrudan StoreKit 2 kontrolü: RevenueCat sunucusu yetki görmüyorsa veya gecikme varsa
        // Apple'ın yerel imzalı işlemini kontrol eder.
        if let sk = await checkStoreKitEntitlement(triggerMigration: !active) {
            if !active {
                active = true
                latestExpiration = sk.expiration
            }
        }

        // Abonelik bu kontrolde sona erdiyse işaretle
        let hadEntitlement = UserDefaults.standard.bool(forKey: Self.cacheKey)
        if hadEntitlement && !active {
            entitlementJustExpired = true
        }

        if !active { signedTransactionJWS = nil }
        persistEntitlement(active: active, expiration: latestExpiration)
        entitlementsLoaded = true
        NotificationManager.shared.schedulePushSync()

        #if DEBUG
        // Teşhis: bitiş tarihi doğrudan StoreKit'in bildirdiği değerdir.
        // Xcode/Sandbox ortamlarında gerçek süreyi DEĞİL, sıkıştırılmış test
        // süresini yansıtabilir.
        if let latestExpiration {
            let hours = latestExpiration.timeIntervalSinceNow / 3_600
            AppLog.performance.debug("""
            entitlement: expires=\(latestExpiration.description, privacy: .public) \
            kalan=\(String(format: "%.2f", hours), privacy: .public) saat
            """)
        }
        #endif
    }
}
