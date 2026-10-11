import SwiftUI
import MapKit
import UIKit

struct MapTrackingRegion: Equatable {
    let center: CLLocationCoordinate2D
    let radiusKm: Double

    static func == (lhs: Self, rhs: Self) -> Bool {
        abs(lhs.center.latitude - rhs.center.latitude) < 0.000_01
            && abs(lhs.center.longitude - rhs.center.longitude) < 0.000_01
            && abs(lhs.radiusKm - rhs.radiusKm) < 0.1
    }
}

struct SavedMapRegion: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    let latitude: Double
    let longitude: Double
    let radiusKm: Double

    var trackingRegion: MapTrackingRegion {
        MapTrackingRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            radiusKm: radiusKm
        )
    }
}

struct MapRegionReportSnapshot: Equatable {
    let isTurkish: Bool
    let dateRange: String
    let coordinate: String
    let radius: Int
    let maximumMagnitude: String
    let playbackDuration: String
    let histogramBins: [Int]
}

@MainActor
@Observable
final class MapRegionPlaybackModel {
    static let trackingRadiusPoints: CGFloat = 110
    /// Çemberi ekran merkezinden yukarı kaydırır — alttaki oynatma paneline
    /// çok yakın durmaması için. Görsel halka (`trackingRing`) ve sorgulanan
    /// gerçek bölgenin merkezi (`EarthquakeMapView.publishTrackingRegion`)
    /// aynı değeri kullanmalı, aksi halde ikisi birbirini tutmaz.
    static let trackingVerticalOffsetPoints: CGFloat = 70
    private static let catalogStartDate = Date(timeIntervalSince1970: -2_208_988_800) // 1900-01-01
    private static let savedRegionsKey = "mapRegionPlayback.savedRegions.v1"
    private static let histogramBucketCount = 32

    /// Oynatma hızı çarpanı. Toplam süre bu değere bölünür; oynatma sürerken
    /// değiştirilirse `EarthquakeMapView` ilerlemeyi mevcut noktadan yeniden
    /// çıpalar, böylece sıçrama olmaz.
    enum PlaybackSpeed: Double, CaseIterable, Identifiable {
        case half = 0.5
        case normal = 1
        case oneAndHalf = 1.5
        case double = 2

        var id: Double { rawValue }

        /// Tek dokunuşla sıradaki hız — menü açıp seçenek seçmeye gerek
        /// kalmadan 0,5× → 1× → 1,5× → 2× → 0,5× diye döner.
        var next: PlaybackSpeed {
            let all = Self.allCases
            let index = all.firstIndex(of: self) ?? 0
            return all[(index + 1) % all.count]
        }

        /// "0,5×" / "0.5×" — ondalık ayırıcı kullanıcının diline göre.
        var label: String {
            let number = rawValue.formatted(
                .number.precision(.fractionLength(0...1))
                    .locale(AppLanguage.currentLocale)
            )
            return "\(number)×"
        }
    }

    private(set) var isEnabled = false
    private(set) var isPlaying = false
    private(set) var isPreparing = false
    var playbackSpeed: PlaybackSpeed = .normal
    private(set) var events: [Earthquake] = []
    private(set) var largestEvent: Earthquake?
    /// Büyüklüğe göre azalan sıralı ilk kayıtlar. Panelde tek bir "en büyük"
    /// yerine liste gösterilir: bir bölgede genellikle birbirine yakın birkaç
    /// büyük sarsıntı olur ve yalnızca en tepedekini göstermek geri kalanını
    /// gizliyordu.
    private(set) var topEvents: [Earthquake] = []
    private(set) var dataRevision = 0
    private(set) var region: MapTrackingRegion?
    private(set) var regionFocusRevision = 0
    private(set) var histogramBins = Array(repeating: 0, count: 32)
    /// Her zaman dilimindeki en büyük deprem — histogram çubuğu tek renk
    /// yerine bu değere göre (MagnitudeLevel) renklendirilir.
    private(set) var histogramMaxMagnitudes = Array(repeating: 0.0, count: 32)
    private(set) var savedRegions: [SavedMapRegion] = []
    private(set) var windowStart: Date
    private(set) var selectableStartDate: Date

    var startDate: Date {
        didSet {
            guard startDate != oldValue else { return }
            normalizeDateRange(changedStart: true)
        }
    }

    var endDate: Date {
        didSet {
            guard endDate != oldValue else { return }
            normalizeDateRange(changedStart: false)
        }
    }

    /// Çemberde gösterilecek en düşük büyüklük eşiği (0 = filtre yok).
    /// Hem yerel önbellek filtresine hem sunucu sorgusuna uygulanır — veri
    /// maliyetini de azaltır.
    var minMagnitude: Double = 0 {
        didSet {
            guard minMagnitude != oldValue else { return }
            isDataStale = true
        }
    }

    var progress = 0.0 {
        didSet {
            guard progress != oldValue else { return }
            progressStorage = progress
            // Oynatma sürerken ilerleme saniyede 15 kez yayınlanır; harita
            // katmanının o akışta yeniden kurulmasına gerek yok. Yalnızca
            // duraklamışken (kaydırıcı/histogram ile atlama, sıfırlama)
            // sayaç artar ve MapKit köprüsü ilerlemeyi yeniden çıpalar.
            if !isPlaying { seekRevision += 1 }
        }
    }

    @ObservationIgnored private var sourceEarthquakes: [Earthquake] = []
    @ObservationIgnored private var rangeLoadTask: Task<Void, Never>?
    @ObservationIgnored private var rangeLoadGeneration = 0
    @ObservationIgnored private var isAdjustingDateRange = false
    @ObservationIgnored private let calendar = Calendar.autoupdatingCurrent
    /// Harita sürüklenirken/tarih ya da filtre değişirken artık otomatik
    /// sorgu atılmaz (her hareket ayrı bir sunucu isteğine dönüşmesin diye);
    /// yalnızca bu bayrak işaretlenir. Gerçek veri çekimi oynatma
    /// başlatıldığında (bkz. `togglePlayback`) tek seferde yapılır.
    @ObservationIgnored private var isDataStale = true
    @ObservationIgnored private var pendingAutoPlay = false

