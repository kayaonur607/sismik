import SwiftUI

// MARK: - Kilitli ekran önizlemesi (harita, istatistik)
//
// Premium olmayan kullanıcıya harita ve istatistik ekranlarının yerine
// gösterilir. Premium ekranının vitriniyle aynı düzen: ortada ekranın
// özelliklerini sırayla, gerçek ekranı taklit ederek oynatan tek bir sahne;
// altında oynat/duraklat ve özellik başına ilerleme çubukları; onun altında
// o anki özelliğin başlığı ve açıklaması (her geçişte yumuşakça değişir).
//
// Performans: sahneler hafif vektör çizimdir (MapKit, Swift Charts yok);
// harita zemini bir kez çizilir. Sürekli çizim yalnızca oynatım sayfasındaki
// birkaç işarette ve konum sayfasındaki nabız halkasında olur. Ekrandan
// kaydırılınca ve "Hareketi Azalt" açıkken sahne durur.

struct PremiumToolkitItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    /// "Eriş" düğmesi bu özellik görünürken basılırsa Premium ekranının
    /// açılacağı vitrin sayfası.
    let paywallFeature: PaywallFeature
}

struct PremiumFeatureTeaser<Hero: View>: View {
    let title: String
    let subtitle: String
    let buttonTitle: String
    let tint: Color
    let items: [PremiumToolkitItem]
    let onUnlock: (PaywallFeature) -> Void
    var heroHeight: CGFloat = 264
    /// `false`: sahne kendi kartlarını çizer; çerçeve eklenmez (istatistik
    /// sahnesi ekrandaki kartların kendisidir).
    var framesHero = true
    /// Sahne: gösterilen özelliğin sırası ve animasyonların oynayıp oynamadığı.
    @ViewBuilder let hero: (_ phase: Int, _ isAnimating: Bool) -> Hero

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var phase = 0
    /// Oynatım duraklatıldı: kullanıcı bir ilerleme çubuğuna dokundu ya da
    /// duraklat düğmesine bastı. Oynat düğmesi kaldığı yerden sürdürür.
    @State private var userPaused = false
    @State private var isVisible = true
    /// Gösterilen özelliğin süresinin dolan kısmı (0…1); ilerleme çubuğu.
    @State private var segmentProgress: CGFloat = 0
    /// Tanıtım bir tur döndü: oynatım durur ve sahne animasyonları da
    /// kesilir. Sonsuz döngü ekranda beklerken sürekli ~%17 işlemci
    /// harcıyordu (ölçüldü); oynat düğmesi turu baştan başlatır.
    @State private var finishedCycle = false

    /// Bir özelliğin ekranda kaldığı süre: sahnelerin animasyonları (sayaçlar,
    /// oynatım turu, belirme) bu sürede tamamlanır.
    private static var advanceSeconds: Double { 4 }

    private var autoAdvances: Bool {
        !reduceMotion && !voiceOverEnabled && !userPaused && isVisible && items.count > 1
    }

    var body: some View {
        VStack(spacing: 22) {
            header
            VStack(spacing: 14) {
                heroCard
                if items.count > 1 {
                    PremiumPlaybackBar(
                        count: items.count,
                        current: phase,
                        progress: segmentProgress,
                        isPlaying: autoAdvances,
                        showsPlayButton: !reduceMotion && !voiceOverEnabled,
                        tint: tint,
                        onTogglePlay: { togglePlay() },
                        onSelect: select
                    )
                }
                PremiumFeatureCaption(
                    entries: items.map { ($0.title, $0.detail) },
                    current: phase,
                    onStep: { offset in select((phase + offset + items.count) % items.count) }
                )
            }
            Button {
                onUnlock(items.indices.contains(phase) ? items[phase].paywallFeature : .places)
            } label: {
                Text(buttonTitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.sismikPrimary)
        }
        .task(id: "\(phase)-\(autoAdvances)") {
            guard autoAdvances else {
                segmentProgress = 1
                return
            }
            // Çubuk sıfırlanır, bir kare sonra süre boyunca doğrusal dolar
            // (aynı karede yapılırsa animasyon birleşip hiç oynamıyor).
            segmentProgress = 0
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            let remaining = Self.advanceSeconds - 0.04
            withAnimation(.linear(duration: remaining)) { segmentProgress = 1 }
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, autoAdvances else { return }
            if phase == items.count - 1 {
                // Tur bitti: son özellikte durulur.
                withAnimation(.smooth(duration: 0.25)) {
                    userPaused = true
                    finishedCycle = true
                }
                return
            }
            withAnimation(.smooth(duration: 0.5)) { phase += 1 }
        }
    }

    private func togglePlay() {
        withAnimation(.smooth(duration: 0.25)) {
            if userPaused, finishedCycle {
                phase = 0
                finishedCycle = false
            }
            userPaused.toggle()
        }
    }

    /// Çubuktan ya da erişilebilirlik ayarından özellik seçimi: oynatım duraklar.
    private func select(_ index: Int) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) {
            userPaused = true
            finishedCycle = false
            phase = index
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image("LogoOrange")
                    .resizable().scaledToFit()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                Text(verbatim: "Sismik Premium")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.7))
                .lineSpacing(2)
                .frame(maxWidth: 360)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var heroCard: some View {
        hero(phase, isVisible && !reduceMotion && !finishedCycle)
            .frame(maxWidth: .infinity)
            .frame(height: heroHeight)
            .clipShape(.rect(cornerRadius: SismikDesign.Radius.card, style: .continuous))
            .overlay {
                if framesHero {
                    RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
            }
            // Sahne sabit yükseklikte: yazı boyutu burada sınırlanır; aynı
            // bilgi alttaki açıklamada erişilebilir boyutlarda okunur.
            .dynamicTypeSize(...DynamicTypeSize.large)
            .accessibilityHidden(true)
            .onScrollVisibilityChange(threshold: 0.3) { visible in
                isVisible = visible
            }
    }
}

