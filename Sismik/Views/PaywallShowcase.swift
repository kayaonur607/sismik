import SwiftUI

// MARK: - Premium vitrini
//
// Premium ekranının üstündeki sayfalı tanıtım: her Premium özelliğinin kendi
// sayfası var; kullanıcı sağa sola kaydırarak geçer (otomatik geçiş yok).
// Altında harita/istatistik önizlemelerindeki çubuklar sayfa göstergesi
// olarak durur ve her geçişte başlık/açıklama değişir.
// Her sayfa, uygulamadaki karşılığının aynısını gösterir: deprem haritasının
// katman ekranı, oynatım paneli, bildirimler, Canlı Etkinlik, analiz kartı,
// istatistik kartı, widget'lar. Kullanıcı satın alacağı şeyi görür.
//
// Performans kuralları (paywall açıkken pil ve GPU harcamasın):
//  - Animasyonu yalnızca GÖRÜNEN sayfa oynatır (`isActive`); diğerleri durağan.
//  - Bulanık malzeme ve katmanlı gölge kullanılmaz. Hareketler tek seferlik
//    animasyonlardır; sürekli çizim yalnızca aktif oynatım sayfasındaki
//    birkaç işarette (~30 fps, tek Canvas).
//  - Haritalar MapKit değil: kıyı hatları bir kez çizilen vektör verisidir
//    (`PreviewRegionMap`).
//  - Vitrin ekrandan kaydırılınca (`onScrollVisibilityChange`) her şey durur.
//  - Çizimler sabit yükseklikte olduğu için yazı boyutu çizim içinde
//    sınırlanır; aynı bilgi çizimin altındaki metinde erişilebilir boyutlarda
//    büyümeye devam eder.

/// Vitrin sayfaları, gösterim sırasıyla.
enum PaywallFeature: String, CaseIterable, Identifiable {
    case places, notifications, digest, aftershock, statistics, layers, playback, analysis, sounds

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .places: "mappin.and.ellipse"
        case .notifications: "bell.badge.fill"
        case .digest: "calendar"
        case .aftershock: "dot.radiowaves.left.and.right"
        case .layers: "map.fill"
        case .playback: "play.rectangle.fill"
        case .analysis: "waveform.path.ecg"
        case .statistics: "chart.xyaxis.line"
        case .sounds: "speaker.wave.3.fill"
        }
    }

    var title: String {
        switch self {
        case .places: L("places.premium.title")
        case .notifications: L("paywall.benefit.alerts")
        case .digest: L("settings.weeklyDigest.title")
        case .aftershock: L("paywall.benefit.aftershock")
        case .layers: L("paywall.benefit.layers")
        case .playback: L("paywall.benefit.playback")
        case .analysis: L("paywall.benefit.ai")
        case .statistics: L("paywall.benefit.regional")
        case .sounds: L("paywall.benefit.sounds")
        }
    }

    /// Vitrinde çizimin altındaki kısa açıklama.
    var caption: String {
        switch self {
        case .places: L("paywall.slide.places")
        case .notifications: L("paywall.slide.notifications")
        case .digest: L("paywall.slide.digest")
        case .aftershock: L("paywall.slide.aftershock")
        case .layers: L("paywall.slide.layers")
        case .playback: L("paywall.slide.playback")
        case .analysis: L("paywall.slide.analysis")
        case .statistics: L("paywall.slide.statistics")
        case .sounds: L("paywall.slide.sounds")
        }
    }
}

struct PaywallShowcase: View {
    @Binding var selection: PaywallFeature

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Vitrin ekrandaysa görünen sayfanın animasyonu oynar.
    @State private var isVisible = true
    /// Kaydırma görünümünün gösterdiği sayfa; `selection` ile eşlenir.
    @State private var scrolledID: PaywallFeature?

    private static let artworkHeight: CGFloat = 232

    init(selection: Binding<PaywallFeature>) {
        _selection = selection
    }