    init(now: Date = Date()) {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        startDate = today
        endDate = today
        windowStart = today
        selectableStartDate = Self.catalogStartDate
        if let data = UserDefaults.standard.data(forKey: Self.savedRegionsKey),
           let decoded = try? JSONDecoder().decode([SavedMapRegion].self, from: data) {
            savedRegions = decoded
        }
    }

    var currentTime: Date {
        windowStart.addingTimeInterval(progress * windowDuration)
    }

    /// Oynatma sırasında saniyede onlarca kez okunur; `.formatted(.dateTime...)`
    /// her çağrıda yeniden desen çözümlemesi yaptığı için burada tekrar
    /// kullanılan bir `DateFormatter` tercih edilir (belirgin ucuz).
    private static let currentTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM HH:mm")
        return formatter
    }()

    var currentTimeText: String {
        let formatter = Self.currentTimeFormatter
        let identifier = AppLanguage.current.localeIdentifier
        if formatter.locale.identifier != identifier {
            formatter.locale = AppLanguage.locale(for: identifier)
            formatter.setLocalizedDateFormatFromTemplate("d MMM HH:mm")
        }
        return formatter.string(from: currentTime)
    }

    /// Seçili tarih aralığı ve çemberde oluşan en büyük deprem — detay
    /// ekranına gidiş için kullanılır. Oynatma panelinin gövdesi saniyede
    /// onlarca kez değerlendiği için hesaplanan değil, `events` yazılırken
    /// bir kez bulunup saklanan bir özelliktir; hesaplanan hâli her karede
    /// binlerce kayıt üzerinde `max` taraması yapıyordu.

    var selectableDateRange: ClosedRange<Date> {
        selectableStartDate...calendar.startOfDay(for: Date())
    }

    var windowDuration: TimeInterval {
        let end = calendar.date(byAdding: .day, value: 1, to: endDate)
            ?? windowStart.addingTimeInterval(86_400)
        return end.timeIntervalSince(windowStart)
    }

    var selectedDayCount: Int {
        max(1, (calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 0) + 1)
    }

    /// Kısa aralıkları gereksiz uzatmadan, geniş tarih aralıklarına ve yoğun
    /// kataloglara daha fazla görsel zaman ayırır. Üst sınır, oynatmanın
    /// kullanışsız ölçüde uzamasını engeller.
    var playbackDuration: TimeInterval {
        let rangeSeconds = 10 + log2(Double(selectedDayCount) + 1) * 4.5
        let densitySeconds = 12 + sqrt(Double(events.count)) * 1.25
        let base = min(120, max(15, rangeSeconds, densitySeconds))
        return base / playbackSpeed.rawValue
    }

    var playbackDurationText: String {
        let seconds = Int(playbackDuration.rounded())
        return AppLanguage.isTurkish ? "\(seconds) saniye" : "\(seconds) seconds"
    }

    var shareReportText: String {
        let radius = Int((region?.radiusKm ?? 0).rounded())
        let maximum = largestEvent?.magnitude
        let maxText = maximum.map { "M \($0.formatted(.number.precision(.fractionLength(1))))" } ?? "—"
        let rangeText = "\(startDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(AppLanguage.currentLocale))) – \(endDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(AppLanguage.currentLocale)))"
        let chart = histogramSparkline
        if AppLanguage.isTurkish {
            return """
            Sismik Bölge Raporu
            \(rangeText) · ≈ \(radius) km yarıçap
            En büyük: \(maxText) · Oynatma: \(playbackDurationText)
            \(chart)
            Kaynaklar: AFAD · EMSC · USGS · NOA
            """
        }
        return """
        Sismik Region Report
        \(rangeText) · ≈ \(radius) km radius
        Largest: \(maxText) · Playback: \(playbackDurationText)
        \(chart)
        Sources: AFAD · EMSC · USGS · NOA
        """
    }

    var shareSnapshot: MapRegionReportSnapshot {
        let maximum = largestEvent?.magnitude
        return MapRegionReportSnapshot(
            isTurkish: AppLanguage.isTurkish,
            dateRange: "\(startDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(AppLanguage.currentLocale))) – \(endDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(AppLanguage.currentLocale)))",
            coordinate: region.map {
                String(format: "%.3f°, %.3f°", $0.center.latitude, $0.center.longitude)
            } ?? "—",
            radius: Int((region?.radiusKm ?? 0).rounded()),
            maximumMagnitude: maximum.map {
                "M \($0.formatted(.number.precision(.fractionLength(1))))"
            } ?? "—",
            playbackDuration: playbackDurationText,
            histogramBins: histogramBins
        )
    }

    /// Harita katmanı oynatma ilerlemesini artık her karede SwiftUI üzerinden
    /// almaz (bkz. `progressSnapshot`); yalnızca bu sayaç değiştiğinde
    /// ilerlemeyi yeniden okuyup çıpalar.
    private(set) var seekRevision = 0

    func seek(to newProgress: Double) {
        pause()
        progress = min(1, max(0, newProgress))
    }

    /// `progress` değerini gözlemleme (`@Observable`) kaydı oluşturmadan okur.
    /// Görünüm gövdesi içinde `model.progress` okumak, saniyede 15 kez gelen
    /// ilerleme yayınında bütün paneli ve MapKit köprüsünü yeniden
    /// kuruyordu; harita katmanı değeri bunun yerine çizim anında çeker.
    @ObservationIgnored private var progressStorage = 0.0

    var progressSnapshot: Double { progressStorage }

    func saveCurrentRegion(named rawName: String) {
        guard let region else { return }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = String(
            format: "%.2f, %.2f",
            region.center.latitude,
            region.center.longitude
        )
        let saved = SavedMapRegion(
            id: UUID(),
            name: trimmed.isEmpty ? fallback : trimmed,
            latitude: region.center.latitude,
            longitude: region.center.longitude,
            radiusKm: region.radiusKm
        )
        savedRegions.append(saved)
        persistSavedRegions()
    }

    func activateSavedRegion(_ savedRegion: SavedMapRegion) {
        guard !isPlaying else { return }
        region = savedRegion.trackingRegion
        regionFocusRevision &+= 1
        isDataStale = true
    }

    func deleteSavedRegion(_ savedRegion: SavedMapRegion) {
        savedRegions.removeAll { $0.id == savedRegion.id }
        persistSavedRegions()
    }

    func toggleTracking() {
        isEnabled.toggle()
        if isEnabled {
            progress = 0
            isDataStale = true
        } else {
            pause()
            rangeLoadTask?.cancel()
            rangeLoadTask = nil
            isPreparing = false
            pendingAutoPlay = false
        }
    }

    func setSourceEarthquakes(_ earthquakes: [Earthquake]) {
        sourceEarthquakes = earthquakes
    }

    /// Harita sürüklenirken artık burada sorgu atılmaz — yalnızca hedef
    /// bölge güncellenip bayatlık işaretlenir. Gerçek veri, oynatma
    /// başlatıldığında tek seferde çekilir; böylece her gezinme sunucuya
    /// ayrı bir istek göndermez.
    func updateRegion(_ newRegion: MapTrackingRegion) {
        guard !isPlaying else { return }
        guard region != newRegion else { return }
        region = newRegion
        isDataStale = true
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            beginPlayback()
        }
    }

    func reset() {
        pause()
        progress = 0
    }

    func updatePlaybackProgress(_ newProgress: Double) {
        guard isPlaying else { return }
        progress = min(1, max(0, newProgress))
    }

    func finishPlayback() {
        progress = 1
        isPlaying = false
    }

    /// Oynatma isteği: veri güncelse hemen başlar, bayatsa (bölge/tarih/filtre
    /// değişmiş veya hiç yüklenmemişse) önce sunucudan çekilir, yükleme
    /// bitince otomatik olarak oynatma başlar.
    private func beginPlayback() {
        guard isEnabled, region != nil, !isPreparing else { return }
        if isDataStale || events.isEmpty {
            pendingAutoPlay = true
            scheduleRangeLoading()
        } else {
            play()
        }
    }

    private func play() {
        guard isEnabled, !isPreparing, !events.isEmpty else { return }
        if progress >= 1 { progress = 0 }
        isPlaying = true
    }

    private func pause() {
        isPlaying = false
    }

    private func scheduleRangeLoading() {
        guard let region else { return }
        pause()
        rangeLoadTask?.cancel()
        rangeLoadGeneration += 1
        let generation = rangeLoadGeneration
        let fallbackSource = sourceEarthquakes
        let minMagnitude = minMagnitude
        let start = calendar.startOfDay(for: startDate)
        let selectedEnd = calendar.startOfDay(for: endDate)
        let endOfSelectedRange = calendar.date(byAdding: .day, value: 1, to: selectedEnd)
            ?? start.addingTimeInterval(86_400)
        let queryEnd = min(endOfSelectedRange, Date())

        isPreparing = true
        windowStart = start
        setEvents([])
        progress = 0
        dataRevision += 1

        rangeLoadTask = Task { @MainActor [weak self] in
            await Task.yield()

            // Disk/bellek harita havuzunu uzak sorguyla paralel süz. Kullanıcı
            // daha önce indirilmiş veriyi hemen görür; veritabanı sonucu
            // geldiğinde aynı ekran sessizce kesin sonuçla yenilenir.
            async let remoteRequest = EarthquakeService.shared.fetchMapRange(
                start: start,
                end: queryEnd,
                latitude: region.center.latitude,
                longitude: region.center.longitude,
                radiusKm: region.radiusKm,
                minMagnitude: minMagnitude
            )
            let localEvents = await Task.detached(priority: .userInitiated) {
                Self.filteredEvents(
                    fallbackSource,
                    start: start,
                    end: queryEnd,
                    region: region,
                    minMagnitude: minMagnitude
                )
            }.value

            guard let self,
                  !Task.isCancelled,
                  self.rangeLoadGeneration == generation else { return }
            if !localEvents.isEmpty {
                self.setEvents(localEvents)
                self.dataRevision += 1
            }

            let remote = await remoteRequest
            guard !Task.isCancelled,
                  self.rangeLoadGeneration == generation else { return }

            if !remote.isEmpty {
                let remoteEvents = await Task.detached(priority: .userInitiated) {
                    Self.filteredEvents(
                        remote,
                        start: start,
                        end: queryEnd,
                        region: region,
                        minMagnitude: minMagnitude
                    )
                }.value
                guard !Task.isCancelled,
                      self.rangeLoadGeneration == generation else { return }

                let changed = self.events.count != remoteEvents.count
                    || zip(self.events, remoteEvents).contains { pair in
                        pair.0.id != pair.1.id
                    }
                if changed {
                    self.setEvents(remoteEvents)
                    self.dataRevision += 1
                }
            }

            self.isPreparing = false
            self.rangeLoadTask = nil
            self.isDataStale = false
            if self.pendingAutoPlay {
                self.pendingAutoPlay = false
                self.play()
            }
        }
    }

    /// Listede gösterilen en fazla kayıt sayısı. Panel bir sayfa değil,
    /// haritanın üstünde duran bir kart — sınırsız liste orayı boğardı.
    static let topEventLimit = 25

    private func setEvents(_ newEvents: [Earthquake]) {
        events = newEvents
        // Tek geçişte sıralanır; `largestEvent` bu listenin ilk öğesidir,
        // ayrıca `max` taraması yapılmaz.
        topEvents = Array(
            newEvents.sorted { $0.magnitude > $1.magnitude }.prefix(Self.topEventLimit)
        )
        largestEvent = topEvents.first
        rebuildHistogram()
    }

    private func rebuildHistogram() {
        var bins = Array(repeating: 0, count: Self.histogramBucketCount)
        var maxMagnitudes = Array(repeating: 0.0, count: Self.histogramBucketCount)
        let duration = max(windowDuration, 1)
        for event in events {
            let fraction = event.date.timeIntervalSince(windowStart) / duration
            let index = min(
                Self.histogramBucketCount - 1,
                max(0, Int(fraction * Double(Self.histogramBucketCount)))
            )
            bins[index] += 1
            maxMagnitudes[index] = max(maxMagnitudes[index], event.magnitude)
        }
        histogramBins = bins
        histogramMaxMagnitudes = maxMagnitudes
    }

    private var histogramSparkline: String {
        let levels = Array("▁▂▃▄▅▆▇█")
        let maximum = max(1, histogramBins.max() ?? 1)
        return histogramBins.map { count in
            let index = min(levels.count - 1, Int((Double(count) / Double(maximum) * Double(levels.count - 1)).rounded()))
            return String(levels[index])
        }.joined()
    }

    private func persistSavedRegions() {
        guard let data = try? JSONEncoder().encode(savedRegions) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedRegionsKey)
    }

    private func normalizeDateRange(changedStart: Bool) {
        guard !isAdjustingDateRange else { return }
        isAdjustingDateRange = true
        defer { isAdjustingDateRange = false }

        let today = calendar.startOfDay(for: Date())
        let normalizedStart = min(today, max(selectableStartDate, calendar.startOfDay(for: startDate)))
        let normalizedEnd = min(today, max(selectableStartDate, calendar.startOfDay(for: endDate)))
        startDate = normalizedStart
        endDate = normalizedEnd
        if startDate > endDate {
            if changedStart { endDate = startDate } else { startDate = endDate }
        }
        // Tarih değişince de otomatik sorgu atılmaz; veri yalnızca oynatma
        // başlatıldığında çekilir (bkz. beginPlayback).
        isDataStale = true
    }

    /// Çember tüm kaynaklardan (AFAD/EMSC/USGS/NOA) yararlanır; aynı fiziksel
    /// olayın birden çok kaynaktan tekrar görünmesi sunucudaki çapraz kaynak
    /// tekilleştirmesiyle (bkz. backend `deduplicateQuakes`) önlenir.
    private nonisolated static func filteredEvents(
        _ earthquakes: [Earthquake],
        start: Date,
        end: Date,
        region: MapTrackingRegion,
        minMagnitude: Double
    ) -> [Earthquake] {
        earthquakes
            .filter { earthquake in
                earthquake.magnitude >= minMagnitude
                    && earthquake.date >= start
                    && earthquake.date < end
                    && distanceKm(
                        from: region.center,
                        to: earthquake.coordinate.clCoordinate
                    ) <= region.radiusKm
            }
            .sorted { lhs, rhs in
                if lhs.date == rhs.date { return lhs.id < rhs.id }
                return lhs.date < rhs.date
            }
    }

    private nonisolated static func distanceKm(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> Double {
        let radians = Double.pi / 180
        let latitudeDelta = (end.latitude - start.latitude) * radians
        let longitudeDelta = (end.longitude - start.longitude) * radians
        let startLatitude = start.latitude * radians
        let endLatitude = end.latitude * radians
        let haversine = pow(sin(latitudeDelta / 2), 2)
            + cos(startLatitude) * cos(endLatitude) * pow(sin(longitudeDelta / 2), 2)
        return 6_371 * 2 * atan2(sqrt(haversine), sqrt(max(0, 1 - haversine)))
    }
}

