import SwiftUI
import MapKit

/// Depremleri tek bir indeksli overlay içinde çizer. Böylece çok sayıda kayıt
/// için binlerce UIView üretilmez; yalnızca görünür harita dilimindeki noktalar
/// işlenir ve her deprem kümelemeden ayrı ayrı gösterilir.
struct EarthquakeMapView: UIViewRepresentable {
    /// Harita katmanı ekranda mı? Liste moduna geçildiğinde katman bellekte
    /// kalır (MKMapView'i yıkıp yeniden kurmak "pop-in" gecikmesi yaratıyor)
    /// fakat uykuya alınır — bkz. `updateUIView`.
    var isActive: Bool
    var earthquakes: [Earthquake]
    var dataRevision: Int
    var faultOverlays: [RiskMultiPolyline]
    var showFaults: Bool
    /// Deprem yoğunluğu (ısı) katmanı: aynı veriden, noktaların altında.
    var showDensity: Bool = false
    /// Programatik odak (ör. büyük olay kartı): kimlik değişince kamera
    /// oraya gider ve deprem seçilir.
    var focusRequest: MapFocusRequest?
    /// Kullanıcının takip ettiği yerler. Haritada yerin simgesiyle görünür;
    /// simgeye dokununca o yerin bildirim alanı (yarıçap dairesi) açılır.
    /// Tüm daireleri aynı anda çizmek, yerler üst üste bindiğinde haritayı
    /// kesikli çizgilerle dolduruyor ve depremleri okumayı zorlaştırıyordu.
    var notificationPlaces: [NotificationPlace]
    var showNotificationPlaces: Bool
    /// Haritaya uzun basıldığında o koordinatla yer ekleme akışını açar.
    var onLongPressCoordinate: ((CLLocationCoordinate2D) -> Void)?
    var satellite: Bool
    var recenterToken: Int
    /// Artınca haritadaki seçim programatik olarak kaldırılır (kart kapatıldı).
    var deselectToken: Int
    var userLocation: CLLocation?
    var trackingEnabled: Bool
    var trackingRadiusPoints: CGFloat
    var trackingFocusRegion: MapTrackingRegion?
    var trackingFocusRevision: Int
    var playbackEvents: [Earthquake]
    var playbackRevision: Int
    /// Oynatma ilerlemesi artık her karede bir görünüm özelliği olarak
    /// akmaz; yalnızca kullanıcı atladığında bu sayaç artar ve güncel değer
    /// sağlayıcıdan çekilir. Aksi hâlde `updateUIView` saniyede 15 kez
    /// baştan çalışıyordu.
    var playbackSeekRevision: Int
    var playbackProgressProvider: () -> Double
    var playbackIsPlaying: Bool
    var playbackWindowStart: Date
    var playbackWindowDuration: TimeInterval
    var playbackDuration: TimeInterval
    var onTrackingRegionChange: (MapTrackingRegion) -> Void
    var onPlaybackProgress: (Double) -> Void
    var onPlaybackEnded: () -> Void
    /// Bir deprem işareti seçildiğinde çağrılır (kart açılır).
    var onSelect: (Earthquake) -> Void
    /// Seçim haritadan kaldırıldığında çağrılır (kart kapanır).
    var onDeselect: () -> Void

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsScale = true
        map.isPitchEnabled = false
        // Sistem görünümünü izle; haritayı zorla koyu ve "muted" gösterme.
        // Böylece standart Apple Haritalar görünümü geri gelir.
        let standardConfiguration = MKStandardMapConfiguration(
            elevationStyle: .flat,
            emphasisStyle: .default
        )
        standardConfiguration.showsTraffic = false
        map.preferredConfiguration = standardConfiguration
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleMapTap(_:)))
        tap.cancelsTouchesInView = false
        map.addGestureRecognizer(tap)
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMapLongPress(_:))
        )
        longPress.minimumPressDuration = 0.45
        map.addGestureRecognizer(longPress)
        context.coordinator.mapView = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coord = context.coordinator
        coord.onSelect = onSelect
        coord.onDeselect = onDeselect
        coord.onTrackingRegionChange = onTrackingRegionChange
        coord.onPlaybackProgress = onPlaybackProgress
        coord.onPlaybackEnded = onPlaybackEnded
        coord.updatePlaybackFrameRate()

        // Liste modundayken harita katmanı görünmüyordu ama ÇALIŞMAYA devam
        // ediyordu: `opacity(0)` yalnızca kompozisyonu etkiler, MKMapView
        // altta karo indirmeyi/çizmeyi, kullanıcı konumunu izlemeyi ve her
        // veri tazelemesinde on binlerce noktayı yeniden eşlemeyi sürdürüyordu.
        // Liste kaydırılırken kaybolan kareler büyük ölçüde buradan geliyordu.
        //
        // `isHidden` gerçek çizim durdurma anahtarıdır; katman hiyerarşide
        // kalır, kamera konumu ve karo önbelleği korunur, geri dönüldüğünde
        // harita anında görünür.
        if !isActive {
            if !map.isHidden {
                map.isHidden = true
                map.showsUserLocation = false
                coord.stopPlaybackDisplayLink()
            }
            // `coord.lastRevision` bilerek güncellenmez: uykudayken biriken
            // veri değişiklikleri harita geri döndüğünde tek seferde eşitlenir.
            return
        }
        if map.isHidden {
            map.isHidden = false
            map.showsUserLocation = true
        }

        let isCurrentlySatellite = map.preferredConfiguration is MKHybridMapConfiguration
        if isCurrentlySatellite != satellite {
            if satellite {
                map.preferredConfiguration = MKHybridMapConfiguration()
            } else {
                let standardConfiguration = MKStandardMapConfiguration(
                    elevationStyle: .flat,
                    emphasisStyle: .default
                )
                standardConfiguration.showsTraffic = false
                map.preferredConfiguration = standardConfiguration
            }
        }

        if coord.lastRevision != dataRevision {
            coord.syncPoints(earthquakes, revision: dataRevision, on: map)
        }
        coord.setDensityVisible(showDensity, on: map)

        if let focusRequest, coord.focusRequestID != focusRequest.id {
            coord.focusRequestID = focusRequest.id
            coord.focus(focusRequest, on: map)
        }

        coord.updateTracking(
            isEnabled: trackingEnabled,
            radiusPoints: trackingRadiusPoints,
            focusRegion: trackingFocusRegion,
            focusRevision: trackingFocusRevision,
            events: playbackEvents,
            revision: playbackRevision,
            progress: playbackProgressProvider(),
            seekRevision: playbackSeekRevision,
            isPlaying: playbackIsPlaying,
            windowStart: playbackWindowStart,
            windowDuration: playbackWindowDuration,
            playbackDuration: playbackDuration,
            on: map
        )

        // Açılış bölgesi: liste moduna geçilip dönüldüğünde son kamera konumu
        // korunur; ilk açılışta kullanıcının konumu, konum yoksa anında Türkiye geneli.
        if !coord.didSetRegion {
            if let saved = Self.savedRegion {
                coord.didSetRegion = true
                coord.didCenterOnUser = true
                map.setRegion(saved, animated: false)
            } else if let loc = userLocation {
                coord.didSetRegion = true
                coord.didCenterOnUser = true
                map.setRegion(MKCoordinateRegion(
                    center: loc.coordinate,
                    latitudinalMeters: 380_000, longitudinalMeters: 380_000), animated: false)
            } else {
                // Konum kapalı/yoksa veri yüklenmesini beklemeden anında tam Türkiye çerçevesi gösterilir.
                coord.didSetRegion = true
                map.setRegion(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 39.0, longitude: 35.2),
                    latitudinalMeters: 1_150_000, longitudinalMeters: 1_700_000), animated: false)
            }
        } else if !coord.didCenterOnUser, let loc = userLocation {
            coord.didCenterOnUser = true
            map.setRegion(MKCoordinateRegion(
                center: loc.coordinate,
                latitudinalMeters: 380_000, longitudinalMeters: 380_000), animated: true)
        }

        // Konuma dön
        if coord.recenterToken != recenterToken {
            coord.recenterToken = recenterToken
            if let loc = map.userLocation.location {
                map.setRegion(MKCoordinateRegion(center: loc.coordinate,
                                                 latitudinalMeters: 120_000,
                                                 longitudinalMeters: 120_000), animated: true)
            }
        }

        // Kart kapatıldı: haritadaki seçimi bırak.
        if coord.deselectToken != deselectToken {
            coord.deselectToken = deselectToken
            coord.clearPointSelection()
        }

        // Fay katmanı (aç/kapa)
        if showFaults, !faultOverlays.isEmpty {
            let desiredFaultIDs = faultOverlays.map(ObjectIdentifier.init)
            if coord.installedFaultOverlayIDs != desiredFaultIDs {
                let existingFaults = map.overlays.compactMap { $0 as? RiskMultiPolyline }
                if !existingFaults.isEmpty { map.removeOverlays(existingFaults) }
                map.addOverlays(faultOverlays, level: .aboveRoads)
                coord.installedFaultOverlayIDs = desiredFaultIDs
            }
        } else if !showFaults, !coord.installedFaultOverlayIDs.isEmpty {
            let existingFaults = map.overlays.compactMap { $0 as? RiskMultiPolyline }
            if !existingFaults.isEmpty { map.removeOverlays(existingFaults) }
            coord.installedFaultOverlayIDs = []
        }

        // Takip edilen yerler katmanı (aç/kapa): her yer simgesiyle bir işaret.
        // Fay katmanıyla aynı desen — imza değişmediyse dokunulmaz.
        coord.onLongPressCoordinate = onLongPressCoordinate
        let desiredPlaces = showNotificationPlaces ? notificationPlaces.filter(\.isActive) : []
        let placeSignature = desiredPlaces
            .map { "\($0.id):\($0.latitude):\($0.longitude):\($0.radiusKm):\($0.icon.rawValue):\($0.name)" }
            .joined(separator: "|")
        if coord.installedPlaceSignature != placeSignature {
            let existing = map.annotations.compactMap { $0 as? NotificationPlaceAnnotation }
            if !existing.isEmpty { map.removeAnnotations(existing) }
            map.addAnnotations(desiredPlaces.map(NotificationPlaceAnnotation.init))
            coord.installedPlaceSignature = placeSignature
            // Açık daire, yeri silinmiş ya da değişmiş olabilir.
            coord.hidePlaceArea(on: map)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ uiView: MKMapView, coordinator: Coordinator) {
        coordinator.stopPlaybackDisplayLink()
        coordinator.cancelPointsSync()
        if let latest = coordinator.latestAnnotation {
            uiView.removeAnnotation(latest)
            coordinator.latestAnnotation = nil
        }
        uiView.delegate = nil
    }

    /// Harita kapatılıp yeniden açıldığında kameranın kaldığı yerden devam
    /// etmesi için son bölge saklanır (delegate ana thread'de çağrılır).
    nonisolated(unsafe) static var savedRegion: MKCoordinateRegion?

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastRevision: Int = -1
        weak var mapView: MKMapView? {
            didSet {
                guard let mapView else {
                    boundsObservation = nil
                    return
                }
                // Bölge izleme çemberi açılırken layout henüz oturmamışsa
                // (bounds sıfırsa) yayın sessizce atlanır; bounds pozitife
                // geçtiğinde bekleyen yayını burada tamamla.
                boundsObservation = mapView.observe(\.bounds, options: [.new]) { [weak self] map, change in
                    guard let self, self.pendingTrackingRegionPublish,
                          let bounds = change.newValue, bounds.width > 0, bounds.height > 0 else { return }
                    self.publishTrackingRegion(for: map)
                }
            }
        }
        private var boundsObservation: NSKeyValueObservation?
        private var pendingTrackingRegionPublish = false
        var pointsOverlay: EarthquakePointsOverlay?
        weak var pointsRenderer: EarthquakePointsRenderer?
        var densityOverlay: EarthquakeDensityOverlay?
        weak var densityRenderer: EarthquakeDensityRenderer?
        var isDensityVisible = false
        var focusRequestID: String?
        var selectedQuakeID: String?
        var latestAnnotation: LatestEarthquakeAnnotation?
        var didSetRegion = false
        var didCenterOnUser = false
        var recenterToken = 0
        var deselectToken = 0
        var onSelect: ((Earthquake) -> Void)?
        var onDeselect: (() -> Void)?
        var onTrackingRegionChange: ((MapTrackingRegion) -> Void)?
        var onPlaybackProgress: ((Double) -> Void)?
        var onPlaybackEnded: (() -> Void)?
        var installedFaultOverlayIDs: [ObjectIdentifier] = []
        var isTrackingEnabled = false
        var isPlaybackRunning = false
        var trackingRadiusPoints: CGFloat = 110
        var trackingFocusRevision = 0
        var lastPlaybackRevision = -1
        var playbackOverlay: EarthquakePlaybackOverlay?
        weak var playbackRenderer: EarthquakePlaybackRenderer?
        var playbackProgress = 0.0
        var playbackWindowStart = Date.distantPast
        var playbackWindowDuration: TimeInterval = 86_400
        var playbackDuration: TimeInterval = 12
        var playbackDisplayLink: CADisplayLink?
        var playbackStartTimestamp: CFTimeInterval = 0
        var playbackStartProgress = 0.0
        var lastSeekRevision = -1
        var lastProgressPublishTimestamp: CFTimeInterval = 0

        override init() {
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAppBackground),
                name: UIApplication.didEnterBackgroundNotification,
                object: nil
            )
            for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handlePerformanceConditionsChanged),
                    name: name,
                    object: nil
                )
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            stopPlaybackDisplayLink()
            pointsSyncTask?.cancel()
        }

        @objc private func handleAppBackground() {
            stopPlaybackDisplayLink()
        }

        func cancelPointsSync() {
            pointsSyncTask?.cancel()
            pointsSyncTask = nil
        }

        private var pointsSyncTask: Task<Void, Never>?

        /// Veri revizyonunda tek overlay'i atomik değiştirir. Kayıtların
        /// dönüştürme/sıralama işi ana thread'i bloklamaması için arka planda
        /// hazırlanır; tile çizimleri zaten tüm diziyi taramaz.
        func syncPoints(_ earthquakes: [Earthquake], revision: Int, on map: MKMapView) {
            lastRevision = revision
            pointsSyncTask?.cancel()
            pointsSyncTask = Task { @MainActor [weak self] in
                let records = await Task.detached(priority: .userInitiated) {
                    EarthquakePointsOverlay.buildSortedRecords(from: earthquakes)
                }.value

                guard let self, !Task.isCancelled, self.lastRevision == revision else { return }

                if let pointsOverlay = self.pointsOverlay { map.removeOverlay(pointsOverlay) }
                let overlay = EarthquakePointsOverlay(sortedRecords: records)
                self.pointsOverlay = overlay
                self.pointsRenderer = nil
                map.addOverlay(overlay, level: .aboveLabels)
                if self.isDensityVisible { self.installDensity(on: map) }

                // En son gerçekleşen deprem için canlı, GPU-hızlandırmalı radar animasyonunu güncelle
                self.updateLatestEarthquakeAnnotation(from: earthquakes, on: map)

                if let selectedQuakeID = self.selectedQuakeID,
                   !earthquakes.contains(where: { $0.id == selectedQuakeID }) {
                    self.selectedQuakeID = nil
                    self.onDeselect?()
                }
            }
        }

        /// Yoğunluk katmanı noktaların sıralı kayıtlarını paylaşır; açıp
        /// kapatmak veriyi yeniden işlemez.
        func setDensityVisible(_ visible: Bool, on map: MKMapView) {
            guard visible != isDensityVisible else { return }
            isDensityVisible = visible
            if visible {
                installDensity(on: map)
            } else if let densityOverlay {
                map.removeOverlay(densityOverlay)
                self.densityOverlay = nil
                densityRenderer = nil
            }
            pointsRenderer?.alpha = isTrackingEnabled ? 0 : (visible ? 0.55 : 1)
        }

        func installDensity(on map: MKMapView) {
            if let densityOverlay { map.removeOverlay(densityOverlay) }
            guard let pointsOverlay else { densityOverlay = nil; return }
            let overlay = EarthquakeDensityOverlay(points: pointsOverlay)
            densityOverlay = overlay
            densityRenderer = nil
            map.addOverlay(overlay, level: .aboveRoads)
        }

        func focus(_ request: MapFocusRequest, on map: MKMapView) {
            let meters = max(40_000, request.radiusKm * 2_000)
            map.setRegion(MKCoordinateRegion(center: request.coordinate,
                                             latitudinalMeters: meters,
                                             longitudinalMeters: meters), animated: true)
            if let quakeID = request.quakeID {
                selectedQuakeID = quakeID
                pointsRenderer?.selectedQuakeID = quakeID
                pointsRenderer?.setNeedsDisplay()
            }
        }

        func updateTracking(
            isEnabled: Bool,
            radiusPoints: CGFloat,
            focusRegion: MapTrackingRegion?,
            focusRevision: Int,
            events: [Earthquake],
            revision: Int,
            progress: Double,
            seekRevision: Int,
            isPlaying: Bool,
            windowStart: Date,
            windowDuration: TimeInterval,
            playbackDuration: TimeInterval,
            on map: MKMapView
        ) {
            let didChangeMode = isTrackingEnabled != isEnabled
            isTrackingEnabled = isEnabled
            isPlaybackRunning = isPlaying
            trackingRadiusPoints = radiusPoints
            pointsRenderer?.alpha = isEnabled ? 0 : (isDensityVisible ? 0.55 : 1)
            densityRenderer?.alpha = isEnabled ? 0 : 1
            map.isScrollEnabled = !isPlaying
            map.isZoomEnabled = !isPlaying
            map.isRotateEnabled = !isPlaying
            self.playbackWindowStart = windowStart
            self.playbackWindowDuration = windowDuration
            // Hız değiştiğinde toplam süre de değişir. Display link ilerlemeyi
            // "başlangıç + geçen süre / toplam süre" ile hesapladığı için, süre
            // oynatma sürerken değişirse ilerleme sıçrar; bu yüzden mevcut
            // ilerlemeden yeniden çıpalıyoruz.
            if self.playbackDuration != playbackDuration, playbackDisplayLink != nil {
                playbackStartProgress = playbackProgress
                playbackStartTimestamp = 0
            }
            self.playbackDuration = playbackDuration

            if trackingFocusRevision != focusRevision, let focusRegion {
                trackingFocusRevision = focusRevision
                let horizontalMeters = focusRegion.radiusKm * 1_000
                    * Double(max(map.bounds.width, radiusPoints * 2) / max(radiusPoints, 1))
                let verticalMeters = focusRegion.radiusKm * 1_000
                    * Double(max(map.bounds.height, radiusPoints * 2) / max(radiusPoints, 1))
                let baseRegion = MKCoordinateRegion(
                    center: focusRegion.center,
                    latitudinalMeters: verticalMeters,
                    longitudinalMeters: horizontalMeters
                )

                // Halka ekran merkezinden yukarı kaydırılmış durumda; hedef
                // koordinat gerçek ekran merkezi yerine halkanın bulunduğu
                // noktada görünsün diye kamerayı bir miktar aşağı düzeltiyoruz.
                if map.bounds.width > 0, map.bounds.height > 0 {
                    map.setRegion(baseRegion, animated: false)
                    let offsetPoint = CGPoint(
                        x: map.bounds.midX,
                        y: map.bounds.midY - MapRegionPlaybackModel.trackingVerticalOffsetPoints
                    )
                    let offsetCoordinate = map.convert(offsetPoint, toCoordinateFrom: map)
                    let correctedCenter = CLLocationCoordinate2D(
                        latitude: 2 * focusRegion.center.latitude - offsetCoordinate.latitude,
                        longitude: 2 * focusRegion.center.longitude - offsetCoordinate.longitude
                    )
                    map.setRegion(
                        MKCoordinateRegion(center: correctedCenter, span: baseRegion.span),
                        animated: true
                    )
                } else {
                    map.setRegion(baseRegion, animated: true)
                }
            }

            guard isEnabled else {
                stopPlaybackDisplayLink()
                if let playbackOverlay { map.removeOverlay(playbackOverlay) }
                playbackOverlay = nil
                playbackRenderer = nil
                lastPlaybackRevision = -1
                return
            }

            if lastPlaybackRevision != revision {
                lastPlaybackRevision = revision
                if let playbackOverlay { map.removeOverlay(playbackOverlay) }
                let overlay = EarthquakePlaybackOverlay(earthquakes: events)
                playbackOverlay = overlay
                playbackRenderer = nil
                map.addOverlay(overlay, level: .aboveLabels)
            }

            if isPlaying {
                startPlaybackDisplayLinkIfNeeded(from: progress)
            } else {
                stopPlaybackDisplayLink()
                // Duraklamışken çizim yalnızca gerçek bir atlama olduğunda
                // yenilenir; `updateUIView` başka nedenlerle de çalışıyor.
                if lastSeekRevision != seekRevision || playbackProgress != progress {
                    lastSeekRevision = seekRevision
                    playbackProgress = progress
                    playbackRenderer?.update(
                        progress: progress,
                        windowStart: windowStart,
                        windowDuration: windowDuration,
                        playbackDuration: playbackDuration
                    )
                }
            }

            if isEnabled, let latest = latestAnnotation {
                map.removeAnnotation(latest)
                latestAnnotation = nil
            }

            if didChangeMode {
                clearPointSelection()
                onDeselect?()
                DispatchQueue.main.async { [weak self, weak map] in
                    guard let self, let map else { return }
                    self.publishTrackingRegion(for: map)
                }
            }
        }

        func updateLatestEarthquakeAnnotation(from earthquakes: [Earthquake], on map: MKMapView) {
            guard !isTrackingEnabled else {
                if let latest = latestAnnotation {
                    map.removeAnnotation(latest)
                    latestAnnotation = nil
                }
                return
            }

            guard let latestQuake = earthquakes.first else {
                if let latest = latestAnnotation {
                    map.removeAnnotation(latest)
                    latestAnnotation = nil
                }
                return
            }

            if let current = latestAnnotation {
                if current.earthquake.id == latestQuake.id {
                    return
                }
                map.removeAnnotation(current)
            }

            let annotation = LatestEarthquakeAnnotation(earthquake: latestQuake)
            latestAnnotation = annotation
            map.addAnnotation(annotation)
        }

        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            EarthquakeMapView.savedRegion = map.region
            if isTrackingEnabled, !isPlaybackRunning {
                publishTrackingRegion(for: map)
            }
        }

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let place = annotation as? NotificationPlaceAnnotation {
                let reuseID = "NotificationPlace"
                let view = (map.dequeueReusableAnnotationView(withIdentifier: reuseID) as? NotificationPlaceAnnotationView)
                    ?? NotificationPlaceAnnotationView(annotation: place, reuseIdentifier: reuseID)
                view.annotation = place
                view.configure(with: place.place)
                return view
            }
            if let latest = annotation as? LatestEarthquakeAnnotation {
                let reuseID = "LatestEarthquakeBeacon"
                let view = (map.dequeueReusableAnnotationView(withIdentifier: reuseID) as? LatestEarthquakeAnnotationView)
                    ?? LatestEarthquakeAnnotationView(annotation: latest, reuseIdentifier: reuseID)
                view.configure(with: latest.earthquake)
                return view
            }
            return nil
        }

        func mapView(_ map: MKMapView, didSelect view: MKAnnotationView) {
            if let place = view.annotation as? NotificationPlaceAnnotation {
                showPlaceArea(place.place, on: map)
                return
            }
            if let latestView = view as? LatestEarthquakeAnnotationView,
               let quake = latestView.earthquake {
                map.deselectAnnotation(latestView.annotation, animated: false)
                selectedQuakeID = quake.id
                pointsRenderer?.selectedQuakeID = quake.id
                pointsRenderer?.setNeedsDisplay()
                onSelect?(quake)
            }
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let points = overlay as? EarthquakePointsOverlay {
                let renderer = EarthquakePointsRenderer(overlay: points)
                renderer.selectedQuakeID = selectedQuakeID
                renderer.alpha = isTrackingEnabled ? 0 : (isDensityVisible ? 0.55 : 1)
                pointsRenderer = renderer
                return renderer
            }

            if let density = overlay as? EarthquakeDensityOverlay {
                let renderer = EarthquakeDensityRenderer(overlay: density)
                renderer.alpha = isTrackingEnabled ? 0 : 1
                densityRenderer = renderer
                return renderer
            }

            if let playback = overlay as? EarthquakePlaybackOverlay {
                let renderer = EarthquakePlaybackRenderer(overlay: playback)
                renderer.update(
                    progress: playbackProgress,
                    windowStart: playbackWindowStart,
                    windowDuration: playbackWindowDuration,
                    playbackDuration: playbackDuration
                )
                playbackRenderer = renderer
                return renderer
            }

            if let circle = overlay as? NotificationPlaceCircle {
                return circle.makeRenderer()
            }

            if let multi = overlay as? RiskMultiPolyline {
                let r = MKMultiPolylineRenderer(multiPolyline: multi)
                // Faylar hem standart hem uydu zeminde kesintisiz ve net
                // okunmalı; tam opak renk ve hafif kalınlaştırılmış hat kullan.
                r.strokeColor = UIColor(multi.risk.color).withAlphaComponent(multi.risk == .unknown ? 0.82 : 1)
                r.lineWidth = multi.risk.lineWidth + 0.65
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        var installedPlaceSignature = ""

        func mapView(_ map: MKMapView, didDeselect view: MKAnnotationView) {
            if view.annotation is NotificationPlaceAnnotation { hidePlaceArea(on: map) }
        }

        /// Seçilen yerin bildirim alanını çizer ve daireyi ekrana sığdırır.
        func showPlaceArea(_ place: NotificationPlace, on map: MKMapView) {
            hidePlaceArea(on: map)
            let circle = NotificationPlaceCircle(place: place)
            map.addOverlay(circle, level: .aboveRoads)
            UISelectionFeedbackGenerator().selectionChanged()
            map.setVisibleMapRect(
                circle.boundingMapRect,
                edgePadding: UIEdgeInsets(top: 90, left: 40, bottom: 160, right: 40),
                animated: true
            )
        }

        func hidePlaceArea(on map: MKMapView) {
            let circles = map.overlays.compactMap { $0 as? NotificationPlaceCircle }
            if !circles.isEmpty { map.removeOverlays(circles) }
        }
        var onLongPressCoordinate: ((CLLocationCoordinate2D) -> Void)?

        @objc func handleMapLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  let map = mapView,
                  let handler = onLongPressCoordinate,
                  !isTrackingEnabled else { return }
            let point = recognizer.location(in: map)
            let coordinate = map.convert(point, toCoordinateFrom: map)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            handler(coordinate)
        }

        @objc func handleMapTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let map = mapView,
                  let overlay = pointsOverlay,
                  !isTrackingEnabled else { return }

            let location = recognizer.location(in: map)
            // Yer simgesine dokunuş MapKit'in seçimine aittir; altındaki
            // depremi de seçip kartı açmasın.
            var hit = map.hitTest(location, with: nil)
            while let view = hit {
                if view is NotificationPlaceAnnotationView { return }
                hit = view.superview
            }
            let hitRadius: CGFloat = 30
            let corners = [
                CGPoint(x: location.x - hitRadius, y: location.y - hitRadius),
                CGPoint(x: location.x + hitRadius, y: location.y + hitRadius)
            ].map { MKMapPoint(map.convert($0, toCoordinateFrom: map)) }
            let searchRect = MKMapRect(
                x: min(corners[0].x, corners[1].x),
                y: min(corners[0].y, corners[1].y),
                width: abs(corners[1].x - corners[0].x),
                height: abs(corners[1].y - corners[0].y)
            )

            let nearest = overlay.records(in: searchRect)
                .compactMap { record -> (EarthquakePointRecord, CGFloat)? in
                    let point = map.convert(record.mapPoint.coordinate, toPointTo: map)
                    let distance = hypot(point.x - location.x, point.y - location.y)
                    return distance <= hitRadius ? (record, distance) : nil
                }
                .sorted(by: {
                    if abs($0.1 - $1.1) < 12 {
                        return $0.0.earthquake.magnitude > $1.0.earthquake.magnitude
                    }
                    return $0.1 < $1.1
                })
                .first?.0

            guard let nearest else {
                if selectedQuakeID != nil {
                    selectedQuakeID = nil
                    pointsRenderer?.selectedQuakeID = nil
                    pointsRenderer?.setNeedsDisplay()
                    onDeselect?()
                }
                return
            }

            selectedQuakeID = nearest.earthquake.id
            pointsRenderer?.selectedQuakeID = nearest.earthquake.id
            pointsRenderer?.setNeedsDisplay()
            onSelect?(nearest.earthquake)
        }

        func clearPointSelection() {
            guard selectedQuakeID != nil else { return }
            self.selectedQuakeID = nil
            pointsRenderer?.selectedQuakeID = nil
            pointsRenderer?.setNeedsDisplay()
        }

        private func publishTrackingRegion(for map: MKMapView) {
            guard map.bounds.width > 0, map.bounds.height > 0 else {
                pendingTrackingRegionPublish = true
                return
            }
            pendingTrackingRegionPublish = false
            // Görsel halka ekran merkezinden yukarı kaydırılmış durumda
            // (bkz. trackingRing); sorgulanan gerçek bölgenin merkezi de aynı
            // ofseti kullanmalı ki ikisi eşleşsin.
            let centerPoint = CGPoint(
                x: map.bounds.midX,
                y: map.bounds.midY - MapRegionPlaybackModel.trackingVerticalOffsetPoints
            )
            let edgePoint = CGPoint(x: centerPoint.x + trackingRadiusPoints, y: centerPoint.y)
            let center = map.convert(centerPoint, toCoordinateFrom: map)
            let edge = map.convert(edgePoint, toCoordinateFrom: map)
            let radiusKm = CLLocation(latitude: center.latitude, longitude: center.longitude)
                .distance(from: CLLocation(latitude: edge.latitude, longitude: edge.longitude)) / 1_000
            onTrackingRegionChange?(.init(center: center, radiusKm: radiusKm))
        }

        private func startPlaybackDisplayLinkIfNeeded(from progress: Double) {
            guard playbackDisplayLink == nil else { return }
            playbackStartProgress = progress
            playbackProgress = progress
            playbackStartTimestamp = 0
            lastProgressPublishTimestamp = 0

            let displayLink = CADisplayLink(
                target: self,
                selector: #selector(handlePlaybackFrame(_:))
            )
            displayLink.add(to: .main, forMode: .common)
            playbackDisplayLink = displayLink
            updatePlaybackFrameRate()
        }

        @objc private func handlePerformanceConditionsChanged() {
            DispatchQueue.main.async { [weak self] in
                self?.updatePlaybackFrameRate()
            }
        }

        /// Request ProMotion only for the active playback clock. iOS remains
        /// free to choose a lower rate; static screens do not run a display link.
        func updatePlaybackFrameRate() {
            guard let displayLink = playbackDisplayLink else { return }
            let screenMaximum = Float(mapView?.window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
            let process = ProcessInfo.processInfo
            let constrained = process.isLowPowerModeEnabled
                || process.thermalState == .serious || process.thermalState == .critical
            let maximum = min(screenMaximum, constrained ? 60 : 120)
            let range = CAFrameRateRange(minimum: min(30, maximum), maximum: maximum, preferred: maximum)
            let current = displayLink.preferredFrameRateRange
            guard current.minimum != range.minimum || current.maximum != range.maximum
                    || current.preferred != range.preferred else { return }
            displayLink.preferredFrameRateRange = range
        }

        func stopPlaybackDisplayLink() {
            playbackDisplayLink?.invalidate()
            playbackDisplayLink = nil
            playbackStartTimestamp = 0
        }

        @objc private func handlePlaybackFrame(_ displayLink: CADisplayLink) {
            if playbackStartTimestamp == 0 {
                playbackStartTimestamp = displayLink.timestamp
            }

            let elapsed = displayLink.timestamp - playbackStartTimestamp
            let progress = min(
                1,
                playbackStartProgress + elapsed / max(playbackDuration, 0.001)
            )
            playbackProgress = progress
            playbackRenderer?.update(
                progress: progress,
                windowStart: playbackWindowStart,
                windowDuration: playbackWindowDuration,
                playbackDuration: playbackDuration
            )

            if progress >= 1 {
                onPlaybackProgress?(1)
                stopPlaybackDisplayLink()
                onPlaybackEnded?()
            } else if displayLink.timestamp - lastProgressPublishTimestamp >= 1.0 / 15.0 {
                lastProgressPublishTimestamp = displayLink.timestamp
                onPlaybackProgress?(progress)
            }
        }
    }
}

