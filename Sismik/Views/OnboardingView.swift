import CoreLocation
import SwiftUI
import UserNotifications

/// Tanıtımdaki tek bir özellik satırı: renkli simge + başlık + tek satır
/// açıklama. Apple'ın karşılama ekranlarındaki (Ayarlar, Fotoğraflar, "Yenilikler")
/// sol hizalı özellik listesi düzeninin aynısıdır.
private struct OnboardingFeature: Identifiable {
    let id: String
    let symbol: String
    /// Yalnızca semantik bir anlam taşıdığında marka renginden ayrılır
    /// (ör. acil durum kırmızısı). Diğer her şey tek marka tonunda kalır.
    var tint: Color = .appAction
    let title: String
    let caption: String
}

/// Sayfanın gerçekten kullanabildiği alana göre ölçeklenen tipografi ve
/// boşluklar. Tanıtım metinleri her cihazda aynı puntoda çizildiğinde küçük
/// iPhone'da başlık ve açıklama ekranı yiyor, büyük ekranda ise başlık gereğinden
/// iri duruyordu. Tek ölçüm noktası `OnboardingScaffold`; alt görünümler değeri
/// ortamdan okur, kendi başlarına cihaz tahmini yapmaz.
fileprivate struct OnboardingMetrics: Equatable {
    var titleFont: Font
    var descriptionFont: Font
    var featureTitleFont: Font
    var featureCaptionFont: Font
    var sectionSpacing: CGFloat
    var featureSpacing: CGFloat
    var featurePadding: CGFloat
    var horizontalPadding: CGFloat
    /// Sayfanın önizleme görseli (kaynak birleşmesi, kart, bildirim alanı).
    /// SE sınıfı ekranda özellik satırlarına yer kalsın diye gizlenir;
    /// görselin anlattığını satırlar da söyler.
    var showsPreview: Bool

    /// `height` sayfanın (üst çubuk ve alt eylem çubuğu düşülmüş) net yüksekliği.
    static func fitting(height: CGFloat, width: CGFloat) -> OnboardingMetrics {
        // Üç kademe: SE sınıfı dar ekran, standart iPhone, geniş iPhone/iPad.
        let isTight = height < 560
        let isRoomy = height >= 720

        return OnboardingMetrics(
            // Görsel blok kalktığı için başlığa yer açıldı; sayfa yine tek
            // ekrana sığar.
            titleFont: (isTight ? Font.title2 : .title).weight(.bold),
            descriptionFont: isTight ? .subheadline : .body,
            featureTitleFont: (isTight ? Font.subheadline : .body).weight(.semibold),
            featureCaptionFont: isTight ? .caption : .footnote,
            sectionSpacing: isTight ? 16 : (isRoomy ? 26 : 21),
            featureSpacing: 0,
            featurePadding: isTight ? 13 : 15,
            horizontalPadding: isTight ? 22 : 26,
            showsPreview: height >= 540
        )
    }
}

fileprivate struct OnboardingMetricsKey: EnvironmentKey {
    static let defaultValue = OnboardingMetrics.fitting(height: 640, width: 390)
}

extension EnvironmentValues {
    fileprivate var onboardingMetrics: OnboardingMetrics {
        get { self[OnboardingMetricsKey.self] }
        set { self[OnboardingMetricsKey.self] = newValue }
    }
}

private struct OnboardingPage: Identifiable {
    enum Kind { case brand, features, permissions }

    let id: String
    let kind: Kind
    /// `nil` yalnızca marka sayfasında: simge yerine uygulama logosu kullanılır.
    let symbol: String?
    var accentColor: Color = .appAction
    let badge: String
    let title: String
    let description: String
    var features: [OnboardingFeature] = []
    /// Başlıkla satırlar arasındaki önizleme: özelliği uygulamadaki
    /// görünümüyle bir kez gösterir.
    var preview: OnboardingPreviewKind?
}

private enum OnboardingPreviewKind {
    /// Üç ajansın kaydı tek depreme birleşir.
    case sources
    /// Listenin başındaki "hissedilmiş olabilir" kartı.
    case feltCard
    /// Kayıtlı yerin bildirim alanı ve hissedilir deprem halkası.
    case placeRings
}