struct EarthquakeMapPlaybackHost: View {
    let isActive: Bool
    let earthquakes: [Earthquake]
    let dataRevision: Int
    let playbackEarthquakes: [Earthquake]
    let playbackSourceRevision: Int
    let faultOverlays: [RiskMultiPolyline]
    let showFaults: Bool
    let showDensity: Bool
    let focusRequest: MapFocusRequest?
    let notificationPlaces: [NotificationPlace]
    let showNotificationPlaces: Bool
    let onLongPressCoordinate: (CLLocationCoordinate2D) -> Void
    let satellite: Bool
    let recenterToken: Int
    let deselectToken: Int
    let userLocation: CLLocation?
    let playbackModel: MapRegionPlaybackModel
    let onSelect: (Earthquake) -> Void
    let onDeselect: () -> Void

    var body: some View {
        EarthquakeMapView(
            isActive: isActive,
            earthquakes: earthquakes,
            dataRevision: dataRevision,
            faultOverlays: faultOverlays,
            showFaults: showFaults,
            showDensity: showDensity,
            focusRequest: focusRequest,
            notificationPlaces: notificationPlaces,
            showNotificationPlaces: showNotificationPlaces,
            onLongPressCoordinate: onLongPressCoordinate,
            satellite: satellite,
            recenterToken: recenterToken,
            deselectToken: deselectToken,
            userLocation: userLocation,
            trackingEnabled: playbackModel.isEnabled,
            trackingRadiusPoints: Self.trackingRadiusPoints,
            trackingFocusRegion: playbackModel.region,
            trackingFocusRevision: playbackModel.regionFocusRevision,
            playbackEvents: playbackModel.events,
            playbackRevision: playbackModel.dataRevision,
            playbackSeekRevision: playbackModel.seekRevision,
            playbackProgressProvider: { [playbackModel] in playbackModel.progressSnapshot },
            playbackIsPlaying: playbackModel.isPlaying,
            playbackWindowStart: playbackModel.windowStart,
            playbackWindowDuration: playbackModel.windowDuration,
            playbackDuration: playbackModel.playbackDuration,
            onTrackingRegionChange: playbackModel.updateRegion,
            onPlaybackProgress: playbackModel.updatePlaybackProgress,
            onPlaybackEnded: playbackModel.finishPlayback,
            onSelect: onSelect,
            onDeselect: onDeselect
        )
        .onChange(of: playbackSourceRevision, initial: true) {
            playbackModel.setSourceEarthquakes(playbackEarthquakes)
        }
    }