    var body: some View {
        VStack(spacing: 14) {
            // Otomatik geçiş yok: sayfalar arasında kullanıcı sağa sola
            // kaydırarak geçer. Her sayfanın kendi animasyonu görünür
            // olduğunda oynar.
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(PaywallFeature.allCases) { feature in
                        PaywallShowcaseArtwork(feature: feature, isActive: isVisible && selection == feature)
                            .padding(.horizontal, 2)
                            .containerRelativeFrame(.horizontal)
                            .id(feature)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.never)
            .scrollPosition(id: $scrolledID)
            // Ekran bir özellikle açıldıysa (ör. harita katmanlarından) vitrin
            // ilk karede o sayfada durur; tembel yığında başlangıç konumu
            // görünüm yerleştikten sonra verilir, animasyonsuz.
            .onAppear {
                guard scrolledID == nil else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { scrolledID = selection }
            }
            .frame(height: Self.artworkHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(selection.title)
            .accessibilityValue(selection.caption)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(by: 1)
                case .decrement: step(by: -1)
                @unknown default: break
                }
            }

            // Önizlemelerdeki çubuklar sayfa göstergesi olarak: bulunulan
            // sayfaya kadar dolu; dokunulan çubuğun sayfasına geçilir.
            PremiumPlaybackBar(
                count: PaywallFeature.allCases.count,
                current: PaywallFeature.allCases.firstIndex(of: selection) ?? 0,
                progress: 1,
                isPlaying: false,
                showsPlayButton: false,
                tint: .appAction,
                onTogglePlay: {},
                onSelect: { index in selection = PaywallFeature.allCases[index] }
            )
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: selection)

            // Başlık ve açıklama her geçişte bulanıklıktan netleşerek değişir;
            // sayfanın kendisi VoiceOver'da zaten okunuyor.
            PremiumFeatureCaption(
                entries: PaywallFeature.allCases.map { ($0.title, $0.caption) },
                current: PaywallFeature.allCases.firstIndex(of: selection) ?? 0
            )
            .accessibilityHidden(true)
        }
        .onScrollVisibilityChange(threshold: 0.3) { visible in
            isVisible = visible
        }
        .onChange(of: scrolledID) { _, newValue in
            if let newValue, newValue != selection { selection = newValue }
        }
        .onChange(of: selection) { _, newValue in
            // Çubuğa dokunma ya da VoiceOver adımı: kaydırma o sayfaya gider.
            if scrolledID != newValue {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.45)) { scrolledID = newValue }
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func step(by offset: Int) {
        selection = neighbor(of: selection, offset: offset)
    }

    private func neighbor(of feature: PaywallFeature, offset: Int) -> PaywallFeature {
        let all = PaywallFeature.allCases
        let index = all.firstIndex(of: feature) ?? 0
        return all[(index + offset + all.count) % all.count]
    }
}

// MARK: - Sayfa çizimleri

private struct PaywallShowcaseArtwork: View {
    let feature: PaywallFeature
    let isActive: Bool