/// Tanıtım akışı: hoş geldin → tek liste (kaynaklar) → hissettiğin depremler
/// → yerlerin için bildirimler → acil durum → premium → izinler.
///
/// Her sayfa aynı iskelet: rozet, büyük başlık, kısa açıklama, özelliği
/// uygulamadaki görünümüyle gösteren küçük bir önizleme ve sol hizalı özellik
/// satırları. Ana eylem her zaman ekranın altında sabit bir çubukta durur.
/// İzin isteği akışın son sayfasıdır — ayrı bir ekran olarak gösterilmez.
struct OnboardingView: View {
    let locationManager: LocationManager
    var onFinish: () -> Void
    /// Yalnızca `#Preview` için: sistem ayarından bağımsız olarak Reduce
    /// Motion durumunu zorlar. `.environment(\.accessibilityReduceMotion, _)`
    /// artık yazılabilir değil, bu yüzden yerel bir geçersiz kılma kullanılır.
    var previewReducedMotion: Bool = false

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReducedMotion }
    @State private var selection: String
    /// Ölçülen alt eylem çubuğu yüksekliği. Sayfa içeriği bu kadar alt dolgu
    /// alır: durağan hâlde hiçbir şey butonun altında saklı kalmaz, ama
    /// kaydırırken içerik oraya akabilir.
    @State private var footerHeight: CGFloat = 0

    init(
        locationManager: LocationManager,
        initialPage: String = "welcome",
        previewReducedMotion: Bool = false,
        onFinish: @escaping () -> Void
    ) {
        self.locationManager = locationManager
        self.onFinish = onFinish
        self.previewReducedMotion = previewReducedMotion
        _selection = State(initialValue: initialPage)
    }

    /// Güncel özellik seti (2.1.4). İkonlar tek marka tonunda; yalnızca acil
    /// sayfası semantik kırmızıyı, hissedilen deprem sayfası "Hissettim"
    /// butonunun camgöbeğini kullanır.
    private var pages: [OnboardingPage] {
        func feature(_ key: String, _ symbol: String, tint: Color = .appAction) -> OnboardingFeature {
            OnboardingFeature(id: key, symbol: symbol, tint: tint,
                              title: L("\(key).title"), caption: L("\(key).caption"))
        }
        return [
            OnboardingPage(
                id: "welcome",
                kind: .brand,
                symbol: nil,
                badge: L("onboarding.welcome.badge"),
                title: L("intro.welcome.title"),
                description: L("ob3.welcome.description"),
                features: [
                    feature("ob2.welcome.live", "antenna.radiowaves.left.and.right"),
                    feature("ob2.welcome.alerts", "mappin.and.ellipse"),
                    feature("ob2.welcome.ready", "cross.case.fill", tint: .red)
                ]
            ),
            OnboardingPage(
                id: "list",
                kind: .features,
                symbol: "waveform.path.ecg",
                badge: L("ob2.list.badge"),
                title: L("ob3.sources.title"),
                description: L("ob3.sources.description"),
                features: [
                    feature("ob3.sources.filter", "line.3.horizontal.decrease.circle.fill"),
                    feature("ob3.sources.map", "map.fill"),
                    OnboardingFeature(id: "scale", symbol: "paintpalette.fill",
                                      title: L("ob2.list.title"), caption: L("ob2.list.description"))
                ],
                preview: .sources
            ),
            OnboardingPage(
                id: "felt",
                kind: .features,
                symbol: "hand.raised.fill",
                accentColor: .teal,
                badge: L("ob3.felt.badge"),
                title: L("ob3.felt.title"),
                description: L("ob3.felt.description"),
                features: [
                    feature("ob3.felt.card", "waveform.path.ecg", tint: .teal),
                    feature("ob3.felt.button", "hand.raised.fill", tint: .teal),
                    feature("ob3.felt.live", "dot.radiowaves.left.and.right", tint: .teal)
                ],
                preview: .feltCard
            ),
            OnboardingPage(
                id: "alerts",
                kind: .features,
                symbol: "bell.badge.fill",
                badge: L("ob2.alerts.badge"),
                title: L("ob3.alerts.title"),
                description: L("ob3.alerts.description"),
                features: [
                    feature("ob3.alerts.presets", "mappin.circle.fill"),
                    feature("ob3.alerts.felt", "waveform.circle.fill"),
                    feature("ob2.alerts.critical", "speaker.wave.3.fill"),
                    feature("ob2.alerts.tsunami", "water.waves"),
                    feature("ob2.alerts.location", "location.fill")
                ],
                preview: .placeRings
            ),
            OnboardingPage(
                id: "emergency",
                kind: .features,
                symbol: "cross.case.fill",
                accentColor: .red,
                badge: L("ob2.emergency.badge"),
                title: L("onboarding.emergency.title"),
                description: L("ob2.emergency.description"),
                features: [
                    feature("ob2.emergency.trapped", "dot.radiowaves.left.and.right", tint: .red),
                    feature("ob2.emergency.firstaid", "heart.text.square.fill", tint: .red),
                    feature("ob2.emergency.family", "person.2.fill", tint: .red),
                    feature("ob2.emergency.assembly", "figure.walk", tint: .red)
                ]
            ),
            OnboardingPage(
                id: "premium",
                kind: .features,
                symbol: "chart.bar.fill",
                badge: L("ob2.premium.badge"),
                title: L("ob2.premium.title"),
                description: L("ob2.premium.description"),
                features: [
                    feature("ob2.premium.stats", "chart.bar.fill"),
                    feature("ob2.premium.map", "map.fill"),
                    feature("ob2.premium.ai", "text.magnifyingglass")
                ]
            ),
            OnboardingPage(
                id: "permissions",
                kind: .permissions,
                symbol: "location.fill.viewfinder",
                badge: L("ob2.permissions.badge"),
                title: L("permissions.header.title"),
                description: L("permissions.header.subtitle")
            )
        ]
    }

    private var currentIndex: Int { pages.firstIndex { $0.id == selection } ?? 0 }
    private var isLast: Bool { currentIndex == pages.count - 1 }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            // Alt çubuk `safeAreaInset` ile eklendiğinde sayfanın kaydırma
            // alanı tam orada bitiyor ve içerik keskin bir çizgiyle kesiliyordu
            // (kartın yarısı görünüp altı düz zemine dönüyordu). Artık sayfa tam
            // boy; içerik butonun altına akıp yumuşakça soluyor.
            TabView(selection: $selection) {
                ForEach(pages) { page in
                    pageView(for: page)
                        .tag(page.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .safeAreaInset(edge: .top, spacing: 0) { skipBar }

            footer
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    footerHeight = height
                }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    @ViewBuilder
    private func pageView(for page: OnboardingPage) -> some View {
        switch page.kind {
        case .brand, .features:
            OnboardingPageView(
                page: page,
                isActive: selection == page.id,
                bottomInset: footerHeight,
                previewReducedMotion: previewReducedMotion
            )
        case .permissions:
            OnboardingPermissionsPageView(
                page: page,
                isActive: selection == page.id,
                bottomInset: footerHeight,
                locationManager: locationManager,
                previewReducedMotion: previewReducedMotion
            )
        }
    }

    /// Üstte yalnızca "Atla" durur; son sayfada eylem alt çubuğa devredildiği
    /// için sessizce kaybolur ama düzen kaymasın diye yüksekliği korunur.
    private var skipBar: some View {
        let accent = pages[currentIndex].accentColor
        return HStack {
            Text("Sismik")
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(.primary)
            Spacer()
            Button(action: onFinish) {
                HStack(spacing: 6) {
                    Text(L("onboarding.skip"))
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(accent.opacity(0.12), in: Capsule())
                .overlay(Capsule().stroke(accent.opacity(0.24), lineWidth: 1))
            }
            .buttonStyle(.sismikPressable(scale: 0.92))
            .opacity(isLast ? 0 : 1)
            .disabled(isLast)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isLast)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Sayfa göstergesi + ana eylem. Ekranın altında sabit durur; arkasında
    /// opak bir panel yerine yalnızca içeriği eriten bir geçiş vardır.
    private var footer: some View {
        VStack(spacing: 14) {
            pageIndicator
            continueButton
        }
        // Sayfa gövdesiyle aynı kenar boşluğu: dar ekranda buton kenara
        // yaklaşır, geniş pencerede sütunla hizalı kalır.
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        // Opak bir raf değil: üst kenarı tamamen saydam, aşağı inerken sayfa
        // zeminine karışan bir geçiş. İçerik butonun altına girerken kesilmek
        // yerine eriyip kaybolur.
        .background {
            let base = Color(.systemGroupedBackground)
            LinearGradient(
                stops: [
                    .init(color: base.opacity(0), location: 0),
                    .init(color: base.opacity(0.65), location: 0.28),
                    .init(color: base, location: 0.62)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }

    private var pageIndicator: some View {
        let activeColor = pages[currentIndex].accentColor
        return HStack(spacing: 7) {
            ForEach(pages) { page in
                let isActive = page.id == selection
                Capsule()
                    .fill(isActive ? activeColor : Color.secondary.opacity(0.25))
                    .frame(width: isActive ? 22 : 7, height: 7)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.82), value: selection)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("onboarding.continue"))
        .accessibilityValue("\(currentIndex + 1) / \(pages.count)")
    }

    private var continueButton: some View {
        Button {
            if isLast {
                onFinish()
            } else {
                withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86)) {
                    selection = pages[currentIndex + 1].id
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(isLast ? L("onboarding.start") : L("onboarding.continue"))
                Image(systemName: isLast ? "checkmark.circle.fill" : "arrow.right")
                    .font(.subheadline.weight(.semibold))
            }
        }
        // Uygulamanın her yerinde kullanılan birincil buton: basıldığında
        // içeri çöker, gölgesi alçalır ve hafif dokunsal geri bildirim verir.
        //
        // Rengi sayfanın vurgusunu izler ve sayfa değişirken oraya doğru
        // geçer: karşılama turuncu, takip mavi, istatistik mor, toplanma
        // yeşil, acil durum kırmızı.
        .buttonStyle(.sismikPrimary(height: 52, tint: pages[currentIndex].accentColor))
    }
}

// MARK: - Sayfa gövdesi

/// Marka ve özellik sayfalarının ortak gövdesi: görsel → rozet → başlık →
/// açıklama → özellik satırları. İçerik sığmadığında (küçük ekran, büyük
/// Dynamic Type) kaydırılır; sığdığında sabit durur.
private struct OnboardingPageView: View {
    let page: OnboardingPage
    let isActive: Bool
    /// Alt eylem çubuğunun kapladığı yükseklik.
    var bottomInset: CGFloat = 0
    var previewReducedMotion: Bool = false

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReducedMotion }

    var body: some View {
        OnboardingScaffold(bottomInset: bottomInset) {
            OnboardingHeader(page: page)

            if let preview = page.preview {
                OnboardingPreview(kind: preview, isActive: isActive, reduceMotion: reduceMotion)
            }

            if !page.features.isEmpty {
                OnboardingFeatureList(features: page.features)
                    .opacity(isActive ? 1 : 0)
                    .offset(y: isActive || reduceMotion ? 0 : 14)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: isActive)
            }
        }
    }
}

/// Özellik satırları. Ölçülen tanıtım metriklerini ortamdan okuyabilmesi için
/// ayrı bir görünümdür: `OnboardingPageView` iskeletin ÜSTÜNDE durduğundan
/// oradan okunan metrik hâlâ varsayılan değeri verirdi.
private struct OnboardingFeatureList: View {
    let features: [OnboardingFeature]

    @Environment(\.onboardingMetrics) private var metrics

    var body: some View {
        // Üç ayrı yüzen kart yerine ayraçlı tek grup. Yan yana duran üç
        // kartın kenarlıkları, sayfanın asıl bilgisi olan metinden daha
        // baskın çıkıyordu; sistemin kendi ayar listeleriyle aynı dil daha
        // sakin ve daha az dikey yer kaplıyor.
        VStack(spacing: 0) {
            ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                if index > 0 {
                    Divider().padding(.leading, metrics.featurePadding * 2 + 34)
                }
                OnboardingFeatureRow(feature: feature)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.card))
    }
}

// MARK: - Önizlemeler

/// Başlığın altındaki küçük önizleme. Özelliği uygulamadaki görünümüyle
/// gösterir (aynı büyüklük renkleri, ajans etiketleri, kart ve buton dili);
/// kullanıcı listede kartı ilk gördüğünde onu tanır. Dar ekranda gizlenir.
private struct OnboardingPreview: View {
    let kind: OnboardingPreviewKind
    let isActive: Bool
    let reduceMotion: Bool

    @Environment(\.onboardingMetrics) private var metrics

    var body: some View {
        if metrics.showsPreview {
            Group {
                switch kind {
                case .sources: SourcesMergePreview(isActive: isActive, reduceMotion: reduceMotion)
                case .feltCard: FeltCardPreview()
                case .placeRings: PlaceRingsPreview(isActive: isActive, reduceMotion: reduceMotion)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.card))
            .opacity(isActive ? 1 : 0)
            .scaleEffect(isActive || reduceMotion ? 1 : 0.97)
            .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: isActive)
            .accessibilityHidden(true)
        }
    }
}