// MARK: - Ortak oynatım parçaları (önizlemeler ve Premium vitrini)

/// Sayfa göstergesi: her özellik için bir nokta, gösterilen özellik uzun bir
/// hapa dönüşür ve oynatım sürerken içi dolar. Eskiden ekran genişliğinde
/// sekiz ayrı ilerleme çubuğu vardı (hikâye tarzı); sistemin sayfa
/// göstergesine yakın bu biçim daha az yer tutuyor ve daha sakin.
/// Dokunulan noktanın özelliğine geçilir.
struct PremiumPlaybackBar: View {
    let count: Int
    let current: Int
    /// Gösterilen özelliğin dolan kısmı (0…1).
    let progress: CGFloat
    let isPlaying: Bool
    let showsPlayButton: Bool
    let tint: Color
    let onTogglePlay: () -> Void
    let onSelect: (Int) -> Void

    private static let dot: CGFloat = 7
    private static let activeWidth: CGFloat = 24

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { index in
                    let isCurrent = index == current
                    Capsule()
                        .fill(Color.primary.opacity(isCurrent ? 0.18 : 0.22))
                        .overlay(alignment: .leading) {
                            if isCurrent {
                                Capsule()
                                    .fill(tint)
                                    .scaleEffect(x: max(progress, 0.001), anchor: .leading)
                            }
                        }
                        .clipShape(Capsule())
                        .frame(width: isCurrent ? Self.activeWidth : Self.dot, height: Self.dot)
                        .frame(height: 28)
                        .contentShape(.rect)
                        .onTapGesture { onSelect(index) }
                }
            }
            .accessibilityHidden(true)

            if showsPlayButton {
                Button(action: onTogglePlay) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.sismikPressable)
                .accessibilityLabel(L(isPlaying ? "premiumPreview.playback.pause" : "premiumPreview.playback.play"))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// O anki özelliğin başlığı ve açıklaması. Her geçişte eski metin bulanıklaşıp