// MARK: - Son Deprem Animasyonlu Radar İşareti (GPU Hızlandırmalı)

final class LatestEarthquakeAnnotation: NSObject, MKAnnotation {
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

final class LatestEarthquakeAnnotationView: MKAnnotationView {
    /// Merkez noktanın yarıçapı. Çember tam bu kenardan doğar.
    private static let coreRadius: CGFloat = 14
    /// Görünümün kenar uzunluğu — açılmış dalgayı kırpmadan barındırır.
    private static let viewSide: CGFloat = 88
    /// "SON" rozetinin merkezden yukarı kaydırılma miktarı.
    private static let badgeCenterOffset: CGFloat = 21.5
    /// Dalganın söndüğü yarıçap oranı (14 → ~38pt).
    private static let pulseMaxScale: CGFloat = 2.7
    private static let pulseLineWidth: CGFloat = 2.4
    private static let pulseDuration: CFTimeInterval = 2.4
    /// Çember büyüklük rengini değil, her zaman aynı uyarı kırmızısını kullanır:
    /// "son deprem" işaretini büyüklük paletinden ayıran tek sinyal budur.
    private static let pulseColor = UIColor(Color.brandRed)

    private let radarPulseLayer1 = CAShapeLayer()
    private let radarPulseLayer2 = CAShapeLayer()
    private let coreDotView = UIView()
    private let magnitudeLabel = UILabel()
    private let badgeLabel = UILabel()
    private(set) var earthquake: Earthquake?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setupView()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setupView()
    }