/// Aynı depremin üç ajans kaydı → listede tek satır (bölgenin resmî ajansı).
private struct SourcesMergePreview: View {
    let isActive: Bool
    let reduceMotion: Bool

    private struct Report: Identifiable {
        let id: String
        let magnitude: Double
        let color: Color
    }

    private let reports = [
        Report(id: "EMSC", magnitude: 5.6, color: Color(red: 0.20, green: 0.62, blue: 0.62)),
        Report(id: "KANDİLLİ", magnitude: 5.5, color: Color(red: 0.80, green: 0.45, blue: 0.20)),
        Report(id: "AFAD", magnitude: 5.4, color: Color(red: 0.85, green: 0.30, blue: 0.30))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(reports.enumerated()), id: \.element.id) { index, report in
                        HStack(spacing: 6) {
                            Text(report.id)
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(report.color)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(report.color.opacity(0.14), in: Capsule())
                            Text(String(format: "M%.1f", report.magnitude))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .opacity(isActive ? 1 : 0)
                        .offset(x: isActive || reduceMotion ? 0 : -10)
                        .animation(reduceMotion ? nil : .smooth(duration: 0.4).delay(0.08 * Double(index)), value: isActive)
                    }
                }
                .fixedSize()

                Image(systemName: "arrow.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.tertiary)

                mergedRow
            }