    private static var trackingRadiusPoints: CGFloat {
        MapRegionPlaybackModel.trackingRadiusPoints
    }
}

struct MapRegionPlaybackOverlay: View {
    let model: MapRegionPlaybackModel

    var body: some View {
        // Yalnızca haritanın üzerindeki izleme çemberi. Oynatım paneli
        // (`MapRegionPlaybackControls`) buradan çıkarıldı: alt köşedeki
        // filtre düğmesiyle aynı dikey akışta durması gerekiyor, yoksa panel
        // düğmenin üstüne biniyordu. Panel artık haritayı barındıran
        // görünümün tek alt yığınında yaşıyor.
        //
        // Çember de liste modunda bellekte kalıyordu (yalnızca `opacity` ile
        // gizleniyordu); artık yalnızca izleme açıkken hiyerarşiye giriyor.
        ZStack {
            if model.isEnabled {
                trackingRing
                    // Sistemin kendi büyüyerek-belirme geçişi. Önceki hâlde
                    // özel bir açılış vardı (yayla büyüme + kesikli çizginin
                    // tepeden saat yönünde çizilmesi + dışa sönen radar
                    // halkası); haritanın geri kalanındaki geçişlerden ayrı
                    // bir ritmi olduğu için yabancı duruyordu.
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86),
                   value: model.isEnabled)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trackingRing: some View {
        Circle()
            .fill(Color.brandOrange.opacity(0.07))
            .stroke(Color.brandOrange.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .frame(
                width: MapRegionPlaybackModel.trackingRadiusPoints * 2,
                height: MapRegionPlaybackModel.trackingRadiusPoints * 2
            )
            .offset(y: -MapRegionPlaybackModel.trackingVerticalOffsetPoints)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                L("Bölge izleme çemberi")
            )
    }
}

/// Yalnızca `bins` değiştiğinde yeniden çizilir. Oynatma sırasında `progress`
/// her karede değişse de bu view'ın girdisi sabit kaldığı için SwiftUI
/// Canvas'ı yeniden çalıştırmaz — 32 çubuğu saniyede onlarca kez yeniden
/// çizmek yerine yalnızca ayrı, hafif imleç katmanı hareket eder.
private struct HistogramBars: View {
    let bins: [Int]
    let maxMagnitudes: [Double]

