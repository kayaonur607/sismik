import SwiftUI

/// İstatistik ekranı. Bölümler "herkesin sorabileceği sorular" sırasıyla
/// (bkz. StatisticsSections.swift): kaç deprem, ne kadar büyük, ne zaman,
/// ne kadar derin, ne kadar enerji, en büyükleri, en hareketli yerler.
struct StatisticsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let premium = PremiumStore.shared
    @State private var showPaywall = false
    /// Premium ekranı önizlemede o an görünen vitrin sayfasıyla açılır.
    @State private var paywallFeature: PaywallFeature = .statistics
    @State private var viewModel = StatisticsViewModel()
    @State private var path = NavigationPath()

    // MARK: - Filtreler

    private enum StatsRegion: String, CaseIterable {
        case turkiye, global
        var queryValue: String? { self == .turkiye ? "TR" : nil }
    }
    @State private var region: StatsRegion = .turkiye
    @State private var range: EarthquakeListViewModel.TimeRange = .week

    @State private var isVisible = false

    // MARK: - Sismolog AI

    @State private var aiSummary: String?
    @State private var isAISummarizing = false
    @State private var aiSummaryFailed = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isWide: Bool { horizontalSizeClass == .regular }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 18) {
                    if !premium.isPremium {
                        statisticsPremiumPreview
                    } else {
                        overviewContent
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 36)
                // Büyük başlık güvenli alanın soluna çizildiği için kart
                // sütunu da sola hizalanır; iPad yatayda başlık solda,
                // kartlar ortada kalıyordu.
                .sismikContentWidth(alignment: .leading)
                // KPI/nabız/dağılım sayılarının "sayaç" gibi kayarak animasyonlu
                // güncellenmesi için tek bir ortak animasyon kapsamı: `stats`
                // değiştiğinde (yenileme, bölge/aralık geçişi) içindeki tüm
                // `.contentTransition(.numericText)` öğeleri bunu kullanır.
                .animation(reduceMotion ? nil : SismikDesign.Motion.entranceSpring, value: viewModel.stats)
            }
            // ScrollView kendi kullanılabilir genişliğini ilk yerleşimde bilir;
            // içerik marjı vermek sıfır genişlikli ara ölçümü ve yatay taşmayı
            // birlikte önler.
            .contentMargins(.horizontal, 16, for: .scrollContent)
            #if DEBUG
            // Ekran görüntüsü için: `-SismikStatsAnchor center|bottom`.
            .defaultScrollAnchor(Self.debugScrollAnchor)
            #endif
            .background(Color(.systemGroupedBackground))
            .navigationTitle(L("stats.title"))
            .navigationBarTitleDisplayMode(.large)
            // Önizlemenin kendi başlığı var; ekranın büyük başlığı onun
            // üstünde ikinci bir başlık gibi duruyordu.
            .toolbar(premium.isPremium ? .visible : .hidden, for: .navigationBar)
            .navigationDestination(for: Earthquake.self) { EarthquakeDetailView(earthquake: $0) }
            .fullScreenCover(isPresented: $showPaywall) { PaywallView(initialFeature: paywallFeature) }
            .task(id: "\(statsTaskKey)-\(isVisible)") {
                guard isVisible, premium.isPremium else { return }
                await loadStats()
            }
            .refreshable {
                guard premium.isPremium else { return }
                await loadStats(force: true)
            }
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .onChange(of: statsTaskKey) { _, _ in
                aiSummary = nil
                aiSummaryFailed = false
            }
        }
    }

    #if DEBUG
    private static var debugScrollAnchor: UnitPoint? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-SismikStatsAnchor"), index + 1 < args.count else { return nil }
        return args[index + 1] == "bottom" ? .bottom : .center
    }
    #endif

    private var statsTaskKey: String {
        "\(region.rawValue)-\(range.rawValue)-\(premium.isPremium)"
    }

    // MARK: - Ücretsiz Kullanıcı Önizlemesi

    /// Premium olmayan kullanıcıya istatistik ekranı yerine gösterilen tanıtım:
    /// tek canlı sahne ekranın kartlarını sırayla gösterir.
    private var statisticsPremiumPreview: some View {
        PremiumFeatureTeaser(
            title: L("premiumPreview.stats.title"),
            subtitle: L("premiumPreview.stats.subtitle"),
            buttonTitle: L("premiumPreview.stats.unlockButton"),
            tint: .appAction,
            items: [
                .init(id: "trends", icon: "chart.line.uptrend.xyaxis",
                      title: L("premiumPreview.stats.feature.trends.title"),
                      detail: L("premiumPreview.stats.feature.trends.detail"), paywallFeature: .statistics),
                .init(id: "magnitude", icon: "chart.bar.fill",
                      title: L("premiumPreview.stats.feature.magnitude.title"),
                      detail: L("premiumPreview.stats.feature.magnitude.detail"), paywallFeature: .statistics),
                .init(id: "pulse", icon: "waveform.path.ecg",
                      title: L("premiumPreview.stats.feature.pulse.title"),
                      detail: L("premiumPreview.stats.feature.pulse.detail"), paywallFeature: .statistics),
                .init(id: "topEvents", icon: "list.number",
                      title: L("premiumPreview.stats.feature.topEvents.title"),
                      detail: L("premiumPreview.stats.feature.topEvents.detail"), paywallFeature: .statistics),
                .init(id: "comparison", icon: "globe.europe.africa.fill",
                      title: L("premiumPreview.stats.feature.comparison.title"),
                      detail: L("premiumPreview.stats.feature.comparison.detail"), paywallFeature: .statistics)
            ],
            onUnlock: { feature in
                paywallFeature = feature
                showPaywall = true
            },
            heroHeight: 200,
            framesHero: false
        ) { phase, isAnimating in
            StatsToolkitHero(phase: StatsToolkitHero.Phase(rawValue: phase) ?? .trends, isAnimating: isAnimating)
        }
        .padding(.top, 12)
    }

    private func loadStats(force: Bool = false) async {
        let alternateRegion: StatsRegion = (region == .turkiye) ? .global : .turkiye
        await viewModel.load(
            range: range,
            region: region.queryValue,
            alternateRegion: alternateRegion.queryValue,
            forceRefresh: force
        )
    }

    // MARK: - Genel Bakış Ekran İçeriği

    private var scopeTitle: String {
        "\(range.title) · \(region == .turkiye ? L("Türkiye") : L("Dünya"))"
    }

    @ViewBuilder
    private var overviewContent: some View {
        regionAndRangeCard

        if let stats = viewModel.stats, let presentation = viewModel.presentation {
            Group {
                // Kaç deprem oldu? (detay ekranının başlığıyla aynı dil)
                StatsHero(stats: stats, presentation: presentation, scopeTitle: scopeTitle)

                // Dönemin en büyüğü: listedeki büyük deprem kartının aynısı.
                if let strongest = presentation.strongestQuakes.first {
                    let quake = toEarthquake(strongest)
                    FeaturedQuakeCard(
                        earthquake: quake,
                        isWorldwide: region == .global,
                        caption: L("stats.largest.caption")
                    ) { path.append(quake) }
                }

                StatsMagnitudeBreakdown(stats: stats)
                StatsTimelineCard(stats: stats, buckets: presentation.trendBuckets, peak: presentation.peakBucket)
                StatsDepthCard(stats: stats)
                if let joules = stats.totalEnergyJoules, joules > 0 {
                    StatsEnergyCard(joules: joules)
                }
                if presentation.strongestQuakes.count > 1 {
                    topQuakesCard(Array(presentation.strongestQuakes.dropFirst()))
                }
                if !presentation.topRegions.isEmpty {
                    StatsRegionsCard(regions: presentation.topRegions)
                }
                seismologistAISummaryCard(stats, presentation: presentation)
                footerCard(stats)
            }
        } else if viewModel.viewState.isInitialLoading || (viewModel.viewState.value == nil && viewModel.errorMessage == nil) {
            statsSkeleton
                .transition(.opacity)
        } else if viewModel.errorMessage != nil {
            statsErrorCard
        }
    }

    // MARK: - Bölge & Zaman Aralığı Kartı

    private var regionAndRangeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(L("İstatistik kapsamı"), selection: $region) {
                Text(L("Türkiye")).tag(StatsRegion.turkiye)
                Text(L("Dünya")).tag(StatsRegion.global)
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
            .sensoryFeedback(.selection, trigger: region)
            .accessibilityLabel(L("İstatistik bölgesi"))

            HStack(spacing: 8) {
                ForEach(EarthquakeListViewModel.TimeRange.allCases) { range in
                    rangeChip(range)
                }
            }
            .sensoryFeedback(.selection, trigger: range)
        }
        .bentoCardStyle()
        .overlay(alignment: .bottomTrailing) {
            ProgressView()
                .controlSize(.mini)
                .opacity(viewModel.isRefreshing ? 1 : 0)
                .padding(12)
                .accessibilityHidden(!viewModel.isRefreshing)
        }
        .animation(reduceMotion ? nil : SismikDesign.Motion.rowSpring, value: viewModel.isRefreshing)
    }

    private func rangeChip(_ r: EarthquakeListViewModel.TimeRange) -> some View {
        let isOn = range == r
        return Button {
            guard range != r else { return }
            range = r
        } label: {
            Text(r.shortTitle)
                .font(.caption.weight(.bold).monospacedDigit())
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(
                    isOn ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color(.tertiarySystemGroupedBackground)),
                    in: Capsule()
                )
                .foregroundStyle(isOn ? Color(.systemBackground) : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sismik Aktivite Değerlendirmesi

    private func seismologistAISummaryCard(_ s: GlobalStats, presentation: StatisticsPresentation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            StatsSectionTitle(title: L("stats.ai.title"))

            if let aiSummary {
                VStack(alignment: .leading, spacing: 10) {
                    Text(aiSummary)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(L("stats.ai.footer"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            } else if isAISummarizing {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.brandOrange)
                    Text(L("stats.ai.loading"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("stats.ai.intro", region == .turkiye ? L("Türkiye") : L("Dünya")))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Düz metin etiket — bkz. SeismicAssessmentCard: `sparkles`
                    // glifi ekrandaki sayıları derleyen bu eylemi olduğundan
                    // farklı gösteriyordu.
                    Button {
                        Task { await runAISummary(s, presentation: presentation) }
                    } label: {
                        Text(L("stats.ai.action"))
                    }
                    .buttonStyle(.sismikPrimary)
                    .disabled(isAISummarizing)

                    if aiSummaryFailed {
                        Text(L("stats.ai.unavailable"))
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .transition(.opacity)
            }
        }
        // Değerlendirme kartıyla aynı davranış: boşta → yükleniyor → özet
        // geçişleri yüksekliği sıçratmadan yumuşar.
        .animation(
            reduceMotion ? nil : SismikDesign.Motion.rowSpring,
            value: SummaryPhase(hasSummary: aiSummary != nil, isLoading: isAISummarizing, failed: aiSummaryFailed)
        )
        .bentoCardStyle()
    }

    /// Özet kartının durumunu tek karşılaştırılabilir değerde toplar.
    private struct SummaryPhase: Equatable {
        let hasSummary: Bool
        let isLoading: Bool
        let failed: Bool
    }

    private func runAISummary(_ s: GlobalStats, presentation: StatisticsPresentation) async {
        guard !isAISummarizing else { return }
        isAISummarizing = true
        aiSummaryFailed = false
        let result = await AIService.fetchStatsSummary(
            region: region.queryValue,
            rangeLabel: range.shortTitle,
            stats: s,
            presentation: presentation
        )
        guard !Task.isCancelled else { return }
        isAISummarizing = false
        if let result {
            aiSummary = result
        } else {
            aiSummaryFailed = true
        }
    }

    // MARK: - En Büyük Depremler Tablosu

    /// Dönemin diğer büyük depremleri, listedeki satır tasarımıyla.
    private func topQuakesCard(_ topList: [GlobalStats.TopQuake]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            StatsSectionTitle(title: L("stats.top.title"), subtitle: L("stats.top.subtitle"))
            VStack(spacing: 0) {
                ForEach(topList) { q in
                    let eq = toEarthquake(q)
                    NavigationLink(value: eq) {
                        EarthquakeRow(earthquake: eq)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    if q.id != topList.last?.id {
                        Divider().padding(.leading, 62)
                    }
                }
            }
        }
        .bentoCardStyle()
    }

    private func toEarthquake(_ q: GlobalStats.TopQuake) -> Earthquake {
        let resolvedProvider: String = {
            if let p = q.provider, !p.isEmpty { return p.uppercased() }
            let lowerID = q.id.lowercased()
            if lowerID.hasPrefix("usgs-") { return "USGS" }
            if lowerID.hasPrefix("emsc-") { return "EMSC" }
            if lowerID.hasPrefix("afad-") { return "AFAD" }
            if lowerID.hasPrefix("noa-") { return "NOA" }
            return "USGS"
        }()

        return Earthquake(
            id: q.id,
            provider: resolvedProvider,
            title: q.place,
            magnitude: q.magnitude,
            depth: q.depth ?? 10.0,
            coordinate: Coordinate(longitude: q.lon ?? 0, latitude: q.lat ?? 0),
            date: q.time ?? Date()
        )
    }

    // MARK: - Dipnot Kartı

    /// Kaynaklar ve güncelleme saati tek dipnot satırında.
    private func footerCard(_ s: GlobalStats) -> some View {
        let sources = [("AFAD", s.sourceCounts.afad), ("EMSC", s.sourceCounts.emsc),
                       ("USGS", s.sourceCounts.usgs), ("NOA", s.sourceCounts.noa ?? 0)]
            .filter { $0.1 > 0 }
            .map { "\($0.0) \($0.1.formatted())" }
            .joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 4) {
            if !sources.isEmpty {
                Text(String(format: L("stats.footer.sources"), sources))
            }
            if let date = s.updatedAt {
                Text(L("stats.scopeCard.lastUpdated", date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.currentLocale))))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Skelet & Hata Durumları

    /// Veriler hazırlanırken gösterilen bekleme düzeni.
    ///
    /// Genel `LoadingCardSkeleton` yığını burada yanlış bir şekil veriyordu:
    /// istatistik ekranı satır listesi değil, KPI ızgarası + grafik kartları.
    /// Bu iskelet gerçek yerleşimin ölçülerini taklit eder, böylece veri
    /// geldiğinde kartlar yerinden oynamaz — sayfa "sıçrayarak" kurulmaz.
    private var statsSkeleton: some View {
        VStack(alignment: .leading, spacing: 18) {
            skeletonSectionHeader(width: 96)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: isWide ? 4 : 2),
                spacing: 12
            ) {
                ForEach(0..<(isWide ? 4 : 6), id: \.self) { _ in
                    skeletonKPITile
                }
            }

            skeletonSectionHeader(width: 128)
            skeletonChartCard

            skeletonSectionHeader(width: 110)
            skeletonChartCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .skeletonStyle()
        .overlay(alignment: .top) {
            // Tek hareketli öğe: iskeletin kendisi parıldamıyor, yalnızca
            // standart çark dönüyor. Parıltı efekti tüm kart ağacını her
            // karede yeniden boyatıyor ve bekleme ekranı asıl içerikten
            // pahalıya mal oluyordu.
            ProgressView()
                .controlSize(.small)
                .padding(.top, 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("loading"))
    }

    private func skeletonSectionHeader(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(.secondary.opacity(0.20))
            .frame(width: width, height: 15)
    }

    private var skeletonKPITile: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.secondary.opacity(0.18))
                .frame(width: 30, height: 30)
            RoundedRectangle(cornerRadius: 6)
                .fill(.secondary.opacity(0.22))
                .frame(width: 62, height: 26)
            RoundedRectangle(cornerRadius: 4)
                .fill(.secondary.opacity(0.14))
                .frame(height: 11)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }

    private var skeletonChartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 5)
                .fill(.secondary.opacity(0.20))
                .frame(width: 140, height: 16)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<12, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.secondary.opacity(0.16))
                        .frame(height: Self.skeletonBarHeights[index % Self.skeletonBarHeights.count])
                }
            }
            .frame(height: 96, alignment: .bottom)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }

    /// Sabit yükseklikler — her boyamada yeniden üretilen rastgele değerler
    /// iskeleti titretiyor ve gereksiz yeniden çizim yaratıyordu.
    private static let skeletonBarHeights: [CGFloat] = [34, 58, 46, 72, 40, 88, 52, 30, 66, 44, 78, 38]

    private var statsErrorCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(L("Analiz Yüklenemedi"))
                .font(.headline.weight(.bold))
            Button {
                Task { await loadStats(force: true) }
            } label: {
                RetryButtonLabel(title: L("Tekrar Dene"))
            }
            .buttonStyle(.sismikPrimary)
            .frame(maxWidth: 280)
        }
        .bentoCardStyle()
    }

}

extension View {
    func bentoCardStyle() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Liste ve detay kartlarıyla aynı: düz zemin, çerçevesiz.
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }
}