            Label(L("ob3.preview.merged"), systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appAction)
        }
    }

    private var mergedRow: some View {
        let level = MagnitudeLevel(magnitude: 5.4)
        return HStack(spacing: 10) {
            Text("5.4")
                .font(.system(size: 17, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(level.foregroundOnColor)
                .frame(width: 44, height: 40)
                .background(level.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Şanlıurfa")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("AFAD · \(L("ob3.preview.official"))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Listenin başındaki kartın küçültülmüş hâli: MajorEventCard ile aynı
/// başlık, büyüklük rozeti ve "Hissettim" butonu.
private struct FeltCardPreview: View {
    var body: some View {
        let level = MagnitudeLevel(magnitude: 5.4)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L("feltcard.felt.title", "IV"), systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(level.textColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Color(.tertiarySystemGroupedBackground), in: Circle())
            }
            HStack(spacing: 10) {
                Text("5.4")
                    .font(.system(size: 22, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(level.foregroundOnColor)
                    .frame(width: 56, height: 46)
                    .background(level.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Şanlıurfa")
                        .font(.subheadline.weight(.semibold))
                    Text("212 km · \(L("feltcard.distance.you"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            Label(L("feltcard.felt.button"), systemImage: "hand.raised.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(Color.teal, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(level.color.opacity(0.55), lineWidth: 1.2)
                .padding(-8)
        }
        .padding(8)
    }
}

/// Kayıtlı yerin bildirim alanı (dolu halka) ve dışındaki hissedilir deprem
/// halkası (kesikli): alanın dışındaki güçlü deprem de yerde hissedilecekse
/// bildirim gelir. Yanında ön ayarlar ve seçilen şiddet.
private struct PlaceRingsPreview: View {
    let isActive: Bool
    let reduceMotion: Bool

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 14) {
            rings
                .frame(width: 118, height: 118)

            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 4) {
                    presetChip(L("places.preset.near"), selected: false)
                    presetChip(L("places.preset.city"), selected: true)
                    presetChip(L("places.preset.region"), selected: false)
                }
                Label(L("places.felt.level.4"), systemImage: "waveform.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: isActive, initial: true) {
            pulse = isActive && !reduceMotion
        }
    }

    private var rings: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.orange.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                .background(Circle().fill(Color.orange.opacity(0.06)))
            Circle()
                .fill(Color.appAction.opacity(0.16))
                .overlay(Circle().strokeBorder(Color.appAction.opacity(0.7), lineWidth: 1.5))
                .frame(width: 58, height: 58)
            VStack(spacing: 0) {
                Text(L("ob3.preview.home"))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.appAction)
                    .offset(y: -4)
                Image(systemName: "mappin.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white, Color.appAction)
            }
            // Alanın dışında ama hissedilir halkanın içinde bir deprem.
            ZStack {
                Circle()
                    .stroke(MagnitudeLevel(magnitude: 5.4).color, lineWidth: 1.5)
                    .frame(width: 26, height: 26)
                    .scaleEffect(pulse ? 1.25 : 0.6)
                    .opacity(pulse ? 0 : 0.9)
                    .animation(pulse ? .easeOut(duration: 1.6).repeatForever(autoreverses: false) : nil, value: pulse)
                Circle()
                    .fill(MagnitudeLevel(magnitude: 5.4).color)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
            }
            .offset(x: 38, y: -30)
        }
    }

    private func presetChip(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(selected ? Color.white : .secondary)
            .frame(maxWidth: .infinity, minHeight: 24)
            .background(selected ? Color.appAction : Color(.tertiarySystemGroupedBackground), in: Capsule())
    }
}

/// Ortak sayfa iskeleti: okunabilir genişlikte, üstten dengeli başlayan, sığmazsa
/// kaydırılan tek sütun. iPad ve büyük iPhone'da içerik ekranın tamamına
/// yayılmaz; küçük ekranda hiçbir metin kırpılmaz.
private struct OnboardingScaffold<Content: View>: View {
    /// İçerik sığdığında dikeyde ortalanır — büyük iPhone ve iPad'de alt
    /// kısımda kocaman bir boşluk kalmasın diye. Sığmadığında çerçeve zaten
    /// içerik boyuna büyür, hizalama etkisiz kalır ve sayfa normal kaydırılır.
    var alignment: Alignment = .center
    /// Alt eylem çubuğunun yüksekliği: içerik bu kadar alt dolgu alır, böylece
    /// durağan hâlde hiçbir şey butonun arkasında kalmaz. Sayfanın kendisi
    /// çubuğun altına uzanmaya devam eder — kesme çizgisi yerine yumuşak geçiş.
    var bottomInset: CGFloat = 0
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            // Tipografi, alt çubuğun kapladığı alan düşülmüş NET yüksekliğe
            // göre ölçeklenir.
            let metrics = OnboardingMetrics.fitting(
                height: max(proxy.size.height - bottomInset, 320),
                width: proxy.size.width
            )
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                    content()
                }
                .environment(\.onboardingMetrics, metrics)
                // Okunabilir sütun: iPhone'da ekranı doldurur, iPad ve geniş
                // pencerede metin satırı uzayıp okunmaz hâle gelmez.
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 20 + bottomInset)
                .frame(minHeight: proxy.size.height, alignment: alignment)
            }
            .background(ScrollTouchDelayFix())
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
        }
    }
}