    var body: some View {
        Canvas { context, size in
            let maximum = max(1, bins.max() ?? 1)
            let spacing: CGFloat = 1
            let barWidth = max(1, (size.width - spacing * CGFloat(max(0, bins.count - 1))) / CGFloat(max(1, bins.count)))

            for (index, count) in bins.enumerated() {
                let normalized = CGFloat(count) / CGFloat(maximum)
                let height = max(2, normalized * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * (barWidth + spacing),
                    y: size.height - height,
                    width: barWidth,
                    height: height
                )
                let barColor = count == 0
                    ? Color.primary.opacity(0.12)
                    : MagnitudeLevel(magnitude: maxMagnitudes[index]).color.opacity(0.85)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: min(2, barWidth / 2)),
                    with: .color(barColor)
                )
            }
        }
    }
}

/// Oynatma ilerlemesine bağlı tek yaprak. `progress` yalnızca burada
/// okunduğu için saniyede 15 kez gelen yayın panelin geri kalanını
/// (cam katman, tarih seçiciler, menüler) yeniden kurmaz.
private struct PlaybackTimeline: View {
    @Bindable var model: MapRegionPlaybackModel

    var body: some View {
        VStack(spacing: 2) {
            MapPlaybackHistogram(
                bins: model.histogramBins,
                maxMagnitudes: model.histogramMaxMagnitudes,
                progress: model.progress,
                onSeek: model.seek
            )

            Slider(value: $model.progress, in: 0...1) { isEditing in
                if isEditing, model.isPlaying { model.togglePlayback() }
            }
            .tint(.appAction)
            .disabled(model.events.isEmpty || model.isPreparing)
            .accessibilityLabel(L("Tarih aralığı zaman çizelgesi"))
        }
    }
}

/// Oynatma saati — `currentTimeText` de `progress` türevi olduğu için ayrı
/// yaprakta tutulur.
private struct PlaybackClock: View {
    let model: MapRegionPlaybackModel

    var body: some View {
        Text(model.currentTimeText)
            .font(.caption.weight(.semibold).monospacedDigit())
    }
}

private struct MapPlaybackHistogram: View {
    let bins: [Int]
    let maxMagnitudes: [Double]
    let progress: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                HistogramBars(bins: bins, maxMagnitudes: maxMagnitudes)
                Rectangle()
                    .fill(Color.primary.opacity(0.9))
                    .frame(width: 2)
                    .offset(x: min(proxy.size.width, max(0, CGFloat(progress) * proxy.size.width)) - 1)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard proxy.size.width > 0 else { return }
                        onSeek(value.location.x / proxy.size.width)
                    }
            )
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Deprem yoğunluğu"))
        .accessibilityValue(L("Zaman aralığındaki olay dağılımı"))
    }
}

private struct MapRegionSharePayload: Identifiable {
    let id = UUID()
    let image: UIImage
    let text: String
}