    var body: some View {
        // Arkada renkli bir zemin yok: her çizim, uygulamadaki karşılığı gibi
        // kendi kartıyla doğrudan sayfada durur.
        Group {
            switch feature {
            case .places: PlacesArtwork(isActive: isActive)
            case .notifications: NotificationsArtwork(isActive: isActive)
            case .digest: DigestArtwork(isActive: isActive)
            case .aftershock: AftershockArtwork(isActive: isActive)
            case .layers: FaultLayersArtwork(isActive: isActive)
            case .playback: PlaybackArtwork(isActive: isActive)
            case .analysis: AnalysisArtwork(isActive: isActive)
            case .statistics: StatisticsArtwork(isActive: isActive)
            case .sounds: SoundsArtwork(isActive: isActive)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Çizim sabit yükseklikte: yazı boyutu burada sınırlanır.
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityHidden(true)
    }
}

private extension View {
    /// Uygulamanın gruplu kart zemini; çizimlerdeki ekran parçaları bunu kullanır.
    func artworkCard() -> some View {
        background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }

    /// Sıralı beliriş: `step` sırasına göre gecikmeli, tek seferlik.
    func reveal(_ revealed: Bool, step: Int, reduceMotion: Bool) -> some View {
        opacity(revealed ? 1 : 0)
            .offset(y: revealed || reduceMotion ? 0 : 8)
            .animation(reduceMotion ? nil : .smooth(duration: 0.35).delay(0.1 + Double(step) * 0.16), value: revealed)
    }
}

private func formattedMagnitude(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
}

/// Kayıtlı yerler listesi: satırlar sırayla belirir.
private struct PlacesArtwork: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    /// Yer türü uygulamanın dilinde (dil değişirse yeniden hesaplanır).
    private static var places: [NotificationPlace] {
        [
            NotificationPlace(id: "demo-home", name: "\(L("places.sample.home")) · Kadıköy", icon: .house,
                              latitude: 40.99, longitude: 29.03, radiusKm: 50, minMagnitude: 2.0,
                              criticalMagnitude: 5.0),
            NotificationPlace(id: "demo-family", name: "\(L("places.sample.family")) · İzmir", icon: .family,
                              latitude: 38.42, longitude: 27.14, radiusKm: 100, minMagnitude: 3.0),
            NotificationPlace(id: "demo-work", name: "\(L("places.sample.work")) · Ankara", icon: .work,
                              latitude: 39.93, longitude: 32.85, radiusKm: 30, minMagnitude: 3.5)
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(Self.places.enumerated()), id: \.element.id) { index, place in
                if index > 0 { Divider().padding(.leading, 42) }
                NotificationPlaceRow(place: place)
                    .reveal(revealed, step: index, reduceMotion: reduceMotion)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .artworkCard()
        .onChange(of: isActive, initial: true) { _, active in revealed = active }
    }
}

/// Kilit ekranındaki deprem bildirimleri: metinler sunucunun gönderdiği
/// şablonlarla aynı (renkli nokta + yer adı başlığı, büyüklük ve uzaklık alt
/// başlığı, kaynak satırı; sağda yerin simgesi).
private struct NotificationsArtwork: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    private struct Banner: Identifiable {
        let id: Int
        let title: String
        let subtitle: String
        let body: String
        let secondsAgo: TimeInterval
        let place: PlaceIcon?
    }

    private var banners: [Banner] {
        [
            Banner(id: 0,
                   title: "🟠 \(L("paywall.demo.notif.nearStrong", L("places.sample.home")))",
                   subtitle: "M5.4 · \(L("paywall.demo.notif.away", 6))",
                   body: "Kadıköy, İstanbul · 14:32 · AFAD",
                   secondsAgo: 0, place: .house),
            Banner(id: 1,
                   title: "🟢 \(L("paywall.demo.notif.near", L("places.sample.family")))",
                   subtitle: "M3.2 · \(L("paywall.demo.notif.away", 14))",
                   body: "Buca, İzmir · 09:14 · AFAD",
                   secondsAgo: 5 * 3600, place: .family),
            Banner(id: 2,
                   title: "🔴 \(L("paywall.demo.notif.world"))",
                   subtitle: "M7.1 · \(L("paywall.demo.depth", 12))",
                   body: "Honshu · 03:05 · USGS",
                   secondsAgo: 11 * 3600, place: nil)
        ]
    }

    /// Eski bildirimler sayfa kaydırılırken bile görünür; sayfa açılınca en
    /// yenisi kilit ekranındaki gibi en üste düşer, diğerlerini aşağı iter.
    var body: some View {
        VStack(spacing: 8) {
            ForEach(banners) { banner in
                if banner.id > 0 || revealed {
                    bannerView(banner)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: isActive, initial: true) { _, active in
            guard active, !reduceMotion else { revealed = active; return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.08)) { revealed = true }
        }
    }

    private func bannerView(_ banner: Banner) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image("LogoOrange")
                .resizable().scaledToFit()
                .frame(width: 34, height: 34)
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: banner.title)
                        .font(.footnote.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(verbatim: relativeTime(banner.secondsAgo))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: banner.subtitle)
                    .font(.footnote.weight(.semibold))
                Text(verbatim: banner.body)
                    .font(.footnote)
                    .foregroundStyle(.primary.opacity(0.8))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            if let place = banner.place {
                PlaceIconBadge(icon: place, size: 34)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    /// Bildirim merkezindeki gibi göreli zaman ("şimdi", "5 sa. önce").
    private func relativeTime(_ secondsAgo: TimeInterval) -> String {
        let style = Date.RelativeFormatStyle(presentation: secondsAgo < 60 ? .named : .numeric,
                                             unitsStyle: .abbreviated)
            .locale(AppLanguage.currentLocale)
        return Date.now.addingTimeInterval(-secondsAgo).formatted(style)
    }
}

/// Haftalık özet: pazartesi sabahı gelen sessiz bildirim ve altında haftanın
/// günlük dağılımı (çubuklar günün en büyük depreminin renginde).
private struct DigestArtwork: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    private static let days: [(count: Int, maxMagnitude: Double)] = [
        (1, 2.1), (3, 2.8), (0, 0), (2, 3.4), (4, 2.6), (1, 1.9), (1, 2.4)
    ]

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image("LogoOrange")
                    .resizable().scaledToFit()
                    .frame(width: 34, height: 34)
                    .clipShape(.rect(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("paywall.demo.digest.title"))
                        .font(.footnote.weight(.semibold))
                    Text(L("paywall.demo.digest.body"))
                        .font(.footnote)
                        .foregroundStyle(.primary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(Self.days.enumerated()), id: \.offset) { index, day in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(day.count == 0 ? Color.primary.opacity(0.08) : MagnitudeLevel(magnitude: day.maxMagnitude).color)
                            .frame(height: revealed ? CGFloat(max(day.count, 0)) * 16 + 6 : 6)
                        Text(Self.weekday(index))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 88, alignment: .bottom)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: isActive, initial: true) { _, active in
            guard active, !reduceMotion else { revealed = active || reduceMotion; return }
            withAnimation(.smooth(duration: 0.6).delay(0.1)) { revealed = true }
        }
    }