    /// Noktanın kenarından doğan çember, verilen çerçevenin tam merkezinde.
    private static func ringPath(in rect: CGRect) -> CGPath {
        UIBezierPath(
            arcCenter: CGPoint(x: rect.midX, y: rect.midY),
            radius: coreRadius,
            startAngle: 0,
            endAngle: .pi * 2,
            clockwise: true
        ).cgPath
    }

    /// MapKit görünümü yeniden boyutlandırdığında katman çerçeveleri geride
    /// kalmasın: çapa noktası kaydığı anda dalga yine merkezden çıkmaz.
    /// Sonsuz animasyonlar örtük katman animasyonundan etkilenmesin diye
    /// güncelleme işlem bloğuna alınır.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard radarPulseLayer1.frame != bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for pulse in [radarPulseLayer1, radarPulseLayer2] {
            pulse.frame = bounds
            pulse.path = Self.ringPath(in: bounds)
        }
        coreDotView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        badgeLabel.center = CGPoint(x: bounds.midX, y: bounds.midY - Self.badgeCenterOffset)
        CATransaction.commit()
    }

    private func setupView() {
        // Çerçeve, tümüyle açılmış dalgayı (yarıçap 14 × 2.7 ≈ 38) çizgi
        // kalınlığıyla birlikte içine alacak kadar geniştir; dalga kenarda
        // kırpılmaz.
        bounds = CGRect(x: 0, y: 0, width: Self.viewSide, height: Self.viewSide)
        canShowCallout = false
        displayPriority = .required
        collisionMode = .none

        let centerPoint = CGPoint(x: bounds.midX, y: bounds.midY)

        for pulse in [radarPulseLayer1, radarPulseLayer2] {
            // KRİTİK: katmana çerçeve verilmezse `bounds` sıfır kalır ve
            // `transform.scale` görünümün SOL ÜST köşesi etrafında ölçekler.
            // Dalga o zaman merkezden değil köşeden doğup çapraz kayıyordu.
            // Çerçeve görünümle eşitlenince çapa noktası tam merkeze oturur.
            pulse.frame = bounds
            pulse.path = Self.ringPath(in: bounds)
            pulse.fillColor = UIColor.clear.cgColor
            pulse.strokeColor = Self.pulseColor.cgColor
            pulse.lineWidth = Self.pulseLineWidth
            pulse.opacity = 0
            layer.addSublayer(pulse)
        }

        // Merkez nokta
        coreDotView.frame = CGRect(x: centerPoint.x - 14, y: centerPoint.y - 14, width: 28, height: 28)
        coreDotView.layer.cornerRadius = 14
        coreDotView.layer.borderWidth = 2.2
        coreDotView.layer.borderColor = UIColor.white.cgColor
        coreDotView.layer.shadowColor = UIColor.black.cgColor
        coreDotView.layer.shadowOpacity = 0.45
        coreDotView.layer.shadowOffset = CGSize(width: 0, height: 2)
        coreDotView.layer.shadowRadius = 4
        coreDotView.layer.shadowPath = UIBezierPath(ovalIn: coreDotView.bounds).cgPath
        addSubview(coreDotView)

        // Büyüklük yazısı
        magnitudeLabel.frame = coreDotView.bounds
        magnitudeLabel.textAlignment = .center
        magnitudeLabel.font = .systemFont(ofSize: 10, weight: .black)
        magnitudeLabel.textColor = .white
        coreDotView.addSubview(magnitudeLabel)

        // "SON" etiketi (Üstte şık bir hap rozet)
        badgeLabel.bounds = CGRect(x: 0, y: 0, width: 44, height: 13)
        badgeLabel.center = CGPoint(x: centerPoint.x, y: centerPoint.y - Self.badgeCenterOffset)
        badgeLabel.backgroundColor = UIColor(white: 0.12, alpha: 0.88)
        badgeLabel.layer.cornerRadius = 6.5
        badgeLabel.layer.masksToBounds = true
        badgeLabel.textAlignment = .center
        badgeLabel.textColor = .white
        badgeLabel.font = .systemFont(ofSize: 8, weight: .heavy)
        // Rozet uygulamanın dilinde ("SON", "LATEST"…); uzun karşılıklar sığar.
        badgeLabel.text = L("map.latest.badge")
        badgeLabel.adjustsFontSizeToFitWidth = true
        badgeLabel.minimumScaleFactor = 0.6
        addSubview(badgeLabel)
    }

    func configure(with earthquake: Earthquake) {
        self.earthquake = earthquake
        // Nokta büyüklük rengini korur; yayılan çember sabit kırmızıdır.
        coreDotView.backgroundColor = UIColor(earthquake.magnitudeColor)
        magnitudeLabel.text = earthquake.magnitudeString

        startRadarAnimation()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        earthquake = nil
        stopRadarAnimation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopRadarAnimation()
        } else if earthquake != nil {
            startRadarAnimation()
        }
    }

    private func stopRadarAnimation() {
        radarPulseLayer1.removeAllAnimations()
        radarPulseLayer2.removeAllAnimations()
    }

    /// Merkez nokta hiç hareket etmez — büyüyüp küçülen "nefes" animasyonu,
    /// işareti haritada şişip sönen bir leke gibi gösteriyordu. Tek hareket
    /// noktanın çevresinden doğup dağılarak sönen kırmızı çemberdir:
    /// dışa doğru genişlerken çizgisi incelir ve tümüyle kaybolur.
    private func startRadarAnimation() {
        guard window != nil else { return }
        // Son deprem güncellendiğinde sonsuz animasyonlar baştan kurulmaz;
        // geometri değişmiyor, yalnızca noktanın rengi/yazısı güncelleniyor.
        guard radarPulseLayer1.animation(forKey: "radarPulse1") == nil else { return }

        radarPulseLayer1.add(pulseAnimation(delay: 0), forKey: "radarPulse1")
        // İkinci dalga yarım periyot gecikmeli: çemberler kesintisiz bir
        // radar ritmi kurar, aralarında boşluk kalmaz.
        radarPulseLayer2.add(
            pulseAnimation(delay: Self.pulseDuration / 2),
            forKey: "radarPulse2"
        )
    }

    private func pulseAnimation(delay: CFTimeInterval) -> CAAnimationGroup {
        let easeOut = CAMediaTimingFunction(name: .easeOut)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = Self.pulseMaxScale
        scale.timingFunction = easeOut

        // Çizgi genişlerken incelir: dalga "dağılıyor" hissi verir, kalın bir
        // halka olarak birden yok olmaz.
        let width = CABasicAnimation(keyPath: "lineWidth")
        width.fromValue = Self.pulseLineWidth
        width.toValue = Self.pulseLineWidth * 0.3
        width.timingFunction = easeOut

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.9
        opacity.toValue = 0.0
        opacity.timingFunction = easeOut

        let group = CAAnimationGroup()
        group.animations = [scale, width, opacity]
        group.duration = Self.pulseDuration
        group.beginTime = delay > 0 ? CACurrentMediaTime() + delay : 0
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        return group
    }
}

