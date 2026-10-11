import SwiftUI
import MapKit

/// Deprem detay sayfası — Baştan aşağı yenilenmiş ultra-modern sismolojik detay ekranı.
/// Mercalli Şiddet Skalası (MMI), doğrulanmış teknik veriler, Sismolog AI ve topluluk sinyalleri.
struct EarthquakeDetailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let earthquake: Earthquake
    @Environment(LocationManager.self) private var locationManager

    @State private var isAIAnalyzing = false
    /// RRSM istasyon ölçümü; yalnızca yayımlanmışsa dolar.
    @State private var rrsmResult: RRSMService.Result?
    @State private var analysis: AIAnalysisResult?
    @State private var aiFailed = false
    @State private var revealedMercalliLevel = 0
    private let premium = PremiumStore.shared
    /// Ayarlar → Harita ve Detay Tercihleri: açılışta AI analizini otomatik başlat.
    @AppStorage(PremiumPreference.autoAIAnalysis) private var prefAutoAIAnalysis = false
    private let tracker = AftershockTracker.shared
    @State private var showPaywall = false
    /// Premium ekranı hangi özelliğin vitriniyle açılsın (tetikleyene göre).
    @State private var paywallFeature: PaywallFeature = .layers
    @State private var selectedQuestion: String?
    @State private var feltCount: Int?
    @State private var feltCells: [FeltReportService.Cell] = []
    @State private var feltReported = false
    @State private var feltSubmitting = false
    @State private var impactViewState: ViewState<SeismicImpactData?> = .loading
    @State private var showDetailMap = false
    @State private var detailMapInitialLayer: DetailMapLayer = .shaking
    @State private var relatedAftershocks: [Earthquake] = []
    @State private var isAftershocksLoading = true
    @State private var actionFeedback = 0
    /// Hazırlık aşaması yalnızca gerçekten BEKLENECEK bir şey varken açılır.
    /// Ücretsiz kullanıcıda ShakeMap sorgusu hiç atılmaz, veri önbellekteyse
    /// anında hazırdır, olayın ürünü olmadığı yakın zamanda öğrenilmişse
    /// tekrar sorulmaz — üç durumda da ekran hiç görünmez ve detay ilk karede
    /// açılır.
    @State private var showsIntroLoader: Bool
    /// Hazırlık aşamasının alt ve üst sınırı. Alt sınır göz kırpması gibi bir
    /// titremeyi önler, üst sınır yavaş bir ShakeMap sorgusunun ekranı rehin
    /// almasına izin vermez.
    private static let introLoaderMinimum: Duration = .milliseconds(260)
    private static let introLoaderTimeout: Duration = .milliseconds(900)

    init(earthquake: Earthquake) {
        self.earthquake = earthquake
        _showsIntroLoader = State(
            initialValue: PremiumStore.shared.isPremium
                && SeismicDataService.cachedImpactData(for: earthquake) == nil
                && !SeismicDataService.hasRecentMissingProduct(for: earthquake)
        )
    }

    private var isTR: Bool { AppLanguage.isTurkish }
    private var impactData: SeismicImpactData? {
        guard premium.isPremium else { return nil }
        return impactViewState.value ?? SeismicDataService.cachedImpactData(for: earthquake)
    }
    private var isImpactDataLoading: Bool { impactViewState.isInitialLoading }

    /// Harita kartındaki "ShakeMap hazırlanıyor" göstergesinin koşulu.
    /// Gösterge yalnızca gerçekten bir ağ sorgusu sürerken çıkar: ücretsiz
    /// kullanıcıda hiç istek atılmaz, önbellekte veri varsa beklenmez ve
    /// yakın zamanda "ürün yok" yanıtı alınmış olaylarda tekrar sorulmaz.
    private var isFetchingShakeMap: Bool {
        premium.isPremium && isImpactDataLoading && impactData == nil
            && !SeismicDataService.hasRecentMissingProduct(for: earthquake)
    }

    /// Artçı takibi/listesi yalnızca M5+ ana olaylarda anlamlıdır — küçük
    /// depremler için bilimsel olarak izlenebilir bir artçı dizisi olmaz.
    private var isMainEventForAftershocks: Bool { earthquake.magnitude >= 5 }
    /// Büyük olay süresince artçı takibi ve analiz herkese açık: olayın
    /// kendisi en çok bilgiye ihtiyaç duyulan an (bkz. MajorEventCenter).
    private var isMajorEvent: Bool { MajorEventCenter.shared.matches(earthquake) }
    private var unlocksEventTools: Bool { premium.isPremium || isMajorEvent }

    var body: some View {
        // Kısa bir hazırlık aşaması, sonra içerik. İki işi birden yapar:
        //
        // 1. Harita kartı ancak sayfa yerleştikten SONRA monte olur. Daha önce
        //    kart ilk karede kuruluyor, ShakeMap yanıtı gelince üst görünüm
        //    yeniden çiziliyor ve yakınlaşma görevi yarıda iptal olabiliyordu —
        //    "bazen yakınlaşıyor, bazen yakınlaşmıyor" bundandı.
        // 2. Kullanıcı yarım yamalak dolan bir sayfaya değil, tek seferde
        //    yerleşmiş bir sayfaya bakar.
        //
        // Bekleme ÜST SINIRLI: ShakeMap sorgusu 10 saniye sürebiliyor, ama bu
        // ekran en fazla `introLoaderTimeout` kadar bekler ve sonra içeriği
        // gösterir; veri sonradan gelirse harita kartı yerinde tazelenir.
        Group {
            if showsIntroLoader {
                introLoader.transition(.opacity)
            } else {
                detailContent.transition(.opacity)
            }
        }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(L("detail.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: shareText) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.bold))
                    }
                }
            }
            .fullScreenCover(isPresented: $showPaywall) { PaywallView(initialFeature: paywallFeature) }
            .fullScreenCover(isPresented: $showDetailMap) {
                EarthquakeDetailMapScreen(
                    earthquake: earthquake,
                    impactData: impactData,
                    aftershocks: relatedAftershocks,
                    userLocation: locationManager.location,
                    initialLayer: detailMapInitialLayer
                )
            }
            .sheet(item: Binding(
                get: { selectedQuestion.map { IdentifiableString(id: $0) } },
                set: { selectedQuestion = $0?.id }
            )) { item in
                AIQuestionView(earthquake: earthquake, question: item.id)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .task(id: earthquake.id) {
                let isPrem = premium.isPremium
                let unlocked = unlocksEventTools
                let isMainEvent = isMainEventForAftershocks
                // Sismolog AI analizi varsayılan olarak ekran açılır açılmaz
                // yüklenmez; yalnızca kullanıcı "Analiz Et" düğmesine bastığında
                // `runAnalysis()` üzerinden gösterilir. Ayarlar'daki "Detayda
                // otomatik AI analizi" tercihi açıksa aşağıda kendiliğinden
                // tetiklenir. `fetchAnalysis` zaten önbelleği önce kontrol
                // ettiğinden buton basılınca anında görünür, ağ gecikmesi olmaz.
                // ShakeMap yalnızca premium'da gösteriliyor; premium olmayan
                // kullanıcı için USGS'e hiç istek atılmaz.
                async let loadedImpactData: SeismicImpactData? = isPrem
                    ? await SeismicDataService.impactData(for: earthquake)
                    : nil
                async let loadedFeltSummary = FeltReportService.summary(for: earthquake.id)
                // Küçük depremlerin bilimsel olarak anlamlı bir artçı dizisi
                // takibi olmaz; yalnızca M5+ ana olaylarda sorgulanır.
                async let loadedAftershocks: [Earthquake] = (unlocked && isMainEvent)
                    ? Self.loadRelatedAftershocks(for: earthquake) : []

                feltReported = FeltReportService.hasReported(earthquake.id)

                // Tam ekran harita, fay katmanı için ~7 MB'lık dünya GeoJSON'ını
                // çözmek zorunda. Kullanıcı harita kartına dokunduktan SONRA
                // başlatılınca ekran saniyelerce boş kalıyordu; detay açılır
                // açılmaz arka planda hazırlanır ve harita anında açılır.
                // `load()` yeniden çağrılabilir: veri hazırsa anında döner.
                if isPrem {
                    Task(priority: .utility) { await FaultLinesViewModel.shared.load() }
                }

                let resolvedImpactData = await loadedImpactData
                guard !Task.isCancelled else { return }
                impactViewState = .loaded(resolvedImpactData)

                // Sayfa tek seferde yerleşsin: harita kartı bu andan sonra
                // monte olur, dolayısıyla yakınlaşma görevi kararlı bir
                // görünümde başlar ve yarıda iptal edilmez.
                // Alt sınır yalnızca hazırlık ekranı gerçekten gösteriliyorsa:
                // ücretsiz kullanıcıda ya da önbellekte veri varken her detay
                // açılışında hissedenler/artçı bilgisi boşuna 260 ms gecikiyordu.
                if showsIntroLoader {
                    try? await Task.sleep(for: Self.introLoaderMinimum)
                    guard !Task.isCancelled else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                        showsIntroLoader = false
                    }
                }
                let resolvedFeltSummary = await loadedFeltSummary
                let resolvedAftershocks = await loadedAftershocks
                guard !Task.isCancelled else { return }
                feltCount = resolvedFeltSummary?.count
                feltCells = resolvedFeltSummary?.cells ?? []
                relatedAftershocks = resolvedAftershocks
                isAftershocksLoading = false

                // Büyük olayda analiz sunucuda önceden üretildi; beklemeden gösterilir.
                if (isPrem && prefAutoAIAnalysis) || isMajorEvent, analysis == nil, !isAIAnalyzing,
                   RemoteConfig.isEnabled(.aiAnalysis) {
                    await runAnalysis()
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: actionFeedback)
        // Üst sınır: ShakeMap sorgusu 10 saniyeye kadar sürebiliyor, ama
        // hazırlık aşaması ekranı rehin almaz. Süre dolunca içerik açılır;
        // veri sonradan gelirse harita kartı yerinde tazelenir.
        .task(id: earthquake.id) {
            try? await Task.sleep(for: Self.introLoaderTimeout)
            guard !Task.isCancelled, showsIntroLoader else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                showsIntroLoader = false
            }
        }
    }

    private var detailContent: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    summaryHeader
                    mapHeaderCard
                    keyFactsStrip
                }

                // GDACS / USGS PAGER etki seviyesi: beklenen insani etki.
                if let level = earthquake.impactLevel {
                    ImpactLevelCard(level: level)
                }

                // Kaynağın yayımladığı Mercalli şiddeti AI yorumundan önce gösterilir.
                mercalliCard

                // Beni Nasıl Etkiler? Kişisel sarsıntı ve mesafe değerlendirmesi
                PersonalImpactLinkCard(
                    earthquake: earthquake,
                    impactData: impactData,
                    userLocation: locationManager.location
                )

                // Sismolog AI Analiz Kartı — yalnızca premium kullanıcıya gösterilir;
                // ücretsiz kullanıcı için tanıtım "Hissettim" kartının hemen altında.
                if unlocksEventTools, RemoteConfigCenter.shared.config.isEnabled(.aiAnalysis) { aiAnalysisCard }

                // Takip ve teknik bilgiler tek, kesintisiz detay akışında.
                // "Hissettim" kartı uzak yapılandırmayla kapatılabilir; RRSM
                // izlemesi kart gizlense de sürer (boş yer tutucuya bağlanır).
                Group {
                    if RemoteConfigCenter.shared.config.isEnabled(.feltReports) {
                        feltCard
                    } else {
                        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
                    }
                }
                    // RRSM ölçümü arka planda aranır; kart yer tutmaz.
                    .task(id: earthquake.id) {
                        await RRSMCard.watch(earthquake) { result in
                            withAnimation(reduceMotion ? nil : SismikDesign.Motion.entranceSpring) {
                                rrsmResult = result
                            }
                        }
                    }
                // Hissedilenin hemen altında istasyonlarda ÖLÇÜLEN sarsıntı
                // (ORFEUS RRSM); yalnızca ölçüm yayımlanmışsa.
                if let rrsmResult {
                    RRSMCard(earthquake: earthquake, result: rrsmResult)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
                premiumTeaserSection
                if isMainEventForAftershocks && unlocksEventTools {
                    aftershockTrackCard
                    aftershockOverviewCard
                }
                if premium.isPremium && earthquake.tsunami { tsunamiCard }
                if hasLocalDetails { localDetailsCard }
                if !earthquake.locationProperties.closestCities.isEmpty { nearbyCitiesCard }
                eventUpdatesCard
                EarthquakeTechnicalCard(
                    earthquake: earthquake,
                    impactData: impactData
                )
                safetyCard
            }
            .sismikContentWidth()
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 36)
        }
    }

    /// Hazırlık aşaması. Uygulamanın kendi görsel diliyle kurulur: liste ve
    /// harita kartındaki büyüklük rozetinin aynısı, altında kaynak çipi ve
    /// derinlik. Böylece bekleme ekranı araya sıkışmış yabancı bir sayfa gibi
    /// değil, detayın ilk hâli gibi okunur.
    private var introLoader: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)

            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("M").font(.system(size: 15, weight: .bold))
                    Text(earthquake.magnitudeString)
                        .font(.system(size: 42, weight: .black, design: .rounded).monospacedDigit())
                }
                Text(earthquake.level.label.uppercased())
                    .font(.caption2.weight(.heavy))
                    .tracking(0.9)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(earthquake.level.foregroundOnColor)
            .frame(width: 134, height: 108)
            .background(earthquake.magnitudeColor, in: .rect(cornerRadius: 28, style: .continuous))
            .shadow(color: earthquake.magnitudeColor.opacity(0.30), radius: 20, y: 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("M \(earthquake.magnitudeString)")

            VStack(spacing: 8) {
                Text(earthquake.displayTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(earthquake.sourceTag)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(earthquake.sourceColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(earthquake.sourceColor.opacity(0.12), in: .capsule)
                    Text(earthquake.depth.depthKmText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.brandOrange)
                Text(L("detail.shakemap.preparing"))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 1. Harita & Sismik Etki Alanı Kartı

    private var mapDistanceKm: Double? {
        locationManager.location.map { earthquake.clLocation.distance(from: $0) / 1_000 }
    }

    /// Depremin, kullanıcının takip ettiği EN YAKIN yere uzaklığı.
    ///
    /// "Sana 400 km" cümlesi çoğu zaman bir şey söylemiyor; "Annemlere 30 km"
    /// söylüyor. Bildirim kuralının kurulduğu yer ile olayın arasındaki bağ
    /// burada görünür hâle geliyor.
    private var nearestPlace: (place: NotificationPlace, distanceKm: Double)? {
        guard premium.isPremium else { return nil }
        return NotificationPlacesStore.shared.places
            .filter(\.isActive)
            .map { ($0, CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: earthquake.clLocation) / 1_000) }
            .min { $0.1 < $1.1 }
            .map { (place: $0.0, distanceKm: $0.1) }
    }

    /// Detayın başlığı: büyüklük, seviye, yer ve zaman. Eskiden bunlar
    /// haritanın üstünde yarı saydam bir kartın içindeydi; haritanın yarısını
    /// örtüyor, büyüklük de küçük bir rozette kalıyordu.
    private var summaryHeader: some View {
        let level = earthquake.level
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(verbatim: "M")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(earthquake.magnitudeString)
                        .font(.system(size: 54, weight: .heavy, design: .rounded).monospacedDigit())
                }
                .foregroundStyle(level.textColor)
                Text(level.label)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(level.textColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(level.color.opacity(0.15), in: Capsule())
                Spacer(minLength: 0)
            }
            Text(earthquake.displayTitle)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(fullDate) · \(earthquake.sourceTag)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Derinlik, şiddet ve uzaklık tek kartta, eşit sütunlarda. Takip edilen
    /// en yakın yer varsa altında tek satır.
    private var keyFactsStrip: some View {
        let nearest = nearestPlace
        let userDistance = mapDistanceKm
        let mmi = sourceIntensityDescriptor
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                factColumn(label: L("detail.depth"), value: earthquake.depth.depthKmText, tint: .primary)
                Divider().frame(height: 36)
                factColumn(
                    label: isTR ? "Şiddet" : "Intensity",
                    value: mmi.map { "MMI \($0.roman)" } ?? "—",
                    tint: mmi?.color ?? .secondary
                )
                if let userDistance {
                    Divider().frame(height: 36)
                    factColumn(label: L("detail.distance"), value: userDistance.kmText, tint: .primary)
                }
            }
            .padding(.vertical, 14)

            if let nearest {
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: nearest.place.icon.symbolName)
                        .foregroundStyle(nearest.distanceKm <= nearest.place.radiusKm ? nearest.place.icon.color : .secondary)
                    Text(L(nearest.distanceKm <= nearest.place.radiusKm ? "detail.nearestPlace.inside" : "detail.nearestPlace"))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text("\(nearest.place.name) · \(nearest.distanceKm.kmText)")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func factColumn(label: String, value: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var mapHeaderCard: some View {
        EarthquakeMapHeaderCard(
            earthquake: earthquake,
            contours: sourceShakeMapContours,
            isEstimated: isEstimatedIntensity,
            sourceIntensity: sourceIntensityDescriptor,
            intensitySourceTag: intensityDataSourceTag,
            isPremium: premium.isPremium,
            isLoading: isFetchingShakeMap,
            onTapMap: {
                actionFeedback += 1
                openPremiumMap(layer: .shaking)
            }
        )
    }

    // MARK: - 2. Premium Önizleme

    /// "Daha fazlasını keşfet": beş premium özelliği boşluk bırakmadan dizer.
    ///
    /// Beş kutu iki sütunlu ızgaraya dizildiğinde son satırda tek kutu kalıyor
    /// ve yanında boş bir hücre açılıyordu. En yeni ve en kişisel özellik
    /// (kayıtlı yerlere bildirim) üstte tam genişlikte duruyor; kalan dört
    /// özellik eşit yükseklikte 2×2 ızgarada. Kartın tamamı dokunulabilir,
    /// ama ne olacağını söyleyen açık bir düğmesi de var.
    @ViewBuilder
    private var premiumTeaserSection: some View {
        if !premium.isPremium {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("earthquakeDetail.premiumTeaser.title"))
                        .font(.subheadline.weight(.bold))
                    Text(L("earthquakeDetail.premiumTeaser.subtitle"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                placesTeaserHero

                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        premiumTeaserTile(icon: "doc.text.magnifyingglass", tint: .brandOrange,
                                           title: L("earthquakeDetail.premiumTeaser.ai.title"),
                                           detail: L("earthquakeDetail.premiumTeaser.ai.detail"))
                        premiumTeaserTile(icon: "dot.radiowaves.left.and.right", tint: .pink,
                                           title: L("earthquakeDetail.premiumTeaser.aftershocks.title"),
                                           detail: L("earthquakeDetail.premiumTeaser.aftershocks.detail"))
                    }
                    GridRow {
                        premiumTeaserTile(icon: "waveform.path.ecg", tint: .blue,
                                           title: L("earthquakeDetail.premiumTeaser.shakemap.title"),
                                           detail: L("earthquakeDetail.premiumTeaser.shakemap.detail"))
                        premiumTeaserTile(icon: "circle.hexagongrid.fill", tint: .teal,
                                           title: L("earthquakeDetail.premiumTeaser.nearby.title"),
                                           detail: L("earthquakeDetail.premiumTeaser.nearby.detail"))
                    }
                }

                Button {
                    presentPaywall(.layers)
                } label: {
                    Text(L("places.locked.cta"))
                }
                .buttonStyle(SismikPrimaryButtonStyle(height: 46, font: .subheadline.weight(.semibold)))
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture { presentPaywall(.layers) }
            .sensoryFeedback(.selection, trigger: showPaywall) { _, presented in presented }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(L("premiumPreview.unlockHint"))
        }
    }

    /// Üstteki tam genişlik özellik: kayıtlı yerler. Örnek simgeler, simge
    /// setinin kendisinden gelir — kullanıcı ne alacağını görür.
    private var placesTeaserHero: some View {
        HStack(spacing: 12) {
            HStack(spacing: -8) {
                ForEach([PlaceIcon.house, .family, .work], id: \.self) { icon in
                    PlaceIconBadge(icon: icon, size: 30)
                        .overlay {
                            RoundedRectangle(cornerRadius: 30 * 0.26, style: .continuous)
                                .strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 2)
                        }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L("places.teaser.title"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                Text(L("places.teaser.detail"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.appAction.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func premiumTeaserTile(icon: String, tint: Color, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        // `Grid` satırdaki iki kutuyu en uzun olanın boyuna eşitler; kutu
        // yüksekliği sabit bir alt sınırla değil içerikle belirlenir.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 3. Mercalli Şiddet Skalası (MMI) Kartı

    @ViewBuilder
    private var mercalliCard: some View {
        if let sourceMMI = sourceIntensityDescriptor {
            sourceMercalliCard(sourceMMI)
        } else {
            unavailableMercalliCard
        }
    }

    private func sourceMercalliCard(_ sourceMMI: SeismicIntensityDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L("Mercalli Şiddet Skalası (MMI)"), systemImage: "waveform.path.ecg")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                HStack(spacing: 5) {
                    Text("MMI \(sourceMMI.roman)")
                        .font(.system(size: 13, weight: .black).monospacedDigit())
                    Text(sourceMMI.title(isTurkish: isTR))
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(sourceMMI.color, in: Capsule())
            }

            Divider().opacity(0.4)

            // Merkez Üssü Şiddet ve İvme Özeti
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isEstimatedIntensity
                         ? (L("Tahmini Merkez Üssü Şiddeti"))
                         : (L("Kaynağın Yayımladığı Şiddet")))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("MMI \(sourceMMI.roman)")
                            .font(.title3.weight(.black).monospacedDigit())
                            .foregroundStyle(sourceMMI.color)
                        Text("· \(sourceMMI.title(isTurkish: isTR))")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                    }
                }

                Spacer()

                if let pgaText = sourcePGAText {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(L("Maksimum PGA"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(pgaText)
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(12)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            // Sismolojik Etki Açıklaması
            Text(sourceMMI.description(isTurkish: isTR))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)

            // 12 Kademeli Renkli Mercalli Seviye Barı (I - XII) — çubuklar
            // ilk açılışta soldan sağa, tek tek ilerleyerek dolar.
            VStack(spacing: 4) {
                HStack(spacing: 3) {
                    ForEach(1...12, id: \.self) { idx in
                        let filled = idx <= sourceMMI.roundedLevel && idx <= revealedMercalliLevel
                        Rectangle()
                            .fill(filled ? mmiColor(for: idx) : Color.primary.opacity(0.08))
                            .frame(height: 6)
                            .clipShape(Capsule())
                    }
                }
                .animation(reduceMotion ? nil : SismikDesign.Motion.rowSpring, value: revealedMercalliLevel)
                .task(id: sourceMMI.roundedLevel) {
                    revealedMercalliLevel = 0
                    let target = max(1, min(12, sourceMMI.roundedLevel))
                    for level in 1...target {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        guard !Task.isCancelled else { return }
                        revealedMercalliLevel = level
                    }
                }

                HStack {
                    Text("I (Hissedilmez)")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("VI (Kuvvetli)")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("XII (Yıkıcı / Felaket)")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 2)

            // Kaynak Atfı ve Resmi Sismoloji Modeli
            HStack(spacing: 6) {
                Image(systemName: isEstimatedIntensity ? "function" : "checkmark.seal.fill")
                    .font(.caption2)
                    .foregroundStyle(isEstimatedIntensity ? Color.orange : earthquake.sourceColor)

                Text(intensitySourceLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous))
    }

    private var unavailableMercalliCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L("Mercalli Şiddet Skalası (MMI)"), systemImage: "waveform.path.ecg")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Divider().opacity(0.4)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(earthquake.sourceColor)
                    .frame(width: 38, height: 38)
                    .background(earthquake.sourceColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Kaynak şiddet verisi yayımlamadı"))
                        .font(.subheadline.weight(.bold))
                    Text(isTR
                         ? "Bu olay için \(earthquake.sourceTag) veya doğrulanmış USGS ShakeMap tarafından yayımlanan MMI gösterilir. Konum, uzaklık veya büyüklükten tahmin üretilmez."
                         : "MMI published by \(earthquake.sourceTag) or a verified USGS ShakeMap is shown for this event. No estimate is derived from location, distance, or magnitude.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous))
    }

    // MARK: - 4. Tsunami Bilgi Kartı

    private var tsunamiCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "water.waves")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.cyan)
                .frame(width: 40, height: 40)
                .background(Color.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(L("Tsunami Bilgisi Yayımlandı"))
                    .font(.subheadline.weight(.bold))
                Text(L("USGS bu deprem için tsunami bilgisi yayımladı. Kıyı bölgelerindeki resmî uyarıları takip et."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - 5. Artçı Takibi Canlı Etkinliği (Premium)

    private var aftershockTrackCard: some View {
        let tracking = tracker.isTracking(earthquake.id)
        return HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.brandOrange)
                .frame(width: 40, height: 40)
                .background(Color.brandOrange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(L("detail.aftershockTracking"))
                    .font(.subheadline.weight(.bold))
                Text(L("Artçı depremleri Kilit Ekranı ve Dynamic Island'da canlı takip et."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                if tracking {
                    Task { await tracker.stop() }
                    return
                }
                guard premium.isPremium else {
                    presentPaywall(.aftershock)
                    return
                }
                Task { await tracker.start(for: earthquake) }
            } label: {
                Text(tracking ? (L("Durdur")) : (L("Başlat")))
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(tracking ? Color.brandOrange : .white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(
                        tracking ? AnyShapeStyle(Color.brandOrange.opacity(0.15)) : AnyShapeStyle(Color.brandOrange),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tracking ? Color.brandOrange.opacity(0.4) : Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var aftershockOverviewCard: some View {
        Button {
            actionFeedback += 1
            openPremiumMap(layer: .aftershocks)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.brandOrange)
                    .frame(width: 40, height: 40)
                    .background(Color.brandOrange.opacity(0.12), in: .rect(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text(L("aftershocks.title"))
                        .font(.subheadline.weight(.bold))
                    Text(aftershockOverviewText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityHint(
            premium.isPremium
                ? (L("aftershocks.map.hint"))
                : (L("Premium ekranını açar"))
        )
    }

    private func openPremiumMap(layer: DetailMapLayer) {
        guard premium.isPremium else {
            presentPaywall(.layers)
            return
        }
        detailMapInitialLayer = layer
        showDetailMap = true
    }

    // MARK: - 6. "Hissettim" Kartı (Ücretsiz)

    private var feltCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.teal)
                    .frame(width: 40, height: 40)
                    .background(Color.teal.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Bu depremi hissettin mi?"))
                        .font(.subheadline.weight(.bold))
                    if let feltCount, feltCount > 0 {
                        Text(isTR
                             ? "\(feltCount.formatted()) kişi hissettiğini bildirdi"
                             : "\(feltCount.formatted()) people reported feeling it")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L("İlk bildiren sen ol"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 4)

                if feltSubmitting {
                    Image(systemName: "hourglass")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if feltReported {
                    Label(L("Bildirildi"), systemImage: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.teal)
                } else {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        Task {
                            feltSubmitting = true
                            let ok = await FeltReportService.report(earthquake.id)
                            feltSubmitting = false
                            if ok {
                                feltReported = true
                                feltCount = (feltCount ?? 0) + 1
                            }
                        }
                    } label: {
                        Text(L("Hissettim"))
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(Color.teal, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Hissedilen bölgeler: raporların ~11 km'lik hücrelerdeki dağılımı.
            // Tek hücre bilgi taşımadığı için en az iki hücrede gösterilir.
            if feltCells.count >= 2 {
                FeltReportsMap(epicenter: earthquake.clLocation.coordinate, cells: feltCells)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(L("felt.map.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - 7. Sismolojik Analiz & Jeolojik Değerlendirme Kartı

    private var aiAnalysisCard: some View {
        SeismicAssessmentCard(
            analysis: analysis,
            isAnalyzing: isAIAnalyzing,
            failed: aiFailed,
            onRunAnalysis: {
                guard !isAIAnalyzing else { return }
                Task { await runAnalysis() }
            },
            onSelectQuestion: { question in
                selectedQuestion = question
            }
        )
    }

    // MARK: - 8. Yerel Deprem Detayları

    private var hasLocalDetails: Bool {
        let hasEpi = !(earthquake.locationProperties.epiCenter?.name.isEmpty ?? true)
        let hasCity = earthquake.locationProperties.closestCity != nil
        return earthquake.provider.lowercased() == "afad" && (hasEpi || hasCity)
    }

    private var localDetailsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("detail.localDetails"), systemImage: "map.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)

            Divider()

            if let epi = earthquake.locationProperties.epiCenter?.name, !epi.isEmpty {
                detailRow(L("detail.epicenter"), epi.capitalizedTR, icon: "circle.circle.fill", tint: .red)
            }

            if let city = earthquake.locationProperties.closestCity {
                detailRow(L("detail.closestCities"), closestCityText(city), icon: "building.2.fill", tint: .blue)
            }

            if let district = earthquake.district, !district.isEmpty {
                detailRow(L("detail.district"), district, icon: "mappin.and.ellipse", tint: .brandOrange)
            }

            detailRow(L("detail.depthClass"), depthClassification, icon: "arrow.down.forward.and.arrow.up.backward", tint: .teal)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous))
    }

    private func detailRow(_ label: String, _ value: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
    }

    // MARK: - 9. Yakındaki Şehirler

    private var nearbyCitiesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("detail.nearbyCities"), systemImage: "house.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)

            Divider()

            ForEach(Array(earthquake.locationProperties.closestCities.prefix(6))) { city in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(city.name)
                            .font(.subheadline.weight(.bold))
                        if let pop = city.population {
                            Text("\(pop.formatted(.number.grouping(.automatic))) " + L("detail.population"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let d = city.distance {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(d.metersAsKmText)
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(.primary)
                            Text(L("Merkez üssüne"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
                if city.name != earthquake.locationProperties.closestCities.prefix(6).last?.name {
                    Divider().opacity(0.5)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous))
    }

    private var eventUpdatesCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(L("Olay Durumu ve Güncellemeler"), systemImage: "clock.arrow.circlepath")
                .font(.headline.weight(.bold))

            eventUpdateRow(
                icon: "antenna.radiowaves.left.and.right",
                title: L("Kaynakta yayımlandı"),
                detail: "\(earthquake.sourceTag) · \(fullDate)",
                tint: .blue
            )

            if earthquake.revised || earthquake.status == "reviewed" {
                eventUpdateRow(
                    icon: "checkmark.seal.fill",
                    title: earthquake.revised ? (L("Çözüm revize edildi")) : (L("Çözüm incelendi")),
                    detail: L("Kaynağın mevcut olay kaydı"),
                    tint: .green
                )
            }

            if let impactData {
                eventUpdateRow(
                    icon: "waveform.path.ecg",
                    title: L("ShakeMap eşleşti"),
                    detail: impactData.isReviewed ? (L("İncelenmiş sarsıntı ürünü")) : (L("Otomatik / öncül sarsıntı ürünü")),
                    tint: .brandOrange
                )
            }

            Text(L("Bu alan yalnızca veri sağlayıcısının mevcut kaydını gösterir; geçmiş büyüklük veya derinlik değerleri kaynak tarafından iletilmediyse üretilmez."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.card))
    }

    private func eventUpdateRow(icon: String, title: String, detail: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.11), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 10. Teknik Bilgiler


    // MARK: - 11. Bilgilendirme Notu

    private var safetyCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("detail.importantNotice"))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Text(L("detail.noticeText"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous))
    }

    // MARK: - Computations & Helpers


    /// Artçılar: sunucunun ana şoka özel kataloğu + canlı liste, ortak kuralla
    /// süzülür (`AftershockSequence`). Büyük olay kartı da bunu kullanır; iki
    /// ekran aynı sayıyı gösterir. Deprem büyük olayın ana şokuysa (farklı
    /// ajans kaydı olsa bile) referans olayın kendisidir: aynı merkez, aynı
    /// büyüklük, dolayısıyla aynı alan.
    static func loadRelatedAftershocks(for earthquake: Earthquake) async -> [Earthquake] {
        let reference = await MainActor.run { () -> Earthquake in
            let center = MajorEventCenter.shared
            if let event = center.event, !event.isExpired, center.matches(earthquake) { return event.earthquake }
            return earthquake
        }
        let radius = AftershockSequence.zoneRadiusKm(forMagnitude: reference.magnitude)
        // Merkez üssüne özel sorgu, genel dünya kataloğunun 20.000 kayıt
        // limitine takılmaz; canlı liste en yeni kayıtları (CDN önbelleği
        // tazelenmeden) ekler.
        async let catalog = EarthquakeService.shared.fetchAftershockCandidates(for: reference, radiusKm: radius)
        async let live = EarthquakeService.shared.liveSnapshot(minMagnitude: 0)
        var pool = await catalog + (await live).quakes
        if pool.isEmpty {
            pool = await EarthquakeService.shared.fetchMapData(days: 30, minMagnitude: 0)
        }
        return AftershockSequence.select(mainshock: reference, from: pool)
    }

    static func aftershockRadiusKm(for earthquake: Earthquake) -> Double {
        AftershockSequence.zoneRadiusKm(forMagnitude: earthquake.magnitude)
    }

    private var aftershockRadiusKm: Double {
        Self.aftershockRadiusKm(for: earthquake)
    }

    private var aftershockOverviewText: String {
        if isAftershocksLoading {
            return L("aftershocks.overview.loading")
        }
        let radius = Int(aftershockRadiusKm)
        if relatedAftershocks.isEmpty {
            return L("aftershocks.overview.none", radius)
        }
        return L("aftershocks.overview.count", relatedAftershocks.count, radius)
    }

    private var mapItem: MKMapItem {
        let item: MKMapItem
        if #available(iOS 26.0, *) {
            item = MKMapItem(location: earthquake.clLocation, address: nil)
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: earthquake.clLocation.coordinate))
        }
        item.name = earthquake.displayTitle
        return item
    }

    private var depthText: String {
        earthquake.depth.depthKmText
    }

    private var depthClassification: String {
        switch earthquake.depth {
        case ..<70: L("detail.depth.shallow")
        case ..<300: L("detail.depth.intermediate")
        default: L("detail.depth.deep")
        }
    }

    private var fullDate: String {
        return earthquake.date.formatted(
            .dateTime.locale(AppLanguage.currentLocale)
                .day().month(.wide).year().hour().minute().second()
        )
    }

    private func closestCityText(_ city: City) -> String {
        if let d = city.distance { return "\(city.name) · \(d.metersAsKmText)" }
        return city.name
    }

    /// Kullanıcı konumundan şiddet türetmez. Önce katalog sağlayıcısının
    /// yayımladığı MMI, sonra aynı olayla doğrulanmış USGS ShakeMap kullanılır.
    /// İkisi de yoksa tüm olaylarda MMI gösterebilmek için yalnızca olayın
    /// büyüklük ve derinliğinden merkez üssü şiddeti tahmin edilir.
    private var sourceIntensityValue: Double? {
        if let value = earthquake.maximumIntensity, value.isFinite, value > 0 {
            return value
        }
        if let value = impactData?.maximumMMI,
           value.isFinite,
           value > 0 {
            return value
        }
        let estimate = SeismicImpactModel(earthquake: earthquake)
            .estimatedMMI(atEpicentralDistance: 0)
        guard estimate.isFinite else { return 1 }
        return min(10, max(1, estimate))
    }

    private var sourceIntensityDescriptor: SeismicIntensityDescriptor? {
        sourceIntensityValue.map(SeismicIntensityDescriptor.init(value:))
    }

    private var sourceShakeMapContours: [SeismicImpactData.Contour]? {
        if let contours = impactData?.contours, !contours.isEmpty {
            return contours
        }
        let estimated = SeismicImpactModel(earthquake: earthquake).estimatedContoursAsSeismicContours
        return estimated.isEmpty ? nil : estimated
    }

    private var intensitySourceLabel: String {
        if isEstimatedIntensity {
            return L("Tahmin: kaynak büyüklüğü ve derinliği · Sismik azalım + Wald MMI dönüşümü")
        }
        return isTR
            ? "Kaynak: \(intensityDataSourceTag) doğrulanmış olay verisi"
            : "Source: verified \(intensityDataSourceTag) event data"
    }

    private var isEstimatedIntensity: Bool {
        let catalogHasMMI = earthquake.maximumIntensity.map { $0.isFinite && $0 > 0 } ?? false
        let shakeMapHasMMI = impactData?.maximumMMI.map { $0.isFinite && $0 > 0 } ?? false
        return !catalogHasMMI && !shakeMapHasMMI
    }

    private var intensityDataSourceTag: String {
        if let value = earthquake.maximumIntensity, value.isFinite, value > 0 {
            return earthquake.sourceTag
        }
        if let value = impactData?.maximumMMI, value.isFinite, value > 0 {
            return "USGS ShakeMap"
        }
        return L("Sismik Tahmin Modeli")
    }

    private var sourcePGAText: String? {
        guard let pga = impactData?.maximumPGA,
              pga.isFinite,
              pga >= 0 else { return nil }
        return "\(pga.formatted(.number.precision(.significantDigits(2...3)))) g"
    }

    private func mmiColor(for level: Int) -> Color {
        switch level {
        case ...2: return Color(red: 0.19, green: 0.55, blue: 0.91)
        case 3: return Color(red: 0.16, green: 0.72, blue: 0.72)
        case 4: return Color(red: 0.34, green: 0.72, blue: 0.36)
        case 5: return Color(red: 0.95, green: 0.78, blue: 0.16)
        case 6: return Color(red: 0.98, green: 0.52, blue: 0.12)
        case 7: return Color(red: 0.93, green: 0.30, blue: 0.16)
        default: return Color(red: 0.78, green: 0.12, blue: 0.16)
        }
    }

    private var shareText: String {
        var text = String(format: L("detail.share.format"), earthquake.displayTitle, earthquake.magnitude.formatted(.number.precision(.fractionLength(1))), depthText, earthquake.sourceTag)
        if premium.isPremium, let link = QuakeShareLink.url(for: earthquake) {
            text += "\n" + link.absoluteString
        }
        return text
    }

    private func runAnalysis() async {
        guard !isAIAnalyzing else { return }
        isAIAnalyzing = true
        aiFailed = false
        let result = await AIService.fetchAnalysis(for: earthquake)
        guard !Task.isCancelled else { return }
        isAIAnalyzing = false
        if let result {
            analysis = result
        } else {
            aiFailed = true
        }
    }
}

extension EarthquakeDetailView {
    /// Premium ekranını, onu tetikleyen özelliğin vitrin sayfasıyla açar.
    fileprivate func presentPaywall(_ feature: PaywallFeature) {
        paywallFeature = feature
        showPaywall = true
    }
}