    /// Pazartesiden başlayan kısa gün adları, uygulama dilinde.
    private static func weekday(_ index: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = AppLanguage.currentLocale
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return symbols[(index + 1) % 7]
    }
}

/// Artçı takibinin Canlı Etkinliği: Dynamic Island'ın küçük hâli ve kilit
/// ekranı kartı (widget uzantısındaki `AftershockLiveActivity` ile aynı).
private struct AftershockArtwork: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var count = 9

    private static let finalCount = 14
    private static let brand = Color.brandOrange

    var body: some View {
        VStack(spacing: 14) {
            // Dynamic Island (küçük hâl): solda simge, sağda artçı sayısı.
            HStack {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Self.brand)
                Spacer(minLength: 0)
                Text(count, format: .number)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(Self.brand)
                    .contentTransition(.numericText(value: Double(count)))
            }
            .padding(.horizontal, 14)
            .frame(width: 190, height: 36)
            .background(Color.black, in: Capsule())

            lockScreenCard
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .task(id: isActive) {
            guard isActive else { count = 9; return }
            guard !reduceMotion else { count = Self.finalCount; return }
            while count < Self.finalCount {
                try? await Task.sleep(for: .seconds(0.9))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy) { count += 1 }
            }
        }
    }

    private var lockScreenCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.bold))
                Text(L("paywall.demo.activity.title"))
                    .font(.caption.weight(.heavy))
                    .tracking(0.6)
                Spacer()
                Text(verbatim: "14:32")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
            }
            .foregroundStyle(Self.brand)

            HStack(spacing: 12) {
                Text(verbatim: "M \(formattedMagnitude(5.1))")
                    .font(.title2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Self.brand, in: .rect(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Sındırgı (Balıkesir)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text(L("widget.time.hour", 3))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                statColumn(Text(count, format: .number).contentTransition(.numericText(value: Double(count))),
                           label: L("paywall.demo.activity.aftershocks"))
                divider
                statColumn(Text(verbatim: "M \(formattedMagnitude(3.9))"), label: L("paywall.demo.activity.largest"))
                divider
                statColumn(Text(count > 9 ? L("widget.time.justnow") : L("widget.time.min", 4)),
                           label: L("paywall.demo.activity.last"))
            }
        }
        .padding(14)
        .background(Color(white: 0.11), in: .rect(cornerRadius: 22, style: .continuous))
    }

    private func statColumn(_ value: some View, label: String) -> some View {
        VStack(spacing: 2) {
            value
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.15))
            .frame(width: 1, height: 22)
    }
}