// MARK: - Yüksek performanslı deprem katmanı

struct EarthquakePointRecord {
    let earthquake: Earthquake
    let mapPoint: MKMapPoint
    let level: MagnitudeLevel
    /// Çizim döngüleri `earthquake` alanına hiç dokunmasın diye önceden
    /// hesaplanır. Her erişim `Earthquake`'in on kadar `String` alanını ARC
    /// ile tutuyordu; kare başına yüzlerce noktada ölçülebilir maliyetti.
    let date: Date
    let markerRadius: CGFloat
    /// Yoğunluk katmanındaki ağırlık: büyük deprem küçükten daha çok iz
    /// bırakır; enerjiye göre ağırlık tek bir M7'yi her şeyin üstüne
    /// taşırdı, doğrusal yeter.
    let densityWeight: Float

    init(earthquake: Earthquake, mapPoint: MKMapPoint, level: MagnitudeLevel) {
        self.earthquake = earthquake
        self.mapPoint = mapPoint
        self.level = level
        self.date = earthquake.date
        self.markerRadius = Self.markerRadius(for: earthquake.magnitude)
        self.densityWeight = 1 + Float(max(0, earthquake.magnitude - 2.5))
    }

    private static func markerRadius(for magnitude: Double) -> CGFloat {
        switch magnitude {
        case 7.0...:  23
        case 6.0..<7: 20
        case 5.0..<6: 17
        case 4.0..<5: 15
        case 3.0..<4: 13.5
        default:      12
        }
    }
}