/// Sayfa başlığı: rozet + başlık + açıklama. Görsel, başlığın ÜSTÜNDE değil
/// altındaki önizlemededir: tek okuma ekseni korunur, dekoratif bir çerçeve
/// yerine özelliğin kendisi görünür.
private struct OnboardingHeader: View {
    let page: OnboardingPage

    @Environment(\.onboardingMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if page.kind == .brand {
                Image("LogoOrange")
                    .resizable()
                    .scaledToFit()
                    .frame(width: metrics.showsPreview ? 72 : 52, height: metrics.showsPreview ? 72 : 52)
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)
            }
            Text(page.badge)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(page.accentColor)
            Text(page.title)
                .font(metrics.titleFont)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(page.description)
                .font(metrics.descriptionFont)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Sol hizalı özellik satırı: simge + başlık + açıklama.
private struct OnboardingFeatureRow: View {
    let feature: OnboardingFeature

    @Environment(\.onboardingMetrics) private var metrics

    private var iconSide: CGFloat { 34 }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: feature.symbol)
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(feature.tint)
                .frame(width: iconSide, height: iconSide)
                .background(feature.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(metrics.featureTitleFont)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(feature.caption)
                    .font(metrics.featureCaptionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.featurePadding)
        .padding(.vertical, metrics.featurePadding - 1)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - İzin sayfası

/// Akışın son sayfası: diğer sayfalarla aynı iskeleti kullanır, altında
/// gerçek izin satırları durur. Alttaki "Başlat" butonu izin durumundan
/// bağımsız olarak her zaman etkindir — kullanıcı izin vermeden de devam
/// edebilir; izinler yalnızca açık bir dokunuşla istenir.
private struct OnboardingPermissionsPageView: View {
    let page: OnboardingPage
    let isActive: Bool
    /// Alt eylem çubuğunun kapladığı yükseklik.
    var bottomInset: CGFloat = 0
    let locationManager: LocationManager
    var previewReducedMotion: Bool = false

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var isRequestingNotifications = false
    @State private var criticalAlertSetting: UNNotificationSetting = .notSupported
    @State private var isRequestingCriticalAlerts = false
    /// Kritik uyarı sistem diyaloğu daha önce gösterildi mi? Bildirim izni
    /// kritik uyarı olmadan verildiğinde iOS durumu `.disabled` bildirir —
    /// "hiç sorulmadı" ile "reddedildi" ayırt edilemez. Sorulmadıysa düğme
    /// iOS'un izin ekranını açar; ancak sorulup reddedildiyse Ayarlar'a gider.
    @AppStorage("notif.criticalAlertRequested") private var criticalAlertRequested = false
    @State private var showLocationServicesOffAlert = false
    @State private var feedbackTrigger = 0

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReducedMotion }
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        OnboardingScaffold(bottomInset: bottomInset) {
            // Diğer sayfalarla birebir aynı başlık bloğu: animasyonlu görsel,
            // küçük açıklaması, rozet, başlık ve özet. İzin sayfası daha önce
            // kendi sade düzenini kullanıyor, akışın sonunda başka bir ekrana
            // geçilmiş gibi duruyordu.
            OnboardingHeader(page: page)

            permissionRows
        }
        .task(id: isActive) {
            guard isActive else { return }
            await refreshNotificationStatus()
            await refreshCriticalAlertStatus()
        }
        .onChange(of: scenePhase) {
            guard scenePhase == .active else { return }
            Task {
                await refreshNotificationStatus()
                await refreshCriticalAlertStatus()
            }
        }
        .sensoryFeedback(.selection, trigger: feedbackTrigger)
        .alert(
            L("settings.locationRequired"),
            isPresented: $showLocationServicesOffAlert
        ) {
            Button(L("open.settings")) { openSettings() }
            Button(L("cancel"), role: .cancel) {}
        } message: {
            Text(L("settings.locationRequired"))
        }
    }

