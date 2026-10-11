import SwiftUI
import UserNotifications

/// Bildirim, Premium ve uygulama tercihlerini native iOS Form bölümlerinde sunar.
struct SettingsView: View {
    /// Sheet olarak sunulduğunda (yalnızca iPad liste-detay düzeni) sağ üstte
    /// "Kapat" gösterilir. Sayfa olarak push edildiğinde geri düğmesi zaten
    /// vardır; ikinci bir kapatma düğmesi araç çubuğunu kalabalıklaştırır.
    var showsCloseButton: Bool = false

    @State private var settings = NotificationSettings()
    /// Takip edilen yerler; bildirim kurallarının tek kaynağı.
    private let places = NotificationPlacesStore.shared
    /// Yer ekleme/düzenleme artık yaprak değil, push edilen tam ekran harita.
    @State private var placeRoute: NotificationPlace?

    @AppStorage(SignificantLocationService.preferenceKey) private var backgroundLocationUpdates = false
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue

    /// Premium kullanıcıya açık açılış tercihleri; harita ve detay ekranları
    /// bu değerleri ilk görünümde bir kez uygular.
    @AppStorage(PremiumPreference.defaultMapMode) private var prefDefaultMapMode = false
    @AppStorage(PremiumPreference.defaultSatellite) private var prefDefaultSatellite = false
    @AppStorage(PremiumPreference.defaultFaults) private var prefDefaultFaults = false
    @AppStorage(PremiumPreference.autoAIAnalysis) private var prefAutoAIAnalysis = false

    /// Liste hangi kaynakla açılsın (tüm kullanıcılara açık).
    @AppStorage(AppPreference.feltCardEnabled) private var feltCardEnabled = true

    @Environment(\.dismiss) private var dismiss
    @Environment(LocationManager.self) private var locationManager
    @State private var permissionDenied = false
    /// iOS bildirim izni. Uygulamadaki anahtar açık olsa bile izin kapalıysa
    /// hiçbir bildirim gelmez; kart bunu ayrıca gösterir.
    @State private var systemNotificationStatus: UNAuthorizationStatus?
    @Environment(\.scenePhase) private var scenePhase
    /// Bildirim açma akışı sürerken anahtarın açık görünmesini sağlar.
    @State private var isEnablingNotifications = false
    @State private var locationPermissionDenied = false
    @State private var locationServicesOff = false
    private let premium = PremiumStore.shared
    private let aftershockTracker = AftershockTracker.shared
    /// Çalan sesi izler; satırdaki canlı gösterge buna bağlıdır.
    private let soundPlayer = NotificationSoundPreviewPlayer.shared
    @State private var showPaywall = false
    @State private var showManageSubscriptions = false
    @State private var showOnboarding = false
    @State private var soundSelectionFeedback = 0
    @State private var testNotificationFeedback = 0

    /// Bildirimler GERÇEKTEN çalışıyor mu: Premium ve açık anahtar birlikte.
    /// Sunucu yalnızca Premium cihazlara bildirim gönderir. Anahtarın kayıtlı
    /// değeri (`settings.enabled`) aboneliği biten ya da bildirimleri eski
    /// sürümde açmış ücretsiz kullanıcıda `true` kalabiliyor; ekran doğrudan
    /// ona baktığı için ücretsiz kullanıcı yer listesini, dünya bölümünü ve
    /// sesleri görüyordu. Kayıtlı değer değiştirilmez: yeniden abone olunca
    /// yerler ve ayarlar olduğu gibi geri gelir.
    /// Deprem bildirimleri herkese açık (ücretsiz: büyük depremler). Yer
    /// kuralları, ses ve kritik uyarı premium bölümlerde kalır.
    private var notificationsActive: Bool { settings.enabled }