private struct MapRegionShareActivity: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct MapRegionReportCard: View {
    let snapshot: MapRegionReportSnapshot

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)

            VStack(alignment: .leading, spacing: 26) {
                header
                dateSection
                metrics
                histogram
                Spacer(minLength: 0)
                footer
            }
            .padding(42)
        }
        .clipShape(.rect(cornerRadius: 42))
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "waveform.path.ecg.rectangle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(Color.appAction, in: .rect(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 3) {
                Text("Sismik")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(snapshot.isTurkish ? "Bölge Analizi" : "Region Analysis")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.isTurkish ? "SEÇİLİ TARİH ARALIĞI" : "SELECTED DATE RANGE")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.appAction)
            Text(snapshot.dateRange)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            reportMetric(
                title: L("settings.radius"),
                value: "≈ \(snapshot.radius) km",
                symbol: "scope"
            )
            reportMetric(
                title: L("list.sort.largest"),
                value: snapshot.maximumMagnitude,
                symbol: "waveform.path.ecg"
            )
            reportMetric(
                title: snapshot.isTurkish ? "Oynatma" : "Playback",
                value: snapshot.playbackDuration,
                symbol: "play.fill"
            )
        }
    }

    private var histogram: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(snapshot.isTurkish ? "ZAMANSAL YOĞUNLUK" : "TEMPORAL DENSITY")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.appAction)
            MapRegionReportHistogram(bins: snapshot.histogramBins)
                .frame(height: 118)
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 22))
    }

    private var footer: some View {
        HStack {
            Label(snapshot.coordinate, systemImage: "location")
            Spacer()
            Text("AFAD · EMSC · USGS · NOA")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }

    private func reportMetric(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(Color.appAction)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 20))
    }
}

private struct MapRegionReportHistogram: View {
    let bins: [Int]

    var body: some View {
        Canvas { context, size in
            let maximum = max(1, bins.max() ?? 1)
            let spacing: CGFloat = 4
            let width = max(
                2,
                (size.width - spacing * CGFloat(max(0, bins.count - 1)))
                    / CGFloat(max(1, bins.count))
            )
            for (index, count) in bins.enumerated() {
                let fraction = CGFloat(count) / CGFloat(maximum)
                let height = max(4, fraction * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * (width + spacing),
                    y: size.height - height,
                    width: width,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: width / 2),
                    with: .color(Color.appAction.opacity(count == 0 ? 0.15 : 0.9))
                )
            }
        }
        .accessibilityHidden(true)
    }
}

struct MapRegionPlaybackControls: View {
    @Bindable var model: MapRegionPlaybackModel
    var onSelectEvent: (Earthquake) -> Void = { _ in }
    @State private var showSaveRegionPrompt = false
    @State private var showTopEvents = false
    @State private var regionName = ""
    @State private var sharePayload: MapRegionSharePayload?
    private var isTurkish: Bool { AppLanguage.isTurkish }

    private var largestMagnitudeText: String {
        (model.largestEvent?.magnitude ?? 0).formatted(.number.precision(.fractionLength(1)))
    }

    private var largestEventText: String {
        guard model.largestEvent != nil else { return isTurkish ? "En büyük —" : "Largest —" }
        return isTurkish ? "En büyük M \(largestMagnitudeText)" : "Largest M \(largestMagnitudeText)"
    }

    private var countText: String {
        let n = model.events.count.formatted()
        return isTurkish ? "\(n) deprem" : (model.events.count == 1 ? "1 earthquake" : "\(n) earthquakes")
    }

    var body: some View {
        Group {
            if #available(iOS 26, *) {
                GlassEffectContainer(spacing: 12) {
                    controlsContent
                        .padding(13)
                        .glassEffect(.regular, in: .rect(cornerRadius: 24))
                }
                .frame(maxWidth: 440)
                .sensoryFeedback(.selection, trigger: model.isPlaying)
            } else {
                controlsContent
                    .padding(13)
                    .background(.regularMaterial, in: .rect(cornerRadius: 20))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color(.separator).opacity(0.25), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
                    .frame(maxWidth: 440)
                    .sensoryFeedback(.selection, trigger: model.isPlaying)
            }
        }
        .alert(isTurkish ? "Bölgeyi Kaydet" : "Save Region", isPresented: $showSaveRegionPrompt) {
            TextField(isTurkish ? "Bölge adı" : "Region name", text: $regionName)
            Button(isTurkish ? "Kaydet" : "Save") {
                model.saveCurrentRegion(named: regionName)
                regionName = ""
            }
            Button(L("cancel"), role: .cancel) { regionName = "" }
        } message: {
            Text(isTurkish ? "Çemberin mevcut merkezi ve yarıçapı kaydedilir." : "Saves the circle’s current center and radius.")
        }
        .sheet(isPresented: $showTopEvents) {
            MapRegionTopEventsSheet(model: model) { quake in
                showTopEvents = false
                onSelectEvent(quake)
            }
        }
        .sheet(item: $sharePayload) { payload in
            MapRegionShareActivity(items: [payload.image, payload.text])
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var controlsContent: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                datePicker(
                    title: isTurkish ? "Başlangıç" : "From",
                    selection: $model.startDate
                )
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 7)
                    .accessibilityHidden(true)
                datePicker(
                    title: isTurkish ? "Bitiş" : "To",
                    selection: $model.endDate
                )

                Spacer(minLength: 4)