    /// Kritik uyarıyı açmayı dener.
    ///
    /// Bildirim izni DAHA ÖNCE verilmişse `requestAuthorization` yeniden
    /// sormaz; ancak kritik uyarı kendi sistem onayına sahip olduğu için
    /// istek yine de gönderilir — iOS gerekirse kendi diyalogunu gösterir.
    /// Kullanıcı daha önce açıkça kapattıysa (`.disabled`) tek yol Ayarlar.
    private func requestCriticalAlerts() {
        feedbackTrigger += 1
        if criticalAlertCardState == .settingsRequired {
            openSettings()
            return
        }
        Task { @MainActor in
            isRequestingCriticalAlerts = true
            criticalAlertRequested = true
            // Bildirim izni zaten verildiyse iOS yalnızca kritik uyarı
            // diyaloğunu gösterir; henüz istenmediyse önce bildirim, ardından
            // kritik uyarı diyaloğu gelir.
            if await NotificationManager.shared.requestAuthorization(includeCriticalAlert: true) {
                NotificationManager.shared.markEnabledNow()
                NotificationManager.shared.setProductUpdatesEnabled(true)
                NotificationManager.shared.enableEarthquakeAlertsAfterPermission()
            }
            await refreshNotificationStatus()
            await refreshCriticalAlertStatus()
            isRequestingCriticalAlerts = false
        }
    }