/// Önizleme haritalarının ortak çerçevesi: kartın köşeleri ve ince kenarı
/// (deprem haritası kartıyla aynı).
private extension View {
    func previewMapCard() -> some View {
        clipShape(.rect(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }
}

/// Deprem haritasının katman ekranı: gerçek kıyı hatlı harita, merkez üssü
/// işareti, ShakeMap eş-şiddet konturları (MMI renkleriyle) ve fay hatları;
/// altta ekrandaki katman paneli (Sarsıntı / Faylar / Depremler). Önce
/// konturlar çizilir, ardından panel "Faylar"a geçer.
private struct FaultLayersArtwork: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var layer: DetailMapLayer = .shaking
    @State private var drawn = false
    @Namespace private var segment

    /// Sındırgı (Balıkesir) — örnek ana şok.
    private static let epicenter = (latitude: 39.24, longitude: 28.18, magnitude: 6.1)
    private static let focus = PreviewMapFocus(
        west: 26.4, east: 30.0, south: 38.25, north: 40.2,
        insets: EdgeInsets(top: 6, leading: 10, bottom: 70, trailing: 10))
    /// Eş-şiddet konturları: MMI ve merkezden ortalama uzaklık (km). Kabuk
    /// fay doğrultusunda (BKB–DGD) uzar; kenarlar gerçek ShakeMap gibi
    /// düzensizdir.
    private static let contours: [(mmi: Int, radiusKm: Double)] = [(4, 122), (5, 86), (6, 56), (7, 32)]
    /// Bölgedeki başlıca diri faylar (kabaca), uygulamadaki risk renkleriyle.
    private static let faults: [(risk: FaultRisk, points: [(Double, Double)])] = [
        (.high, [(39.34, 27.80), (39.27, 28.05), (39.20, 28.35), (39.13, 28.65)]),
        (.mediumHigh, [(39.13, 28.75), (39.12, 29.05), (39.06, 29.40)]),
        (.medium, [(38.78, 27.55), (38.66, 28.05), (38.52, 28.60)]),
        (.medium, [(39.45, 27.98), (39.58, 28.35), (39.70, 28.70)]),
        (.mediumHigh, [(39.25, 27.50), (39.02, 27.62), (38.80, 27.75)]),
        (.high, [(40.42, 27.20), (40.36, 28.20), (40.44, 29.30)])
    ]

    var body: some View {
        GeometryReader { proxy in
            let projection = PreviewMapProjection(size: proxy.size, focus: Self.focus)
            let showsContours = drawn && layer == .shaking
            let showsFaults = drawn && layer == .faults
            ZStack {
                PreviewRegionMapLayer(focus: Self.focus)

                ForEach(Self.contours.indices, id: \.self) { index in
                    let contour = Self.contours[index]
                    Self.contourPath(mmi: contour.mmi, radiusKm: contour.radiusKm, projection: projection)
                        .trim(from: 0, to: showsContours ? 1 : 0)
                        .stroke(Color(uiColor: detailMMIColor(contour.mmi)),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        // Dıştan içe değil, merkezden dışa: en küçük kontur önce.
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8)
                            .delay(Double(Self.contours.count - 1 - index) * 0.18), value: showsContours)
                }

                ForEach(Self.faults.indices, id: \.self) { index in
                    let fault = Self.faults[index]
                    Path { path in
                        path.addLines(fault.points.map { projection.point(latitude: $0.0, longitude: $0.1) })
                    }
                    .trim(from: 0, to: showsFaults ? 1 : 0)
                    .stroke(fault.risk.color,
                            style: StrokeStyle(lineWidth: fault.risk.lineWidth + 0.6, lineCap: .round, lineJoin: .round))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.6).delay(Double(index) * 0.08),
                               value: showsFaults)
                }

                epicenterMarker
                    .position(projection.point(latitude: Self.epicenter.latitude, longitude: Self.epicenter.longitude))
            }
        }
        .overlay(alignment: .topLeading) { layerBadge.padding(10) }
        .overlay(alignment: .bottom) { layerPanel.padding(10) }
        .previewMapCard()
        .task(id: isActive) {
            guard isActive else {
                drawn = false
                layer = .shaking
                return
            }
            guard !reduceMotion else { drawn = true; return }
            drawn = true
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.3)) { layer = .faults }
        }
    }

    /// Detay haritasındaki merkez üssü işareti: renkli hale, beyaz kenarlı
    /// çekirdek ve büyüklük.
    private var epicenterMarker: some View {
        let color = MagnitudeLevel(magnitude: Self.epicenter.magnitude).color
        return ZStack {
            Circle().fill(color.opacity(0.22)).frame(width: 56, height: 56)
            Circle()
                .fill(color)
                .frame(width: 36, height: 36)
                .overlay(Circle().stroke(.white, lineWidth: 2))
            Text(verbatim: formattedMagnitude(Self.epicenter.magnitude))
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.white)
        }
    }

    /// Seçili katmanın rozeti (deprem kartındaki "ShakeMap" rozetiyle aynı).
    private var layerBadge: some View {
        Label(layer == .faults ? L("Yakındaki aktif faylar") : "USGS ShakeMap",
              systemImage: layer == .faults ? "point.topleft.down.to.point.bottomright.curvepath" : "checkmark.seal.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(layerTint)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background {
                Capsule().fill(Color(.systemBackground).opacity(0.94))
                Capsule().fill(layerTint.opacity(0.14))
            }
            .overlay { Capsule().strokeBorder(layerTint.opacity(0.35), lineWidth: 1) }
            .contentTransition(.opacity)
    }

    /// Katman ekranının alt paneli: segment seçici ve bilgi düğmesi.
    private var layerPanel: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(DetailMapLayer.allCases) { item in
                    let isSelected = item == layer
                    Text(item.title)
                        .font(.footnote.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color(.systemBackground))
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: segment)
                            }
                        }
                }
            }
            .padding(2)
            .background(Color(.tertiarySystemFill), in: Capsule())

            Image(systemName: "info.circle")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .padding(10)
        .background(Color(.systemBackground).opacity(0.96), in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.3), lineWidth: 0.5)
        )
    }

    private var layerTint: Color { layer == .faults ? .red : .brandGreen }

    /// Düzensiz, fay doğrultusunda uzamış kapalı eş-şiddet eğrisi.
    private static func contourPath(mmi: Int, radiusKm: Double, projection: PreviewMapProjection) -> Path {
        let strike = -0.26   // ~15° kuzeybatıya dönük doğrultu (radyan)
        let seed = Double(mmi)
        let latitude = epicenter.latitude
        var path = Path()
        for step in 0...72 {
            let angle = Double(step) / 72 * 2 * .pi
            let wobble = 1 + 0.09 * sin(3 * angle + seed) + 0.05 * cos(5 * angle + seed * 1.7)
            let along = radiusKm * wobble * cos(angle) * 1.35
            let across = radiusKm * wobble * sin(angle) * 0.8
            let eastKm = along * cos(strike) - across * sin(strike)
            let northKm = along * sin(strike) + across * cos(strike)
            let point = projection.point(
                latitude: latitude + northKm / 111.0,
                longitude: epicenter.longitude + eastKm / (111.0 * cos(latitude * .pi / 180)))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// Bölgesel oynatım: bölgeye yakınlaşmış harita, kesikli takip çemberi,
/// içinde sırayla parlayıp sönen depremler ve alttaki oynatım paneli (harita
/// ekranındaki çizimle aynı).
private struct PlaybackArtwork: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now
    @State private var progress: CGFloat = 0.03

    private static let focus = MapPlaybackLayer.focus(bottomInset: 104)

    private var isPlaying: Bool { isActive && !reduceMotion }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                PreviewRegionMapLayer(focus: Self.focus)
                MapPlaybackLayer(projection: PreviewMapProjection(size: proxy.size, focus: Self.focus),
                                 start: start, isAnimating: isPlaying)
            }
        }
        .overlay(alignment: .bottom) {
            PlaybackPanelPreview(progress: progress, isPlaying: isPlaying)
                .padding(10)
        }
        .previewMapCard()
        .onChange(of: isActive, initial: true) { _, active in
            progress = 0.03
            guard active, !reduceMotion else {
                progress = active ? 0.6 : 0.03
                return
            }
            start = .now
            withAnimation(.linear(duration: MapPlaybackLayer.cycle).repeatForever(autoreverses: false)) {
                progress = 1
            }
        }
    }
}

