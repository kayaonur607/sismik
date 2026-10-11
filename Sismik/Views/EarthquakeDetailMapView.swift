import MapKit
import SwiftUI

enum DetailMapLayer: String, CaseIterable, Identifiable {
    case shaking
    case faults
    case aftershocks

    var id: Self { self }

    var title: String {
        switch self {
        case .shaking: L("Sarsıntı")
        case .faults: L("Faylar")
        case .aftershocks: L("map.layer.aftershocks")
        }
    }
}

/// Deprem haritasının görünüm tercihi (hatırlanır).
enum DetailMapStyle: String, CaseIterable, Identifiable {
    case standard, satellite, hybrid
    var id: Self { self }
    var title: String { L("detailmap.style.\(rawValue)") }
}

struct DetailFaultPath: Identifiable {
    let id = UUID()
    let coordinates: [CLLocationCoordinate2D]
    let risk: FaultRisk
}

struct EarthquakeDetailMapScreen: View {
    let earthquake: Earthquake
    let impactData: SeismicImpactData?
    let userLocation: CLLocation?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedLayer: DetailMapLayer
    @State private var aftershocks: [Earthquake]
    @State private var isLoadingAftershocks = false
    @State private var faultPaths: [DetailFaultPath] = []
    @State private var isLoadingFaults = false
    @State private var showLayersInfoBubble = false
    /// Giriş animasyonunu tetikler: harita ve katman paneli yerine otururken
    /// ekran boş bir dikdörtgen olarak sıçramaz.
    @State private var hasAppeared = false
    /// Görünüm tercihleri: kayıtlı yerler, konum/uzaklık çizgisi, artçı alanı
    /// çemberi ve harita türü. Hepsi hatırlanır.
    @AppStorage("detailMap.showPlaces") private var showPlaces = true
    @AppStorage("detailMap.showMyLocation") private var showMyLocation = true
    @AppStorage("detailMap.showZone") private var showZone = true
    @AppStorage("detailMap.style") private var mapStyleRaw = DetailMapStyle.standard.rawValue
    /// Artçı büyüklük filtresi (0 = tümü).
    @State private var aftershockMinMagnitude: Double = 0
    @State private var selectedAftershock: Earthquake?
    /// Arttıkça harita depremin çerçevesine döner.
    @State private var recenterToken = 0