/// Çizim döngülerinde kullanılan önceden üretilmiş renkler. `UIColor(Color)`
/// köprülemesi nokta başına yapılıyordu; renkler sabit olduğu için bir kez
/// üretilip saklanır.
private enum MarkerPalette {
    /// `MagnitudeLevel.allCases` sırasıyla.
    static let fills: [CGColor] = MagnitudeLevel.allCases.map { UIColor($0.color).cgColor }
    static let outline = UIColor.white.withAlphaComponent(0.92).cgColor
    static let white = UIColor.white.cgColor
    static let black = UIColor.black.cgColor

    static func fill(_ level: MagnitudeLevel) -> CGColor {
        fills[level.sortIndex]
    }
}

final class EarthquakePointsOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    private let sortedRecords: [EarthquakePointRecord]

    init(sortedRecords: [EarthquakePointRecord]) {
        self.sortedRecords = sortedRecords
        super.init()
    }

    /// `sortedRecords`'un ağır dönüştürme/sıralama işi; ana thread'i
    /// bloklamamak için çağıran taraf bunu arka planda çalıştırır.
    static func buildSortedRecords(from earthquakes: [Earthquake]) -> [EarthquakePointRecord] {
        earthquakes.map {
            EarthquakePointRecord(
                earthquake: $0,
                mapPoint: MKMapPoint($0.coordinate.clCoordinate),
                level: MagnitudeLevel(magnitude: $0.magnitude)
            )
        }.sorted { $0.mapPoint.x < $1.mapPoint.x }
    }

    /// Çizim döngüsünün indeksle dolaşabilmesi için kayıtlara doğrudan erişim.
    var records: [EarthquakePointRecord] { sortedRecords }

    /// X ekseninde ikili arama ile aday indeks aralığı. Y elemesi çağıran
    /// tarafta yapılır; böylece tile başına yeni bir dizi tahsis edilmez.
    func horizontalRange(in rect: MKMapRect) -> Range<Int> {
        var low = 0
        var high = sortedRecords.count
        while low < high {
            let mid = (low + high) / 2
            if sortedRecords[mid].mapPoint.x < rect.minX { low = mid + 1 } else { high = mid }
        }
        let start = low
        high = sortedRecords.count
        while low < high {
            let mid = (low + high) / 2
            if sortedRecords[mid].mapPoint.x <= rect.maxX { low = mid + 1 } else { high = mid }
        }
        return start..<low
    }

    /// X ekseninde ikili arama, ardından Y filtresi: bir tile çiziminde yalnızca
    /// o tile'a düşebilecek kayıtlar dolaşılır. (Dokunma isabet testi için;
    /// çizim yolu `horizontalRange` kullanır.)
    func records(in rect: MKMapRect) -> ArraySlice<EarthquakePointRecord> {
        var low = 0
        var high = sortedRecords.count
        while low < high {
            let mid = (low + high) / 2
            if sortedRecords[mid].mapPoint.x < rect.minX { low = mid + 1 } else { high = mid }
        }
        let start = low
        high = sortedRecords.count
        while low < high {
            let mid = (low + high) / 2
            if sortedRecords[mid].mapPoint.x <= rect.maxX { low = mid + 1 } else { high = mid }
        }
        return sortedRecords[start..<low].filter { rect.minY <= $0.mapPoint.y && $0.mapPoint.y <= rect.maxY }[...]
    }
}