/// Deprem detayındaki "Sismolojik Değerlendirme" kartı. Kart hemen görünür;
/// fay hattı, deprem türü ve yorum sırayla daktilo gibi yazılır.
///
/// Yazım yalnızca çizimde olur (`TypewriterRenderer`): metin baştan tam
/// yerleşir, harfler tek bir animasyonla sırayla çizilir. Görünüm her harfte
/// yeniden kurulmaz; önceki hâlde saniyede ~30 durum güncellemesi metni
/// yeniden yerleştiriyor ve sayfa kaydırılırken vitrinin kaydırmasını
/// bozuyordu.
private struct AnalysisArtwork: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Üç metin boyunca yazılmış karakter sayısı (animasyonla ilerler).
    @State private var typed = 0.0

    private static let secondsPerCharacter = 0.017

    private var fault: String { L("paywall.demo.fault") }
    private var quakeType: String { L("paywall.demo.quakeType") }
    private var commentary: String { L("paywall.demo.analysis") }
    private var totalCount: Double { Double(fault.count + quakeType.count + commentary.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.brandOrange)
                Text(L("detail.aiAnalysis"))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                factRow(label: L("detail.faultLine"), value: fault, offset: 0)
                factRow(label: L("detail.quakeType"), value: quakeType, offset: Double(fault.count))
                Text(commentary)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .textRenderer(TypewriterRenderer(typed: typed, offset: Double(fault.count + quakeType.count)))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .onChange(of: isActive, initial: true) { _, active in
            guard active else { typed = 0; return }
            guard !reduceMotion else { typed = totalCount; return }
            withAnimation(.linear(duration: totalCount * Self.secondsPerCharacter).delay(0.25)) {
                typed = totalCount
            }
        }
    }

    private func factRow(label: String, value: String, offset: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .textRenderer(TypewriterRenderer(typed: typed, offset: offset))
        }
    }
}

