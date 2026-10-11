import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = 0
    /// Etkin "Son Depremler" sekmesine docktan yeniden dokunulunca artar:
    /// detaydaysa köke döner, kökteyse liste başa kayar (sistem davranışı).
    @State private var recentReselectToken = 0
    @State private var pendingQuakeID: String?
    // Depremler ve İstatistikler aynı view model'i paylaşır (tek çekim, tek yoklama).
    @State private var earthquakeVM = EarthquakeListViewModel()
    @State private var autoRefreshTask: Task<Void, Never>?
    /// Uygulama açıkken sunucunun dakikalık yayınını en geç yaklaşık 30 sn
    /// içinde ekrana al. Arka planda asıl teslim yolu yüksek öncelikli APNs'tir.
    /// Otomatik yenileme aralığı (uzak yapılandırma: `refresh.interval_seconds`).
    private var refreshInterval: Duration {
        .seconds(RemoteConfig.number(\.refresh, "interval_seconds", default: 25, in: 15...600))
    }

    @State private var showEntitlementPaywall = false
    @State private var showRiskProfile = false
    private let premium = PremiumStore.shared
    private let infoCards = InfoCardCenter.shared
    private let strongQuake = StrongQuakeMonitor.shared

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                iOS26TabView
            } else {
                iOS18TabView
            }
        }
        .tint(.brandOrange)
        .task {
            // Tek merkezi yükleme + sakin yoklama: hangi sekme açık olursa olsun
            // veri taze ve paylaşılan kalır (İstatistik sekmesi de aynı veriyi kullanır).
            syncAutoRefresh()
            // Önceki oturumdan yaşayan artçı Canlı Etkinliği'ne yeniden bağlan.
            AftershockTracker.shared.restore()
            // Güncelleme sonrası "yenilikler" ya da bekleyen duyuru kartı.
            infoCards.appDidBecomeReady()
            // İstatistik ön-ısıtma: varsayılan görünüm (Türkiye · 7 gün) arka
            // planda çekilip bellek+disk önbelleğine yazılır — sekme açıldığında
            // ekran ağ beklemeden boyanır.
            if premium.isPremium {
                Task(priority: .utility) {
                    _ = await GlobalStatsService.shared.stats(range: .week, region: "TR")
                }
            }
        }
        .fullScreenCover(isPresented: $showEntitlementPaywall) { PaywallView() }
        // Deprem anı modu (bkz. StrongQuakeMonitor).
        .fullScreenCover(item: Binding(
            get: { strongQuake.active },
            set: { if $0 == nil { strongQuake.dismiss() } }
        )) { event in
            QuakeResponseView(
                event: event,
                onOpenDetail: { quake in
                    strongQuake.dismiss()
                    selection = 0
                    pendingQuakeID = quake.id
                },
                onClose: { strongQuake.dismiss() }
            )
        }
        // Güncelleme sonrası yenilikler ve yayınlanan duyuru kartları.
        .sheet(item: Binding(get: { infoCards.presented }, set: { infoCards.presented = $0 })) { card in
            InfoCardView(card: card)
        }
        .sheet(isPresented: $showRiskProfile) {
            NavigationStack {
                LocationRiskView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(L("common.close")) { showRiskProfile = false }
                                .font(.headline.weight(.bold))
                                .foregroundStyle(Color.appAction)
                        }
                    }
            }
        }
        // Abonelik sona erdiğinde: hatırlatma bildirimi yerine kullanıcı
        // uygulamayı açtığında satın alma ekranı bir kez gösterilir.
        .onChange(of: premium.entitlementJustExpired) { _, expired in
            guard expired else { return }
            premium.acknowledgeEntitlementExpiry()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard !premium.isPremium, !showEntitlementPaywall else { return }
                showEntitlementPaywall = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            syncAutoRefresh()
            if phase == .active { infoCards.sceneDidBecomeActive() }
        }
        .onChange(of: premium.isPremium) { _, _ in
            NotificationManager.shared.scheduleIfEnabled()
        }
        .onChange(of: selection) { _, _ in
            syncAutoRefresh()
        }
        .onOpenURL(perform: handleOpenURL)
        // Ana ekran hızlı eylemi (soğuk açılışta görünüm kurulmadan gelir).
        .onChange(of: QuickActionRouter.shared.pendingURL, initial: true) { _, url in
            guard let url else { return }
            QuickActionRouter.shared.pendingURL = nil
            handleOpenURL(url)
        }
    }

    /// Sekme seçimi; zaten seçili sekmeye yeniden dokunuşu da yakalar
    /// (`TabView` bu durumda da bağlamayı aynı değerle yazar).
    private var tabSelection: Binding<Int> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue == selection, newValue == 0 { recentReselectToken &+= 1 }
                selection = newValue
            }
        )
    }

    private var recentTab: some View {
        LazyView {
            RecentEarthquakesView(
                viewModel: earthquakeVM,
                pendingQuakeID: $pendingQuakeID,
                reselectToken: recentReselectToken
            )
        }
        .modifier(PadTabBackground())
    }

    /// iOS 18–25: bütün sekmeler standart sistem tab barında kalır.
    private var iOS18TabView: some View {
        TabView(selection: tabSelection) {
            Tab(L("tab.recent"), systemImage: "waveform.path.ecg", value: 0) {
                recentTab
            }
            Tab(L("tab.stats"), systemImage: "chart.bar.xaxis", value: 1) {
                LazyView { StatisticsView() }.modifier(PadTabBackground())
            }
            Tab(L("tab.assembly.short"), systemImage: "person.3.sequence.fill", value: 2) {
                LazyView { AssemblyAreasView() }.modifier(PadTabBackground())
            }
            Tab(value: 3) {
                LazyView { EmergencyView() }.modifier(PadTabBackground())
            } label: {
                Label {
                    Text(L("tab.emergency"))
                } icon: {
                    Image(uiImage: (UIImage(systemName: "cross.case.fill") ?? UIImage())
                        .withTintColor(.systemRed, renderingMode: .alwaysOriginal))
                }
            }
        }
        // Sekme ağacı her cihazda sistemin sekme çubuğu sunumunu kullanır.
        // iPad'in üst sekme çubuğu native olarak korunurken Depremler ekranı
        // kendi iki sütunlu NavigationSplitView'ını yönetir. Böylece iPad'e
        // özgü kenar çubuğu iPhone tab bar davranışına sızmaz ve iPad'de iç
        // içe iki farklı sidebar düğmesi oluşmaz.
        .tabViewStyle(.tabBarOnly)
    }

    /// iOS 26+: Acil Durum, docktan ayrılan yuvarlak Liquid Glass aksiyonudur.
    @available(iOS 26.0, *)
    private var iOS26TabView: some View {
        TabView(selection: tabSelection) {
            Tab(L("tab.recent"), systemImage: "waveform.path.ecg", value: 0) {
                recentTab
            }
            Tab(L("tab.stats"), systemImage: "chart.bar.xaxis", value: 1) {
                LazyView { StatisticsView() }.modifier(PadTabBackground())
            }
            Tab(L("tab.assembly.short"), systemImage: "person.3.sequence.fill", value: 2) {
                LazyView { AssemblyAreasView() }.modifier(PadTabBackground())
            }
            Tab(value: 3, role: emergencyTabRole) {
                LazyView { EmergencyView() }.modifier(PadTabBackground())
            } label: {
                Label {
                    Text(L("tab.emergency"))
                } icon: {
                    Image(uiImage: (UIImage(systemName: "cross.case.fill") ?? UIImage())
                        .withTintColor(.systemRed, renderingMode: .alwaysOriginal))
                }
            }
        }
        // Dock kaydırırken küçülmez: sekmeler ve Acil Durum düğmesi her zaman
        // tam boyda görünür (deprem anında tek dokunuşla erişim).
        .tabBarMinimizeBehavior(.never)
        .tabViewStyle(.tabBarOnly)
    }

    /// iOS 27'de `.search` rolü sekmeyi docktan ayırmıyor; ayrı yuvarlak
    /// aksiyon için yeni `.prominent` rolü gerekiyor.
    @available(iOS 26.0, *)
    private var emergencyTabRole: TabRole {
        if #available(iOS 27.0, *) { return .prominent }
        return .search
    }

    private func handleOpenURL(_ url: URL) {
            // Universal Link (https://sismik-app.web.app/quake/...):
            // paylaşılan deprem doğrudan detay sayfasında açılır. Veri
            // bağlantının kendisinde taşındığı için listede olmayan (eski)
            // bir deprem bile açılabilir.
            if let sharedQuake = QuakeShareLink.earthquake(from: url) {
                QuakeShareLink.stash(sharedQuake)
                selection = 0
                pendingQuakeID = sharedQuake.id
                return
            }

            guard url.scheme == "sismik" else { return }
            switch url.host {
            case "search":
                selection = 0
                if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let queryItems = comps.queryItems,
                   let q = queryItems.first(where: { $0.name == "q" })?.value {
                    earthquakeVM.searchText = q
                }
            case "filter":
                selection = 0
                if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let queryItems = comps.queryItems {
                    if let minMagStr = queryItems.first(where: { $0.name == "minMag" })?.value,
                       let minMag = Double(minMagStr) {
                        earthquakeVM.minMagnitude = minMag
                    }
                    if let source = queryItems.first(where: { $0.name == "source" })?.value {
                        // Etiket kaynak stiliyle aynı kurulur ("kandilli" → "KANDİLLİ").
                        let tag = QuakeProviderStyle(normalizedProvider: source.lowercased(), provider: source, title: "").tag
                        earthquakeVM.enabledSources = Set([tag])
                        // Listedeki kaynak menüsüyle aynı kalıcı tercih: menü
                        // doğru seçimi gösterir, sonraki açılışta da hatırlanır.
                        if EarthquakeListViewModel.allSources.contains(tag) {
                            UserDefaults.standard.set(tag, forKey: AppPreference.defaultListSource)
                        } else if source.lowercased() == AppPreference.allListSources {
                            UserDefaults.standard.set(AppPreference.allListSources, forKey: AppPreference.defaultListSource)
                        }
                    }
                }
            case "quake":
                selection = 0
                let id = url.pathComponents.dropFirst().joined(separator: "/")
                if !id.isEmpty { pendingQuakeID = id }
            case "map":
                selection = 0
                NotificationCenter.default.post(name: .sismikOpenMap, object: nil)
            case "paywall":
                selection = 0
                NotificationCenter.default.post(name: .sismikOpenPaywall, object: nil)
            case "info":
                // sismik://info/<kart-id>: bildirimden ya da karttan.
                if let id = url.pathComponents.dropFirst().first, !id.isEmpty {
                    infoCards.open(id: id)
                }
            case "risk":
                showRiskProfile = true
            #if DEBUG
            case "debug-major":
                if let quake = earthquakeVM.earthquakes.max(by: { $0.magnitude < $1.magnitude }) {
                    MajorEventCenter.shared.simulate(quake)
                }
            case "debug-response":
                // Deprem anı ekranını test etmek için: listedeki en büyük deprem.
                if let quake = earthquakeVM.earthquakes.max(by: { $0.magnitude < $1.magnitude }) {
                    strongQuake.active = .init(quake: quake, distanceKm: 42, placeName: nil)
                }
            #endif
            case "stats":     selection = 1
            case "assembly":  selection = 2
            case "emergency": selection = 3
            default:          selection = 0
            }
    }

    private var shouldAutoRefresh: Bool {
        scenePhase == .active && (selection == 0 || selection == 1)
    }

    private func syncAutoRefresh() {
        if shouldAutoRefresh {
            startAutoRefresh()
        } else {
            stopAutoRefresh()
        }
    }

    private func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task {
            // Soğuk açılışta disk/bellek/HTTP önbelleğini kullan; yalnızca kullanıcının
            // çekerek yenilemesi ağı zorlar. Bu, ilk açılış CPU ve ağ tepesini azaltır.
            await earthquakeVM.load()
            while !Task.isCancelled {
                try? await Task.sleep(for: refreshInterval)
                guard !Task.isCancelled else { break }
                await earthquakeVM.load()
            }
        }
    }

    private func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

}