final class EarthquakePointsRenderer: MKOverlayRenderer {
    var selectedQuakeID: String?

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? EarthquakePointsOverlay else { return }
        let unit = 1 / max(zoomScale, .leastNonzeroMagnitude)
        let expanded = mapRect.insetBy(dx: -40 * unit, dy: -40 * unit)
        let candidates = overlay.horizontalRange(in: expanded)
        guard !candidates.isEmpty else { return }
        let records = overlay.records

        // Yakınlaştırma ve uzaklaştırma dengesi:
        // Ülke ve dünya ölçeğinde (düşük zoomScale) noktalar ve kenarlıklar zarifçe küçülür (~5-9pt),
        // yakınlaştıkça (il/ilçe ölçeğinde) tam dokunma boyutuna (12-20pt) genişler.
        let zoomFactor = max(0.48, min(1.0, zoomScale / 0.00010))
        let lineWidth = max(1.0, 2.0 * zoomFactor) * unit

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setStrokeColor(MarkerPalette.outline)
        context.setLineWidth(lineWidth)

        var selectedIndex: Int?
        let hasSelection = selectedQuakeID != nil

        // Tek geçişte adayları seviyelerine göre grupla (5 ayrı candidate taraması yerine tek O(N) geçiş)
        //
        // `draw` her karo için ve kaydırma/yakınlaştırma boyunca her karede
        // çağrılıyor. Kapasite ayrılmazsa dünya ölçeğinde on binlerce `append`
        // dizileri defalarca büyütüp yeniden tahsis ediyor — kaydırma sırasında
        // ölçülebilir bir maliyet.
        let levelCount = MagnitudeLevel.allCases.count
        var buckets: [[Int]] = Array(repeating: [], count: levelCount)
        let expectedPerBucket = max(8, candidates.count / 4)
        for index in buckets.indices { buckets[index].reserveCapacity(expectedPerBucket) }
        for index in candidates {
            let mapPoint = records[index].mapPoint
            guard expanded.minY <= mapPoint.y, mapPoint.y <= expanded.maxY else { continue }
            if hasSelection, records[index].earthquake.id == selectedQuakeID {
                selectedIndex = index
                continue
            }
            let levelIdx = min(levelCount - 1, max(0, records[index].level.sortIndex))
            buckets[levelIdx].append(index)
        }

        // Ekstrem uzaklaşmada (zoomFactor < 0.65) mikro depremlerde piksel aşırı çizimini önleme ızgarası
        // Izgara yalnızca uzak ölçekte gerekiyor; yakın ölçekte her karo için
        // aday sayısı kadar yer ayırmak boşa tahsisti.
        var drawnGrid = Set<Int64>()
        if zoomFactor < 0.65 { drawnGrid.reserveCapacity(buckets[0].count) }
        let gridResolution: Double = 14.0 * Double(unit) // ~14 screen points

        for levelIndex in 0..<levelCount {
            let level = MagnitudeLevel.allCases[levelIndex]
            context.setFillColor(MarkerPalette.fill(level))
            let bucket = buckets[levelIndex]

            for index in bucket {
                let mapPoint = records[index].mapPoint

                // Uzaklaştırmada küçük depremlerin üst üste binip GPU/CPU'yu boğmasını önle
                if zoomFactor < 0.65 && levelIndex == 0 {
                    let cellX = Int64(floor(mapPoint.x / gridResolution))
                    let cellY = Int64(floor(mapPoint.y / gridResolution))
                    let cellKey = (cellX &* 73856093) ^ (cellY &* 19349663)
                    if drawnGrid.contains(cellKey) { continue }
                    drawnGrid.insert(cellKey)
                }

                let center = point(for: mapPoint)
                let radius = records[index].markerRadius * zoomFactor * unit
                let dotRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

                context.fillEllipse(in: dotRect)
                context.strokeEllipse(in: dotRect)
            }
        }

        // Seçili deprem en üst katmanda, dış aurasıyla birlikte gösterilir
        if let selectedIndex {
            let selected = records[selectedIndex]
            let center = point(for: selected.mapPoint)
            let baseRadius = selected.markerRadius * zoomFactor * unit
            let selectedRadius = baseRadius + 2.5 * unit

            // Dış saydam halka / aura (Deprem detayındaki ana deprem gösterimi)
            let haloRadius = selectedRadius + 11.0 * unit
            let haloRect = CGRect(x: center.x - haloRadius, y: center.y - haloRadius, width: haloRadius * 2, height: haloRadius * 2)
            context.saveGState()
            let selectedFill = MarkerPalette.fill(selected.level)
            context.setFillColor(selectedFill.copy(alpha: 0.24) ?? selectedFill)
            context.fillEllipse(in: haloRect)
            context.restoreGState()

            let selectedDotRect = CGRect(x: center.x - selectedRadius, y: center.y - selectedRadius, width: selectedRadius * 2, height: selectedRadius * 2)
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: 1.5 * unit),
                blur: 5.0 * unit,
                color: UIColor.black.withAlphaComponent(0.50).cgColor
            )
            context.setFillColor(selectedFill)
            context.fillEllipse(in: selectedDotRect)
            context.restoreGState()

            // Belirgin beyaz kenarlık
            context.saveGState()
            context.setStrokeColor(UIColor.white.cgColor)
            context.setLineWidth(2.5 * unit)
            context.strokeEllipse(in: selectedDotRect)
            context.restoreGState()
        }

        context.restoreGState()
    }

}