    private func refreshCriticalAlertStatus() async {
        criticalAlertSetting = await NotificationManager.shared.criticalAlertSetting()
        await NotificationManager.shared.refreshCriticalAlertState()
    }

    private var permissionRows: some View {
        VStack(alignment: .leading, spacing: 18) {
            standardPermissions
            criticalAlertPermission
        }
    }

    private var standardPermissions: some View {
        OnboardingPermissionGroup {
            PermissionRow(
                icon: "location.fill",
                accent: .blue,
                title: L("permissions.location.title"),
                summary: L("permissions.location.desc"),
                state: locationCardState,
                actionTitle: locationActionTitle,
                isLoading: false,
                action: requestLocationPermission
            )

            Divider().padding(.leading, 62)

            PermissionRow(
                icon: "bell.badge.fill",
                accent: .brandOrange,
                title: L("permissions.notif.title"),
                summary: L("permissions.notif.desc"),
                state: notificationCardState,
                actionTitle: notificationActionTitle,
                isLoading: isRequestingNotifications,
                action: requestNotificationPermission
            )
        }
    }

    /// Kritik uyarılar kendi alanında durur: konum ve bildirimden farklı bir
    /// şey ister — sessize alınmış telefonu ÇALDIRMA izni. Bildirim satırının
    /// altına iliştirildiğinde sıradan bir alt seçenek gibi okunuyordu;
    /// kullanıcı gece sessize aldığı telefonun deprem için çalacağını
    /// ancak ayrı ve başlıklı bir alanda fark ediyor.
    private var criticalAlertPermission: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("permissions.critical.section"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)

            OnboardingPermissionGroup {
                PermissionRow(
                    icon: "exclamationmark.triangle.fill",
                    accent: Color(red: 0.80, green: 0.10, blue: 0.12),
                    title: L("permissions.critical.title"),
                    summary: criticalAlertCardState == .unavailable
                        ? L("permissions.critical.unavailable")
                        : L("permissions.critical.desc"),
                    state: criticalAlertCardState,
                    actionTitle: criticalAlertCardState == .settingsRequired
                        ? L("permissions.notif.settingsButton")
                        : L("permissions.critical.enable"),
                    isLoading: isRequestingCriticalAlerts || isRequestingNotifications,
                    action: requestCriticalAlerts
                )
            }
        }
    }

    /// Kritik uyarının durumu bildirim iznine bağlıdır: bildirim reddedildiyse
    /// tek yol Ayarlar, henüz istenmediyse istek ikisini birlikte sorar.
    ///
    /// Bildirim izni varken `.notSupported` iki sebepten olabilir: Apple
    /// yetkisi yüklü sürümde yok ya da cihaz desteklemiyor. Kullanıcıya ikisi
    /// ayırt ettirilmez, "şu an kullanılamıyor" denir ve işe yaramayacak bir
    /// düğme gösterilmez.
    private var criticalAlertCardState: PermissionCardState {
        switch notificationCardState {
        case .settingsRequired: return .settingsRequired
        case .available, .unavailable: return .available
        case .enabled: break
        }
        switch criticalAlertSetting {
        case .enabled: return .enabled
        case .disabled: return criticalAlertRequested ? .settingsRequired : .available
        // Kritik uyarı izin isteğine hiç eklenmediyse iOS durumu
        // `.notSupported` bildirir — "desteklenmiyor" değil, "henüz
        // sorulmadı" demektir. Bildirim izni artık kritik uyarı olmadan
        // istendiği için bu, izni verilmiş her yeni kullanıcının ilk
        // durumu. Ancak istek yapıldıktan sonra da `.notSupported` kalırsa
        // yetki gerçekten yoktur (cihaz ya da imza profili).
        case .notSupported: return criticalAlertRequested ? .unavailable : .available
        default: return .available
        }
    }

    private var locationCardState: PermissionCardState {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: .enabled
        case .denied, .restricted: .settingsRequired
        case .notDetermined: .available
        @unknown default: .available
        }
    }

    private var notificationCardState: PermissionCardState {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: .enabled
        case .denied: .settingsRequired
        case .notDetermined: .available
        @unknown default: .available
        }
    }

    private var locationActionTitle: String {
        locationCardState == .settingsRequired
            ? L("permissions.location.settingsButton")
            : L("permissions.location.allowButton")
    }

    private var notificationActionTitle: String {
        notificationCardState == .settingsRequired
            ? L("permissions.notif.settingsButton")
            : L("permissions.notif.allowButton")
    }

    private func requestLocationPermission() {
        feedbackTrigger += 1
        if locationCardState == .settingsRequired {
            openSettings()
            return
        }

        Task { @MainActor in
            if await LocationManager.servicesEnabled() {
                locationManager.requestPermission()
            } else {
                showLocationServicesOffAlert = true
            }
        }
    }

    private func requestNotificationPermission() {
        feedbackTrigger += 1
        if notificationCardState == .settingsRequired {
            openSettings()
            return
        }

        Task { @MainActor in
            isRequestingNotifications = true
            let granted = await NotificationManager.shared.requestAuthorization()
            if granted {
                NotificationManager.shared.markEnabledNow()
                NotificationManager.shared.setProductUpdatesEnabled(true)
                NotificationManager.shared.enableEarthquakeAlertsAfterPermission()
            }
            await refreshNotificationStatus()
            await refreshCriticalAlertStatus()
            isRequestingNotifications = false
        }
    }

    private func refreshNotificationStatus() async {
        notificationStatus = await NotificationManager.shared.authorizationStatus()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

/// İzin kartlarını özellik listesiyle aynı gruplanmış yüzeyde toplar.
/// Ayrı bir görünümdür çünkü `OnboardingPermissionsPageView` iskeletin
/// ÜSTÜNDE durur; oradan okunan metrik varsayılan değeri verirdi.
private struct OnboardingPermissionGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.card))
    }
}


