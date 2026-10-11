import SwiftUI
import UIKit
import CoreLocation
import MapKit

/// Son depremler — native iOS düzeni (büyük başlık, toolbar, arama) + harita modu.
struct RecentEarthquakesView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var viewModel: EarthquakeListViewModel
    @Environment(LocationManager.self) private var locationManager
    private let faultsVM = FaultLinesViewModel.shared

    enum Mode { case list, map }

    @State private var mode: Mode = .list
    @State private var showFaults = false   // fay hatları haritada varsayılan kapalı
    /// Yoğunluk (ısı) katmanı; tercih cihazda hatırlanır.
    @AppStorage("map.showDensity") private var showDensity = false
    /// Lejant açık mı? Kapalıyken tek satırlık renk şeridi kalır.
    @AppStorage("map.legendExpanded") private var legendExpanded = true
    @State private var mapFocusRequest: MapFocusRequest?
    private let majorEvents = MajorEventCenter.shared
    /// Takip edilen yerlerin yarıçap daireleri. Kullanıcının kendi kuralıyla
    /// gördüğü deprem arasında görsel bağ kuran katman; varsayılan AÇIK
    /// çünkü asıl sorusu "bu bana bildirim getirir miydi".
    @State private var showNotificationPlaces = true
    private let notificationPlaces = NotificationPlacesStore.shared
    private let permissionNotices = PermissionNoticeCenter.shared
    /// Haritaya uzun basınca açılan yer ekleme akışı.
    @State private var mapPlaceDraft: NotificationPlace?
    @State private var satellite = false    // harita varsayılan standart modda açılır
    @State private var showPaywall = false
    /// Premium ekranı hangi özelliğin vitriniyle açılsın (tetikleyene göre).
    @State private var paywallFeature: PaywallFeature = .places
    /// Dock üstü kompakt harita filtresinin açık/kapalı durumu. Ayrı bir
    /// gözlemlenebilir nesnede: yalnızca `MapFilterDock` okur, açılıp
    /// kapanırken bu ekranın gövdesi ve harita (`updateUIView`) yeniden
    /// hesaplanmaz — panel eskiden bu yüzden kasıntılı açılıyordu.
    @State private var mapFilterDock = MapFilterDockState()

    /// Harita üzerindeki BÜTÜN panel/düğme geçişleri bu eğriyi kullanır.
    ///
    /// Daha önce her geçiş kendi eğrisini seçiyordu: kart açılışı yaylı,
    /// kapanışı 0.18 sn `easeOut`, filtre paneli `snappy`, çember `easeInOut`.
    /// Aynı köşede sırayla oynayan bu farklı ritimler harita modunu tutuk
    /// gösteriyordu. Tek eğri, birinden diğerine geçerken de sürekli bir
    /// hareket veriyor.
    private static let mapOverlayAnimation: Animation = .spring(response: 0.34, dampingFraction: 0.86)

    /// Harita katmanlarının ekran kenarlarına ve sekme çubuğuna uzaklığı.
    /// Alt panellerin hepsi aynı değeri kullanır — kart, filtre ve oynatım
    /// paneli eskiden farklı boşluklarla duruyordu, kimi dock'a yapışıyordu.
    private static let mapOverlayInset: CGFloat = 14
    private static let mapOverlayBottomInset: CGFloat = 18

    private var mapOverlayAnimation: Animation? {
        reduceMotion ? nil : Self.mapOverlayAnimation
    }
    @State private var recenterToken = 0
    /// iPad harita modundaki yığının yolu. iPhone liste ve harita için aşağıdaki
    /// tek `detailPath` yolunu paylaşarak görünüm geçişinde stack değiştirmez.
    @State private var mapPath = NavigationPath()
    /// Haritada seçilen deprem — alt bilgi kartında gösterilir.
    @State private var selectedMapQuake: Earthquake?
    /// Artınca haritadaki işaret seçimi programatik olarak kaldırılır.
    @State private var mapDeselectToken = 0
    @State private var regionPlayback = MapRegionPlaybackModel()

    /// Harita katmanının uyanık olup olmadığı. Mod değişiminde hemen değişmez:
    /// listeye geçerken çapraz geçiş bitene kadar harita çizilmeye devam eder,
    /// yoksa listenin altından sert bir kesme görünür.
    @State private var mapLayerActive = false
    private let premium = PremiumStore.shared

    @State private var localSearchText = ""
    /// Liste tepesindeki kartların EKRANDA gösterilen hâli. Canlı durum
    /// (izinler, konum, hissedilir deprem) açılışta ve yenilemede birkaç kez
    /// değişebiliyor; her değişim listenin üstüne satır ekleyip çıkarıyor ve
    /// içerik zıplıyordu. Gösterilen hâl yalnızca durum oturunca, liste en
    /// üstteyken ve aşağı çekip yenileme sürmüyorken güncellenir.
    @State private var shownNotice: ListNotice?
    @State private var shownFeltCard: FeltEventCenter.Card?
    @State private var isPullRefreshing = false
    @State private var isListNearTop = true
    /// Haritadan listeye her dönüşte artar: liste yeniden kurulur ve
    /// navigation bar büyük başlık + arama alanıyla yeniden açılır. (Arama
    /// yalnızca listede bağlı; kaldırılıp eklenince bar daralmış kalıyordu.)
    @State private var listIdentity = 0
    /// Widget deep link'i: bu kimlikteki depreme git.
    @Binding var pendingQuakeID: String?
    /// Docktaki "Son Depremler" sekmesine yeniden dokunuldukça artar (RootView).
    var reselectToken: Int = 0
    /// Liste başa kaydırılsın diye artar (`handleTabReselect`).
    @State private var listScrollToTopToken = 0

    /// Premium açılış tercihleri (Ayarlar → Harita ve Detay Tercihleri).
    /// Yalnızca ilk görünümde bir kez uygulanır; kullanıcı oturum içinde
    /// modu/katmanı değiştirdiğinde tercih geri yazılmaz.
    @AppStorage(PremiumPreference.defaultMapMode) private var prefDefaultMapMode = false
    @AppStorage(PremiumPreference.defaultSatellite) private var prefDefaultSatellite = false
    @AppStorage(PremiumPreference.defaultFaults) private var prefDefaultFaults = false
    /// Listenin hangi kaynakla açılacağı — premium gerektirmez.
    @AppStorage(AppPreference.defaultListSource) private var defaultListSource = AppPreference.allListSources
    @AppStorage(AppPreference.feltCardEnabled) private var feltCardEnabled = true
    @State private var didApplyLaunchPreferences = false
    /// Premium açılış tercihleri yetki doğrulanana kadar bekler.
    @State private var premiumLaunchPreferencesPending = true
    @State private var launchPreferencesStartedAt = Date()
    /// Yetki açılıştan en geç bu kadar sonra gelirse tercih yine uygulanır;
    /// sonrası (ör. oturum ortasında satın alma) ekranı yerinden oynatmaz.
    private static let premiumLaunchWindow: TimeInterval = 20

    /// iPad/geniş pencere: liste solda kalır, seçilen deprem sağdaki sütunda
    /// açılır. iPhone ve dar iPad pencerelerinde gerçek NavigationStack
    /// kullanılır; iPhone artık çöktürülmüş bir NavigationSplitView üzerinden
    /// çalışmadığı için iPad gezinme durumu telefona etki etmez.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Detay sütununun (iPhone'da tek yığının) navigasyon yolu.
    @State private var detailPath = NavigationPath()
    /// iPad'in sağ detay sütununda gösterilen deprem. NavigationLink'in
    /// çökmüş/yayılmış sütun yorumuna bırakılmaz; satır seçimi açıkça yönetilir.
    @State private var selectedDetailQuake: Earthquake?
    /// Yalnızca iPad'in liste-detay düzeninde kullanılır: 400pt'lik kenar
    /// çubuğuna push edilirse yardım/ayarlar okunmaz bir şeride sıkışır,
    /// bu yüzden orada sayfa olarak sunulur. iPhone'da bu ekranlar alttan
    /// kayan bir sheet değil, normal navigasyon push'u ile açılır.
    @State private var utilitySheet: UtilityRoute?
    /// Bildirim altyapısı yerler modeline geçti. Güncelleyen eski kullanıcı
    /// ayarları hiç açmasa da bunu görmeli — sessizce daha az bildirim
    /// almasındansa bir kez rahatsız edilmesi yeğdir.
    @State private var showNotificationMigrationNotice = false
    /// Geniş düzen cihaz türüne değil, verilen alana göre seçilir: iPad,
    /// iPhone Duo'nun iç ekranı ve iPhone'da yeniden boyutlanan pencere aynı
    /// kuralı izler (Apple: arayüz deyimine göre ekran boyutu varsayma).
    /// Regular genişlik yetse de iki sütun için alan dar olabilir (Duo iç
    /// ekranı, iPad mini/11" dikey); o zaman tek yığın, genişletilmiş sütunla.
    private var usesSplitNavigation: Bool {
        guard horizontalSizeClass == .regular else { return false }
        return containerWidth == 0 || containerWidth >= Self.splitMinimumWidth
    }
    @State private var containerWidth: CGFloat = 0
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
    /// Bunun altında sistem kenar çubuğunu yan yana değil detayın ÜSTÜNE
    /// bindiriyor (iPad mini dikeyde 744 pt'de ölçüldü); detay örtülüp
    /// karartılıyor. Bu genişliklerde tek sütun yığın daha okunur.
    private static let splitMinimumWidth: CGFloat = 900
    /// 900–1000 pt arası pencerelerde liste sütunu daralır; detay telefon
    /// genişliğinin altına inmez.
    private var sidebarWidths: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        containerWidth > 0 && containerWidth < 1_000 ? (320, 360, 420) : (400, 480, 620)
    }

    /// Bağlantı yok: ne sistem monitörü ne de son isteğin sonucu ağ görüyor.
    /// İkisi birden kontrol edilir — monitör bazen kısa süre geç kalıyor.
    private var isOffline: Bool {
        NetworkMonitor.shared.isOffline || viewModel.isOffline
    }

    var body: some View {
        Group {
            if usesSplitNavigation {
                // iPad'de liste-detay split'i ile tam genişlikli harita ayrı
                // kapsayıcılardır; harita mod değişiminde bellekte kalır.
                ZStack {
                    padListSplit
                        .modifier(ModeVisibility(isVisible: mode == .list))

                    padMapScreen
                        .modifier(ModeVisibility(isVisible: mode == .map))
                }
                .animation(reduceMotion ? nil : SismikDesign.Motion.rowSpring, value: mode)
            } else {
                // iPhone davranışı özellikle ayrı tutulur: yalnız aktif kök
                // çizilir; iPad split state'i ve görünmez navigation bar'lar
                // telefonun başlık/arama düzenine karışmaz.
                phoneScreen
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            // Yalnızca eşik/sütun sınıfı değişince yaz: her piksel değişimi
            // (pencere yeniden boyutlanırken) tüm ekranı yeniden kurmasın.
            let old = containerWidth
            let crossesSplit = (old >= Self.splitMinimumWidth) != (width >= Self.splitMinimumWidth)
            let crossesSidebar = (old < 1_000) != (width < 1_000)
            if old == 0 || crossesSplit || crossesSidebar { containerWidth = width }
        }
        .tint(.appAction)
        .onChange(of: reselectToken) { _, _ in handleTabReselect() }
        // Mod değişiminin dokunsal geri bildirimi. `UIImpactFeedbackGenerator`
        // her değişimde yeniden kurulmak yerine sistemin paylaşılan motoruna
        // bırakılır ve kullanıcının dokunsal geri bildirim ayarına uyar.
        .sensoryFeedback(.selection, trigger: mode)
    }

    /// Sekmeye yeniden dokunma — UIKit sekme çubuğunun alışılmış davranışı:
    /// önce açık detaydan köke dönülür, kökteyken liste en başa kayar.
    private func handleTabReselect() {
        if usesSplitNavigation {
            if mode == .map {
                if !mapPath.isEmpty { mapPath = NavigationPath() }
                return
            }
        } else if !detailPath.isEmpty {
            detailPath = NavigationPath()
            return
        }
        if mode == .list { listScrollToTopToken &+= 1 }
    }

    /// Listenin ilk satırının kimliği; başa kaydırmanın hedefi.
    private var listTopRowID: String {
        if usesSplitNavigation { return ListTopRow.modePicker }
        if let notice = shownNotice { return notice.id }
        if shownFeltCard != nil { return ListTopRow.feltCard }
        return ListTopRow.filters
    }

    private enum ListTopRow {
        static let modePicker = "list.top.modePicker"
        static let feltCard = "list.top.feltCard"
        static let filters = "list.top.filters"
    }

    /// iPad geniş düzende liste solda, açıkça seçilen deprem sağda gösterilir.
    private var padListSplit: some View {
        // Görünürlük açıkça `.all`: varsayılan (`.automatic`) dikey yönde
        // listeyi gizleyip ekranda yalnızca boş "deprem seç" alanını
        // bırakıyordu (iPad dikey, iPhone Duo iç ekranı). Kenar çubuğu
        // düğmesiyle kullanıcı yine gizleyebilir.
        NavigationSplitView(columnVisibility: $splitVisibility) {
            listRoot
                .navigationSplitViewColumnWidth(min: sidebarWidths.min, ideal: sidebarWidths.ideal, max: sidebarWidths.max)
        } detail: {
            NavigationStack {
                Group {
                    if let selectedDetailQuake {
                        EarthquakeDetailView(earthquake: selectedDetailQuake)
                            .id(selectedDetailQuake.id)
                    } else {
                        detailPlaceholder
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// iPhone'da aynı anda yalnız aktif kök oluşturulur. Görünmez bir List ile
    /// Map aynı navigation bar'ı paylaşmadığı için scroll-edge, büyük başlık ve
    /// arama alanı durumları modlar arasında sızmaz.
    @ViewBuilder
    private var phoneScreen: some View {
        NavigationStack(path: $detailPath) {
            configuredRoot(
                phoneModeLayers,
                titleDisplayMode: mode == .list ? .large : .inline,
                toolbarScheme: mode == .map && satellite ? .dark : nil
            )
            .navigationDestination(for: Earthquake.self) {
                EarthquakeDetailView(earthquake: $0)
            }
            .navigationDestination(for: UtilityRoute.self) { route in
                switch route {
                case .help: HelpCenterView()
                case .settings: SettingsView()
                }
            }
        }
    }

    /// iPhone'da liste ve harita tek navigasyon yığınının kökünde iki katman
    /// olarak durur; geçiş 140 ms'lik çapraz geçişle akar ve harita bellekte
    /// kalır. Modları ayrı `NavigationStack`'lere bölmek her geçişte
    /// MKMapView'ı sıfırdan kuruyor ("pop-in" gecikmesi), kökteki `.task`ı
    /// yeniden çalıştırıyor ve çapraz geçişi tamamen kaldırıyordu.
    private var phoneModeLayers: some View {
        ZStack {
            // Harita altta, liste üstte: 140 ms'lik çapraz geçiş boyunca iki
            // katman üst üste binerken listenin opak zemini haritayı örter.
            mapContent.modifier(ModeVisibility(isVisible: mode == .map))
            listContent.id(listIdentity).modifier(ModeVisibility(isVisible: mode == .list))
        }
        .animation(reduceMotion ? nil : SismikDesign.Motion.rowSpring, value: mode)
    }

    /// Kenar çubuğu (iPhone'da kök): liste, başlığı, araması ve araç çubuğu.
    private var listRoot: some View {
        configuredRoot(listContent, titleDisplayMode: .large)
    }

    /// Yalnız iPad'de kullanılan tam genişlikli harita stack'i.
    private var padMapScreen: some View {
        NavigationStack(path: $mapPath) {
            mapContent
                .navigationTitle(L("recent.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent(includingModePicker: true) }
                // Uydu modunda koyu zemin: başlık ve araç çubuğu beyaz görünsün.
                .toolbarColorScheme(satellite ? .dark : nil, for: .navigationBar)
                .navigationDestination(for: Earthquake.self) { EarthquakeDetailView(earthquake: $0) }
        }
    }

    /// Liste ve haritanın ortak sunum/lifecycle davranışları. iPhone'da tek
    /// kez, iPad'de daima bellekte kalan liste kökünde uygulanır.
    private func configuredRoot<Content: View>(
        _ content: Content,
        titleDisplayMode: NavigationBarItem.TitleDisplayMode,
        toolbarScheme: ColorScheme? = nil
    ) -> some View {
        content
            .navigationTitle(L("recent.title"))
            .navigationBarTitleDisplayMode(titleDisplayMode)
            .toolbar { toolbarContent(includingModePicker: !usesSplitNavigation) }
            .toolbarColorScheme(toolbarScheme, for: .navigationBar)
            .task {
                // "Bildirimlerin yerlere taşındı" uyarısı yalnızca Premium'a:
                // sunucu ücretsiz cihaza bildirim göndermez, uyarı ona
                // kullanamayacağı bir kurulum vaat ediyordu. Bekleyen uyarı
                // silinmez; kullanıcı abone olursa sonraki açılışta görür.
                if NotificationPlacesStore.shared.migrateLegacySettingsIfNeeded(), premium.isPremium {
                    showNotificationMigrationNotice = true
                }
            }
            .alert(L("places.migrated.title"), isPresented: $showNotificationMigrationNotice) {
                Button(L("places.migrated.action")) {
                    NotificationPlacesStore.shared.acknowledgeMigrationNotice()
                    openUtility(.settings)
                }
                Button(L("places.migrated.later"), role: .cancel) {
                    NotificationPlacesStore.shared.acknowledgeMigrationNotice()
                }
            } message: {
                Text(L("places.migrated.body"))
            }
            .sheet(item: $mapPlaceDraft) { draft in
                NavigationStack {
                    NotificationPlaceMapEditor(
                        place: draft,
                        isNew: true,
                        usedIcons: notificationPlaces.usedIcons(),
                        onSave: { notificationPlaces.add($0) }
                    )
                }
            }
            .sheet(item: $utilitySheet) { route in
                NavigationStack {
                    switch route {
                    case .help: HelpCenterView(showsCloseButton: true)
                    case .settings: SettingsView(showsCloseButton: true)
                    }
                }
            }
            .fullScreenCover(isPresented: $showPaywall, onDismiss: {
                if premium.isPremium && mode == .map {
                    Task { await viewModel.loadMapData() }
                }
            }) {
                LazyView { PaywallView(initialFeature: paywallFeature) }
            }
            .task {
                localSearchText = viewModel.searchText
                navigateToPendingQuake()
                applyLaunchPreferencesIfNeeded()
                viewModel.clampRangesForPremium(premium.isPremium)
                if premium.isPremium { await viewModel.loadMapData() }
            }
            .onChange(of: premium.isPremium) { _, isPremium in
                viewModel.clampRangesForPremium(isPremium)
                if isPremium {
                    applyPremiumLaunchPreferencesIfNeeded()
                    Task { await viewModel.loadMapData() }
                }
            }
            .onChange(of: mode) { _, newMode in
                // Kullanıcı modu kendisi seçtiyse bekleyen açılış tercihi onu ezmez.
                premiumLaunchPreferencesPending = false
                if newMode == .list {
                    selectedMapQuake = nil
                    if regionPlayback.isEnabled { regionPlayback.toggleTracking() }
                    if !usesSplitNavigation { listIdentity += 1 }
                }
            }
            // Ayarlar sayfa olarak açıldığı için kök görünüm canlı kalır;
            // tercih değiştiği anda liste yeni kaynağa geçer.
            .onChange(of: defaultListSource) { _, _ in applyDefaultListSource() }
            .onChange(of: RemoteConfigCenter.shared.config.hiddenSources) { _, _ in applyDefaultListSource() }
            // Liste başı izin kartları için bildirim/kritik uyarı durumu.
            .task { await permissionNotices.refresh() }
            .onChange(of: pendingQuakeID) { _, _ in navigateToPendingQuake() }
            // Diziyi izlemek, SwiftUI'ın her yoklamada yüzlerce `Earthquake`
            // kaydını alan alan `==` ile karşılaştırmasına yol açıyordu — bu
            // iş ana thread'de yapılıyor. Sayaç aynı bilgiyi tek `Int`
            // karşılaştırmasıyla verir.
            .onChange(of: viewModel.dataRevision) { _, _ in navigateToPendingQuake() }
            // Liste başı deprem kartı: veri, kaynak seçimi, büyük olay ya da
            // ayar değişince yeniden karar verilir.
            .task(id: feltCardKey) {
                FeltEventCenter.shared.update(quakes: viewModel.earthquakes, enabledSources: viewModel.enabledSources)
            }
            .onReceive(NotificationCenter.default.publisher(for: .sismikOpenMap)) { _ in
                if premium.isPremium {
                    mode = .map
                } else {
                    presentPaywall(.layers)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sismikOpenPaywall)) { _ in
                presentPaywall(.places)
            }
            .onChange(of: viewModel.searchText) { _, newValue in
                if localSearchText != newValue { localSearchText = newValue }
            }
            .onChange(of: localSearchText) { _, newValue in
                if viewModel.searchText != newValue { viewModel.searchText = newValue }
            }
    }

    private var detailPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(L("detail.selectPrompt"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Toolbar

    /// Ayarlar'daki açılış tercihlerini oturumda yalnızca bir kez uygular.
    private func applyLaunchPreferencesIfNeeded() {
        guard !didApplyLaunchPreferences else { return }
        didApplyLaunchPreferences = true
        launchPreferencesStartedAt = Date()

        applyDefaultListSource()
        applyPremiumLaunchPreferencesIfNeeded()
    }

    /// Premium açılış tercihleri (harita modu, uydu, fay katmanı).
    ///
    /// Açılışta yetki bir anlığına "ücretsiz" görünebiliyor: RevenueCat'in
    /// önbellekteki müşteri bilgisi ya da bitiş tarihi olmayan yetki (ömür
    /// boyu, promosyon) doğrulanana kadar. Eskiden tercih tam o anda
    /// tüketiliyor ve oturum boyunca hiç uygulanmıyordu — "Haritayla aç"
    /// çalışmıyordu. Artık yetki gelene kadar bekler; kullanıcı modu kendisi
    /// değiştirdiyse ya da açılış penceresi geçtiyse uygulanmaz.
    private func applyPremiumLaunchPreferencesIfNeeded() {
        guard premiumLaunchPreferencesPending, premium.isPremium else { return }
        premiumLaunchPreferencesPending = false
        guard Date().timeIntervalSince(launchPreferencesStartedAt) < Self.premiumLaunchWindow else { return }
        if prefDefaultMapMode { mode = .map }
        if prefDefaultSatellite { satellite = true }
        if prefDefaultFaults { showFaults = true }
    }

    /// Listedeki kaynak menüsünde seçilen (kalıcı) kaynağı uygular: uygulama
    /// her açılışta son seçilen kaynakla açılır. Seçim değiştiği anda da
    /// çağrılır. Kaynak tercihi premium gerektirmez.
    /// Menüde gösterilen kaynaklar: uzak yapılandırmada gizlenenler çıkar
    /// (`hidden_sources`, ör. verisi bozuk bir ajans).
    private var menuSources: [String] {
        let remote = RemoteConfigCenter.shared.config
        return EarthquakeListViewModel.allSources.filter { !remote.isSourceHidden($0) }
    }

    private func applyDefaultListSource() {
        let sources: Set<String>
        if menuSources.contains(defaultListSource) {
            sources = [defaultListSource]
        } else {
            // "all", eski "auto" ve tanınmayan değerler: tüm kaynaklar.
            sources = Set(EarthquakeListViewModel.allSources)
        }
        guard viewModel.enabledSources != sources else { return }
        viewModel.enabledSources = sources
    }

    private var feltCardKey: String {
        "\(viewModel.dataRevision)|\(viewModel.enabledSources.sorted())|\(MajorEventCenter.shared.event?.id ?? "")|\(feltCardEnabled)"
    }

    /// Boş liste: nedenini söyler ve tek dokunuşla çözüm sunar. Tek kaynak
    /// seçiliyken boş liste (ör. CENC sakin bir günde) hata gibi görünüyordu;
    /// artık kaynağın bölgesel olduğu ve son 24 saatte kayıt yayımlamadığı yazar.
    @ViewBuilder
    private var emptyListState: some View {
        let isSearching = !localSearchText.trimmingCharacters(in: .whitespaces).isEmpty
        if isSearching {
            ContentUnavailableView.search
        } else if viewModel.enabledSources.count == 1, let source = viewModel.enabledSources.first {
            let info = Self.sourceInfo(source)
            ContentUnavailableView {
                Label(L("list.empty.source.title", info.name), systemImage: "antenna.radiowaves.left.and.right.slash")
            } description: {
                Text(L("list.empty.source.body", info.name, L(info.regionKey)))
            } actions: {
                Button(L("list.empty.showAll")) {
                    defaultListSource = AppPreference.allListSources
                }
                .buttonStyle(.sismikPrimary(height: 44))
                .frame(maxWidth: 260)
            }
        } else if viewModel.minMagnitude > 0 {
            ContentUnavailableView {
                Label(L("list.empty.magnitude.title"), systemImage: "waveform.path.ecg")
            } description: {
                Text(L("list.empty.magnitude.body"))
            } actions: {
                Button(L("list.empty.clearFilter")) {
                    viewModel.minMagnitude = 0
                }
                .buttonStyle(.sismikPrimary(height: 44))
                .frame(maxWidth: 260)
            }
        } else {
            ContentUnavailableView.search
        }
    }

    /// Liste başı bilgilendirmesinin görünümü ve eylemleri.
    @ViewBuilder
    private func listNoticeView(_ notice: ListNotice) -> some View {
        switch notice {
        case .remote(let remote):
            RemoteNoticeBanner(notice: remote)
        case .appUpdate:
            ListInfoCard(
                icon: "arrow.down.app.fill",
                tint: .brandOrange,
                title: L("Yeni Sürüm Mevcut"),
                message: L("Uygulamanın yeni sürümü yayında. Güncellemek için tıklayın."),
                actionTitle: L("Update"),
                actionIcon: "arrow.down.circle.fill",
                action: { UIApplication.shared.open(AppUpdateNotice.storeURL) }
            )
        case .autoPlace(let place):
            AutoPlaceNoticeCard(
                place: place,
                onEdit: {
                    withAnimation(.snappy) {
                        notificationPlaces.dismissAutoPlaceNotice()
                        shownNotice = nil
                    }
                    openUtility(.settings)
                },
                onDismiss: {
                    withAnimation(.snappy) {
                        notificationPlaces.dismissAutoPlaceNotice()
                        shownNotice = nil
                    }
                }
            )
        case .noActivePlace:
            // Kapatılamaz: bildirimler açık ama hiçbir yer takip edilmiyor.
            ListInfoCard(
                icon: "exclamationmark.triangle.fill",
                tint: Color(red: 0.80, green: 0.10, blue: 0.12),
                title: L("places.noneWarning.title"),
                message: L("places.noneWarning.body"),
                actionTitle: L("places.add"),
                actionIcon: "plus.circle.fill",
                action: { openUtility(.settings) }
            )
        case .notifications(let denied):
            ListInfoCard(
                icon: "bell.slash.fill",
                tint: .brandOrange,
                title: L("notice.notif.title"),
                message: L(denied ? "notice.notif.body.denied" : "notice.notif.body.ask"),
                actionTitle: L(denied ? "open.settings" : "permissions.notif.allowButton"),
                actionIcon: denied ? "gear" : "bell.badge.fill",
                action: {
                    if denied { openSystemSettings() } else { Task { await permissionNotices.requestNotifications() } }
                },
                onDismiss: { snoozeNotice("notifications") }
            )
        case .earthquakeAlertsOff:
            ListInfoCard(
                icon: "bell.slash.fill",
                tint: .brandOrange,
                title: L("notice.notif.title"),
                message: L("notice.alerts.off.body"),
                actionTitle: L("notice.alerts.off.enable"),
                actionIcon: "bell.badge.fill",
                action: {
                    withAnimation(.snappy) {
                        permissionNotices.enableEarthquakeAlerts()
                        shownNotice = nil
                    }
                },
                onDismiss: { snoozeNotice("earthquakeAlerts") }
            )
        case .location(let denied):
            ListInfoCard(
                icon: "location.slash.fill",
                tint: .blue,
                title: L("notice.location.title"),
                message: L(denied ? "notice.location.body.denied" : "notice.location.body.ask"),
                actionTitle: L(denied ? "open.settings" : "permissions.location.allowButton"),
                actionIcon: denied ? "gear" : "location.fill",
                action: {
                    if denied {
                        openSystemSettings()
                    } else {
                        Task {
                            if await LocationManager.servicesEnabled() {
                                locationManager.requestPermission()
                            } else {
                                openSystemSettings()
                            }
                        }
                    }
                },
                onDismiss: { snoozeNotice("location") }
            )
        case .criticalAlerts(let settingsRequired):
            ListInfoCard(
                icon: "exclamationmark.triangle.fill",
                tint: Color(red: 0.80, green: 0.10, blue: 0.12),
                title: L("notice.critical.title"),
                message: L("notice.critical.body"),
                actionTitle: L(settingsRequired ? "open.settings" : "notice.critical.allow"),
                actionIcon: settingsRequired ? "gear" : "speaker.wave.3.fill",
                action: {
                    if settingsRequired { openSystemSettings() } else { Task { await permissionNotices.requestCriticalAlerts() } }
                },
                onDismiss: { snoozeNotice("criticalAlerts") }
            )
        }
    }

    private func snoozeNotice(_ id: String) {
        withAnimation(.snappy) {
            permissionNotices.snooze(id)
            shownNotice = nil
        }
    }

    // MARK: Tepe kartlarının kararlı gösterimi

    /// Canlı durumdan hesaplanan (henüz ekrana yansımamış) kartlar.
    private var liveTopCards: TopCards {
        let felt = FeltEventCenter.shared.card
        let notice = permissionNotices.topNotice(
            locationStatus: locationManager.authorizationStatus,
            hasFeltCard: felt != nil
        )
        return TopCards(notice: notice, felt: felt)
    }

    struct TopCards: Equatable {
        var notice: ListNotice?
        var felt: FeltEventCenter.Card?
    }

    struct TopCardsSyncKey: Equatable {
        var live: TopCards
        var frozen: Bool
    }

    /// Gösterilen kartları canlı duruma getirir.
    /// - İçerik güncellemesi (aynı kart, ör. büyüklük revizyonu) hemen uygulanır:
    ///   satır eklenip çıkmaz, zıplama olmaz.
    /// - Kart eklenip çıkması: durum 0,4 sn oturmalı (açılışta yanıp sönen
    ///   izin/konum kartları), liste en üstte olmalı ve yenileme bitmiş olmalı.
    private func syncTopCards(_ live: TopCards, frozen: Bool) async {
        let shown = TopCards(notice: shownNotice, felt: shownFeltCard)
        guard live != shown else { return }
        let sameSlots = (live.notice?.id == shown.notice?.id) && ((live.felt == nil) == (shown.felt == nil))
        if sameSlots {
            shownNotice = live.notice
            shownFeltCard = live.felt
            return
        }
        guard !frozen else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        withAnimation(.snappy(duration: 0.3)) {
            shownNotice = live.notice
            shownFeltCard = live.felt
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Filtre satırındaki tek tip seçici görünümü.
    private func filterChip(symbol: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .contentTransition(.opacity)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
        .contentShape(Capsule())
    }

    /// Kaynak seçimi (eskiden Ayarlar'daydı). Seçim kalıcıdır: uygulama bir
    /// sonraki açılışta aynı kaynakla açılır. Menüde her kaynağın bayrağı,
    /// adı ve kapsadığı bölge görünür.
    private var sourceMenu: some View {
        let selected = menuSources.contains(defaultListSource) ? defaultListSource : AppPreference.allListSources
        return Menu {
            Button {
                defaultListSource = AppPreference.allListSources
            } label: {
                Label(L("filter.sources.all"), systemImage: selected == AppPreference.allListSources ? "checkmark" : "globe")
            }
            Divider()
            ForEach(menuSources, id: \.self) { source in
                let info = Self.sourceInfo(source)
                Button {
                    defaultListSource = source
                } label: {
                    if source == selected {
                        Label {
                            Text(verbatim: "\(info.flag)  \(info.name)")
                            Text(L(info.regionKey))
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    } else {
                        Text(verbatim: "\(info.flag)  \(info.name)")
                        Text(L(info.regionKey))
                    }
                }
            }
        } label: {
            filterChip(
                symbol: "antenna.radiowaves.left.and.right",
                text: selected == AppPreference.allListSources ? L("filter.sources.allShort") : Self.sourceInfo(selected).name
            )
        }
        .tint(Color.primary)
        .accessibilityLabel(L("filter.sources.title"))
    }

    /// Kaynağın menüde görünen bayrağı, adı ve bölgesi.
    private static func sourceInfo(_ tag: String) -> (flag: String, name: String, regionKey: String) {
        switch tag {
        case "AFAD": ("🇹🇷", "AFAD", "source.region.turkiye")
        case "KANDİLLİ": ("🇹🇷", "Kandilli", "source.region.turkiye")
        case "EMSC": ("🇪🇺", "EMSC", "source.region.euromed")
        case "USGS": ("🇺🇸", "USGS", "source.region.world")
        case "NOA": ("🇬🇷", "NOA", "source.region.greece")
        case "JMA": ("🇯🇵", "JMA", "source.region.japan")
        case "CENC": ("🇨🇳", "CENC", "source.region.china")
        case "BMKG": ("🇮🇩", "BMKG", "source.region.indonesia")
        case "GEONET": ("🇳🇿", "GeoNet", "source.region.newzealand")
        default: ("🌐", tag, "source.region.world")
        }
    }

    /// iPad'de mod seçici listenin kendi başlık bloğunda, aramanın hemen
    /// altında durur. Daha önce tüm pencereyi kaplayan yüzen bir katmandaydı:
    /// dikey iPad'de kenar çubuğunun araç çubuğunu örtüyor, yatayda ise boş
    /// detay sütununun ortasında sahipsiz kalıyordu. Harita moduna geçildiğinde
    /// seçici tam genişlikli haritanın araç çubuğuna taşınır (`toolbarContent`).
    private var padModePickerRow: some View {
        modePicker(width: nil)
            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// `width` nil ise seçici kapsayıcısını doldurur (liste başlık satırı);
    /// sabit değer verildiğinde araç çubuğunda mod değişimiyle genişlik
    /// oynamaz, böylece navigation bar ikinci kez yerleşim almaz.
    private func modePicker(width: CGFloat?) -> some View {
        // Etiketler `Label` iken segment, bulunduğu kaba göre bazen yalnız
        // simgeye düşüyordu: kenar çubuğunda "Liste | Harita", haritanın araç
        // çubuğunda iki ikon görünüyordu. Düz metin her iki yerde de aynı
        // okunur kontrolü verir.
        Picker(L("list.view.mode"), selection: $mode) {
            Text(L("list.view.list")).tag(Mode.list)
            Text(L("list.view.map")).tag(Mode.map)
        }
        .pickerStyle(.segmented)
        .tint(.appAction)
        .frame(width: width)
    }

    /// Yardım ve Ayarlar. iPhone'da (ve dar iPad penceresinde) sayfa olarak
    /// push edilir — geri düğmesiyle dönülen, kenardan kenara normal bir ekran.
    /// Yalnızca iPad'in liste-detay bölmesinde sheet kalır: dar kenar çubuğuna
    /// push edilen bir form okunmaz hâle geliyordu.
    private func openUtility(_ route: UtilityRoute) {
        if usesSplitNavigation {
            utilitySheet = route
        } else {
            detailPath.append(route)
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(includingModePicker: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                openUtility(.help)
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .tint(.appAction)
            .foregroundStyle(.primary)
            .accessibilityLabel(L("help.navTitle"))
        }

        // iPhone'da ve iPad'in tam genişlikli harita ekranında seçici başlığın
        // yerinde ortalanır. iPad'in liste-detay bölmesinde kenar çubuğunun
        // araç çubuğu 400pt'ye sığmadığı için seçici listenin başlık bloğuna
        // iner (bkz. `padModePickerRow`).
        if includingModePicker {
            ToolbarItem(placement: .principal) {
                modePicker(width: 170)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                openUtility(.settings)
            } label: {
                Image(systemName: "gearshape")
            }
            .tint(.appAction)
            .foregroundStyle(.primary)
            .accessibilityLabel(L("tab.settings"))
        }
    }

    // MARK: Liste

    @ViewBuilder
    private var listContent: some View {
        // Çevrimdışıyken önbellekteki deprem listesi GÖSTERİLMEZ. Eskiden
        // yalnızca önbellek de boşsa engelleniyor, veri varsa bir uyarı
        // şeridiyle birlikte gösteriliyordu — ama o liste dakikalar, hatta
        // saatler eski olabiliyor ve deprem uygulamasında bayat bir liste
        // "yeni deprem yok" gibi okunuyor. Bağlantı yokken tek doğru cevap
        // veriyi hiç göstermemek.
        if isOffline {
            offlineBlockingView
        } else if viewModel.viewState.isInitialLoading && viewModel.earthquakes.isEmpty {
            // İskelet yükleme: boş ekran + spinner yerine gerçek satır
            // silüetleri gösterilir — algılanan açılış süresi kısalır.
            listSkeleton
        } else if viewModel.isSortingAndLoadingArchive && viewModel.earthquakes.isEmpty {
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text(L("Büyüklük sıralaması için son 24 saatin verileri derleniyor..."))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(AppLanguage.isTurkish
                     ? "\(viewModel.earthquakes.count) sarsıntı yüklendi"
                     : "\(viewModel.earthquakes.count) earthquakes loaded")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
        } else if let error = viewModel.errorMessage, viewModel.earthquakes.isEmpty {
            ContentUnavailableView {
                Label(L("error.connection"), systemImage: "wifi.slash")
            } description: {
                Text(error)
            } actions: {
                Button { Task { await viewModel.load() } } label: { RetryButtonLabel(title: L("retry")) }
                    .buttonStyle(.sismikPrimary)
                    .frame(maxWidth: 280)
            }
            .background(Color(.systemGroupedBackground))
        } else {
            earthquakeList
        }
    }

    private var offlineBlockingView: some View {
        ContentUnavailableView {
            Label(L("İnternet Bağlantısı Yok"), systemImage: "wifi.slash")
        } description: {
            Text(L("Deprem listesini görüntülemek için internete bağlanın. Bayat veriyle yanlış bilgilendirmeyi önlemek için liste çevrimdışıyken gösterilmez."))
        } actions: {
            Button { Task { await viewModel.load(forceRefresh: true) } } label: { RetryButtonLabel(title: L("retry")) }
                .buttonStyle(.sismikPrimary)
                .frame(maxWidth: 280)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var earthquakeList: some View {
        let isPremium = premium.isPremium
        return ScrollViewReader { proxy in
        List {
            Group {
                if usesSplitNavigation { padModePickerRow.id(ListTopRow.modePicker) }

                // Tepede en fazla bir bilgilendirme (duyuru, kapalı izin, yer
                // yok, kendiliğinden eklenen yer, güncelleme). Deprem kartı
                // görünürken hiçbiri çıkmaz; bkz. ListNoticeCards.swift.
                if let notice = shownNotice {
                    listNoticeView(notice)
                        .id(notice.id)
                        .transition(.opacity)
                }

                // Hissedilir deprem kartı (FeltEventCenter): kullanıcının
                // konumunda/yerlerinde hissedilmiş olabilecek deprem ya da
                // büyük olay. Kapatılabilir; büyüklük güncel resmî kayıttan.
                if let card = shownFeltCard {
                    MajorEventCard(
                        card: card,
                        aftershockCount: MajorEventCenter.shared.aftershockCount(in: viewModel.earthquakes),
                        onOpen: { openListDetail(card.quake, resetsPhonePath: true) },
                        onDismiss: {
                            withAnimation(SismikDesign.Motion.rowSpring) {
                                FeltEventCenter.shared.dismiss()
                                shownFeltCard = nil
                            }
                        }
                    )
                    .id(ListTopRow.feltCard)
                    .transition(.opacity)
                    // Detaydaki "Artçılar" ile aynı sayı; liste yenilendikçe (en
                    // sık 2 dk'da bir) tazelenir.
                    .task(id: "\(card.majorEvent?.id ?? "")-\(viewModel.dataRevision)") {
                        if card.majorEvent != nil { await MajorEventCenter.shared.refreshAftershockCount() }
                    }
                }

                // Filtre satırı: büyüklük, kaynak ve sıralama aynı boyutta üç
                // kompakt seçici. Eskiden sıralama geniş bir segment kontrolüydü
                // ve kaynak seçimi Ayarlar'daydı.
                HStack(spacing: 8) {
                    // Canlı akış göstergesi: ayrı bir satır yerine çubukta.
                    Circle()
                        .fill(Color.brandGreen)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(L("badge.live"))

                    Menu {
                        Picker(L("legend.magnitude"), selection: $viewModel.minMagnitude) {
                            Text(L("Tüm Büyüklükler")).tag(0.0)
                            Text(verbatim: "M 3.0+").tag(3.0)
                            Text(verbatim: "M 4.0+").tag(4.0)
                            Text(verbatim: "M 5.0+").tag(5.0)
                            Text(verbatim: "M 6.0+").tag(6.0)
                        }
                    } label: {
                        filterChip(
                            symbol: "waveform.path.ecg",
                            text: viewModel.minMagnitude == 0.0
                                ? L("Tümü")
                                : "M\(viewModel.minMagnitude.formatted(.number.precision(.fractionLength(0))))+"
                        )
                    }
                    .tint(Color.primary)
                    .accessibilityLabel(L("legend.magnitude"))

                    sourceMenu

                    Spacer(minLength: 0)

                    Menu {
                        Picker(L("list.sort.title"), selection: $viewModel.sortMode) {
                            Label(L("list.sort.newest"), systemImage: "clock").tag(EarthquakeListViewModel.SortMode.newest)
                            Label(L("legend.magnitude"), systemImage: "bolt.fill").tag(EarthquakeListViewModel.SortMode.magnitude)
                        }
                    } label: {
                        filterChip(
                            symbol: "arrow.up.arrow.down",
                            text: viewModel.sortMode == .newest ? L("list.sort.newest") : L("legend.magnitude")
                        )
                    }
                    .tint(Color.primary)
                    .accessibilityLabel(L("list.sort.title"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                // Diğer kartlarla aynı köşe (SismikDesign.Radius.card). Eskiden
                // 14 pt'ydi; içindeki 30 pt'lik kapsül seçicilerle (15 pt
                // yarıçap) köşeler birbirine uymuyor, çubuk sıkışık duruyordu.
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous))
                .animation(.snappy, value: viewModel.sortMode)
                .animation(.snappy, value: defaultListSource)
                .id(ListTopRow.filters)

                if viewModel.isSortingAndLoadingArchive {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L("Büyüklük sıralaması için son 24 saat indiriliyor..."))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.purple)
                }

                // Arama kapsam bilgisi: tüm kullanıcılar için son 24 saat.
                if !localSearchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchScopeBanner
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Öne çıkan deprem büyük olayın kendisiyse ikinci kez gösterilmez.
                // Seçili kaynağın son 24 saatteki en büyüğü; her kaynakta
                // görünür. Yalnızca aynı deprem zaten üstteki kartta
                // gösteriliyorsa ikinci kez gösterilmez.
                if let featured = viewModel.featuredQuake,
                   shownFeltCard.map({
                       abs($0.quake.date.timeIntervalSince(featured.date)) > 120
                           || $0.quake.clLocation.distance(from: featured.clLocation) > 100_000
                   }) ?? true {
                    FeaturedQuakeCard(
                        earthquake: featured,
                        isWorldwide: viewModel.enabledSources == Set(EarthquakeListViewModel.allSources)
                    ) {
                        openListDetail(featured, resetsPhonePath: true)
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            if viewModel.filteredAll.isEmpty {
                emptyListState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .padding(.top, 40)
            } else {
                // Zaman bölümleri (en yeni sıralamada): Son 1 saat, Bugün, Dün…
                // Satırlar iOS'un gruplu listesinde; ayrı yüzen kartlar
                // ekrana daha az deprem sığdırıyordu.
                ForEach(Self.listSections(viewModel.filtered, sortMode: viewModel.sortMode)) { section in
                    Section {
                        ForEach(section.quakes) { earthquake in
                            Button {
                                openListDetail(earthquake)
                            } label: {
                                EarthquakeRow(
                                    earthquake: earthquake,
                                    isNew: viewModel.freshQuakeIDs.contains(earthquake.id),
                                    showsTsunami: earthquake.tsunami && isPremium,
                                    showsChevron: false
                                )
                            }
                            .buttonStyle(ListCellButtonStyle())
                            // Sistemin varsayılan hücre boşluğundan sıkı: bir ekranda daha çok kayıt.
                            .listRowInsets(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                ShareLink(item: shareText(for: earthquake)) {
                                    Label(L("share"), systemImage: "square.and.arrow.up")
                                }
                                .tint(.appAction)
                            }
                            .onAppear {
                                // Sona ~8 satır kala VEYA son satırda yeni sayfayı önden yükle —
                                // kullanıcı dibe varmadan içerik hazır olur (akıcı kaydırma).
                                if earthquake.id == viewModel.prefetchTriggerID
                                    || earthquake.id == viewModel.filtered.last?.id {
                                    Task {
                                        await viewModel.loadMore()
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(section.title)
                            Spacer()
                            Text("\(section.quakes.count)")
                                .monospacedDigit()
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                    }
                }
                if viewModel.canLoadMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Text(L("list.loadingMore"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    // Görünür olduğunda yalnızca bir sayfa yükle. Sürekli dönen görev
                    // açılışta arka arkaya ağ + filtreleme başlatıp CPU'yu yükseltiyordu.
                    .task {
                        guard viewModel.canLoadMore else { return }
                        await viewModel.loadMore()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(14)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .sismikContentWidth()
        // Bölge/şehir araması: filtreleme mantığı zaten ViewModel'de vardı,
        // arayüzde ilk kez erişilebilir hale geliyor (debounce'lu).
        // Arama kutusu yalnızca liste modunda gösterilir. Harita modunda
        // navigation bar'ın altındaki arama alanı haritayı gölgeliyordu.
        .modifier(ListSearchable(isEnabled: mode == .list, isWide: usesSplitNavigation, text: $localSearchText))
        .refreshable {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            isPullRefreshing = true
            await viewModel.refreshFromPull()
            isPullRefreshing = false
        }
        // Kartlar yalnızca liste en üstteyken eklenip çıkar: aşağıdayken
        // üstte satır belirmesi okunan satırları iterdi.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top < 60
        } action: { _, nearTop in
            if nearTop != isListNearTop { isListNearTop = nearTop }
        }
        .task(id: TopCardsSyncKey(live: liveTopCards, frozen: isPullRefreshing || !isListNearTop)) {
            await syncTopCards(liveTopCards, frozen: isPullRefreshing || !isListNearTop)
        }
        .onChange(of: listScrollToTopToken) { _, _ in
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
                proxy.scrollTo(listTopRowID, anchor: .top)
            }
        }
        }
    }

    /// Arama penceresi bilgilendirmesi — tüm kullanıcılar için son 24 saat.
    private var searchScopeBanner: some View {
        HStack(spacing: 8) {
            Text(L("Arama son 24 saati kapsıyor"))
                .font(.footnote.weight(.medium))
            Spacer(minLength: 4)
        }
        .foregroundStyle(Color.brandOrange)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.brandOrange.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// İlk açılış iskeleti — satır silüetleri (redacted placeholder).
    private var listSkeleton: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Capsule().fill(Color(.secondarySystemGroupedBackground)).frame(width: 130, height: 26)
                    Spacer()
                    Capsule().fill(Color(.secondarySystemGroupedBackground)).frame(width: 90, height: 22)
                }
                .padding(.bottom, 2)

                ForEach(0..<8, id: \.self) { _ in
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                            .frame(width: 58, height: 52)
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(.secondarySystemGroupedBackground))
                                .frame(height: 14)
                                .frame(maxWidth: 210)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(.secondarySystemGroupedBackground))
                                .frame(width: 130, height: 10)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground).opacity(0.5),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Color(.systemGroupedBackground))
        .redacted(reason: .placeholder)
        .overlay(alignment: .bottom) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("data.loading.initial"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 24)
        }
        .allowsHitTesting(false)
    }

    /// Bildirim/widget'tan gelen deprem kimliğine git.
    /// Önce akışta arar; bulunamazsa bildirim payload'ında taşınan veriden açar
    /// (eski deprem listeden düşmüş olsa bile detay her zaman açılır).
    private func navigateToPendingQuake() {
        guard let id = pendingQuakeID else { return }

        let quake = viewModel.earthquakes.first(where: { $0.id == id })
            ?? NotificationManager.consumePendingQuake(id: id)

        guard let quake else { return } // veri henüz yüklenmediyse onChange tekrar dener

        if mode != .list { withAnimation(.easeInOut(duration: 0.2)) { mode = .list } }
        openListDetail(quake, resetsPhonePath: true)
        pendingQuakeID = nil
    }

    /// Liste detay seçimini cihaz sunumundan bağımsız tek noktada yönetir.
    /// iPad geniş düzende değer doğrudan sağ sütuna bağlanır; iPhone'un özgün
    /// görünümünde programatik path push edilir ve sistem satır oku oluşmaz.
    private func openListDetail(_ quake: Earthquake, resetsPhonePath: Bool = false) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if usesSplitNavigation {
            selectedDetailQuake = quake
        } else {
            if resetsPhonePath { detailPath = NavigationPath() }
            detailPath.append(quake)
        }
    }

    /// Harita detayları iPhone'da aynı kök stack'e, iPad'de haritanın kendi
    /// tam genişlikli stack'ine açılır.
    private func openMapDetail(_ quake: Earthquake) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if usesSplitNavigation {
            mapPath.append(quake)
        } else {
            detailPath.append(quake)
        }
    }

    /// Hızlı paylaşım metni (uzun basma menüsü için).
    private func shareText(for quake: Earthquake) -> String {
        var text = String(format: L("detail.share.format"),
               quake.displayTitle,
               quake.magnitude.formatted(.number.precision(.fractionLength(1))),
               quake.depth.depthKmText,
               quake.sourceTag)
        // Premium: alıcıda uygulamayı/detayı açan akıllı bağlantı.
        if premium.isPremium, let link = QuakeShareLink.url(for: quake) {
            text += "\n" + link.absoluteString
        }
        return text
    }

    /// Sistem menüsü kullanan tek-seçimli veri kaynağı kontrolü.
    // MARK: Harita

    @ViewBuilder
    private var mapContent: some View {
        if !premium.isPremium {
            mapPremiumPreview
        } else {
            ZStack {
                // Harita, listenin sayfalama/aramasından bağımsız 30 günlük veri
                // havuzunu kullanır; yüklenene dek liste
                // verisi gösterilir.
                EarthquakeMapPlaybackHost(
                    // Çevrimdışıyken işaretler çizilmez: listedeki gerekçenin
                    // aynısı — bayat bir harita "bölgede bir şey yok" gibi
                    // okunuyor. Harita zemini kalır, veri katmanı boşalır.
                    isActive: mapLayerActive,
                    earthquakes: isOffline ? [] : viewModel.mapFiltered,
                    dataRevision: viewModel.mapDataRevision,
                    playbackEarthquakes: mapPlaybackPool,
                    playbackSourceRevision: mapPlaybackSourceRevision,
                    faultOverlays: faultsVM.overlays,
                    showFaults: showFaults,
                    showDensity: showDensity,
                    focusRequest: mapFocusRequest,
                    notificationPlaces: premium.isPremium ? notificationPlaces.places : [],
                    showNotificationPlaces: showNotificationPlaces && premium.isPremium,
                    onLongPressCoordinate: { coordinate in
                        guard premium.isPremium else {
                            presentPaywall(.places)
                            return
                        }
                        guard !notificationPlaces.isFull else { return }
                        mapPlaceDraft = NotificationPlace(
                            name: "",
                            icon: notificationPlaces.nextFreeIcon(),
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude,
                            radiusKm: 100,
                            minMagnitude: 3.0
                        )
                    },
                    satellite: satellite,
                    recenterToken: recenterToken,
                    deselectToken: mapDeselectToken,
                    userLocation: locationManager.location,
                    playbackModel: regionPlayback,
                    onSelect: { quake in
                        // İşarete dokununca eski MapKit balonu yerine modern,
                        // SwiftUI alt bilgi kartı açılır (daha hızlı ve okunaklı).
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(mapOverlayAnimation) {
                            selectedMapQuake = quake
                        }
                    },
                    onDeselect: {
                        withAnimation(mapOverlayAnimation) {
                            selectedMapQuake = nil
                        }
                    }
                )
                .ignoresSafeArea() // map covers full screen including top navigation bar and status bar
                .modifier(MapScrollEdgeHost())

                if isOffline {
                    ContentUnavailableView {
                        Label(L("İnternet Bağlantısı Yok"), systemImage: "wifi.slash")
                    } description: {
                        Text(L("Deprem listesini görüntülemek için internete bağlanın. Bayat veriyle yanlış bilgilendirmeyi önlemek için liste çevrimdışıyken gösterilmez."))
                    } actions: {
                        Button {
                            Task { await viewModel.loadMapData(force: true) }
                        } label: {
                            RetryButtonLabel(title: L("retry"))
                        }
                        .buttonStyle(.sismikPrimary)
                        .frame(maxWidth: 280)
                    }
                    .frame(maxWidth: 360)
                    .background(.regularMaterial, in: .rect(cornerRadius: 22))
                    .padding(.horizontal, 20)
                } else if viewModel.mapViewState.isInitialLoading && viewModel.mapFiltered.isEmpty {
                    LoadingCardSkeleton(rowCount: 2)
                        .frame(maxWidth: 320)
                        .padding(.horizontal, 24)
                        .transition(.opacity)
                } else if viewModel.mapViewState.failure != nil && viewModel.mapFiltered.isEmpty {
                    ContentUnavailableView {
                        Label(L("error.connection"), systemImage: "map.fill")
                    } description: {
                        Text(L("error.dataUnavailable"))
                    } actions: {
                        Button {
                            Task { await viewModel.loadMapData(force: true) }
                        } label: {
                            RetryButtonLabel(title: L("retry"))
                        }
                        .buttonStyle(.sismikPrimary)
                        .frame(maxWidth: 280)
                    }
                    .frame(maxWidth: 360)
                    .background(.regularMaterial, in: .rect(cornerRadius: 22))
                    .padding(.horizontal, 20)
                }

                MapRegionPlaybackOverlay(model: regionPlayback)

                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 10) {
                            magnitudeLegend
                        }
                        Spacer()
                        mapTopRightButtons
                    }
                    .padding(.horizontal, Self.mapOverlayInset)
                    .padding(.top, 12)
                    Spacer()
                }

                // Haritanın tek alt yığını: üstte açılan panel, altında sabit
                // düğme sırası. Üçü (deprem kartı, filtre paneli, oynatım
                // paneli) aynı yeri paylaştığı için tek bir dalda toplandı;
                // düğme sırası hep onların ALTINDA kaldığından hiçbir panel
                // filtreyi ya da çemberi örtmüyor.
                VStack(spacing: 10) {
                    Spacer()

                    if regionPlayback.isEnabled {
                        MapRegionPlaybackControls(model: regionPlayback) { quake in
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            openMapDetail(quake)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if let quake = selectedMapQuake {
                        MapQuakeCard(
                            earthquake: quake,
                            userLocation: locationManager.location,
                            onDetail: {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                openMapDetail(quake)
                            },
                            onClose: {
                                mapDeselectToken += 1
                                withAnimation(mapOverlayAnimation) {
                                    selectedMapQuake = nil
                                }
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        // Filtre düğmesi ve paneli. Deprem kartı ya da oynatım
                        // paneli ekranı devraldığında ikisi de ortadan kalkar.
                        MapFilterDock(
                            state: mapFilterDock,
                            viewModel: viewModel,
                            animation: mapOverlayAnimation,
                            onPaywall: { presentPaywall(.layers) }
                        ) {
                            mapCircleButton(icon: "line.3.horizontal.decrease",
                                            active: viewModel.mapActiveFilterCount > 0,
                                            badge: viewModel.mapActiveFilterCount,
                                            label: L("filter")) {
                                mapFilterDock.isOpen = true
                            }
                            if let event = majorEvents.event, !event.isExpired {
                                majorEventChip(event)
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, Self.mapOverlayInset)
                .padding(.bottom, Self.mapOverlayBottomInset)
                .animation(mapOverlayAnimation, value: selectedMapQuake?.id)
                .animation(mapOverlayAnimation, value: regionPlayback.isEnabled)
            }
            // Fay katmanı ~7 MB'lık dünya GeoJSON'ı: çözümlemesi saniyeler
            // sürüyor ve daha önce yalnızca butona BASILDIKTAN sonra
            // başlıyordu — düğme basılı görünüp fay çizgileri geç geliyordu.
            // Artık harita açılır açılmaz arka planda hazırlanır; butona
            // basıldığında katman çoğunlukla anında çizilir.
            .task(id: showFaults) {
                if showFaults && faultsVM.segments.isEmpty { await faultsVM.load() }
            }
            .task(id: mode) {
                guard mode == .map else { return }
                Task { await faultsVM.load() }
                await viewModel.loadMapData()
            }
            .task(id: mode) {
                if mode == .map {
                    mapLayerActive = true
                    return
                }
                // Çapraz geçiş süresi kadar canlı kal, sonra uykuya geç.
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled else { return }
                mapLayerActive = false
            }
            .onChange(of: regionPlayback.isEnabled) { _, isEnabled in
                if isEnabled {
                    mapFilterDock.isOpen = false
                    selectedMapQuake = nil
                    mapDeselectToken += 1
                }
            }
        }
    }

    // MARK: - Harita Premium Önizlemesi

    /// Premium olmayan kullanıcıya harita yerine gösterilen tanıtım: tek canlı
    /// sahne harita ekranını (düğmeler, filtre ve oynatım panelleri) taklit
    /// ederek özellikleri sırayla gösterir. Eskiden gerçek bir MapKit haritası
    /// (3B arazi) çiziyordu; ücretsiz kullanıcı sekmeyi her açtığında GPU
    /// harcıyordu.
    private var mapPremiumPreview: some View {
        ScrollView {
            PremiumFeatureTeaser(
                title: L("premiumPreview.map.title"),
                subtitle: L("premiumPreview.map.subtitle"),
                buttonTitle: L("premiumPreview.map.unlockButton"),
                tint: .appAction,
                items: [
                    .init(id: "faults", icon: "point.bottomleft.forward.to.point.topright.scurvepath",
                          title: L("premiumPreview.map.feature.faults.title"),
                          detail: L("premiumPreview.map.feature.faults.detail"), paywallFeature: .layers),
                    .init(id: "density", icon: "aqi.medium",
                          title: L("premiumPreview.map.feature.density.title"),
                          detail: L("premiumPreview.map.feature.density.detail"), paywallFeature: .layers),
                    .init(id: "playback", icon: "play.rectangle.fill",
                          title: L("premiumPreview.map.feature.playback.title"),
                          detail: L("premiumPreview.map.feature.playback.detail"), paywallFeature: .playback),
                    .init(id: "places", icon: "mappin.and.ellipse",
                          title: L("premiumPreview.map.feature.places.title"),
                          detail: L("premiumPreview.map.feature.places.detail"), paywallFeature: .places),
                    .init(id: "filters", icon: "line.3.horizontal.decrease.circle.fill",
                          title: L("premiumPreview.map.feature.filters.title"),
                          detail: L("premiumPreview.map.feature.filters.detail"), paywallFeature: .layers),
                    .init(id: "location", icon: "location.viewfinder",
                          title: L("premiumPreview.map.feature.location.title"),
                          detail: L("premiumPreview.map.feature.location.detail"), paywallFeature: .layers)
                ],
                onUnlock: { feature in presentPaywall(feature) }
            ) { phase, isAnimating in
                MapToolkitHero(phase: MapToolkitHero.Phase(rawValue: phase) ?? .faults, isAnimating: isAnimating)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 36)
            .sismikContentWidth()
        }
        .scrollIndicators(.never)
        .background(Color(.systemGroupedBackground))
    }

    private var mapPlaybackPool: [Earthquake] {
        viewModel.mapQuakes.isEmpty ? viewModel.earthquakes : viewModel.mapQuakes
    }

    private var mapPlaybackSourceRevision: Int {
        viewModel.mapDataRevision &* 31 &+ viewModel.dataRevision
    }

    /// Harita sağ üst köşesindeki 4 buton (çember, fay, uydu, konuma dön).
    /// iOS 26'da tek bir `GlassEffectContainer` içinde gruplanmazlarsa, çember
    /// butonunun `selected` (tint'li) duruma geçmesi komşu camlı butonların
    /// konumunu/şeklini de hafifçe kaydırıyordu — bu container o sıçramayı önler.
    @ViewBuilder
    private var mapTopRightButtons: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                mapTopRightButtonsContent
            }
        } else {
            mapTopRightButtonsContent
        }
    }

    private var mapTopRightButtonsContent: some View {
        VStack(spacing: 12) {
            MapRegionPlaybackToggleButton(model: regionPlayback)
            // `withAnimation` yok: durum değişimi haritanın overlay'lerini
            // yeniden kuran `updateUIView`'i de aynı işleme sarıyor ve
            // dokunuşun görsel yanıtını geciktiriyordu. Düğme artık anında
            // döner; veri hâlâ hazırlanıyorsa yerinde bir çark gösterir.
            mapCircleButton(icon: "point.bottomleft.forward.to.point.topright.scurvepath",
                            active: showFaults,
                            // Yükleme başarısız olursa çark sonsuza dek dönmez;
                            // simge geri gelir ve yeniden denemek için basılabilir.
                            isBusy: showFaults && faultsVM.overlays.isEmpty && faultsVM.errorMessage == nil,
                            label: showFaults ? L("faults.hide") : L("faults.show")) {
                showFaults.toggle()
            }
            mapCircleButton(icon: "aqi.medium",
                            active: showDensity,
                            label: showDensity ? L("map.density.hide") : L("map.density.show")) {
                showDensity.toggle()
            }
            mapCircleButton(icon: "mappin.and.ellipse",
                            active: showNotificationPlaces && premium.isPremium,
                            label: showNotificationPlaces
                                ? L("places.map.hide")
                                : L("places.map.show")) {
                guard premium.isPremium else {
                    presentPaywall(.places)
                    return
                }
                showNotificationPlaces.toggle()
            }
            mapCircleButton(icon: satellite ? "map.fill" : "globe.americas.fill",
                            active: satellite,
                            label: satellite ? L("map.standard") : L("map.satellite")) {
                satellite.toggle()
            }
            mapCircleButton(icon: "location.fill",
                            active: false,
                            label: L("map.recenter")) {
                // Programatik kamera hareketinden önce oynatmayı durdur;
                // yeni merkez için çember sorgusu harita durunca yenilenir.
                if regionPlayback.isPlaying { regionPlayback.togglePlayback() }
                recenterToken += 1
            }
        }
    }

    private func mapCircleButton(
        icon: String,
        active: Bool,
        badge: Int = 0,
        isBusy: Bool = false,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        // Dokunma alanı görsel daireden BÜYÜK ve açıkça tanımlı.
        //
        // Önceki hâlde rozet `ZStack`'te kardeş öğeydi ve `offset` ile dışarı
        // taşıyordu; düğmenin yerleşim sınırları rozetin durumuna göre
        // oynuyordu. Ayrıca `contentShape` verilmediği için dokunulabilir alan
        // arka plandaki dairenin çizim sınırlarına bağlıydı. İkisi birlikte
        // dokunuşun bazen ıskalanmasına yol açıyordu.
        //
        // Artık: rozet `overlay` (yerleşimi etkilemez), gövde sabit 48pt,
        // çevresinde 4pt görünmez pay ve `contentShape(.rect)` ile 56×56'lık
        // net bir hedef.
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(active ? .white : .appAction)
                } else {
                    Image(systemName: icon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(Color.appAction))
                }
            }
            .frame(width: 48, height: 48)
            .sismikGlassChip(in: Circle(), tint: .appAction, selected: active)
            .shadow(
                color: active ? Color.appAction.opacity(0.28) : .black.opacity(0.12),
                radius: 8,
                y: 3
            )
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Color.appAction, in: .circle)
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
                        .offset(x: 4, y: -4)
                        .allowsHitTesting(false)
                }
            }
            .padding(4)
            .contentShape(.rect)
        }
        .buttonStyle(.sismikPressable)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }

    /// Normal ve çember (bölge izleme) harita modlarında ortak kullanılan
    /// büyüklük lejantı — nokta boyutu haritadaki gerçek işaret ölçeğini yansıtır.
    private var magnitudeLegend: some View {
        Button {
            withAnimation(mapOverlayAnimation) { legendExpanded.toggle() }
        } label: {
            Group {
                if legendExpanded {
                    legendCard(title: L("legend.magnitude")) {
                        ForEach(MagnitudeLevel.allCases, id: \.self) { level in
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(level.color)
                                    .frame(
                                        width: level.playbackLegendDiameter,
                                        height: level.playbackLegendDiameter
                                    )
                                    .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 1) }
                                    .frame(width: 18, height: 18)
                                Text(level.range).font(.caption.monospacedDigit())
                            }
                        }
                    }
                } else {
                    // Kapalı hâl: haritayı örtmeyen tek satırlık renk şeridi.
                    HStack(spacing: 4) {
                        Text("M")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        ForEach(MagnitudeLevel.allCases, id: \.self) { level in
                            Circle()
                                .fill(level.color)
                                .frame(width: 9, height: 9)
                                .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 0.8) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.sismikPressable)
        .accessibilityLabel(L("Deprem rengi ve büyüklük ölçeği"))
        .accessibilityHint(L(legendExpanded ? "map.legend.collapse" : "map.legend.expand"))
    }

    /// Büyük olay sürerken haritada tek dokunuşla olaya odaklanan çip
    /// (sunucu: `major_event`). Olay listede de kartla duyuruluyor; harita
    /// açıkken kullanıcı artçı dağılımını görmek için oraya gitmek ister.
    private func majorEventChip(_ event: MajorEventCenter.Event) -> some View {
        let quake = event.earthquake
        return Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if viewModel.mapTimeRange == .day,
               Date().timeIntervalSince(event.occurredAt) > 20 * 3600 {
                viewModel.mapTimeRange = .week
            }
            mapFocusRequest = MapFocusRequest(
                id: "\(event.id)-\(Date().timeIntervalSince1970)",
                coordinate: quake.coordinate.clCoordinate,
                radiusKm: event.magnitude >= 7 ? 250 : 90,
                quakeID: event.id
            )
            withAnimation(mapOverlayAnimation) {
                selectedMapQuake = viewModel.mapFiltered.first { $0.id == event.id } ?? quake
            }
        } label: {
            HStack(spacing: 8) {
                Text(quake.magnitudeString)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(quake.level.foregroundOnColor)
                    .frame(minWidth: 34, minHeight: 28)
                    .background(quake.magnitudeColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("map.majorEvent.title"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.brandRed)
                    Text(quake.displayTitle)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Image(systemName: "scope")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.appAction)
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 280, alignment: .leading)
            .sismikGlassChip(in: Capsule(), tint: .appAction, selected: false)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .contentShape(.rect)
        }
        .buttonStyle(.sismikPressable)
        .accessibilityLabel("\(L("map.majorEvent.title")): \(quake.magnitudeString) \(quake.displayTitle)")
    }

    private func legendCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(11)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}

// MARK: - Harita filtre dock'u

@MainActor
@Observable
final class MapFilterDockState {
    var isOpen = false
}

/// Filtre düğmesi ile kompakt filtre panelinin yer değiştirdiği alt dock.
/// Açık/kapalı durumu yalnızca burada okunur; geçiş bu küçük görünümle
/// sınırlı kalır.
private struct MapFilterDock<Buttons: View>: View {
    let state: MapFilterDockState
    let viewModel: EarthquakeListViewModel
    let animation: Animation?
    let onPaywall: () -> Void
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(spacing: 10) {
            if state.isOpen {
                // Kompakt filtre paneli: sayfa (sheet) yerine dock'un hemen
                // üzerinde yaşayan hafif kart — harita görünür kalır.
                MapFilterPanel(viewModel: viewModel) {
                    state.isOpen = false
                } onPaywall: {
                    onPaywall()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                HStack {
                    buttons()
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .animation(animation, value: state.isOpen)
    }
}

private enum UtilityRoute: Hashable, Identifiable {
    case help
    case settings

    var id: Self { self }
}

/// Arama alanını yalnızca liste modunda ekler.
private struct ListSearchable: ViewModifier {
    let isEnabled: Bool
    /// iPad'de `.automatic` arama alanını araç çubuğuna sıkıştırıyor ve dolu
    /// bir çubukta hiç çizmiyordu; kenar çubuğunda Mail/Notlar gibi başlığın
    /// altında sabit durması gerekir. iPhone'da kaydırınca gizlenir.
    var isWide: Bool = false
    @Binding var text: String

    /// Arama yalnızca liste modunda (listeyi süzer). Haritada, özellikle
    /// Premium önizlemesinde, boşta duran bir arama alanı yanıltıcıydı.
    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(
                text: $text,
                placement: .navigationBarDrawer(displayMode: isWide ? .always : .automatic),
                prompt: L("list.search.prompt")
            )
        } else {
            content
        }
    }
}

/// Liste/harita geçişinde bellekte kalan katmanı görünür/görünmez yapar
/// (opacity + hit-testing + erişilebilirlik) — ZStack içindeki uzun modifier
/// zincirini tip denetleyicisi için sadeleştirir.
/// Sistemin yumuşak kaydırma kenarı efektini (liste modundaki) yalnızca
/// kaydırma görünümleri çizer; harita bir kaydırma görünümü olmadığı için kökteki
/// `scrollEdgeEffectStyle` ona hiç uygulanmıyordu. iOS 27'de harita, kaydırılmayan
/// bir ScrollView içine alınır: aynı yerel efekti sistem çizer, kaydırma kapalı
/// olduğu için haritanın kaydırma ve yakınlaştırma hareketleri etkilenmez.
private struct MapScrollEdgeHost: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            // Boyut `containerRelativeFrame` ile değil, ölçülen kaptan verilir:
            // uygulama doğrudan harita moduyla açıldığında (Ayarlar → "Haritayla
            // aç") ilk yerleşimde kabın genişliği 0 okunuyor ve çerçeve öyle
            // kalıyordu — MKMapView 0 genişlikte, ekran bembeyaz.
            GeometryReader { proxy in
                ScrollView {
                    content.frame(width: proxy.size.width, height: proxy.size.height)
                }
                .scrollDisabled(true)
            }
            // Harita çubukların altına uzansın: efekt altındaki haritayı
            // yumuşatır (yoksa çubukların altı boş kalıp düz görünüyor).
            .ignoresSafeArea()
        } else {
            content
        }
    }
}

private struct ModeVisibility: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}


extension RecentEarthquakesView {
    /// Premium ekranını, onu tetikleyen özelliğin vitrin sayfasıyla açar.
    fileprivate func presentPaywall(_ feature: PaywallFeature) {
        paywallFeature = feature
        showPaywall = true
    }
}

// MARK: - Liste bölümleri

struct EarthquakeListSection: Identifiable {
    let id: String
    let title: String
    let quakes: [Earthquake]
}

extension RecentEarthquakesView {
    /// En yeni sıralamada zaman bölümleri; büyüklük sıralamasında tek bölüm
    /// (bölmek sıralamayı bozardı). Liste zaten tarihe göre sıralı geldiği
    /// için tek geçişte gruplanır.
    static func listSections(_ quakes: [Earthquake], sortMode: EarthquakeListViewModel.SortMode, now: Date = Date()) -> [EarthquakeListSection] {
        guard !quakes.isEmpty else { return [] }
        if sortMode == .magnitude {
            return [EarthquakeListSection(id: "magnitude", title: L("list.section.byMagnitude"), quakes: quakes)]
        }
        // Liste gövdesi her çizildiğinde çalışır: deprem başına takvim
        // hesabı ve dört yerelleştirme araması yerine sınırlar bir kez
        // hesaplanır, başlık yalnızca yeni bölüm açılınca çözülür.
        let calendar = Calendar.current
        let hourAgo = now.addingTimeInterval(-3_600)
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        func bucketID(_ date: Date) -> String {
            if date >= hourAgo { return "hour" }
            if date >= startOfToday { return "today" }
            if date >= startOfYesterday { return "yesterday" }
            return "older"
        }
        func title(for id: String) -> String {
            switch id {
            case "hour": return L("list.section.lastHour")
            case "today": return L("list.section.today")
            case "yesterday": return L("list.section.yesterday")
            default: return L("list.section.earlier")
            }
        }
        var sections: [EarthquakeListSection] = []
        var currentID = ""
        var current: [Earthquake] = []
        for quake in quakes {
            let id = bucketID(quake.date)
            if id != currentID, !current.isEmpty {
                sections.append(.init(id: currentID, title: title(for: currentID), quakes: current))
                current = []
            }
            currentID = id
            current.append(quake)
        }
        if !current.isEmpty { sections.append(.init(id: currentID, title: title(for: currentID), quakes: current)) }
        return sections
    }
}

/// Gruplu liste hücresi: basınca sistem listeleri gibi hafifçe solar;
/// ölçek animasyonu hücre sınırları içinde tuhaf duruyordu.
private struct ListCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { SismikDesign.touchFeedback() }
            }
    }
}