// MARK: - Deprem yoğunluğu (ısı) katmanı

/// Haritada programatik odak isteği.
struct MapFocusRequest: Equatable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let radiusKm: Double
    var quakeID: String?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Noktalar katmanının x'e göre sıralı kayıtlarını paylaşır: ek dönüştürme
/// ya da sıralama yok.
final class EarthquakeDensityOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    let points: EarthquakePointsOverlay

    init(points: EarthquakePointsOverlay) {
        self.points = points
        super.init()
    }
}

/// Depremleri ekranda ~28 pt'lik küresel bir ızgarada toplayıp her hücreye
/// yumuşak bir leke çizer. Izgara dünya koordinatına sabit olduğu için
/// komşu karolar aynı hücreyi aynı ağırlıkla çizer, dikiş oluşmaz. Renk
/// ölçeği uygulamanınkiyle aynı: yeşil → turuncu → kırmızı.
final class EarthquakeDensityRenderer: MKOverlayRenderer {
    private static let cellPoints: Double = 28
    /// Ölçeğin doygunluk noktası (hücre ağırlığı). Karo başına normalleştirme
    /// yapılmaz; yapılsaydı komşu karolar farklı tonda boyanırdı.
    private static let saturation: Float = 14
    private static let gradients: [CGGradient] = {
        let space = CGColorSpaceCreateDeviceRGB()
        return [MagnitudeLevel.light, .moderate, .major].compactMap { level in
            let color = UIColor(level.color)
            return CGGradient(colorsSpace: space,
                              colors: [color.withAlphaComponent(0.62).cgColor,
                                       color.withAlphaComponent(0.28).cgColor,
                                       color.withAlphaComponent(0).cgColor] as CFArray,
                              locations: [0, 0.55, 1])
        }
    }()

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? EarthquakeDensityOverlay,
              Self.gradients.count == 3 else { return }
        let cell = Self.cellPoints / Double(max(zoomScale, .leastNonzeroMagnitude))
        let expanded = mapRect.insetBy(dx: -cell * 1.5, dy: -cell * 1.5)
        let range = overlay.points.horizontalRange(in: expanded)
        guard !range.isEmpty else { return }
        let records = overlay.points.records

        let minColumn = Int(floor(expanded.minX / cell))
        let minRow = Int(floor(expanded.minY / cell))
        let columns = Int(ceil(expanded.maxX / cell)) - minColumn + 1
        let rows = Int(ceil(expanded.maxY / cell)) - minRow + 1
        guard columns > 0, rows > 0, columns * rows < 4_096 else { return }
        var weights = [Float](repeating: 0, count: columns * rows)
        for index in range {
            let point = records[index].mapPoint
            guard expanded.minY <= point.y, point.y <= expanded.maxY else { continue }
            let column = Int(floor(point.x / cell)) - minColumn
            let row = Int(floor(point.y / cell)) - minRow
            guard column >= 0, column < columns, row >= 0, row < rows else { continue }
            weights[row * columns + column] += records[index].densityWeight
        }

        let radius = CGFloat(cell) * 1.25
        for row in 0..<rows {
            for column in 0..<columns {
                let weight = weights[row * columns + column]
                guard weight > 0 else { continue }
                let t = min(1, log1p(weight) / log1p(Self.saturation))
                let gradient = Self.gradients[t < 0.45 ? 0 : (t < 0.8 ? 1 : 2)]
                let center = point(for: MKMapPoint(
                    x: (Double(column + minColumn) + 0.5) * cell,
                    y: (Double(row + minRow) + 0.5) * cell
                ))
                context.saveGState()
                context.setAlpha(CGFloat(0.35 + 0.65 * t))
                context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                           endCenter: center, endRadius: radius, options: [])
                context.restoreGState()
            }
        }
    }
}

// MARK: - Bölge izleme zaman katmanı

/// Yalnızca izleme çemberinde seçilen güne ait kayıtları kronolojik tutar.
/// Normal harita indeksinden ayrıdır; playback ilerlerken ana overlay yeniden
/// kurulmaz, renderer yalnızca görünür prefix'i boyar.
final class EarthquakePlaybackOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    let records: [EarthquakePointRecord]
    let largestRecordIndex: Int?

    init(earthquakes: [Earthquake]) {
        let sortedRecords = earthquakes
            .map {
                EarthquakePointRecord(
                    earthquake: $0,
                    mapPoint: MKMapPoint($0.coordinate.clCoordinate),
                    level: MagnitudeLevel(magnitude: $0.magnitude)
                )
            }
            .sorted { $0.earthquake.date < $1.earthquake.date }
        records = sortedRecords
        if let maximumMagnitude = sortedRecords.lazy.map(\.earthquake.magnitude).max() {
            largestRecordIndex = sortedRecords.firstIndex {
                $0.earthquake.magnitude == maximumMagnitude
            }
        } else {
            largestRecordIndex = nil
        }
        super.init()
    }
}

final class EarthquakePlaybackRenderer: MKOverlayRenderer {
    /// Noktalar kısa süreli iz bırakır; görünür kayıt sayısı ayrıca sınırlandığı
    /// için uzun tarih aralıklarında dahi çizim maliyeti sabit kalır.
    private static let markerLifetime: TimeInterval = 1.15
    private static let maximumVisibleTrailMarkers = 180

    private var visibleRange = 0..<0
    private var currentTime = Date.distantPast
    private var transientWindow: TimeInterval = 1
    private var lastZoomScale: MKZoomScale = 1
    private var activeLargestRecordIndex: Int?

    func update(
        progress: Double,
        windowStart: Date,
        windowDuration: TimeInterval,
        playbackDuration: TimeInterval
    ) {
        guard let overlay = overlay as? EarthquakePlaybackOverlay else { return }
        let currentTime = windowStart.addingTimeInterval(progress * windowDuration)
        let transientWindow = max(
            1,
            windowDuration * Self.markerLifetime / max(playbackDuration, 0.001)
        )
        let upperBound = recordIndex(at: currentTime, in: overlay.records)
        let lowerBound = recordIndex(
            at: currentTime.addingTimeInterval(-transientWindow),
            in: overlay.records
        )
        let newVisibleRange = lowerBound..<upperBound
        let newLargestRecordIndex = overlay.largestRecordIndex.flatMap {
            $0 < upperBound ? $0 : nil
        }
        guard visibleRange != newVisibleRange
                || activeLargestRecordIndex != newLargestRecordIndex
                || self.currentTime != currentTime else { return }

        let oldVisibleRange = visibleRange
        let oldLargestRecordIndex = activeLargestRecordIndex
        visibleRange = newVisibleRange
        activeLargestRecordIndex = newLargestRecordIndex
        self.currentTime = currentTime
        self.transientWindow = transientWindow

        var dirtyRect = dirtyMapRect(
            oldRange: oldVisibleRange,
            newRange: newVisibleRange,
            in: overlay.records
        )
        dirtyRect = dirtyRectIncludingPersistentMarker(
            dirtyRect,
            indexes: oldLargestRecordIndex == newLargestRecordIndex
                ? []
                : [oldLargestRecordIndex, newLargestRecordIndex],
            records: overlay.records
        )
        if let dirtyRect {
            setNeedsDisplay(dirtyRect)
        }
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? EarthquakePlaybackOverlay else { return }
        lastZoomScale = zoomScale
        let lowerBound = max(0, min(visibleRange.lowerBound, overlay.records.count))
        let upperBound = max(lowerBound, min(visibleRange.upperBound, overlay.records.count))
        let unit = 1 / max(zoomScale, .leastNonzeroMagnitude)
        let expandedRect = mapRect.insetBy(dx: -44 * unit, dy: -44 * unit)
        let records = overlay.records
        let persistentIndex = activeLargestRecordIndex.flatMap {
            records.indices.contains($0) ? $0 : nil
        }
        // İz penceresi en fazla `maximumVisibleTrailMarkers` kadar geriye
        // bakar. Eskiden bu, `suffix` + `filter` ile kare başına yeni bir
        // dizi üretiyordu; her kopya `Earthquake`'in referans alanlarını ARC
        // ile tuttuğu için 60 Hz'lik döngüde en pahalı adımdı. Artık aralık
        // indeksle dolaşılır: tahsis yok, kopya yok.
        let trailStart = max(lowerBound, upperBound - Self.maximumVisibleTrailMarkers)
        let hasVisiblePersistent = persistentIndex.map {
            expandedRect.contains(records[$0].mapPoint)
        } ?? false
        guard trailStart < upperBound || hasVisiblePersistent else { return }

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        if trailStart < upperBound {
            for index in trailStart..<upperBound where index != persistentIndex {
                guard expandedRect.contains(records[index].mapPoint) else { continue }
                drawMarker(at: index, in: records, unit: unit, in: context)
            }
        }
        if hasVisiblePersistent, let persistentIndex {
            drawMarker(at: persistentIndex, in: records, unit: unit, persistent: true, in: context)
        }

        context.restoreGState()
    }