    private var mapStyle: DetailMapStyle { DetailMapStyle(rawValue: mapStyleRaw) ?? .standard }
    private var zoneRadiusKm: Double { AftershockSequence.zoneRadiusKm(forMagnitude: earthquake.magnitude) }
    private var visibleAftershocks: [Earthquake] {
        aftershockMinMagnitude > 0 ? aftershocks.filter { $0.magnitude >= aftershockMinMagnitude } : aftershocks
    }
    private var savedPlaces: [NotificationPlace] {
        PremiumStore.shared.isPremium ? NotificationPlacesStore.shared.places.filter(\.isActive) : []
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isTR: Bool { AppLanguage.isTurkish }
    private var center: CLLocationCoordinate2D { earthquake.coordinate.clCoordinate }
    private var hasUSGSShakeMapContours: Bool {
        guard let contours = impactData?.contours, !contours.isEmpty else { return false }
        return true
    }

    /// Konturlar ve onlardan türeyen açılış çerçevesi `init`te bir kez
    /// hesaplanır. Daha önce ikisi de hesaplanan özelliklerdi ve gövde her
    /// değerlendirildiğinde (katman seçici, yükleme göstergeleri, popover)
    /// dört-beş kez yeniden üretiliyorlardı; `flatMap` zincirleri on binlerce
    /// koordinatı her seferinde yeniden geziyordu.
    private let sourceShakeMapContours: [SeismicImpactData.Contour]?
    private let initialRegion: MKCoordinateRegion

    private static func contourSpan(
        of contours: [SeismicImpactData.Contour]?,
        center: CLLocationCoordinate2D
    ) -> Double {
        guard let contours else { return 1.8 }
        // Gerçek USGS konturları on binlerce koordinat içerebiliyor; `flatMap`
        // zinciri bunların tamamını iki kez kopyalıyordu.
        var span = 0.7
        for contour in contours {
            for path in contour.paths {
                for coordinate in path.coordinates {
                    span = max(
                        span,
                        abs(coordinate.latitude - center.latitude) * 2.8,
                        abs(coordinate.longitude - center.longitude) * 2.8
                    )
                }
            }
        }
        return span
    }

    init(
        earthquake: Earthquake,
        impactData: SeismicImpactData?,
        aftershocks: [Earthquake],
        userLocation: CLLocation?,
        initialLayer: DetailMapLayer
    ) {
        self.earthquake = earthquake
        self.impactData = impactData
        self.userLocation = userLocation
        _aftershocks = State(initialValue: aftershocks)
        _selectedLayer = State(initialValue: initialLayer)

        let contours: [SeismicImpactData.Contour]?
        if let published = impactData?.contours, !published.isEmpty {
            contours = published
        } else {
            // Model önbelleklidir: aynı deprem için geometri yalnızca ilk
            // istekte üretilir (bkz. SeismicImpactModel.contourCache).
            let estimated = SeismicImpactModel(earthquake: earthquake).estimatedContoursAsSeismicContours
            contours = estimated.isEmpty ? nil : estimated
        }
        self.sourceShakeMapContours = contours

        let center = earthquake.coordinate.clCoordinate
        let span = min(14, max(0.7, Self.contourSpan(of: contours, center: center)))
        let cosLat = max(0.2, cos(center.latitude * .pi / 180.0))
        self.initialRegion = MKCoordinateRegion(
            center: center,
            span: .init(latitudeDelta: span, longitudeDelta: span / cosLat)
        )
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                EarthquakeDetailMapViewRepresentable(
                    earthquake: earthquake,
                    initialRegion: initialRegion,
                    selectedLayer: selectedLayer,
                    contours: sourceShakeMapContours,
                    faultPaths: faultPaths,
                    aftershocks: visibleAftershocks,
                    userLocation: showMyLocation ? userLocation : nil,
                    places: showPlaces ? savedPlaces : [],
                    showsUserLocation: showMyLocation,
                    mapStyle: mapStyle,
                    zoneRadiusKm: selectedLayer == .aftershocks && showZone ? zoneRadiusKm : nil,
                    recenterToken: recenterToken,
                    onSelectAftershock: { quake in
                        withAnimation(.snappy) { selectedAftershock = quake }
                    }
                )
                .ignoresSafeArea(edges: .bottom)
                // Harita ilk karede hazır ama boş görünüyor; katmanlar
                // yerleşirken yumuşak bir açılışla belirir.
                //
                // Ölçek animasyonu bilerek YOK: `fullScreenCover` zaten kendi
                // sunum geçişini oynatıyor ve üstüne bir büyüme eklenince iki
                // hareket üst üste binip zıplama gibi görünüyordu. Geriye
                // yalnızca sunum bittikten sonra çalışan sade bir belirme kaldı.
                .opacity(hasAppeared || reduceMotion ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: hasAppeared)

                VStack(spacing: 8) {
                    if let selectedAftershock, selectedLayer == .aftershocks {
                        aftershockInfoCard(selectedAftershock)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    layerControl
                }
                    .opacity(hasAppeared || reduceMotion ? 1 : 0)
                    .offset(y: hasAppeared || reduceMotion ? 0 : 24)
                    .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86), value: hasAppeared)
            }
            .navigationTitle(L("Deprem Haritası"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("common.close"), systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        recenterToken += 1
                    } label: {
                        Label(L("detailmap.recenter"), systemImage: "scope")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    optionsMenu
                }
            }
            .task {
                // Sunum geçişi bitmeden belirme başlarsa iki hareket çakışır.
                if !reduceMotion {
                    try? await Task.sleep(for: .milliseconds(180))
                }
                hasAppeared = true
                async let faultsTask: Void = loadNearbyFaults()
                if aftershocks.isEmpty {
                    async let aftershocksTask: Void = loadAftershocks()
                    _ = await (faultsTask, aftershocksTask)
                } else {
                    await faultsTask
                }
            }
            .onChange(of: selectedLayer) { _, newLayer in
                if newLayer != .aftershocks { selectedAftershock = nil }
                if newLayer == .aftershocks && aftershocks.isEmpty && !isLoadingAftershocks {
                    Task { await loadAftershocks() }
                }
            }
            .onChange(of: aftershockMinMagnitude) { _, _ in
                if let selected = selectedAftershock, selected.magnitude < aftershockMinMagnitude { selectedAftershock = nil }
            }
        }
    }

    private var layerControl: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Picker(L("Harita katmanı"), selection: $selectedLayer) {
                    ForEach(DetailMapLayer.allCases) { layer in
                        Text(layer.title).tag(layer)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    showLayersInfoBubble.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .popover(isPresented: $showLayersInfoBubble) {
                    LayersInfoBubbleView()
                }
            }
            .frame(minHeight: 44)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: layerIcon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(layerTint)
                    .frame(width: 32, height: 32)
                    .background(layerTint.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(layerTitle)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(layerTint)
                    Text(layerDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if (selectedLayer == .faults && isLoadingFaults) || (selectedLayer == .aftershocks && (isLoadingFaults || isLoadingAftershocks)) {
                    ProgressView().controlSize(.small)
                }
            }

            if selectedLayer == .aftershocks, !aftershocks.isEmpty {
                Picker(L("detailmap.filter"), selection: $aftershockMinMagnitude) {
                    Text(L("detailmap.filter.all")).tag(0.0)
                    Text(verbatim: "M2+").tag(2.0)
                    Text(verbatim: "M3+").tag(3.0)
                    Text(verbatim: "M4+").tag(4.0)
                }
                .pickerStyle(.segmented)
                if let summary = aftershockSummary {
                    Label(summary, systemImage: "chart.bar.xaxis")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if selectedLayer == .shaking, showMyLocation, let distance = userDistanceKm {
                Label(L("detailmap.distance", Int(distance.rounded())), systemImage: "location.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var layerIcon: String {
        switch selectedLayer {
        case .shaking: "waveform.path.ecg"
        case .faults: "point.topleft.down.to.point.bottomright.curvepath"
        case .aftershocks: "circle.hexagongrid.fill"
        }
    }

    private var layerTint: Color {
        switch selectedLayer {
        // Harita kartındaki rozetle aynı dil: doğrulanmış USGS ürünü yeşil,
        // model tabanlı tahmin turuncu, veri yoksa nötr.
        case .shaking:
            if hasUSGSShakeMapContours { .brandGreen }
            else if sourceShakeMapContours != nil { .brandOrange }
            else { .secondary }
        case .faults: .red
        case .aftershocks: .purple
        }
    }

    private var layerTitle: String {
        switch selectedLayer {
        case .shaking:
            if hasUSGSShakeMapContours {
                return "USGS ShakeMap"
            }
            return sourceShakeMapContours != nil
                ? (L("Tahmini ShakeMap (GMPE)"))
                : (L("Şiddet katmanı kullanılamıyor"))
        case .faults:
            return L("Yakındaki aktif faylar")
        case .aftershocks:
            if isLoadingAftershocks && aftershocks.isEmpty {
                return L("aftershocks.overview.loading")
            }
            return L("detailmap.aftershocks.title", visibleAftershocks.count)
        }
    }

    private var layerDescription: String {
        switch selectedLayer {
        case .shaking:
            if hasUSGSShakeMapContours {
                return L("Olaya ait ölçüm ve model verisiyle üretilen eş-şiddet konturları.")
            }
            return sourceShakeMapContours != nil
                ? (L("USGS ve Akkar-Bommer azalım modellerine dayalı, odak derinliği kalibreli eş-şiddet konturları."))
                : (L("Bu olay için şiddet konturu hesaplanamadı."))
        case .faults:
            return L("GEM Global Active Faults verisinden merkez çevresindeki çizgiler.")
        case .aftershocks:
            return L("detailmap.aftershocks.desc", Int(zoneRadiusKm))
        }
    }

    private var mapItem: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: center))
        item.name = earthquake.displayTitle
        return item
    }

    private var userDistanceKm: Double? {
        userLocation.map { $0.distance(from: earthquake.clLocation) / 1_000 }
    }

    /// "En büyük M4.1 · son artçı 12 dk önce" (filtreye göre).
    private var aftershockSummary: String? {
        let list = visibleAftershocks
        guard let largest = list.max(by: { $0.magnitude < $1.magnitude }),
              let latest = list.max(by: { $0.date < $1.date }) else {
            return aftershockMinMagnitude > 0 ? L("detailmap.aftershocks.noneFiltered") : nil
        }
        return L("detailmap.aftershocks.summary", largest.magnitudeString, latest.date.relativeShort)
    }

    private var optionsMenu: some View {
        Menu {
            Section {
                if !savedPlaces.isEmpty {
                    Toggle(L("detailmap.showPlaces"), systemImage: "mappin.and.ellipse", isOn: $showPlaces)
                }
                Toggle(L("detailmap.showMyLocation"), systemImage: "location", isOn: $showMyLocation)
                Toggle(L("detailmap.showZone"), systemImage: "circle.dashed", isOn: $showZone)
            }
            Section(L("detailmap.style")) {
                Picker(L("detailmap.style"), selection: $mapStyleRaw) {
                    ForEach(DetailMapStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
            }
            Section {
                Button {
                    mapItem.openInMaps()
                } label: {
                    Label(L("Apple Haritalar'da Aç"), systemImage: "arrow.up.right.square")
                }
            }
        } label: {
            Label(L("detailmap.options"), systemImage: "slider.horizontal.3")
        }
    }

    /// Haritada dokunulan artçının kısa bilgisi.
    private func aftershockInfoCard(_ quake: Earthquake) -> some View {
        HStack(spacing: 12) {
            Text(quake.magnitudeString)
                .font(.headline.weight(.heavy).monospacedDigit())
                .foregroundStyle(MagnitudeLevel(magnitude: quake.magnitude).foregroundOnColor)
                .frame(width: 48, height: 40)
                .background(quake.magnitudeColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(quake.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(quake.date.relativeShort) · \(L("depth")) \(quake.depth.depthKmText) · \(quake.sourceTag)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(.snappy) { selectedAftershock = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("common.close"))
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .frame(maxWidth: 520)
        .padding(.horizontal, 12)
    }

    @MainActor
    private func loadAftershocks() async {
        guard !isLoadingAftershocks else { return }
        isLoadingAftershocks = true
        let loaded = await EarthquakeDetailView.loadRelatedAftershocks(for: earthquake)
        aftershocks = loaded
        isLoadingAftershocks = false
    }

    @MainActor
    private func loadNearbyFaults() async {
        isLoadingFaults = true
        await FaultLinesViewModel.shared.load()
        let segments = FaultLinesViewModel.shared.segments
        let center = self.center

        // Bu döngü yüz binlerce fay parçasının sınır dikdörtgenini test edip
        // eşleşenlerin koordinatlarını kopyalıyor. Ana thread'de çalıştığı
        // sürece harita açılırken arayüz donuyordu; sonuç hazır olunca geri
        // dönülür.
        let paths = await Task.detached(priority: .userInitiated) { () -> [DetailFaultPath] in
            let point = MKMapPoint(center)
            let padding = 300_000 * MKMapPointsPerMeterAtLatitude(center.latitude)
            return segments.compactMap { segment in
                guard segment.polyline.boundingMapRect.insetBy(dx: -padding, dy: -padding).contains(point) else { return nil }
                var coordinates = Array(repeating: CLLocationCoordinate2D(), count: segment.polyline.pointCount)
                segment.polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: segment.polyline.pointCount))
                return DetailFaultPath(coordinates: coordinates, risk: segment.risk)
            }
        }.value

        guard !Task.isCancelled else { return }
        faultPaths = paths
        isLoadingFaults = false
    }

    private func mmiColor(_ level: Int) -> Color {
        Color(uiColor: detailMMIColor(level))
    }
}

func detailMMIColor(_ level: Int) -> UIColor {
    switch level {
    case ...2: UIColor(red: 0.19, green: 0.55, blue: 0.91, alpha: 1)
    case 3: UIColor(red: 0.16, green: 0.72, blue: 0.72, alpha: 1)
    case 4: UIColor(red: 0.34, green: 0.72, blue: 0.36, alpha: 1)
    case 5: UIColor(red: 0.95, green: 0.78, blue: 0.16, alpha: 1)
    case 6: UIColor(red: 0.98, green: 0.52, blue: 0.12, alpha: 1)
    case 7: UIColor(red: 0.93, green: 0.30, blue: 0.16, alpha: 1)
    default: UIColor(red: 0.78, green: 0.12, blue: 0.16, alpha: 1)
    }
}

// MARK: - Helper Models & Sheet Views

struct IdentifiableString: Identifiable {
    let id: String
}

/// Değerlendirme kartındaki bir konu başlığının açıklama sayfası.
struct AIQuestionView: View {
    let earthquake: Earthquake
    let question: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var answer: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Konu, sayfanın başlığıdır. Eskiden dolgulu bir kabarcığın
                    // içinde durup altında metin akıyordu; bu düzen ekranı bir
                    // mesajlaşma turu gibi okutuyordu. Şimdi uygulamanın diğer
                    // açıklama sayfaları gibi başlık + ayraç + gövde.
                    Text(question)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    detail
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Metin geldiğinde yüksekliğin sıçramaması için: çark ile gövde
                // arasında yumuşak geçiş.
                .animation(reduceMotion ? nil : SismikDesign.Motion.rowSpring, value: isLoading)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(L("detail.aiAnalysis"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.close")) { dismiss() }
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Color.brandOrange)
                }
            }
            .task {
                let result = await AIService.askQuestion(question, for: earthquake)
                guard !Task.isCancelled else { return }
                answer = result
                isLoading = false
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if isLoading {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(Color.brandOrange)
                Text(L("detail.ai.ask.loading"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        } else if let answer {
            VStack(alignment: .leading, spacing: 14) {
                Text(answer)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)

                // Değerlendirme kartıyla aynı dipnot: metnin neye dayandığı
                // burada da görünür kalır.
                Text(L("detail.aiFooter"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity)
        } else {
            Text(L("detail.ai.unavailable"))
                .font(.subheadline)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }
}

/// Katmanların içeriğini ve sismolojik anlamını açıklayan popover bilgi baloncuğu.
struct LayersInfoBubbleView: View {
    @Environment(\.dismiss) private var dismiss
    private var isTR: Bool { AppLanguage.isTurkish }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    Label(
                        L("detail.layers.info.title"),
                        systemImage: "square.3.layers.3d"
                    )
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)

                    Spacer()
                }
                .padding(.bottom, 2)

                VStack(alignment: .leading, spacing: 12) {
                    layerInfoItem(
                        icon: "waveform.path.ecg",
                        color: .brandOrange,
                        title: L("Sarsıntı (ShakeMap)"),
                        desc: L("Depremin hissedilen sarsıntı şiddeti (MMI) ve etki alanı.")
                    )

                    Divider()

                    layerInfoItem(
                        icon: "point.topleft.down.to.point.bottomright.curvepath",
                        color: .orange,
                        title: L("detail.layers.faults.title"),
                        desc: L("Bölgedeki aktif fay hatları ve jeolojik kırıklar.")
                    )

                    Divider()

                    layerInfoItem(
                        icon: "circle.hexagongrid.fill",
                        color: .red,
                        title: L("aftershocks.title"),
                        desc: L("detailmap.aftershocks.info")
                    )
                }
            }
            .padding(18)
        }
        .frame(maxWidth: 340)
        .frame(maxHeight: 280)
        .presentationCompactAdaptation(.popover)
    }

    private func layerInfoItem(icon: String, color: Color, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)

                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Yüksek Performanslı Donanım Hızlandırmalı Harita Katmanı (Kasma ve Isınmayı Önler)

final class DetailShakeMultiPolyline: MKMultiPolyline {
    var mmi: Int = 0
    var isGlow: Bool = false

    convenience init(mmi: Int, polylines: [MKPolyline], isGlow: Bool) {
        self.init(polylines)
        self.mmi = mmi
        self.isGlow = isGlow
    }
}

final class DetailFaultMultiPolyline: MKMultiPolyline {
    var risk: FaultRisk = .unknown
    var isOutline: Bool = false

    convenience init(risk: FaultRisk, polylines: [MKPolyline], isOutline: Bool) {
        self.init(polylines)
        self.risk = risk
        self.isOutline = isOutline
    }
}

final class DetailEpicenterAnnotation: NSObject, MKAnnotation {
    let earthquake: Earthquake
    let coordinate: CLLocationCoordinate2D
    var title: String? { earthquake.displayTitle }

    init(earthquake: Earthquake) {
        self.earthquake = earthquake
        self.coordinate = earthquake.coordinate.clCoordinate
        super.init()
    }
}

final class DetailEpicenterAnnotationView: MKAnnotationView {
    private let haloView = UIView()
    private let coreView = UIView()
    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        bounds = CGRect(x: 0, y: 0, width: 56, height: 56)
        canShowCallout = false

        haloView.frame = bounds
        haloView.layer.cornerRadius = 28
        addSubview(haloView)

        coreView.frame = CGRect(x: 10, y: 10, width: 36, height: 36)
        coreView.layer.cornerRadius = 18
        coreView.layer.borderWidth = 2
        coreView.layer.borderColor = UIColor.white.cgColor
        addSubview(coreView)

        label.frame = coreView.bounds
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 11, weight: .black)
        coreView.addSubview(label)
    }

    func configure(with earthquake: Earthquake) {
        let color = UIColor(earthquake.magnitudeColor)
        haloView.backgroundColor = color.withAlphaComponent(0.22)
        coreView.backgroundColor = color
        label.text = earthquake.magnitudeString
    }
}

/// Artçı alanı çemberi (artçı katmanı).
final class DetailZoneCircle: MKCircle {}

final class DetailAftershockAnnotation: NSObject, MKAnnotation {
    let earthquake: Earthquake
    let coordinate: CLLocationCoordinate2D
    var title: String? { earthquake.displayTitle }
    var subtitle: String? { earthquake.magnitudeString }

    init(earthquake: Earthquake) {
        self.earthquake = earthquake
        self.coordinate = earthquake.coordinate.clCoordinate
        super.init()
    }
}

final class DetailAftershockAnnotationView: MKAnnotationView {
    private let circleView = UIView()
    private let label = UILabel()
    private let badgeView = UIView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        bounds = CGRect(x: 0, y: 0, width: 36, height: 36)
        canShowCallout = false

        circleView.frame = CGRect(x: 4, y: 4, width: 28, height: 28)
        circleView.layer.cornerRadius = 14
        circleView.layer.borderWidth = 1.5
        circleView.layer.borderColor = UIColor.white.cgColor
        addSubview(circleView)

        label.frame = circleView.bounds
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 9, weight: .black)
        circleView.addSubview(label)

        badgeView.frame = CGRect(x: 22, y: 1, width: 12, height: 12)
        badgeView.backgroundColor = UIColor(Color.brandOrange)
        badgeView.layer.cornerRadius = 6
        badgeView.layer.borderWidth = 1
        badgeView.layer.borderColor = UIColor.white.cgColor
        addSubview(badgeView)
    }

    func configure(with earthquake: Earthquake) {
        let color = UIColor(earthquake.magnitudeColor)
        circleView.backgroundColor = color
        label.text = earthquake.magnitudeString
    }
}