/// Daktilo çizimi: metnin yerleşimi değişmez, yalnızca ilk `typed − offset`
/// glif çizilir; sıradaki glif kısa bir geçişle belirir. `typed` animasyonla
/// ilerlediğinden her kare yalnızca çizimi yeniler, yerleşimi değil.
private struct TypewriterRenderer: TextRenderer {
    var typed: Double
    let offset: Double

    var animatableData: Double {
        get { typed }
        set { typed = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let visible = typed - offset
        guard visible > 0 else { return }
        var index = 0.0
        for line in layout {
            for run in line {
                for glyph in run {
                    let remaining = visible - index
                    guard remaining > 0 else { return }
                    if remaining >= 1 {
                        context.draw(glyph)
                    } else {
                        var copy = context
                        copy.opacity = remaining
                        copy.draw(glyph)
                    }
                    index += 1
                }
            }
        }
    }
}

/// İstatistik ekranının sismik trend kartı (harita/istatistik önizlemesindeki
/// kartın aynısı). Sayfa her açıldığında çubuklar yeniden yükselir.
private struct StatisticsArtwork: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StatsTrendScene(isTurkish: AppLanguage.isTurkish, isAnimating: isActive && !reduceMotion,
                        isActive: isActive)
    }
}

/// Ayarlardaki bildirim sesi seçicisi (Apple'ın Zil Sesi ekranı dili): her
/// ses ayrı satır, seçili olanda onay işareti, çalan seste hareketli
/// hoparlör. Sayfa açılınca seçim bir alt sese geçer ve ses "çalar".
private struct SoundsArtwork: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: NotificationSoundOption = .sismik
    @State private var playing: NotificationSoundOption?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("settings.sound.sectionTitle"), systemImage: "speaker.wave.2.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 14)

            VStack(spacing: 0) {
                ForEach(Array(NotificationSoundOption.standardOptions.enumerated()), id: \.element.id) { index, sound in
                    if index > 0 { Divider().padding(.leading, 14) }
                    row(sound)
                }
            }
            .artworkCard()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: isActive) {
            guard isActive else {
                selected = .sismik
                playing = nil
                return
            }
            guard !reduceMotion else { selected = .pulse; return }
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                selected = .pulse
                playing = .pulse
            }
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) { playing = nil }
        }
    }

    private func row(_ sound: NotificationSoundOption) -> some View {
        HStack(spacing: 12) {
            Text(sound.title)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if playing == sound {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.appAction)
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: playing == sound)
                    .transition(.opacity.combined(with: .scale))
            }
            if selected == sound {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.appAction)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
    }
}