    var body: some View {
        Form {
                Section {
                    notificationStatusCard
                } header: {
                    sectionHeader(L("notifications.title"), symbol: "bell.badge.fill")
                } footer: {
                    Text(L("notifications.footer"))
                }


                if notificationsActive {
                    // Beş ayrı filtre kontrolü (kaynak, büyüklük, yakınlık,
                    // hissedilme eşiği, dünya geneli) iki bölüme indi. Eşik
                    // artık yer başına taşındığı için her satır tek başına
                    // okunabilen tam bir kural: bu noktada, bu yarıçapta, bu
                    // büyüklükten itibaren haber ver.
                    Section {
                        if places.usesLegacyRules {
                            // Güncelleyen kullanıcı hâlâ eski kuralıyla bildirim
                            // alıyor; "hiçbir yer takip edilmiyor" uyarısı burada
                            // yanlış olurdu. İlk yer, eski ayarların yarıçap ve
                            // eşiğiyle açılır.
                            LegacyRulesCard(rules: legacyRules) {
                                placeRoute = legacyRules.draftPlace(
                                    at: LocationManager.cachedCoordinate,
                                    icon: places.nextFreeIcon()
                                )
                            }
                        } else if places.hasNoActivePlace {
                            NoActivePlaceWarning()
                        }

                        if places.places.isEmpty {
                            if !places.usesLegacyRules {
                                NotificationPlacesEmptyState()
                            }
                        } else {
                            ForEach(places.places) { place in
                                Button {
                                    placeRoute = place
                                } label: {
                                    HStack {
                                        NotificationPlaceRow(place: place)
                                        Image(systemName: "chevron.right")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    // Satırın TAMAMI dokunma hedefi olsun:
                                    // aksi hâlde yalnızca metnin üstü
                                    // tıklanıyor, boşluklar tepki vermiyordu.
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete { offsets in
                                withAnimation(SismikDesign.Motion.rowSpring) {
                                    places.remove(atOffsets: offsets)
                                }
                            }
                        }

                        // "Bulunduğum yer" uygulama kapalıyken de cihazla taşınsın
                        // (önemli konum değişikliği servisi, "Her zaman" izni).
                        if places.places.contains(where: { $0.kind == .current }) {
                            Toggle(isOn: Binding(
                                get: { backgroundLocationUpdates },
                                set: { enabled in
                                    backgroundLocationUpdates = enabled
                                    SignificantLocationService.shared.setEnabled(enabled)
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L("places.background.title"))
                                    Text(L("places.background.detail"))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .tint(Color.appAction)
                        }

                        // Premium'u biten kullanıcı: yerleri silinmedi ama sunucu
                        // yalnızca ilkini, 50 km'ye kadar kullanıyor.
                        if !premium.isPremium, places.exceedsFreeLimits {
                            Label {
                                Text(L("places.free.downgrade"))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(Color.appAction)
                            }
                        }

                        if places.isFull, !premium.isPremium, !places.usesLegacyRules {
                            Button {
                                showPaywall = true
                            } label: {
                                Label(L("places.free.more"), systemImage: "lock.fill")
                                    .foregroundStyle(Color.appAction)
                            }
                        } else if !places.isFull, !places.usesLegacyRules {
                            Button {
                                // Doğrudan haritayı aç: tüm işlemler orada
                                // yürüyor, araya seçim listesi girmiyor.
                                placeRoute = NotificationPlace(
                                    name: "",
                                    icon: places.nextFreeIcon(),
                                    kind: .current,
                                    latitude: LocationManager.cachedCoordinate?.latitude ?? 39.0,
                                    longitude: LocationManager.cachedCoordinate?.longitude ?? 35.0,
                                    radiusKm: premium.isPremium ? 100 : NotificationPlace.freeMaxRadiusKm,
                                    minMagnitude: 3.0
                                )
                            } label: {
                                Label(L("places.add"), systemImage: "plus.circle.fill")
                                    .foregroundStyle(Color.appAction)
                            }
                        }
                    } header: {
                        sectionHeader(L("places.section"), symbol: "mappin.and.ellipse")
                    } footer: {
                        if premium.isPremium {
                            Text(L("places.section.footer", places.places.count, NotificationPlacesStore.limit))
                        } else {
                            Text(L("places.section.footer.free"))
                        }
                    }
                    .animation(SismikDesign.Motion.rowSpring, value: places.places.count)
                }

                if notificationsActive {
                    // Yerlerden bağımsız büyük depremler: ücretsiz katmanın
                    // tamamı, premium'da yerlerin dışındaki olaylar.
                    Section {
                        MajorAlertsSection(settings: settings, isPremium: premium.isPremium)

                        if premium.isPremium, aftershockTracker.trackedMainshockID != nil {
                            activeAftershockCard
                        }

                        testNotificationCard
                    } header: {
                        sectionHeader(L("notif.major.section"), symbol: "globe.europe.africa.fill")
                    } footer: {
                        Text(L(premium.isPremium ? "notif.major.footer.premium" : "notif.major.footer.free"))
                    }
                }

                // Premium olmayan kullanıcı da özelliği GÖRÜR. Asma kilit
                // yerine gerçek satırların aynısıyla çizilmiş örnek yerler:
                // kilit yalnızca "yasak" der, örnekler ne satın alınacağını
                // gösterir.
                // Bildirimler kapalıyken ücretsiz kullanıcı premium'un yer
                // özelliğini örnek satırlarla görür; açıkken kendi yerini düzenler.
                if premium.entitlementsLoaded, !premium.isPremium, !notificationsActive {
                    Section {
                        NotificationPlacesLockedPreview { showPaywall = true }
                    } header: {
                        sectionHeader(L("places.section"), symbol: "mappin.and.ellipse")
                    }
                }

                if notificationsActive {
                    // Bildirimin görünümü herkese açık: sunucu şablonu da bu
                    // seçime göre yazılır. Satırlar gerçek bir bildirimin
                    // önizlemesini gösterir; kullanıcı neyi seçtiğini görür.
                    Section {
                        ForEach(NotificationStyle.allCases) { style in
                            notificationStyleRow(style)
                        }
                    } header: {
                        sectionHeader(L("settings.notificationStyle.title"), symbol: "bell.badge")
                    } footer: {
                        Text(L("settings.notificationStyle.footer"))
                    }
                }

                if notificationsActive, premium.isPremium {
                    // Ses seçici yalnızca bildirimler açıkken anlamlı; kapalıyken
                    // seçilen ses hiçbir şeyi değiştirmiyordu. Ücretsiz bildirim
                    // konu mesajıyla gelir ve uygulamanın standart sesini kullanır.
                    Section {
                        ForEach(NotificationSoundOption.standardOptions) { sound in
                            soundRow(sound)
                        }
                    } header: {
                        sectionHeader(L("settings.sound.sectionTitle"), symbol: "speaker.wave.2.fill")
                    } footer: {
                        Text(L("settings.sound.footer"))
                    }
                    Section {
                        preferenceToggle(
                            title: L("settings.weeklyDigest.title"),
                            detail: L("settings.weeklyDigest.detail"),
                            isOn: $settings.weeklyDigestEnabled
                        )
                    }
                    // Kritik uyarı sesi ayrı: sessiz modu aşan uyarının olağan
                    // bildirimden kulakla ayırt edilmesi gerekiyor.
                    Section {
                        ForEach(NotificationSoundOption.criticalOptions) { sound in
                            soundRow(sound)
                        }
                    } header: {
                        sectionHeader(L("settings.criticalSound.sectionTitle"), symbol: "exclamationmark.triangle.fill")
                    } footer: {
                        Text(L("settings.criticalSound.footer"))
                    }
                } else if premium.isPremium {
                    // Bildirimler kapalıyken kuralların tamamı sessizce
                    // kayboluyordu; kullanıcı ayarların nereye gittiğini
                    // anlamıyordu. Artık nedeni yazıyor. (Premium olmayan
                    // kullanıcı yukarıdaki kilitli önizlemeyi görür.)
                    Section {
                        Label {
                            Text(L("places.rules.disabled"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "bell.slash")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if premium.entitlementsLoaded, premium.isPremium {
                    Section {
                        preferenceToggle(
                            title: L("settings.prefs.mapMode.title"),
                            detail: L("settings.prefs.mapMode.detail"),
                            isOn: $prefDefaultMapMode
                        )
                        preferenceToggle(
                            title: L("settings.prefs.satellite.title"),
                            detail: L("settings.prefs.satellite.detail"),
                            isOn: $prefDefaultSatellite
                        )
                        preferenceToggle(
                            title: L("settings.prefs.faults.title"),
                            detail: L("settings.prefs.faults.detail"),
                            isOn: $prefDefaultFaults
                        )
                        preferenceToggle(
                            title: L("settings.prefs.autoAI.title"),
                            detail: L("settings.prefs.autoAI.detail"),
                            isOn: $prefAutoAIAnalysis
                        )
                    } header: {
                        sectionHeader(L("settings.prefs.section"), symbol: "map.fill")
                    } footer: {
                        Text(L("settings.prefs.footer"))
                    }
                }

                if premium.entitlementsLoaded, premium.isPremium {
                    Section("Sismik Premium") {
                        subscriptionManagementCard
                    }
                }

                Section {
                    Toggle(isOn: $feltCardEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("settings.feltCard.title"))
                            Text(L("settings.feltCard.detail"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(Color.appAction)
                } header: {
                    sectionHeader(L("settings.list.section"), symbol: "list.bullet")
                }

                Section {
                    DisplaySettingsCard(language: $appLanguage)
                } header: {
                    sectionHeader(L("settings.display"), symbol: "textformat.size")
                }

                Section {
                    safetyNoticeCard
                } header: {
                    // Eski başlık ("Acil durumda resmî kaynakları takip et")
                    // bir bölüm adı değil, tam bir cümleydi; kartın kendisi
                    // zaten aynı şeyi söylüyor.
                    sectionHeader(
                        L("settings.safety.section"),
                        symbol: "exclamationmark.shield.fill"
                    )
                }

                Section {
                    // "Yenilikler" burada yok: kart yalnızca güncellemeden
                    // sonraki ilk açılışta bir kez gösterilir (InfoCardCenter).
                    Button {
                        showOnboarding = true
                    } label: {
                        Label(L("settings.showOnboarding"), systemImage: "arrow.counterclockwise.circle")
                    }

                    NavigationLink {
                        AboutView()
                    } label: {
                        Label(L("about.title"), systemImage: "info.circle")
                    }
                } header: {
                    sectionHeader(L("settings.app.section"), symbol: "app.badge")
                }
            }
            .formStyle(.grouped)
            .tint(Color.appAction)
            .navigationTitle(L("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L("common.close")) { dismiss() }
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Color.appAction)
                    }
                }
            }
            .alert(L("notifications.permission.off"), isPresented: $permissionDenied) {
                Button(L("open.settings")) { openSystemSettings() }
                Button(L("cancel"), role: .cancel) {}
            } message: {
                Text(L("notifications.permission.message"))
            }
            .alert(L("settings.locationRequired"), isPresented: $locationPermissionDenied) {
                Button(L("open.settings")) { openSystemSettings() }
                Button(L("cancel"), role: .cancel) {}
            } message: {
                Text(L("settings.locationRequired"))
            }
            .alert(L("settings.locationRequired"), isPresented: $locationServicesOff) {
                Button(L("open.settings")) { openSystemSettings() }
                Button(L("cancel"), role: .cancel) {}
            } message: {
                Text(L("settings.locationRequired"))
            }
            .fullScreenCover(isPresented: $showPaywall) { PaywallView() }
            // Ayarlar kendisi bir sayfa olarak açılabildiği için kart burada sunulur.
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView(locationManager: locationManager) {
                    showOnboarding = false
                }
            }
            .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
            .onChange(of: appLanguage) {
                NotificationManager.shared.scheduleIfEnabled()
            }
            .task {
                await refreshSystemNotificationStatus()
                await premium.refreshEntitlements()
                // Göç ve bilgilendirme ana ekranda yapılıyor (bkz.
                // RecentEarthquakesView): kullanıcı ayarları hiç açmasa da
                // bildirim altyapısının değiştiğini görmeli.
            }
            // iOS Ayarları'ndan izin açılıp dönüldüğünde uyarı kendiliğinden kalkar.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await refreshSystemNotificationStatus() }
            }
            .navigationDestination(item: $placeRoute) { place in
                let isNew = !places.places.contains { $0.id == place.id }
                NotificationPlaceMapEditor(
                    place: place,
                    isNew: isNew,
                    // Aynı simge iki yerde kullanılamaz: bildirimde hangi
                    // yerin tetiklendiği simgeden ayırt edilebilmeli.
                    usedIcons: places.usedIcons(excluding: place.id),
                    onSave: { saved in
                        if isNew { places.add(saved) } else { places.update(saved) }
                    },
                    onDelete: isNew ? nil : { places.remove(id: $0) }
                )
            }
            .sensoryFeedback(.selection, trigger: soundSelectionFeedback)
            .sensoryFeedback(.impact(weight: .medium), trigger: testNotificationFeedback)
        .id(appLanguage)
    }

    private var isTR: Bool { AppLanguage.isTurkish }

    /// Simgeli bölüm başlığı.
    ///
    /// Formdaki bütün satırlar aynı göründüğü için ekran uzadıkça taranması
    /// zorlaşıyordu; başlıktaki simge her bölüme bir çapa veriyor ve kullanıcı
    /// aradığı ayara göz gezdirerek ulaşıyor.
    private func sectionHeader(_ title: String, symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Color.appAction)
        }
        .font(.footnote.weight(.semibold))
        .textCase(nil)
    }

    // MARK: - Premium Açılış Tercihi Satırı

    private func preferenceToggle(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(.appAction)
    }

    // MARK: - Güvenlik Notu Kartı

    private var safetyNoticeCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("detail.importantNotice"))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Text(L("Sismik bir resmi acil servis veya erken uyarı sistemi değildir. Deprem anında lütfen resmi acil durum yönergelerine uyun."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Bildirim Durum/Özet Kartı

    private var notificationStatusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L(notificationsActive ? "settings.notif.title.on" : "settings.notif.title.off"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(notificationStatusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()

                // `isEnablingNotifications` olmadan anahtar geri sıçrıyordu:
                // kullanıcı açtığı anda binding hâlâ `settings.enabled`i (false)
                // okuyor, `enableNotifications()` ise yetki tazeleme ve izin
                // sorgusunu bekliyor. Arada anahtar kapalıya dönüp iş bitince
                // yeniden açılıyor — takılma bundan. İyimser durum, anahtarı
                // dokunuşta açık tutar.
                Toggle("", isOn: Binding(
                    get: { notificationsActive || isEnablingNotifications },
                    set: { newValue in
                        if newValue {
                            isEnablingNotifications = true
                            enableNotifications()
                        } else {
                            settings.enabled = false
                        }
                    }
                ))
                .labelsHidden()
                .tint(.appAction)
                .disabled(isEnablingNotifications)
            }

            // Uygulamadaki anahtar açık ama iOS izni kapalı: en sık "bildirim
            // gelmiyor" nedeni ve iki ayrı "bildirim" kavramının karıştığı yer.
            if notificationsActive, systemNotificationStatus == .denied {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(red: 0.80, green: 0.10, blue: 0.12))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("settings.notif.system.off.title"))
                            .font(.subheadline.weight(.semibold))
                        Text(L("settings.notif.system.off.body"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L("open.settings")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .tint(.appAction)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.80, green: 0.10, blue: 0.12).opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if notificationsActive {
                Divider()

                // Özet geçerli kuralı yansıtır: yer modelinde takip edilen yerler,
                // güncelleme sonrası eski kuralda ise kaynak ve eşik.
                if places.usesLegacyRules {
                    HStack(spacing: 0) {
                        summaryItem(
                            L("Kaynak"),
                            legacyRules.source.uppercased(),
                            "antenna.radiowaves.left.and.right",
                            Color.appAction
                        )
                        summaryDivider
                        summaryItem(
                            L("places.threshold"),
                            String(format: "%.1f+", legacyRules.minMagnitude),
                            "bolt.circle.fill",
                            MagnitudeLevel(magnitude: legacyRules.minMagnitude).color
                        )
                        summaryDivider
                        summaryItem(
                            L("places.worldMajor.section"),
                            settings.worldMajorEnabled ? L("status.on") : L("status.off"),
                            "globe.europe.africa.fill",
                            .blue
                        )
                    }
                } else {
                    HStack(spacing: 0) {
                        summaryItem(
                            L("places.section"),
                            "\(places.activePlaces.count)",
                            "mappin.and.ellipse",
                            places.hasNoActivePlace ? .secondary : Color.appAction
                        )
                        summaryDivider
                        summaryItem(
                            L("places.summary.lowest"),
                            lowestThresholdLabel,
                            "bolt.circle.fill",
                            lowestThresholdColor
                        )
                        summaryDivider
                        summaryItem(
                            L("places.worldMajor.section"),
                            settings.worldMajorEnabled ? L("status.on") : L("status.off"),
                            "globe.europe.africa.fill",
                            .blue
                        )
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Kartın açıklaması: şu an NE bildirilir, tek cümle.
    private var notificationStatusDetail: String {
        guard notificationsActive else { return L("settings.notif.detail.off") }
        if places.usesLegacyRules { return L("settings.notif.detail.legacy") }
        if !places.hasNoActivePlace { return L("settings.notif.detail.places") }
        return settings.worldMajorEnabled
            ? L("settings.notif.detail.noPlaceWorld")
            : L("settings.notif.detail.noPlace")
    }

    private func refreshSystemNotificationStatus() async {
        systemNotificationStatus = await NotificationManager.shared.authorizationStatus()
    }

    /// Eski kuralın kayıtlı ayarları; ekran açıkken değişmez (düzenleme
    /// arayüzü yok), her çizimde UserDefaults'tan okumak ucuz.
    private var legacyRules: NotificationPlacesStore.LegacyRules {
        NotificationPlacesStore.LegacyRules.stored()
    }

    /// Takip edilen yerler arasındaki EN DÜŞÜK eşik: kullanıcının pratikte
    /// hangi büyüklükten itibaren haber alacağını tek sayıyla söyler.
    private var lowestThresholdLabel: String {
        guard let lowest = places.activePlaces.map(\.minMagnitude).min() else { return "—" }
        return String(format: "%.1f+", lowest)
    }

    private var lowestThresholdColor: Color {
        guard let lowest = places.activePlaces.map(\.minMagnitude).min() else { return .secondary }
        return MagnitudeLevel(magnitude: lowest).color
    }

    private func enableNotifications() {
        Task { @MainActor in
            defer { isEnablingNotifications = false }

            // Yetki zaten yüklüyse ağ turu atlanır. Eskiden her dokunuşta
            // koşulsuz `refreshEntitlements()` çağrılıyordu; bu, RevenueCat'e
            // bir `customerInfo()` isteği demek ve yavaş bağlantıda anahtarın
            // saniyelerce yanıt vermemesine yol açıyordu. Ekran zaten açılışta
            // (`.task`) yetkiyi tazeliyor; yetki düşerse `notificationsActive`
            // anahtarı ve bildirim bölümlerini kendiliğinden kapatır.
            if !premium.entitlementsLoaded {
                await premium.refreshEntitlements()
            }
            let status = await NotificationManager.shared.authorizationStatus()
            if status == .denied {
                permissionDenied = true
            } else if status == .notDetermined {
                let granted = await NotificationManager.shared.requestAuthorization()
                if granted {
                    NotificationManager.shared.markEnabledNow()
                    settings.enableMajorAlertsIfUnset()
                    settings.enabled = true
                    // Onboarding'deki gibi: hiç yer yoksa bulunduğu konum eklenir.
                    NotificationPlacesStore.shared.addCurrentLocationPlaceIfEmpty()
                }
            } else {
                NotificationManager.shared.markEnabledNow()
                settings.enableMajorAlertsIfUnset()
                settings.enabled = true
            }
        }
    }

    // MARK: - Bildirim Görünümü

    private func notificationStyleRow(_ style: NotificationStyle) -> some View {
        let isSelected = settings.style == style
        return Button {
            guard !isSelected else { return }
            settings.style = style
            soundSelectionFeedback += 1
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L(style == .detailed ? "settings.notificationStyle.detailed" : "settings.notificationStyle.compact"))
                            .foregroundStyle(.primary)
                        Text(L(style == .detailed ? "settings.notificationStyle.detailedDetail" : "settings.notificationStyle.compactDetail"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.appAction)
                    }
                }
                NotificationStylePreview(style: style)
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSelected ? L("settings.sound.selected") : "")
    }

    // MARK: - Bildirim Sesi

    /// Native "zil sesi" seçici görünümü: her ses ayrı bir Form satırı,
    /// seçili olan sağda düz bir onay işaretiyle belirtilir — Apple'ın
    /// Ses ve Dokunuş > Zil Sesi ekranıyla aynı dil.
    private func soundRow(_ sound: NotificationSoundOption) -> some View {
        let isSelected = sound.isCritical ? settings.criticalSound == sound : settings.sound == sound
        let isPlaying = soundPlayer.playingSound == sound
        return Button {
            guard !isSelected else {
                soundPlayer.play(sound)
                return
            }
            if sound.isCritical {
                settings.criticalSound = sound
            } else {
                settings.sound = sound
            }
            soundSelectionFeedback += 1
            soundPlayer.play(sound)
        } label: {
            HStack(spacing: 12) {
                Text(sound.title)
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                // Ses çalarken hareketli hoparlör simgesi: hangi sesin
                // dinletildiği satırın kendisinde görünür.
                if isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.appAction)
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers)
                        .transition(.opacity.combined(with: .scale))
                        .accessibilityHidden(true)
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.appAction)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: isPlaying)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sound.title)
        .accessibilityValue(isSelected ? L("settings.sound.selected") : "")
        .accessibilityHint(L("settings.sound.hint"))
    }




    private var summaryDivider: some View {
        Divider()
            .frame(height: 28)
            .padding(.horizontal, 4)
    }

    private func summaryItem(_ title: String, _ val: String, _ icon: String, _ tint: Color) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                Text(val)
                    .font(.caption.weight(.bold).monospacedDigit())
            }
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Abonelik Yönetimi Kartı

    private var subscriptionManagementCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.brandGreen)

            VStack(alignment: .leading, spacing: 2) {
                Text("SİSMİK PREMIUM")
                    .font(.subheadline.weight(.bold))
                // Ömür boyu satın almanın yönetilecek bir aboneliği yok.
                Text(premium.hasLifetimeAccess
                     ? L("settings.premium.lifetime")
                     : L("Aboneliğin aktif. Tüm özellikler açık."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if !premium.hasLifetimeAccess {
                Button {
                    showManageSubscriptions = true
                } label: {
                    Text(L("Yönet"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private var activeAftershockCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.brandOrange)
                .frame(width: 40, height: 40)
                .background(Color.brandOrange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Artçı Bildirimleri Aktif"))
                    .font(.subheadline.weight(.bold))
                Text(L("Takip edilen ana depremin olası artçıları sunucudan bildirilecek."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(L("Durdur"), role: .destructive) {
                Task { await aftershockTracker.stop() }
            }
            .font(.footnote.weight(.bold))
            .frame(minHeight: 44)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Test Bildirimi Kartı

    private var testNotificationCard: some View {
        Button {
            testNotificationFeedback += 1
            Task { await NotificationManager.shared.sendTestNotification() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.brandOrange)
                Text(L("Test Bildirimi Gönder"))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

/// Bildirim biçiminin kilit ekranındaki hâlinin küçük bir kopyası. Örnek
/// metinler gerçek şablonun anahtarlarından gelir; seçilen dile göre değişir.
private struct NotificationStylePreview: View {
    let style: NotificationStyle

    private var home: String { L("places.sample.home") }
    private let place = "Saimbeyli (Adana)"

    private var title: String {
        style == .detailed
            ? "🟠 M4.2 · \(L("notif.v2.near", home))"
            : "🟠 M4.2 · \(place)"
    }
    private var subtitle: String? {
        style == .detailed ? "\(place) · \(L("notif.v2.away", 22))" : nil
    }
    private var bodyText: String {
        style == .detailed
            ? "10:44 · \(L("notif.v2.depth", 7)) · AFAD\n\(L("notif.v2.felt2"))"
            : "\(home): \(L("notif.v2.away", 22)) · 10:44"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.brandOrange)
                .frame(width: 30, height: 30)
                .overlay {
                    Image("LaunchMark")
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                }
                Text(bodyText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14, style: .continuous))
    }
}