/// iPad'de (ve iPhone Duo iç ekranında) sekme çubuğu (`_UIFloatingTabBar`) içeriğin üzerinde yüzer ve
/// kendisi saydamdır; ekranın tepesindeki beyaz şerit UIKit'in sekme
/// kapsayıcısından (`UILayoutContainerView`, `systemBackground`) geliyor.
/// Kapsayıcı SwiftUI barındırma görünümünün ÇOCUĞU olduğu için TabView'a
/// verilen arka plan onun altında kalıyor ve hiç görünmüyor;
/// `.toolbarBackground(_:for: .tabBar)` de bu çubukta etkisiz. Zemin sekme
/// İÇERİĞİNE verilip üst güvenli alanın altına uzatılınca şerit kapanır.
/// iPhone'un alt sekme çubuğu ve zemini dokunulmadan kalır.
private struct PadTabBackground: ViewModifier {
    /// Cihaz türü yerine boyut sınıfı: iPhone Duo'nun iç ekranı da (deyimi
    /// `.phone`) geniş düzende sekme çubuğunu yüzen biçimde gösterir.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular {
            content.background(Color(.systemGroupedBackground).ignoresSafeArea())
        } else {
            content
        }
    }
}

extension Notification.Name {
    /// sismik://map deep link'i — Depremler sekmesini harita modunda açar.
    static let sismikOpenMap = Notification.Name("sismikOpenMap")
    /// sismik://paywall deep link'i — Premium satın alma sayfasını açar.
    static let sismikOpenPaywall = Notification.Name("sismikOpenPaywall")
}