                if model.isPreparing { ProgressView().controlSize(.small) }
            }

            magnitudeFilterRow

            // Özet satırı: kaç deprem ve en büyüğü. Dokununca hepsi büyüklüğe
            // göre sıralı listede açılır — eskiden yalnızca tek bir "en büyük"
            // vardı ve ona dokunmak doğrudan detaya gidiyordu, aradaki diğer
            // büyük sarsıntılara ulaşmanın yolu yoktu.
            //
            // Satır her zaman aynı yükseklikte kalır (yalnızca görünürlüğü
            // değişir) — aksi halde `events` her tarih/bölge değişiminde anlık
            // olarak boşalıp yeniden dolduğunda panel yukarı/aşağı zıplıyordu.
            Button {
                guard !model.topEvents.isEmpty else { return }
                showTopEvents = true
            } label: {
                HStack(spacing: 8) {
                    // Sayı ve büyüklük eşit genişlikli rakamlarla yazılır ve
                    // değişimde yerinde döner: 9 → 10 → 100 olurken satırdaki
                    // hiçbir öğe sağa sola kaymaz.
                    Text(countText)
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())

                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Image(systemName: "arrow.up.right.circle.fill")
                        .font(.caption)
                        .foregroundStyle(model.largestEvent?.level.textColor ?? .clear)
                    Text(largestEventText)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)

                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .animation(.snappy(duration: 0.25), value: model.events.count)
                .animation(.snappy(duration: 0.25), value: model.largestEvent?.magnitude)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(model.topEvents.isEmpty)
            .opacity(model.topEvents.isEmpty ? 0 : 1)
            .accessibilityHidden(model.topEvents.isEmpty)
            .accessibilityLabel(
                isTurkish
                    ? "En büyük deprem detayına git, büyüklük \(largestMagnitudeText)"
                    : "Go to largest earthquake detail, magnitude \(largestMagnitudeText)"
            )

            HStack(spacing: 12) {
                playbackButton

                PlaybackTimeline(model: model)

                resetButton
            }

            HStack {
                PlaybackClock(model: model)
                Spacer()
                playbackSpeedButton
                savedRegionsMenu
                Button(action: prepareShareCard) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appAction)
                        .frame(width: 36, height: 36)
                        .sismikGlassChip(in: Circle(), tint: .appAction, selected: false)
                }
                .accessibilityLabel(isTurkish ? "Bölge raporunu paylaş" : "Share region report")
                Text(
                    isTurkish
                        ? "\(model.selectedDayCount) gün / \(model.playbackDurationText)"
                        : "\(model.selectedDayCount) days / \(model.playbackDurationText)"
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Büyüklük eşiğini menü açmadan tek dokunuşla seçtiren, her seviyeyi
    /// lejanttaki rengiyle gösteren çip sırası — eski menü hem ekstra bir
    /// dokunuş/kapama adımı gerektiriyordu hem de seçenekleri gizliyordu.
    /// Tek satırlık, kaydırma gerektirmeyen native segment kontrolü — önceki
    /// yatay kaydırmalı çip sırası bazı seçenekleri ekran dışında bırakıp
    /// keşfedilmesi gereken bir yapıya dönüşüyordu; bu, tüm seçenekleri tek
    /// bakışta ve tek dokunuşla sunar.
    private var magnitudeFilterRow: some View {
        Picker(isTurkish ? "Büyüklük filtresi" : "Magnitude filter", selection: $model.minMagnitude) {
            Text(isTurkish ? "Tümü" : "All").tag(0.0)
            Text("M2+").tag(2.0)
            Text("M3+").tag(3.0)
            Text("M4+").tag(4.0)
            Text("M5+").tag(5.0)
        }
        .pickerStyle(.segmented)
        .disabled(model.isPreparing)
    }

    private var savedRegionsMenu: some View {
        Menu {
            Button {
                showSaveRegionPrompt = true
            } label: {
                Label(isTurkish ? "Mevcut Bölgeyi Kaydet" : "Save Current Region", systemImage: "bookmark")
            }

            if !model.savedRegions.isEmpty {
                Section(isTurkish ? "Kayıtlı Bölgeler" : "Saved Regions") {
                    ForEach(model.savedRegions) { savedRegion in
                        Button(savedRegion.name, systemImage: "mappin.circle") {
                            model.activateSavedRegion(savedRegion)
                        }
                    }
                }
                Section(isTurkish ? "Kayıt Sil" : "Delete Region") {
                    ForEach(model.savedRegions) { savedRegion in
                        Button(savedRegion.name, systemImage: "trash", role: .destructive) {
                            model.deleteSavedRegion(savedRegion)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: model.savedRegions.isEmpty ? "bookmark" : "bookmark.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(model.savedRegions.isEmpty ? Color.appAction : .white)
                .frame(width: 36, height: 36)
                .sismikGlassChip(in: Circle(), tint: .appAction, selected: !model.savedRegions.isEmpty)
        }
        .disabled(model.region == nil || model.isPlaying)
        .accessibilityLabel(isTurkish ? "Kayıtlı bölgeler" : "Saved regions")
    }

    private func prepareShareCard() {
        let snapshot = model.shareSnapshot
        let renderer = ImageRenderer(
            content: MapRegionReportCard(snapshot: snapshot)
                .frame(width: 540, height: 675)
        )
        renderer.scale = 2
        guard let image = renderer.uiImage else { return }
        sharePayload = MapRegionSharePayload(image: image, text: model.shareReportText)
    }

    private func datePicker(title: String, selection: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            DatePicker(
                title,
                selection: selection,
                in: model.selectableDateRange,
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .tint(.appAction)
            .disabled(model.isPlaying)
        }
        .accessibilityElement(children: .combine)
    }

    /// Oynatma hızı seçici. Oynatma sürerken de değiştirilebilir; süre anında
    /// güncellenir ve ilerleme bulunduğu yerden devam eder.
    /// Menü + seçici yerine tek dokunuşla sıradaki hıza geçen çip: menü her
    /// gövde değerlendirmesinde dört seçenekli bir `Picker` kuruyordu ve hız
    /// değiştirmek iki dokunuş gerektiriyordu.
    private var playbackSpeedButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            model.playbackSpeed = model.playbackSpeed.next
        } label: {
            Text(model.playbackSpeed.label)
                .font(.caption.weight(.bold).monospacedDigit())
                // Seçili çip turuncuyla dolduğu için yazı da turuncu kalırsa
                // görünmez oluyordu (kayıtlı bölgeler çipiyle aynı kural).
                .foregroundStyle(model.playbackSpeed == .normal ? Color.appAction : .white)
                .frame(minWidth: 36, minHeight: 36)
                .sismikGlassChip(in: Capsule(), tint: .appAction, selected: model.playbackSpeed != .normal)
                .contentTransition(.numericText())
        }
        .animation(.easeOut(duration: 0.18), value: model.playbackSpeed)
        .accessibilityLabel(L("playback.speed"))
        .accessibilityValue(model.playbackSpeed.label)
    }

    @ViewBuilder
    private var playbackButton: some View {
        if #available(iOS 26, *) {
            playbackButtonLabel
                .buttonStyle(.glassProminent)
                .tint(.appAction)
        } else {
            playbackButtonLabel
                .buttonStyle(.borderedProminent)
                .tint(.appAction)
        }
    }

    private var playbackButtonLabel: some View {
        Button(action: model.togglePlayback) {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .frame(width: 22, height: 22)
        }
        .buttonBorderShape(.circle)
        // Veri, oynat'a ilk basışta (veya bölge/tarih değiştiğinde) çekilir;
        // bu yüzden `events` boşken de buton etkin kalmalı — aksi halde
        // hiçbir zaman ilk yükleme tetiklenemez.
        .disabled(model.isPreparing)
        .accessibilityLabel(
            model.isPlaying
                ? (isTurkish ? "Oynatmayı durdur" : "Pause playback")
                : (isTurkish ? "Oynat" : "Play")
        )
    }

    @ViewBuilder
    private var resetButton: some View {
        if #available(iOS 26, *) {
            resetButtonLabel
                .buttonStyle(.glass)
                .tint(.appAction)
        } else {
            resetButtonLabel
                .buttonStyle(.bordered)
                .tint(.appAction)
        }
    }

    private var resetButtonLabel: some View {
        Button(action: model.reset) {
            Image(systemName: "backward.end.fill")
                .frame(width: 22, height: 22)
        }
        .buttonBorderShape(.circle)
        .disabled(model.progress == 0)
        .accessibilityLabel(isTurkish ? "Başa dön" : "Restart")
    }
}