    private func drawMarker(
        at index: Int,
        in records: [EarthquakePointRecord],
        unit: CGFloat,
        persistent: Bool = false,
        in context: CGContext
    ) {
        let level = records[index].level
        let ageFraction = persistent
            ? 0
            : min(1, max(0, currentTime.timeIntervalSince(records[index].date) / transientWindow))
        let scale: CGFloat
        if persistent {
            scale = 1.15
        } else if ageFraction < 0.18 {
            scale = 0.7 + CGFloat(ageFraction / 0.18) * 0.5
        } else {
            scale = 1.2 - CGFloat((ageFraction - 0.18) / 0.82) * 0.35
        }
        let alpha = CGFloat(pow(1 - ageFraction, 0.72))
        let center = point(for: records[index].mapPoint)
        let radius = level.playbackMarkerRadius * scale * unit
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let contrastRadius = radius + 2 * unit
        let contrastRect = CGRect(
            x: center.x - contrastRadius,
            y: center.y - contrastRadius,
            width: contrastRadius * 2,
            height: contrastRadius * 2
        )
        context.saveGState()
        context.setAlpha(alpha * 0.32)
        context.setFillColor(MarkerPalette.black)
        context.fillEllipse(in: contrastRect)
        context.restoreGState()

        // Gölge yerine az önce çizilen siyah kontrast halkası derinlik hissi
        // veriyor; saniyede 120 kareye, kareye 180 markere kadar çalışan bu
        // döngüde ayrı bir bulanıklaştırma geçişinden kaçınmak CPU/GPU
        // yükünü belirgin azaltır.
        context.saveGState()
        context.setAlpha(max(0.14, alpha))
        context.setFillColor(MarkerPalette.fill(level))
        context.fillEllipse(in: rect)
        context.restoreGState()

        context.saveGState()
        context.setAlpha(max(0.38, alpha * 0.96))
        context.setStrokeColor(MarkerPalette.white)
        context.setLineWidth((persistent ? 2.6 : 2.0) * unit)
        context.strokeEllipse(in: rect)
        context.restoreGState()
    }

    private func dirtyRectIncludingPersistentMarker(
        _ existingRect: MKMapRect?,
        indexes: [Int?],
        records: [EarthquakePointRecord]
    ) -> MKMapRect? {
        guard !indexes.isEmpty else { return existingRect }
        var dirtyRect = existingRect ?? .null
        for index in indexes.compactMap({ $0 }) where records.indices.contains(index) {
            let point = records[index].mapPoint
            dirtyRect = dirtyRect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        guard !dirtyRect.isNull else { return nil }
        let padding = 52 / max(lastZoomScale, .leastNonzeroMagnitude)
        return dirtyRect.insetBy(dx: -padding, dy: -padding)
    }

    private func recordIndex(
        at date: Date,
        in records: [EarthquakePointRecord]
    ) -> Int {
        var lowerBound = 0
        var upperBound = records.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if records[middle].date <= date {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    /// 60–120 Hz akışta tüm dünya overlay'ini yeniden çizmek yerine yalnızca
    /// yeni nokta ve aktif halkanın kapsadığı küçük harita alanını kirletir.
    private func dirtyMapRect(
        oldRange: Range<Int>,
        newRange: Range<Int>,
        in records: [EarthquakePointRecord]
    ) -> MKMapRect? {
        guard !records.isEmpty else { return nil }
        // Invalidate exactly the old and new rendered trails. A seek can
        // jump over thousands of records that were never drawn in this frame.
        var dirtyRect = MKMapRect.null
        for range in [oldRange, newRange] {
            let end = min(records.count, range.upperBound)
            let start = max(0, range.lowerBound, end - Self.maximumVisibleTrailMarkers)
            guard start < end else { continue }
            for index in start..<end {
                let point = records[index].mapPoint
                dirtyRect = dirtyRect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
            }
        }
        guard !dirtyRect.isNull else { return nil }
        let padding = 48 / max(lastZoomScale, .leastNonzeroMagnitude)
        return dirtyRect.insetBy(dx: -padding, dy: -padding)
    }

}

/// Risk seviyesini taşıyan MKMultiPolyline. Geometry and risk are finalized in
/// the background load task before the overlay reaches MapKit on the main actor.
/// Takip edilen yerin harita işareti: yerin kendi simgesi.
final class NotificationPlaceAnnotation: NSObject, MKAnnotation {
    let place: NotificationPlace
    var coordinate: CLLocationCoordinate2D { place.coordinate }
    var title: String? { place.name }
    /// Balonda kuralın tamamı: "100 km · M3.0+".
    var subtitle: String? {
        "\(Int(place.radiusKm.rounded())) km · M\(String(format: "%.1f", place.minMagnitude))+"
    }

    init(_ place: NotificationPlace) {
        self.place = place
        super.init()
    }
}

/// Yer simgesi rozeti; ayarlar listesindeki `PlaceIconBadge` ile aynı çizim,
/// haritada okunabilsin diye beyaz kenar ve hafif gölgeyle.
final class NotificationPlaceAnnotationView: MKAnnotationView {
    private static let side: CGFloat = 32

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = true
        // Deprem noktalarının ÜSTÜNDE kalır ama birbirini gizlemez: sekiz
        // yerden biri kaybolursa kullanıcı yerini silinmiş sanıyordu.
        displayPriority = .required
        collisionMode = .circle
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1.5)
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    func configure(with place: NotificationPlace) {
        let side = Self.side
        let (r, g, b) = place.icon.rgb
        image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            let outer = UIBezierPath(roundedRect: rect, cornerRadius: side * 0.3)
            UIColor.white.setFill()
            outer.fill()
            let inner = UIBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: side * 0.26)
            UIColor(red: r, green: g, blue: b, alpha: 1).setFill()
            inner.fill()
            let config = UIImage.SymbolConfiguration(pointSize: side * 0.44, weight: .semibold)
            if let symbol = UIImage(systemName: place.icon.symbolName, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                let size = symbol.size
                symbol.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                       width: size.width, height: size.height))
            }
        }
        accessibilityLabel = place.name
    }
}

/// Takip edilen bir yerin harita üzerindeki yarıçap dairesi; yalnızca yer
/// işaretine dokunulduğunda çizilir.
final class NotificationPlaceCircle: MKCircle, @unchecked Sendable {
    private(set) var tint: UIColor = .systemOrange

    convenience init(place: NotificationPlace) {
        self.init(center: place.coordinate, radius: place.radiusKm * 1000)
        let (r, g, b) = place.icon.rgb
        tint = UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// Ana harita ve deprem detayı haritaları aynı çizimi kullanır.
    func makeRenderer() -> MKCircleRenderer {
        let renderer = MKCircleRenderer(circle: self)
        renderer.fillColor = tint.withAlphaComponent(0.10)
        renderer.strokeColor = tint.withAlphaComponent(0.85)
        renderer.lineWidth = 1.8
        // Kesikli çizgi: yer sınırı bir VERİ değil kullanıcı tercihi;
        // fay hatlarının düz çizgisinden görsel olarak ayrılmalı.
        renderer.lineDashPattern = [6, 4]
        return renderer
    }
}

extension NotificationPlace {
    /// Deprem merkez üssü bu yerin bildirim yarıçapının içinde mi? Detay
    /// haritası o yerin dairesini çizer: bildirimin neden geldiği görünür.
    func covers(_ coordinate: CLLocationCoordinate2D) -> Bool {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            <= radiusKm * 1000
    }
}

final class RiskMultiPolyline: MKMultiPolyline, @unchecked Sendable {
    var risk: FaultRisk = .unknown
}