struct EarthquakeDetailMapViewRepresentable: UIViewRepresentable {
    let earthquake: Earthquake
    let initialRegion: MKCoordinateRegion
    let selectedLayer: DetailMapLayer
    let contours: [SeismicImpactData.Contour]?
    let faultPaths: [DetailFaultPath]
    let aftershocks: [Earthquake]
    let userLocation: CLLocation?
    /// Kayıtlı yerler (Premium): simgeleriyle işaretlenir; merkez üssünü
    /// kapsayan yerin dairesi baştan çizilir, diğerleri dokununca açılır.
    var places: [NotificationPlace] = []
    var showsUserLocation = true
    var mapStyle: DetailMapStyle = .standard
    /// Artçı alanı çemberi (yalnızca artçı katmanında ve açıkken).
    var zoneRadiusKm: Double?
    var recenterToken = 0
    var onSelectAftershock: (Earthquake?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = showsUserLocation
        map.showsScale = true
        map.isPitchEnabled = false
        context.coordinator.onSelectAftershock = onSelectAftershock
        context.coordinator.apply(style: mapStyle, on: map)
        map.setRegion(initialRegion, animated: false)
        context.coordinator.lastRecenterToken = recenterToken
        context.coordinator.setup(map: map, earthquake: earthquake, userLocation: userLocation)
        context.coordinator.apply(places: places, epicenter: earthquake.coordinate.clCoordinate, on: map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.update(
            map: map,
            earthquake: earthquake,
            selectedLayer: selectedLayer,
            contours: contours,
            faultPaths: faultPaths,
            aftershocks: aftershocks,
            userLocation: userLocation
        )
        context.coordinator.apply(places: places, epicenter: earthquake.coordinate.clCoordinate, on: map)
        context.coordinator.onSelectAftershock = onSelectAftershock
        if map.showsUserLocation != showsUserLocation { map.showsUserLocation = showsUserLocation }
        context.coordinator.apply(style: mapStyle, on: map)
        context.coordinator.apply(zoneRadiusKm: zoneRadiusKm, center: earthquake.coordinate.clCoordinate, on: map)
        if context.coordinator.lastRecenterToken != recenterToken {
            context.coordinator.lastRecenterToken = recenterToken
            map.setRegion(initialRegion, animated: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var earthquake: Earthquake?
        private var lastLayer: DetailMapLayer?
        private var lastContoursCount: Int = -1
        private var lastFaultsCount: Int = -1
        private var lastAftershocksCount: Int = -1

        private var shakeOverlays: [MKOverlay] = []
        private var faultOverlays: [MKOverlay] = []
        private var aftershockAnnotations: [DetailAftershockAnnotation] = []
        private var epicenterAnnotation: DetailEpicenterAnnotation?
        private var distancePolyline: MKPolyline?
        private var installedPlaceSignature = ""
        /// Dokunulan yerin dairesi (merkez üssünü kapsayanlar kalıcıdır).
        private var selectedPlaceCircle: NotificationPlaceCircle?
        var onSelectAftershock: (Earthquake?) -> Void = { _ in }
        var lastRecenterToken = 0
        private var appliedStyle: DetailMapStyle?
        private var zoneCircle: DetailZoneCircle?

        func apply(style: DetailMapStyle, on map: MKMapView) {
            guard appliedStyle != style else { return }
            appliedStyle = style
            switch style {
            case .standard:
                let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
                configuration.showsTraffic = false
                map.preferredConfiguration = configuration
            case .satellite:
                map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
            case .hybrid:
                let configuration = MKHybridMapConfiguration(elevationStyle: .flat)
                configuration.showsTraffic = false
                map.preferredConfiguration = configuration
            }
        }

        /// Artçı alanı: ana şok merkezli, büyüklüğe göre yarıçaplı kesik çember.
        func apply(zoneRadiusKm: Double?, center: CLLocationCoordinate2D, on map: MKMapView) {
            if let zoneCircle, zoneRadiusKm.map({ abs($0 * 1_000 - zoneCircle.radius) < 1 }) == true { return }
            if let zoneCircle { map.removeOverlay(zoneCircle) }
            zoneCircle = nil
            guard let zoneRadiusKm else { return }
            let circle = DetailZoneCircle(center: center, radius: zoneRadiusKm * 1_000)
            map.addOverlay(circle, level: .aboveRoads)
            zoneCircle = circle
        }

        func apply(places: [NotificationPlace], epicenter: CLLocationCoordinate2D, on map: MKMapView) {
            let signature = places
                .map { "\($0.id):\($0.latitude):\($0.longitude):\($0.radiusKm):\($0.icon.rawValue)" }
                .joined(separator: "|")
            guard signature != installedPlaceSignature else { return }
            installedPlaceSignature = signature
            map.removeAnnotations(map.annotations.compactMap { $0 as? NotificationPlaceAnnotation })
            map.removeOverlays(map.overlays.compactMap { $0 as? NotificationPlaceCircle })
            selectedPlaceCircle = nil
            map.addAnnotations(places.map(NotificationPlaceAnnotation.init))
            let circles = places.filter { $0.covers(epicenter) }.map(NotificationPlaceCircle.init)
            if !circles.isEmpty { map.addOverlays(circles, level: .aboveRoads) }
        }

        func mapView(_ map: MKMapView, didSelect view: MKAnnotationView) {
            if let aftershock = view.annotation as? DetailAftershockAnnotation {
                onSelectAftershock(aftershock.earthquake)
                return
            }
            guard let annotation = view.annotation as? NotificationPlaceAnnotation,
                  let epicenter = epicenterAnnotation?.coordinate,
                  !annotation.place.covers(epicenter) else { return }
            let circle = NotificationPlaceCircle(place: annotation.place)
            map.addOverlay(circle, level: .aboveRoads)
            selectedPlaceCircle = circle
        }

        func mapView(_ map: MKMapView, didDeselect view: MKAnnotationView) {
            if view.annotation is DetailAftershockAnnotation {
                onSelectAftershock(nil)
                return
            }
            guard view.annotation is NotificationPlaceAnnotation, let circle = selectedPlaceCircle else { return }
            map.removeOverlay(circle)
            selectedPlaceCircle = nil
        }

        func setup(map: MKMapView, earthquake: Earthquake, userLocation: CLLocation?) {
            self.earthquake = earthquake
            let epi = DetailEpicenterAnnotation(earthquake: earthquake)
            self.epicenterAnnotation = epi
            map.addAnnotation(epi)

            if let userLocation {
                updateDistanceLine(map: map, epicenter: earthquake.coordinate.clCoordinate, userCoord: userLocation.coordinate)
            }
        }

        func update(
            map: MKMapView,
            earthquake: Earthquake,
            selectedLayer: DetailMapLayer,
            contours: [SeismicImpactData.Contour]?,
            faultPaths: [DetailFaultPath],
            aftershocks: [Earthquake],
            userLocation: CLLocation?
        ) {
            self.earthquake = earthquake

            let layerChanged = lastLayer != selectedLayer
            let contoursChanged = (contours?.count ?? 0) != lastContoursCount
            let faultsChanged = faultPaths.count != lastFaultsCount
            let aftershocksChanged = aftershocks.count != lastAftershocksCount
                || aftershocks.first?.id != aftershockAnnotations.first?.earthquake.id

            lastLayer = selectedLayer
            lastContoursCount = contours?.count ?? 0
            lastFaultsCount = faultPaths.count
            lastAftershocksCount = aftershocks.count

            // ShakeMap katmanı
            if selectedLayer == .shaking {
                if !faultOverlays.isEmpty {
                    map.removeOverlays(faultOverlays)
                    faultOverlays = []
                }
                if !aftershockAnnotations.isEmpty {
                    map.removeAnnotations(aftershockAnnotations)
                    aftershockAnnotations = []
                }
                if (layerChanged || contoursChanged) && (shakeOverlays.isEmpty || contoursChanged) {
                    if !shakeOverlays.isEmpty { map.removeOverlays(shakeOverlays) }
                    shakeOverlays = buildShakeMapOverlays(from: contours)
                    if !shakeOverlays.isEmpty { map.addOverlays(shakeOverlays, level: .aboveRoads) }
                }
            } else if selectedLayer == .faults || selectedLayer == .aftershocks {
                if !shakeOverlays.isEmpty {
                    map.removeOverlays(shakeOverlays)
                    shakeOverlays = []
                }
                if (layerChanged || faultsChanged) && (faultOverlays.isEmpty || faultsChanged) {
                    if !faultOverlays.isEmpty { map.removeOverlays(faultOverlays) }
                    faultOverlays = buildFaultOverlays(from: faultPaths)
                    if !faultOverlays.isEmpty { map.addOverlays(faultOverlays, level: .aboveRoads) }
                }

                if selectedLayer == .aftershocks {
                    if (layerChanged || aftershocksChanged) && (aftershockAnnotations.isEmpty || aftershocksChanged) {
                        if !aftershockAnnotations.isEmpty { map.removeAnnotations(aftershockAnnotations) }
                        aftershockAnnotations = aftershocks.map { DetailAftershockAnnotation(earthquake: $0) }
                        if !aftershockAnnotations.isEmpty { map.addAnnotations(aftershockAnnotations) }
                    }
                } else {
                    if !aftershockAnnotations.isEmpty {
                        map.removeAnnotations(aftershockAnnotations)
                        aftershockAnnotations = []
                    }
                }
            }

            if let userLocation {
                updateDistanceLine(map: map, epicenter: earthquake.coordinate.clCoordinate, userCoord: userLocation.coordinate)
            } else if let existing = distancePolyline {
                map.removeOverlay(existing)
                distancePolyline = nil
            }
        }

        private func updateDistanceLine(map: MKMapView, epicenter: CLLocationCoordinate2D, userCoord: CLLocationCoordinate2D) {
            if let existing = distancePolyline {
                map.removeOverlay(existing)
            }
            var coords = [epicenter, userCoord]
            let poly = MKPolyline(coordinates: &coords, count: 2)
            self.distancePolyline = poly
            map.addOverlay(poly, level: .aboveLabels)
        }

        private func buildShakeMapOverlays(from contours: [SeismicImpactData.Contour]?) -> [MKOverlay] {
            guard let contours, !contours.isEmpty else { return [] }
            var grouped: [Int: [MKPolyline]] = [:]
            for contour in contours {
                let mmi = Int(contour.mmi.rounded())
                for path in contour.paths {
                    guard path.coordinates.count >= 2 else { continue }
                    var coords = path.coordinates
                    let p = MKPolyline(coordinates: &coords, count: coords.count)
                    grouped[mmi, default: []].append(p)
                }
            }

            var overlays: [MKOverlay] = []
            for (mmi, polylines) in grouped.sorted(by: { $0.key < $1.key }) {
                // Alttaki yumuşak parıltı (glow)
                let glow = DetailShakeMultiPolyline(mmi: mmi, polylines: polylines, isGlow: true)
                // Üstteki net çizgi (stroke)
                let stroke = DetailShakeMultiPolyline(mmi: mmi, polylines: polylines, isGlow: false)
                overlays.append(glow)
                overlays.append(stroke)
            }
            return overlays
        }

        private func buildFaultOverlays(from faultPaths: [DetailFaultPath]) -> [MKOverlay] {
            guard !faultPaths.isEmpty else { return [] }
            var grouped: [FaultRisk: [MKPolyline]] = [:]
            for path in faultPaths {
                guard path.coordinates.count >= 2 else { continue }
                var coords = path.coordinates
                let p = MKPolyline(coordinates: &coords, count: coords.count)
                grouped[path.risk, default: []].append(p)
            }

            var overlays: [MKOverlay] = []
            for (risk, polylines) in grouped {
                let outline = DetailFaultMultiPolyline(risk: risk, polylines: polylines, isOutline: true)
                let main = DetailFaultMultiPolyline(risk: risk, polylines: polylines, isOutline: false)
                overlays.append(outline)
                overlays.append(main)
            }
            return overlays
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let shake = overlay as? DetailShakeMultiPolyline {
                let r = MKMultiPolylineRenderer(multiPolyline: shake)
                let tint = detailMMIColor(shake.mmi)
                if shake.isGlow {
                    r.strokeColor = tint.withAlphaComponent(0.30)
                    r.lineWidth = 7.5
                } else {
                    r.strokeColor = tint
                    r.lineWidth = 2.6
                }
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }

            if let fault = overlay as? DetailFaultMultiPolyline {
                let r = MKMultiPolylineRenderer(multiPolyline: fault)
                if fault.isOutline {
                    r.strokeColor = UIColor.black.withAlphaComponent(0.46)
                    r.lineWidth = fault.risk.lineWidth + 2.2
                } else {
                    r.strokeColor = UIColor(fault.risk.color)
                    r.lineWidth = fault.risk.lineWidth + 0.55
                }
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }

            if let circle = overlay as? NotificationPlaceCircle {
                return circle.makeRenderer()
            }

            if let zone = overlay as? DetailZoneCircle {
                let r = MKCircleRenderer(circle: zone)
                r.strokeColor = UIColor.systemPurple.withAlphaComponent(0.75)
                r.fillColor = UIColor.systemPurple.withAlphaComponent(0.06)
                r.lineWidth = 1.5
                r.lineDashPattern = [6, 5]
                return r
            }

            if overlay === distancePolyline {
                let r = MKPolylineRenderer(overlay: overlay)
                r.strokeColor = UIColor.systemBlue.withAlphaComponent(0.65)
                r.lineWidth = 1.5
                r.lineDashPattern = [5, 5]
                return r
            }

            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if let epi = annotation as? DetailEpicenterAnnotation {
                let id = "DetailEpicenterAnnotationView"
                let v = (map.dequeueReusableAnnotationView(withIdentifier: id) as? DetailEpicenterAnnotationView)
                    ?? DetailEpicenterAnnotationView(annotation: epi, reuseIdentifier: id)
                v.configure(with: epi.earthquake)
                return v
            }

            if let place = annotation as? NotificationPlaceAnnotation {
                let id = "DetailPlaceAnnotationView"
                let v = (map.dequeueReusableAnnotationView(withIdentifier: id) as? NotificationPlaceAnnotationView)
                    ?? NotificationPlaceAnnotationView(annotation: place, reuseIdentifier: id)
                v.annotation = place
                v.configure(with: place.place)
                return v
            }

            if let after = annotation as? DetailAftershockAnnotation {
                let id = "DetailAftershockAnnotationView"
                let v = (map.dequeueReusableAnnotationView(withIdentifier: id) as? DetailAftershockAnnotationView)
                    ?? DetailAftershockAnnotationView(annotation: after, reuseIdentifier: id)
                v.configure(with: after.earthquake)
                return v
            }

            return nil
        }
    }
}