struct MapRegionPlaybackToggleButton: View {
    let model: MapRegionPlaybackModel
    private var isTurkish: Bool { AppLanguage.isTurkish }

    var body: some View {
        Button(action: model.toggleTracking) {
            // Saat simgesi: bu düğme bir alanı değil, o alandaki zaman
            // aralığını açıyor — panelde tarih seçiciler ve oynatım var.
            // Önceki `circle.dashed`/`scope` çifti haritadaki çemberi
            // anlatıyordu ama düğmenin ne işe yaradığını anlatmıyordu.
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3.weight(.semibold))
                .foregroundStyle(model.isEnabled ? .white : Color.appAction)
                .frame(width: 48, height: 48)
                .sismikGlassChip(in: Circle(), tint: .appAction, selected: model.isEnabled)
                .shadow(
                    color: model.isEnabled ? Color.appAction.opacity(0.28) : .black.opacity(0.12),
                    radius: 8,
                    y: 3
                )
        }
        // Haritadaki diğer yuvarlak düğmelerle AYNI basma davranışı. Bu düğme
        // tek başına varsayılan buton stilindeydi: yanındaki fay/uydu/konum
        // düğmeleri basınca içeri çöküp titreşim verirken bu hiçbir tepki
        // vermiyordu.
        .buttonStyle(.sismikPressable)
        .accessibilityLabel(
            model.isEnabled
                ? (isTurkish ? "Bölge izlemeyi kapat" : "Disable region tracking")
                : (isTurkish ? "Bölge izlemeyi aç" : "Enable region tracking")
        )
    }
}

// MARK: - Çemberdeki depremler listesi

/// Çemberin içindeki depremleri büyüklüğe göre sıralı gösterir.
///
/// Panelde eskiden yalnızca tek bir "en büyük" satırı vardı ve ona dokunmak
/// doğrudan o depremin detayına gidiyordu; aradaki diğer büyük sarsıntılara
/// ulaşmanın yolu yoktu. Bölgede genellikle birbirine yakın birkaç büyük olay
/// olur ve asıl ilgi çeken de o küme.
private struct MapRegionTopEventsSheet: View {
    let model: MapRegionPlaybackModel
    let onSelect: (Earthquake) -> Void

    @Environment(\.dismiss) private var dismiss
    private var isTurkish: Bool { AppLanguage.isTurkish }

    private var subtitle: String {
        let total = model.events.count
        let shown = model.topEvents.count
        if total <= shown {
            return isTurkish
                ? "Çemberdeki \(total.formatted()) deprem, büyükten küçüğe"
                : "\(total.formatted()) earthquakes in the circle, largest first"
        }
        return isTurkish
            ? "\(total.formatted()) depremin en büyük \(shown.formatted()) tanesi"
            : "Top \(shown.formatted()) of \(total.formatted()) earthquakes"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.topEvents) { quake in
                        Button { onSelect(quake) } label: { row(quake) }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(subtitle)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(isTurkish ? "Bölgedeki Depremler" : "Earthquakes in Region")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.close")) { dismiss() }
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Color.appAction)
                }
            }
            .tint(.appAction)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ quake: Earthquake) -> some View {
        HStack(spacing: 12) {
            // Rozet sabit genişlikte ve eşit genişlikli rakamlarla: satırlar
            // arasında büyüklük hanesi değişse de metin sütunu kaymaz.
            VStack(spacing: 0) {
                Text(quake.magnitudeString)
                    .font(.system(size: 17, weight: .black, design: .rounded).monospacedDigit())
                Text(quake.level.label.uppercased())
                    .font(.system(size: 8, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(quake.level.foregroundOnColor)
            .frame(width: 52, height: 44)
            .background(quake.magnitudeColor, in: .rect(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 3) {
                Text(quake.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(quake.sourceTag)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(quake.sourceColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(quake.sourceColor.opacity(0.12), in: .capsule)
                    Text(quake.depth.depthKmText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(quake.date.formatted(.dateTime.locale(AppLanguage.currentLocale)
                        .day().month(.abbreviated).hour().minute()))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