/// kaybolur, yenisi bulanıklıktan netleşir. Alan en uzun açıklamaya göre
/// sabittir: metin uzunluğu değişince alttaki düğme zıplamaz.
struct PremiumFeatureCaption: View {
    let entries: [(title: String, detail: String)]
    let current: Int
    /// VoiceOver'da yukarı/aşağı kaydırma ile önceki/sonraki özellik.
    var onStep: ((Int) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            // Görünmez yerleşim: yükseklik en uzun metne göre.
            ForEach(entries.indices, id: \.self) { index in
                text(entries[index])
                    .hidden()
            }
            if entries.indices.contains(current) {
                text(entries[current])
                    .id(current)
                    .transition(.blurReplace)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entries.indices.contains(current) ? entries[current].title : "")
        .accessibilityValue(entries.indices.contains(current) ? entries[current].detail : "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onStep?(1)
            case .decrement: onStep?(-1)
            @unknown default: break
            }
        }
    }

    private func text(_ entry: (title: String, detail: String)) -> some View {
        VStack(spacing: 6) {
            Text(entry.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            Text(entry.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(1)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Harita sahnesi

/// Harita ekranının taklidi. Sıra `premiumPreview.map.feature.*` satırlarıyla
/// aynı: fay katmanı, bölgesel oynatım, takip edilen yerler, filtreleme, konum.
/// Kıyılar, fay hatları, depremler ve yerler gerçek koordinatlarıyla, harita
/// ekranının izdüşümüyle çizilir.
struct MapToolkitHero: View {
    enum Phase: Int { case faults, density, playback, places, filters, location }

    let phase: Phase
    let isAnimating: Bool

    @State private var playbackStart = Date.now
    @State private var playbackProgress: CGFloat = 0.03
    @State private var placesShown = false
    @State private var locationPulse = false

    private typealias Quake = (latitude: Double, longitude: Double, magnitude: Double)

    private static let quakes: [Quake] = [
        (40.35, 27.95, 5.4), (38.35, 38.30, 4.6), (36.95, 34.60, 3.5), (37.35, 29.10, 3.9),
        (39.90, 33.40, 2.9), (38.05, 42.00, 4.2), (36.35, 32.80, 3.2), (40.60, 36.10, 3.6),
        (39.35, 40.80, 6.1), (37.80, 36.50, 2.6), (38.75, 27.40, 3.3)
    ]
    /// Konum sayfasındaki kullanıcı (Konya) ve ona en yakın deprem.
    private static let userLocation = (latitude: 37.87, longitude: 32.48)
    private static let nearestQuake: (index: Int, km: Double) = quakes.indices
        .map { (index: $0, km: distanceKm(userLocation, (quakes[$0].latitude, quakes[$0].longitude))) }
        .min { $0.km < $1.km }!
    /// Takip edilen yerler: ikon, konum ve bildirim yarıçapı.
    private static let places: [(icon: PlaceIcon, latitude: Double, longitude: Double, radiusKm: Double)] = [
        (.house, 40.99, 29.03, 120), (.family, 38.42, 27.14, 150), (.work, 39.93, 32.85, 110)
    ]

    var body: some View {
        GeometryReader { proxy in
            let projection = PreviewMapProjection(size: proxy.size)
            ZStack {
                PreviewRegionMapLayer()

                MapFaultLayer()
                    .opacity(phase == .faults ? 1 : 0)

                if phase == .density {
                    densityLayer(projection)
                        .transition(.opacity)
                }

                if phase == .playback {
                    // Oynatım bölgeye yakınlaşmış haritada oynar (harita
                    // ekranında da bölge seçilip yakınlaşılır); panel altta.
                    let focus = MapPlaybackLayer.focus(bottomInset: 112)
                    ZStack {
                        PreviewRegionMapLayer(focus: focus)
                        MapPlaybackLayer(projection: PreviewMapProjection(size: proxy.size, focus: focus),
                                         start: playbackStart, isAnimating: isAnimating)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }

                ForEach(Self.quakes.indices, id: \.self) { index in
                    quakeDot(index)
                        .position(projection.point(latitude: Self.quakes[index].latitude,
                                                   longitude: Self.quakes[index].longitude))
                }

                if phase == .places {
                    placesLayer(projection)
                        .transition(.opacity)
                }

                if phase == .location {
                    locationLayer(projection)
                        .transition(.opacity)
                }
            }
        }
        .overlay(alignment: .topTrailing) { controls.padding(10) }
        .overlay(alignment: .bottomLeading) {
            // Harita ekranındaki gibi: filtre düğmesi sol altta durur; panel
            // açılınca ya da oynatım başlayınca yerini bırakır.
            if phase == .filters {
                filterPanel
                    .padding(10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if phase != .playback {
                mapButton("line.3.horizontal.decrease", active: false)
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if phase == .playback {
                PlaybackPanelPreview(progress: playbackProgress, isPlaying: isAnimating)
                    .padding(10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(isAnimating ? .smooth(duration: 0.45) : nil, value: phase)
        .onChange(of: phase, initial: true) { _, newPhase in resetScene(for: newPhase) }
        .onChange(of: isAnimating) { resetScene(for: phase) }
    }

    /// Sayfaya özgü animasyonları baştan başlatır. Sahne durunca (ekran dışı,
    /// "Hareketi Azalt") değerler animasyonsuz yerine oturur; tekrarlayan
    /// animasyonlar da böylece kesilir.
    private func resetScene(for phase: Phase) {
        playbackProgress = 0.03
        placesShown = false
        locationPulse = false
        guard isAnimating else {
            playbackProgress = phase == .playback ? 0.6 : 0.03
            placesShown = phase == .places
            return
        }
        switch phase {
        case .playback:
            playbackStart = .now
            withAnimation(.linear(duration: MapPlaybackLayer.cycle).repeatForever(autoreverses: false)) {
                playbackProgress = 1
            }
        case .places:
            placesShown = true
        case .location:
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { locationPulse = true }
        case .faults, .density, .filters:
            break
        }
    }

    // MARK: Yoğunluk katmanı (haritadaki ısı katmanının taklidi)

    /// Depremlerin yoğunlaştığı yerlerde yumuşak lekeler; renk ölçeği
    /// gerçek katmandaki gibi yeşil → turuncu → kırmızı.
    private func densityLayer(_ projection: PreviewMapProjection) -> some View {
        ZStack {
            ForEach(Self.quakes.indices, id: \.self) { index in
                let quake = Self.quakes[index]
                let level: MagnitudeLevel = quake.magnitude >= 5 ? .major : (quake.magnitude >= 3.5 ? .moderate : .light)
                let radius = 26 + quake.magnitude * 7
                Circle()
                    .fill(RadialGradient(colors: [level.color.opacity(0.62), level.color.opacity(0.28), level.color.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: radius))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(projection.point(latitude: quake.latitude, longitude: quake.longitude))
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Deprem noktaları

    private func quakeDot(_ index: Int) -> some View {
        let quake = Self.quakes[index]
        let level = MagnitudeLevel(magnitude: quake.magnitude)
        let size = level.playbackMarkerRadius * 1.15
        let filteredOut = phase == .filters && quake.magnitude < 3
        // Oynatımda yalnızca seçilen bölgenin depremleri, sırayla görünür.
        let hidden = filteredOut || phase == .playback
        return Circle()
            .fill(level.color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .background(Circle().fill(.black.opacity(0.22)).padding(-1.5))
            // Yoğunluk sayfasında noktalar gerçek haritadaki gibi soluklaşır.
            .opacity(hidden ? 0 : (phase == .density ? 0.55 : 1))
            .scaleEffect(hidden ? 0.4 : 1)
            .animation(isAnimating ? .smooth(duration: 0.35) : nil, value: hidden)
    }

    // MARK: Sağ üstteki harita düğmeleri (harita ekranındakilerle aynı sıra)

    private var controls: some View {
        VStack(spacing: 7) {
            mapButton("clock.arrow.circlepath", active: phase == .playback)
            mapButton("point.bottomleft.forward.to.point.topright.scurvepath", active: phase == .faults)
            mapButton("aqi.medium", active: phase == .density)
            mapButton("mappin.and.ellipse", active: phase == .places)
            mapButton("globe.americas.fill", active: false)
            mapButton("location.fill", active: phase == .location)
        }
    }

    private func mapButton(_ icon: String, active: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(active ? Color.white : Color.appAction)
            .frame(width: 30, height: 30)
            .background(active ? Color.appAction : Color(.systemBackground).opacity(0.94), in: Circle())
            .overlay(Circle().strokeBorder(active ? Color.appAction.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 1))
    }

    // MARK: Filtre paneli (harita filtre panelinin taklidi)

    private var filterPanel: some View {
        let visibleCount = Self.quakes.filter { $0.magnitude >= 3 }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.appAction)
                Text(verbatim: String(format: L("stats.trend.selectedCount"), visibleCount))
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
            }
            chipRow(icon: "bolt.fill", chips: [L("Tümü"), "M2+", "M3+", "M4+"], selected: 2)
            chipRow(icon: "clock.fill",
                    chips: [EarthquakeListViewModel.TimeRange.hour, .day, .week].map(\.shortTitle),
                    selected: 1)
        }
        .padding(10)
        .background(Color(.systemBackground).opacity(0.96), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.3), lineWidth: 0.5)
        )
    }

    private func chipRow(icon: String, chips: [String], selected: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.appAction)
                .frame(width: 14)
            ForEach(chips.indices, id: \.self) { index in
                let isSelected = index == selected
                Text(verbatim: chips[index])
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isSelected ? AnyShapeStyle(Color.appAction) : AnyShapeStyle(Color(.tertiarySystemFill)),
                                in: Capsule())
            }
        }
        .lineLimit(1)
    }

    // MARK: Takip edilen yerler (haritadaki yer işaretleri ve yarıçapları)

    private func placesLayer(_ projection: PreviewMapProjection) -> some View {
        ZStack {
            ForEach(Self.places.indices, id: \.self) { index in
                let place = Self.places[index]
                let radius = projection.length(km: place.radiusKm, atLatitude: place.latitude)
                // Harita ekranındaki yarıçap dairesiyle aynı çizgi ve dolgu.
                Circle()
                    .fill(place.icon.color.opacity(0.10))
                    .stroke(place.icon.color.opacity(0.85), style: StrokeStyle(lineWidth: 1.8, dash: [6, 4]))
                    .frame(width: radius * 2, height: radius * 2)
                    .scaleEffect(placesShown ? 1 : 0.2)
                    .opacity(placesShown ? 1 : 0)
                    .animation(isAnimating ? .smooth(duration: 0.6).delay(0.3 + Double(index) * 0.15) : nil,
                               value: placesShown)
                    .position(projection.point(latitude: place.latitude, longitude: place.longitude))
            }
            ForEach(Self.places.indices, id: \.self) { index in
                let place = Self.places[index]
                PreviewPlacePin(icon: place.icon)
                    .scaleEffect(placesShown ? 1 : 0.3, anchor: .bottom)
                    .opacity(placesShown ? 1 : 0)
                    .animation(isAnimating ? .spring(response: 0.4, dampingFraction: 0.62).delay(Double(index) * 0.15) : nil,
                               value: placesShown)
                    .position(projection.point(latitude: place.latitude, longitude: place.longitude))
            }
        }
    }

    // MARK: Konum (kullanıcı noktası ve en yakın depreme uzaklık)

    private func locationLayer(_ projection: PreviewMapProjection) -> some View {
        let user = projection.point(latitude: Self.userLocation.latitude, longitude: Self.userLocation.longitude)
        let target = Self.quakes[Self.nearestQuake.index]
        let quake = projection.point(latitude: target.latitude, longitude: target.longitude)
        let mid = CGPoint(x: (user.x + quake.x) / 2, y: (user.y + quake.y) / 2)
        return ZStack {
            Path { path in
                path.move(to: user)
                path.addLine(to: quake)
            }
            .stroke(Color.blue.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

            Text(verbatim: "\(Int(Self.nearestQuake.km.rounded())) km")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(.systemBackground).opacity(0.94), in: Capsule())
                .position(x: mid.x + 26, y: mid.y)

            Circle()
                .fill(Color.blue.opacity(0.25))
                .frame(width: 16, height: 16)
                .scaleEffect(locationPulse ? 3 : 1)
                .opacity(locationPulse ? 0 : 1)
                .position(user)
            Circle()
                .fill(Color.blue)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .position(user)
        }
    }

    private static func distanceKm(_ a: (latitude: Double, longitude: Double),
                                   _ b: (latitude: Double, longitude: Double)) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1, dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * 6371 * asin(min(1, sqrt(h)))
    }
}

/// Bölgesel oynatım: kesikli takip çemberi ve içinde sırayla beliren, parlayıp
/// sönen depremler. İşaretler harita ekranındaki oynatım çiziminin aynısıdır
/// (siyah kontrast halkası, renkli dolgu, beyaz kenar; önce büyüyüp sonra
/// küçülerek solar). Yalnızca bu sayfa görünürken ve sahne oynarken ~30 fps
/// çizilir; birkaç daireden ibaret tek bir Canvas.
struct MapPlaybackLayer: View {
    let projection: PreviewMapProjection
    let start: Date
    let isAnimating: Bool

    /// Oynatımın bir turu; alttaki ilerleme çubuğu da aynı sürede dolar.
    static let cycle: TimeInterval = 3.2
    /// Bir depremin doğup tamamen solduğu süre.
    private static let lifetime: TimeInterval = 1.5
    static let center = (latitude: 37.75, longitude: 37.60)
    static let radiusKm = 240.0
    /// Oynatılan bölge (Kahramanmaraş–Malatya), alttaki panel için boşlukla.
    static func focus(bottomInset: CGFloat) -> PreviewMapFocus {
        PreviewMapFocus(west: 35.0, east: 40.2, south: 35.55, north: 39.95,
                        insets: EdgeInsets(top: 12, leading: 12, bottom: bottomInset, trailing: 12))
    }
    /// Oynatılan bölgedeki depremler, oluş sırasıyla.
    private static let quakes: [(latitude: Double, longitude: Double, magnitude: Double)] = [
        (37.23, 37.02, 4.9), (38.90, 38.00, 3.1), (37.10, 38.80, 2.6), (38.08, 37.24, 4.4),
        (36.95, 36.30, 2.8), (37.76, 38.28, 3.6), (37.45, 37.60, 5.2), (38.60, 39.20, 3.3),
        (38.35, 38.31, 4.1)
    ]

    var body: some View {
        let center = projection.point(latitude: Self.center.latitude, longitude: Self.center.longitude)
        let radius = projection.length(km: Self.radiusKm, atLatitude: Self.center.latitude)
        ZStack {
            Circle()
                .fill(Color.brandOrange.opacity(0.07))
                .stroke(Color.brandOrange.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .frame(width: radius * 2, height: radius * 2)
                .position(center)

            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { timeline in
                let elapsed = timeline.date.timeIntervalSince(start)
                Canvas { context, _ in
                    for index in Self.quakes.indices {
                        drawMarker(index, age: isAnimating ? age(of: index, elapsed: elapsed) : 0.3, in: context)
                    }
                }
            }
        }
    }

    /// 0…1 arası yaş; henüz doğmamış ya da tamamen solmuş depremde `nil`.
    private func age(of index: Int, elapsed: TimeInterval) -> Double? {
        let birth = 0.2 + Double(index) * (Self.cycle - 0.4) / Double(Self.quakes.count)
        guard elapsed >= birth else { return nil }
        let sinceBirth = (elapsed - birth).truncatingRemainder(dividingBy: Self.cycle)
        let age = sinceBirth / Self.lifetime
        return age <= 1 ? age : nil
    }

    private func drawMarker(_ index: Int, age: Double?, in context: GraphicsContext) {
        guard let age else { return }
        let quake = Self.quakes[index]
        let level = MagnitudeLevel(magnitude: quake.magnitude)
        let center = projection.point(latitude: quake.latitude, longitude: quake.longitude)
        // Harita ekranındaki oynatım işaretinin ölçek ve saydamlık eğrisi.
        let scale = age < 0.18 ? 0.7 + age / 0.18 * 0.5 : 1.2 - (age - 0.18) / 0.82 * 0.35
        let alpha = pow(1 - age, 0.72)
        let radius = level.playbackMarkerRadius * 0.575 * scale

        // Doğuş anındaki parlama: işaretten dışa açılıp sönen halka.
        if age < 0.3 {
            let progress = age / 0.3
            context.stroke(Path(ellipseIn: Self.rect(center, radius * (1 + progress * 1.3))),
                           with: .color(level.color.opacity(0.6 * (1 - progress))), lineWidth: 1.5)
        }
        context.fill(Path(ellipseIn: Self.rect(center, radius + 1.5)), with: .color(.black.opacity(alpha * 0.32)))
        context.fill(Path(ellipseIn: Self.rect(center, radius)), with: .color(level.color.opacity(max(0.14, alpha))))
        context.stroke(Path(ellipseIn: Self.rect(center, radius)),
                       with: .color(.white.opacity(max(0.38, alpha * 0.96))), lineWidth: 1.5)
    }

    private static func rect(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}

/// Harita ekranındaki yer işaretinin (`NotificationPlaceAnnotationView`)
/// aynısı: beyaz çerçeveli, ikon renginde yuvarlatılmış kare.
private struct PreviewPlacePin: View {
    let icon: PlaceIcon

    private static let side: CGFloat = 26

    var body: some View {
        let side = Self.side
        RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
            .fill(.white)
            .overlay {
                RoundedRectangle(cornerRadius: side * 0.26, style: .continuous)
                    .fill(icon.color)
                    .padding(2)
            }
            .overlay {
                Image(systemName: icon.symbolName)
                    .font(.system(size: side * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.28), radius: 3, y: 1.5)
    }
}

/// Aktif fay katmanı: başlıca fay zonlarının kabaca izleri, uygulamadaki fay
/// risk renkleri ve çizgi kalınlıklarıyla (enlem, boylam).
private struct MapFaultLayer: View {
    private static let faults: [(risk: FaultRisk, points: [(Double, Double)])] = [
        // Kuzey Anadolu Fayı
        (.high, [(40.60, 26.30), (40.82, 27.60), (40.75, 29.00), (40.72, 29.95), (40.83, 31.20),
                 (40.80, 32.40), (40.95, 33.60), (41.00, 34.60), (40.85, 35.90), (40.55, 37.00),
                 (40.20, 38.10), (39.75, 39.50), (39.35, 40.60), (39.30, 41.00)]),
        // Doğu Anadolu Fayı
        (.high, [(39.30, 41.00), (38.90, 40.40), (38.70, 39.90), (38.40, 39.30), (38.20, 38.80),
                 (37.95, 38.10), (37.80, 37.60), (37.40, 36.95), (36.90, 36.40), (36.20, 36.10)]),
        // Marmara güney kolu
        (.medium, [(40.40, 27.10), (40.35, 28.30), (40.45, 29.40)]),
        // Gediz ve Büyük Menderes grabenleri
        (.mediumHigh, [(38.60, 27.40), (38.45, 28.30), (38.30, 28.90)]),
        (.mediumHigh, [(37.85, 27.30), (37.90, 28.30), (37.80, 29.10)]),
        // Fethiye–Burdur
        (.medium, [(36.65, 29.10), (37.10, 29.60), (37.60, 30.20)]),
        // Tuz Gölü
        (.medium, [(38.30, 34.20), (38.90, 33.60), (39.40, 33.30)]),
        // Bitlis–Zagros
        (.mediumHigh, [(38.50, 41.40), (37.90, 42.40), (37.45, 43.40)])
    ]

    var body: some View {
        Canvas { context, size in
            let projection = PreviewMapProjection(size: size)
            for fault in Self.faults {
                var path = Path()
                path.addLines(fault.points.map { projection.point(latitude: $0.0, longitude: $0.1) })
                context.stroke(path, with: .color(fault.risk.color),
                               style: StrokeStyle(lineWidth: fault.risk.lineWidth + 0.6, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// Bölgesel oynatım panelinin (`MapRegionPlaybackControls`) sade taklidi:
/// özet satırı (deprem sayısı ve en büyüğü), oynat düğmesi, imleçli histogram
/// ve zaman kaydırıcısı, başa dön düğmesi. Harita önizlemesi ve Premium
/// ekranı aynı paneli kullanır.
struct PlaybackPanelPreview: View {
    /// 0…1; imleç ve kaydırıcı buna göre ilerler.
    let progress: CGFloat
    let isPlaying: Bool

    private var isTurkish: Bool { AppLanguage.isTurkish }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: isTurkish ? "24 deprem" : "24 earthquakes")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                Text(verbatim: "·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.caption)
                    .foregroundStyle(MagnitudeLevel(magnitude: 5.2).textColor)
                Text(verbatim: isTurkish ? "En büyük M 5,2" : "Largest M 5.2")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.appAction, in: Circle())
                    .contentTransition(.symbolEffect(.replace))

                VStack(spacing: 5) {
                    PlaybackHistogramShape()
                        .frame(height: 20)
                        .overlay(alignment: .leading) { cursor }
                    slider
                }

                Image(systemName: "backward.end.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.appAction)
                    .frame(width: 36, height: 36)
                    .background(Color.appAction.opacity(0.14), in: Circle())
            }
        }
        .padding(12)
        .background(Color(.systemBackground).opacity(0.96), in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.3), lineWidth: 0.5)
        )
    }

    /// Histogram üzerindeki oynatma imleci.
    private var cursor: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(Color.primary.opacity(0.9))
                .frame(width: 2)
                .offset(x: max(0, min(proxy.size.width, progress * proxy.size.width)) - 1)
        }
    }

    private var slider: some View {
        GeometryReader { proxy in
            let x = max(0, min(proxy.size.width, progress * proxy.size.width))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.appAction)
                    .frame(width: x, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                    .offset(x: x - 8)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 16)
    }
}

/// Oynatım panelindeki histogram: çubuklar dilimdeki en büyük depremin
/// rengini taşır, boş dilimler soluk kalır (uygulamadaki gibi). Sabit; bir
/// kez çizilir.
struct PlaybackHistogramShape: View {
    private static let bins: [(count: CGFloat, magnitude: Double)] = [
        (0.3, 2.4), (0.5, 3.1), (0, 0), (0.2, 2.2), (0.8, 4.2), (1.0, 5.2), (0.6, 3.6), (0.4, 2.9),
        (0.7, 4.6), (0.3, 2.6), (0, 0), (0.5, 3.4), (0.2, 2.1), (0.4, 3.0), (0.6, 3.8), (0.3, 2.5),
        (0.2, 2.3), (0.45, 3.3), (0, 0), (0.35, 2.8), (0.55, 4.1), (0.25, 2.4), (0.4, 3.1), (0.2, 2.2)
    ]

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 1
            let width = (size.width - spacing * CGFloat(Self.bins.count - 1)) / CGFloat(Self.bins.count)
            for (index, bin) in Self.bins.enumerated() {
                let height = max(2, bin.count * size.height)
                let rect = CGRect(x: CGFloat(index) * (width + spacing), y: size.height - height,
                                  width: width, height: height)
                let color = bin.count == 0
                    ? Color.primary.opacity(0.12)
                    : MagnitudeLevel(magnitude: bin.magnitude).color.opacity(0.85)
                context.fill(Path(roundedRect: rect, cornerRadius: min(2, width / 2)), with: .color(color))
            }
        }
    }
}

// MARK: - İstatistik sahnesi

/// İstatistik ekranının taklidi: her özellik, ekrandaki karşılığı olan kartla
/// gösterilir (aynı başlıklar, aynı kart bileşenleri). Sahnenin ayrı bir
/// zemini yok; kart, istatistik ekranındaki gibi doğrudan sayfada durur. Sıra
/// `premiumPreview.stats.feature.*` satırlarıyla aynı.
struct StatsToolkitHero: View {
    enum Phase: Int { case trends, distribution, pulse, regions, comparison }

    let phase: Phase
    let isAnimating: Bool

    private var isTurkish: Bool { AppLanguage.isTurkish }

    var body: some View {
        Group {
            switch phase {
            case .trends: StatsTrendScene(isTurkish: isTurkish, isAnimating: isAnimating)
            case .distribution: StatsDistributionScene(isAnimating: isAnimating)
            case .pulse: StatsPulseScene(isTurkish: isTurkish, isAnimating: isAnimating)
            case .regions: StatsRegionsScene(isTurkish: isTurkish, isAnimating: isAnimating)
            case .comparison: StatsComparisonScene(isAnimating: isAnimating)
            }
        }
        .id(phase)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// İstatistik ekranındaki kart zemini (`bentoCardStyle`) — sahneye sığsın diye
/// iç boşluk biraz daha dar.
private extension View {
    /// `fills`: yalnızca esneyen içerik (trend çubukları) sahneyi doldurur;
    /// diğer kartlar içeriği kadar olur. Eskiden hepsi dolduruyordu ve nabız ile
    /// dağılım kartlarının altında boş beyaz alan kalıyordu.
    func statsSceneCard(fills: Bool = false) -> some View {
        padding(12)
            .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

/// Kart başlığı (`StatisticsSectionHeader` ile aynı görünüm, bilgi düğmesiz).
private struct StatsSceneHeader: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.brandOrange)
            Text(title)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
    }
}

/// Sismik trend kartı: zaman aralığı çipleri ve yükselen çubuklar. Premium
/// ekranının istatistik sayfası da bunu kullanır.
struct StatsTrendScene: View {
    let isTurkish: Bool
    let isAnimating: Bool
    /// Premium ekranında sayfa her görünür olduğunda çubuklar yeniden yükselir.
    var isActive = true

    @State private var grown = false

    /// (sayı oranı, dilimdeki en büyük deprem) — renk trend kartıyla aynı kural.
    private static let buckets: [(value: CGFloat, maxMagnitude: Double)] = [
        (0.35, 3.2), (0.5, 3.6), (0.3, 2.9), (0.62, 4.1), (0.45, 3.4), (1.0, 5.2), (0.7, 4.4),
        (0.4, 3.1), (0.55, 3.7), (0.3, 2.8), (0.8, 4.6), (0.5, 3.5), (0.38, 3.0), (0.6, 3.9)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatsSceneHeader(icon: "chart.bar.fill",
                             title: isTurkish ? "Sismik Trend (Aktivite)" : "Seismic Trend (Activity)")
            HStack(spacing: 5) {
                ForEach(Array([EarthquakeListViewModel.TimeRange.day, .week, .month].enumerated()), id: \.offset) { index, range in
                    Text(verbatim: range.shortTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(index == 1 ? Color.white : Color.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(index == 1 ? AnyShapeStyle(Color.appAction) : AnyShapeStyle(Color(.tertiarySystemFill)),
                                    in: Capsule())
                }
            }
            GeometryReader { proxy in
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Self.buckets.indices, id: \.self) { index in
                        let bucket = Self.buckets[index]
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Self.color(for: bucket.maxMagnitude))
                            .frame(height: proxy.size.height * bucket.value)
                            .scaleEffect(y: grown ? 1 : 0.04, anchor: .bottom)
                            .animation(isAnimating ? .spring(response: 0.5, dampingFraction: 0.8)
                                .delay(Double(index) * 0.04) : nil, value: grown)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
        }
        .statsSceneCard(fills: true)
        .onChange(of: isActive, initial: true) { _, active in grown = active }
    }

    /// Uygulamanın büyüklük ölçeği (istatistik ekranındaki çubuklarla aynı).
    private static func color(for magnitude: Double) -> Color {
        MagnitudeLevel(magnitude: magnitude).color
    }
}

/// Büyüklük dağılımı kartı: halka grafik ve açıklama listesi.
private struct StatsDistributionScene: View {
    let isAnimating: Bool

    @State private var drawn = false

    private static let slices: [(label: String, count: Int, color: Color)] = [
        ("M < 3", 58, .blue), ("M 3–4.4", 31, .green), ("M 4.5–5.9", 9, .orange), ("M 6+", 2, .red)
    ]
    private static let total = slices.reduce(0) { $0 + $1.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatsSceneHeader(icon: "waveform.path.ecg", title: L("stats.distribution.title"))
            HStack(spacing: 16) {
                ZStack {
                    ForEach(Self.slices.indices, id: \.self) { index in
                        let start = Self.fraction(upTo: index)
                        let end = Self.fraction(upTo: index + 1)
                        Circle()
                            .trim(from: start + 0.006, to: max(start + 0.006, (drawn ? end : start) - 0.006))
                            .stroke(Self.slices[index].color, style: StrokeStyle(lineWidth: 16, lineCap: .butt))
                            .rotationEffect(.degrees(-90))
                            .animation(isAnimating ? .smooth(duration: 0.55).delay(Double(index) * 0.12) : nil, value: drawn)
                    }
                    VStack(spacing: 0) {
                        Text(Self.total, format: .number)
                            .font(.headline.weight(.bold).monospacedDigit())
                        Text(L("stats.usgs.total"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(width: 70)
                }
                .frame(width: 118, height: 118)

                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Self.slices.indices, id: \.self) { index in
                        let slice = Self.slices[index]
                        HStack(spacing: 7) {
                            Circle().fill(slice.color).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: slice.label).font(.caption.weight(.bold))
                                Text(verbatim: "\(slice.count) · \(Int((Double(slice.count) / Double(Self.total) * 100).rounded()))%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .statsSceneCard()
        .onAppear { drawn = true }
    }

    private static func fraction(upTo index: Int) -> CGFloat {
        CGFloat(slices.prefix(index).reduce(0) { $0 + $1.count }) / CGFloat(total)
    }
}

/// Sismik nabız kartı: istatistik ekranındaki kartın aynısı. "Dengeli"
/// durumdan "Yükseliyor"a geçer; değerler sayaç gibi akar.
private struct StatsPulseScene: View {
    let isTurkish: Bool
    let isAnimating: Bool

    @State private var rising = false

    private var change: Double { rising ? 18 : 3 }
    private var dailyAverage: Double { rising ? 20.4 : 16.8 }
    private var intervalMinutes: Int { rising ? 71 : 86 }
    private var tint: Color { rising ? .red : .brandOrange }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("SİSMİK NABIZ"))
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    Text(rising ? L("Yükseliyor") : L("Dengeli"))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(tint)
                        .contentTransition(.opacity)
                }
                Spacer()
                Image(systemName: rising ? "arrow.up.right" : "equal")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(tint.opacity(0.12), in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }

            HStack(spacing: 0) {
                metric(value: "+\(Int(change))%", label: L("Dönemsel değişim"), numeric: change)
                Divider().frame(height: 34).padding(.horizontal, 10)
                metric(value: dailyAverage.formatted(.number.precision(.fractionLength(1))),
                       label: L("Günlük ortalama"), numeric: dailyAverage)
                Divider().frame(height: 34).padding(.horizontal, 10)
                metric(value: "\(intervalMinutes) \(L("dk"))", label: L("Olay aralığı"), numeric: Double(intervalMinutes))
            }

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .contentTransition(.opacity)
        }
        .statsSceneCard()
        .onAppear {
            guard isAnimating else { rising = true; return }
            withAnimation(.smooth(duration: 0.6).delay(0.9)) { rising = true }
        }
    }

    /// Kartın özet cümlesi (istatistik ekranındaki metinle aynı).
    private var summary: String {
        let scope = L("Türkiye'de")
        if rising {
            return isTurkish
                ? "\(scope) son yarıdaki olay sıklığı, dönemin ilk yarısına göre arttı. Bu oran tek başına gelecekteki bir depremi öngörmez."
                : "\(scope), event frequency increased in the latter half of the period. This rate alone does not predict a future earthquake."
        }
        return isTurkish
            ? "\(scope) aktivite dönemin iki yarısı arasında benzer bir hızda seyretti."
            : "\(scope), activity remained at a similar rate across both halves of the period."
    }

    private func metric(value: String, label: String, numeric: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline.weight(.bold).monospacedDigit())
                .contentTransition(.numericText(value: numeric))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// En aktif bölgeler kartı: ad, sayı ve dolan çubuk.
private struct StatsRegionsScene: View {
    let isTurkish: Bool
    let isAnimating: Bool

    @State private var filled = false

    private static let regions: [(name: String, count: Int)] = [
        ("Malatya", 42), ("Balıkesir", 31), ("Muğla", 18), ("Van", 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            StatsSceneHeader(icon: "map.fill",
                             title: isTurkish ? "En Aktif Sismik Bölgeler" : "Most Active Seismic Regions")
            ForEach(Self.regions.indices, id: \.self) { index in
                let region = Self.regions[index]
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(verbatim: region.name).font(.footnote.weight(.bold))
                        Spacer()
                        Text(region.count, format: .number)
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(Color.brandOrange)
                    }
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color.primary.opacity(0.07))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(Color.brandOrange)
                                    .frame(width: proxy.size.width * CGFloat(region.count) / 42)
                                    .scaleEffect(x: filled ? 1 : 0.02, anchor: .leading)
                                    .animation(isAnimating ? .smooth(duration: 0.6).delay(Double(index) * 0.1) : nil, value: filled)
                            }
                    }
                    .frame(height: 5)
                }
            }
        }
        .statsSceneCard()
        .onAppear { filled = true }
    }
}

/// Türkiye – Dünya karşılaştırması: ekrandaki KPI kutucuklarıyla.
private struct StatsComparisonScene: View {
    let isAnimating: Bool

    @State private var counted = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                StatisticsKPITile(value: (counted ? 412 : 0).formatted(), label: L("Türkiye"),
                                  icon: "flag.fill", tint: .brandOrange, numericValue: counted ? 412 : 0)
                StatisticsKPITile(value: (counted ? 1286 : 0).formatted(), label: L("Dünya"),
                                  icon: "globe.europe.africa.fill", tint: .blue, numericValue: counted ? 1286 : 0)
            }
            HStack(spacing: 6) {
                ForEach(["AFAD", "EMSC", "USGS", "NOA"], id: \.self) { source in
                    Text(verbatim: source)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
            }
        }
        .frame(maxHeight: .infinity)
        .onAppear {
            guard isAnimating else { counted = true; return }
            withAnimation(.smooth(duration: 0.8)) { counted = true }
        }
    }
}