private enum PermissionCardState: Equatable {
    case available
    case enabled
    case settingsRequired
    /// İzin istenebilecek bir şey yok (ör. cihaz kritik uyarıyı desteklemiyor).
    case unavailable
}

/// Tek satırlık izin kartı: simge, açıklama ve — izin henüz verilmemişse —
/// tam genişlikte bir eylem butonu.
private struct PermissionRow: View {
    let icon: String
    let accent: Color
    let title: String
    let summary: String
    let state: PermissionCardState
    let actionTitle: String
    let isLoading: Bool
    let action: () -> Void

    @Environment(\.onboardingMetrics) private var metrics

    /// Düzen YATAY kurulur: eylem, başlıkla aynı satırda sağda durur ve
    /// açıklama satırın TAM GENİŞLİĞİNİ kullanır.
    ///
    /// Önceki düzende açıklama, rozetin yanında kalan dar bir sütuna
    /// sıkışıyor (3-4 satıra bölünüyor) ve altına tam genişlikte bir buton
    /// ekleniyordu; üç izin satırı ekranı aşağı taşırıyordu. Açıklamaya tüm
    /// genişlik verilince aynı metin iki satıra iniyor, buton da kendi
    /// satırını harcamıyor — satır başına ~50 punto kazanç, metinden ödün
    /// vermeden.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(accent)
                    .frame(width: 36, height: 36)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)

                Text(title)
                    .font(metrics.featureTitleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 8)

                trailingControl
            }

            Text(summary)
                .font(metrics.featureCaptionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, metrics.featurePadding)
        .padding(.vertical, metrics.featurePadding * 0.8)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if state == .unavailable {
            Text(L("permissions.critical.badge.unavailable"))
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        } else if state == .enabled {
            Label(L("permissions.location.badge.allowed"), systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.12), in: Capsule())
                .accessibilityLabel("\(title): \(L("permissions.location.badge.allowed"))")
        } else {
            actionButton
        }
    }

    private var buttonTint: Color {
        state == .settingsRequired ? .orange : accent
    }

    private var actionButton: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Text(actionTitle)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(buttonTint, in: Capsule())
            // Görsel yükseklik 32 punto, dokunma hedefi 44: Apple'ın asgari
            // hedef boyutundan taviz verilmiyor.
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.sismikPressable)
        .disabled(isLoading)
        .layoutPriority(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHint(actionTitle)
    }
}

// MARK: - Onboarding Dokunma Gecikmesi İyileştirmesi

/// ScrollView içindeki izin butonlarının 150ms bekleme olmaksızın, "Devam Et" butonuyla
/// birebir aynı 0ms anlık dokunma yaylanması vermesini sağlar.
private struct ScrollTouchDelayFix: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = TouchDelayHelperView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class TouchDelayHelperView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var current: UIView? = self
            while let parent = current?.superview {
                if let scrollView = parent as? UIScrollView {
                    scrollView.delaysContentTouches = false
                    break
                }
                current = parent
            }
        }
    }
}

// MARK: - Previews

#Preview("Onboarding - First Page") {
    OnboardingView(locationManager: LocationManager()) {}
}

#Preview("Onboarding - Last Page (Permissions)") {
    OnboardingView(locationManager: LocationManager(), initialPage: "permissions") {}
}

#Preview("Onboarding - Small iPhone") {
    OnboardingView(locationManager: LocationManager()) {}
}

#Preview("Onboarding - iPad") {
    OnboardingView(locationManager: LocationManager()) {}
}

#Preview("Onboarding - Large Dynamic Type") {
    OnboardingView(locationManager: LocationManager()) {}
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}

#Preview("Onboarding - RTL Arabic") {
    OnboardingView(locationManager: LocationManager()) {}
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, Locale(identifier: "ar"))
}

#Preview("Onboarding - Reduce Motion") {
    OnboardingView(locationManager: LocationManager(), previewReducedMotion: true) {}
}
