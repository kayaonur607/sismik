import SwiftUI
import MapKit
import CoreLocation

/// Deprem detayının harita, olay özeti ve ShakeMap durumunu tek invalidation
/// sınırında tutar. Detay ekranındaki AI/topluluk state değişimleri haritayı
/// yeniden kurmaz.
struct EarthquakeMapHeaderCard: View {
    let earthquake: Earthquake
    let contours: [SeismicImpactData.Contour]?
    /// `contours` gerçek USGS ShakeMap ürünü mü yoksa model tabanlı tahmin mi
    /// olduğunu ayırt eder. Tahmin modeli boş bırakmadığı için dizinin
    /// dolu/boş olması bu ayrımı YAPAMAZ — çağıran taraf açıkça bildirir.
    let isEstimated: Bool
    let sourceIntensity: SeismicIntensityDescriptor?
    let intensitySourceTag: String
    let isPremium: Bool
    let isLoading: Bool
    /// Kartın herhangi bir yerine dokunulduğunda tam ekran katman haritasını
    /// açar (premium değilse paywall gösterir — karar çağıran tarafta verilir).
    let onTapMap: () -> Void

    /// Kartın tamamı bir düğme gibi davranır; basılı tutulduğu sürece hafifçe
    /// küçülüp soluklaşarak dokunuşun algılandığını gösterir.
    @State private var isPressed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Kameranın açılışta ne kadar geniş başladığı.
    ///
    /// 5× denendi ve geri alındı: o kadar geniş bir başlangıç bir-iki harita
    /// yakınlaşma kademesi birden atlıyor, MapKit önce düşük çözünürlüklü
    /// karoları gösterip sonra keskin olanlara geçiyordu. Kameranın kayması
    /// ile karoların değişmesi üst üste binince hareket akıcı bir yakınlaşma
    /// değil, bir sıçrama gibi görünüyordu. 1.9× aynı kademede kalır:
    /// yakınlaşma fark edilir ama görüntü hiç zıplamaz.
    private static let entryZoomOutFactor: Double = 1.9

    init(
        earthquake: Earthquake,
        contours: [SeismicImpactData.Contour]?,
        isEstimated: Bool,
        sourceIntensity: SeismicIntensityDescriptor?,
        intensitySourceTag: String,
        isPremium: Bool,
        isLoading: Bool,
        onTapMap: @escaping () -> Void
    ) {
        self.earthquake = earthquake
        self.contours = contours
        self.isEstimated = isEstimated
        self.sourceIntensity = sourceIntensity
        self.intensitySourceTag = intensitySourceTag
        self.isPremium = isPremium
        self.isLoading = isLoading
        self.onTapMap = onTapMap
    }

    /// Merkez üssünü ve (varsa) ShakeMap konturlarını kapsayan bölge.
    /// `zoomOutFactor` 1'den büyükse aynı merkezle daha geniş bir çerçeve verir.
    private static func region(
        for earthquake: Earthquake,
        contours: [SeismicImpactData.Contour]?,
        zoomOutFactor: Double = 1
    ) -> MKCoordinateRegion {
        let center = earthquake.coordinate.clCoordinate
        // ShakeMap konturu yoksa çerçeve büyüklükten türetilir. Sabit 1.8°
        // (~200 km) her deprem için aynı uzak görünümü veriyordu; M2.4'lük
        // yerel bir sarsıntı ülke ölçeğinde bir haritanın ortasında minik bir
        // nokta olarak kalıyordu. Etkinin hissedildiği yarıçap büyüklükle
        // büyüdüğü için çerçeve de onunla ölçeklenir.
        var span = Self.defaultSpan(for: earthquake.magnitude)
        if let contours {
            // Kartın kendisi her gövde değerlendirmesinde yeniden kurulduğu
            // için bu tarama sık çalışır: `flatMap` zinciri her seferinde iki
            // büyük ara dizi ayırıyordu. Tek geçişli döngü hiçbir şey ayırmaz.
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
        }
        // Önce hedef çerçeve sınırlanır, sonra açılış çarpanı uygulanır ve
        // sonuç yeniden sınırlanır: M7+ bir deprem 14° × 5 = 70°'lik kıtasal
        // bir görünümden başlamasın.
        let target = min(14, max(0.22, span))
        let delta = min(26, target * zoomOutFactor)
        let cosine = max(0.2, cos(center.latitude * .pi / 180))
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta / cosine)
        )
    }

    /// Merkez üssünün çevresinde gösterilecek derece cinsinden çerçeve.
    /// Küçük depremler mahalle/ilçe ölçeğinde, büyükler bölge ölçeğinde açılır.
    private static func defaultSpan(for magnitude: Double) -> Double {
        switch magnitude {
        case ..<3:    0.30   // ~33 km
        case 3..<4:   0.55
        case 4..<5:   0.95
        case 5..<6:   1.60
        case 6..<7:   2.60
        default:      4.00
        }
    }

    private var isTurkish: Bool { AppLanguage.isTurkish }
    private var hasRealShakeMap: Bool { !isEstimated && contours?.isEmpty == false }
    /// Doğrulanmış ürün ile tahmin arasındaki ayrımın rengi. Uygulamanın
    /// başka yerlerinde de aynı anlamı taşıyorlar: yeşil = doğrulanmış,
    /// turuncu = model tahmini.
    private var shakeMapBadgeTint: Color { hasRealShakeMap ? .brandGreen : .brandOrange }
    private var center: CLLocationCoordinate2D { earthquake.coordinate.clCoordinate }
    var body: some View {
        // Bu önizleme etkileşimli değil (kaydırma/yakınlaştırma yok) — tek
        // eylemi kartın herhangi bir yerine dokunarak tam ekran haritayı
        // açmak. Kendi pan/zoom'u olan küçük bir harita yerine tek, net bir
        // "dokun ve genişlet" alanı.
        EarthquakeMapHeaderPreview(
            earthquake: earthquake,
            contours: isPremium ? contours : nil,
            // Kayıtlı yerler Premium özelliği; haritada simgeleriyle görünür.
            places: isPremium ? NotificationPlacesStore.shared.places.filter(\.isActive) : [],
            startRegion: Self.region(for: earthquake, contours: contours, zoomOutFactor: Self.entryZoomOutFactor),
            targetRegion: Self.region(for: earthquake, contours: contours),
            animatesEntry: !reduceMotion
        )
        .allowsHitTesting(false)
        // Olay özeti artık haritanın üstünde değil, detay başlığında
        // (`EarthquakeDetailView.summaryHeader`); harita yalnızca haritadır.
        .frame(height: 250)
        .overlay { loadingOverlay }
        .overlay(alignment: .top) { mapControls.allowsHitTesting(false) }
        .clipShape(.rect(cornerRadius: 22))
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .contentShape(.rect(cornerRadius: 20))
        .scaleEffect(isPressed ? 0.985 : 1)
        .opacity(isPressed ? 0.92 : 1)
        .animation(.easeOut(duration: 0.14), value: isPressed)
        .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
            isPressed = pressing
        }, perform: onTapMap)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(
            isPremium
                ? (isTurkish ? "Tam ekran harita katmanlarını açar" : "Opens full-screen map layers")
                : (isTurkish ? "Premium ekranını açar" : "Opens the Premium screen")
        )
    }

    /// ShakeMap sorgusu sürerken gösterilen ince şerit.
    ///
    /// Eskiden kartın tamamını örten bir perde ve sonsuz döngüde genişleyen üç
    /// halka vardı: harita zaten görünür ve kullanılabilirken üstünü kapatıyor,
    /// üstelik sürekli kare üreterek işlemciyi meşgul ediyordu. Yerini kartın
    /// üst kenarında duran, haritayı hiç örtmeyen belirleyici bir şerit aldı.
    private var loadingOverlay: some View {
        VStack {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.brandOrange)
                Text(isTurkish ? "ShakeMap hazırlanıyor" : "Preparing ShakeMap")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: .capsule)
            .overlay {
                Capsule().strokeBorder(Color.brandOrange.opacity(0.25), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
            .padding(.top, 56)

            Spacer(minLength: 0)
        }
        .opacity(isLoading ? 1 : 0)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.3), value: isLoading)
    }

    private var mapControls: some View {
        HStack(spacing: 8) {
            if isPremium {
                // Sabit genişlik "Tahmini ShakeMap"/"Estimated ShakeMap" gibi
                // daha uzun metinleri kırpıyor veya iki satıra bölüyordu;
                // kapsül artık içeriğe göre boyutlanıyor.
                //
                // `.fixedSize()` KULLANILMIYOR: metin sarmayı da sıkışmayı da
                // tamamen kapattığı için kapsül, yer kalmasa bile tam intrinsik
                // genişliğini alıyordu. ShakeMap verisi gelip etiket kısa
                // "ShakeMap"ten uzun "Tahmini ShakeMap"e döndüğünde kart
                // genişliği taşıyor, ScrollView'in içerik genişliği ekranı
                // aşıyor ve detay sayfası sağa sola kaydırılabilir hâle
                // geliyordu. Dosyanın geri kalanıyla aynı desen kullanılır:
                // tek satırda kal, gerekirse hafifçe küçül.
                // Rozetin rengi verinin cinsini tek bakışta ayırır: doğrulanmış
                // USGS ürünü yeşil, model tabanlı tahmin turuncu. Daha önce
                // ikisi de aynı nötr materyaldi ve fark yalnızca metinden
                // okunabiliyordu.
                Label(
                    hasRealShakeMap ? "ShakeMap" : (isTurkish ? "Tahmini ShakeMap" : "Estimated ShakeMap"),
                    systemImage: hasRealShakeMap ? "checkmark.seal.fill" : "waveform.path.ecg"
                )
                .font(.caption.weight(.bold))
                .foregroundStyle(shakeMapBadgeTint)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(.regularMaterial, in: .capsule)
            }

            Spacer()

            // Ayrı bir "Katmanlar" düğmesi yerine kartın tamamı dokunulabilir;
            // bu yalnızca dokunulabildiğini belirten görsel bir ipucudur.
            Image(systemName: "hand.tap.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: .circle)
                .accessibilityHidden(true)
        }
        .padding(12)
    }
}

// MARK: - Etkileşimsiz harita önizlemesi

/// Detay başlığındaki harita.
///
/// SwiftUI `Map`'ten MapKit'e taşındı. `MapCameraPosition`'ı `withAnimation`
/// içinde değiştirmek animasyonun oynayacağını **garanti etmiyor**: harita ilk
/// karolarını yüklerken yapılan değişiklik sessizce hedefe sıçrıyor, kullanıcı
/// da "bazen yakınlaşıyor, bazen yakınlaşmıyor" diye görüyordu. Zamanlamayı
/// tahmin etmeye çalışmak (sabit bir bekleme koymak) yarışı kapatmıyor —
/// haritanın hazır olduğu an cihaza, ağa ve karo önbelleğine göre değişiyor.
///
/// MapKit bunu kendisi haber veriyor: `mapViewDidFinishRenderingMap` ilk çizim
/// bittiğinde çağrılır ve yakınlaşma tam o anda başlatılır. Çevrimdışı gibi bu
/// çağrının hiç gelmediği durumlar için de bir yedek zamanlayıcı var.
struct EarthquakeMapHeaderPreview: UIViewRepresentable {
    let earthquake: Earthquake
    let contours: [SeismicImpactData.Contour]?
    /// Kayıtlı yerler: simgeleriyle işaretlenir; merkez üssünü kapsayan yerin
    /// bildirim dairesi de çizilir.
    var places: [NotificationPlace] = []
    /// Kameranın açılışta durduğu geniş çerçeve.
    let startRegion: MKCoordinateRegion
    /// Yakınlaşmanın bittiği çerçeve.
    let targetRegion: MKCoordinateRegion
    let animatesEntry: Bool

    func makeUIView(context: Context) -> MKMapView {
        let map = HeaderMapView()
        map.delegate = context.coordinator

        // Tamamen etkileşimsiz: kart tek bir düğme gibi davranıyor.
        map.isScrollEnabled = false
        map.isZoomEnabled = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsUserLocation = false
        map.showsCompass = false
        map.isUserInteractionEnabled = false

        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
        configuration.showsTraffic = false
        map.preferredConfiguration = configuration

        map.setRegion(animatesEntry ? startRegion : targetRegion, animated: false)
        context.coordinator.targetRegion = targetRegion
        context.coordinator.animatesEntry = animatesEntry
        context.coordinator.install(epicenter: earthquake, on: map)
        context.coordinator.apply(contours: contours, on: map)
        context.coordinator.apply(places: places, epicenter: earthquake.coordinate.clCoordinate, on: map)

        // Yakınlaşma, harita GERÇEKTEN ekranda ve ölçülmüş olduğunda başlar.
        map.onFirstRealLayout = { [weak map] in
            guard let map else { return }
            context.coordinator.scheduleZoom(on: map)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.targetRegion = targetRegion
        // Konturlar tahminden gerçek ShakeMap'e döndüğünde yalnızca katman
        // yenilenir; kamera yerinde bırakılır.
        context.coordinator.apply(contours: contours, on: map)
        context.coordinator.apply(places: places, epicenter: earthquake.coordinate.clCoordinate, on: map)
    }

    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.cancelFallback()
        map.delegate = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var targetRegion = MKCoordinateRegion()
        var animatesEntry = true

        private var didZoom = false
        private var installedContourSignature = ""
        private var installedPlaceSignature = ""
        private var overlays: [MKOverlay] = []
        private var fallback: Task<Void, Never>?

        func install(epicenter earthquake: Earthquake, on map: MKMapView) {
            map.addAnnotation(DetailEpicenterAnnotation(earthquake: earthquake))
        }

        /// Yakınlaşmayı planlar. Tam bir kez çalışır.
        ///
        /// Zamanlama bu ekranın tamamı: `setRegion(animated:)` görünüm henüz
        /// pencereye girmemişken ya da itme (push) geçişi sürerken çağrılırsa
        /// UIKit animasyonu yutuyor ve harita doğrudan hedefte beliriyor.
        /// Bu yüzden iki koşul birden beklenir — haritanın ilk GERÇEK
        /// yerleşimi (sıfır olmayan boyut + pencere) ve geçişin oturması.
        func scheduleZoom(on map: MKMapView) {
            guard animatesEntry, !didZoom, fallback == nil else { return }
            fallback = Task { @MainActor [weak map] in
                try? await Task.sleep(for: .milliseconds(420))
                guard !Task.isCancelled, let map, map.window != nil else { return }
                self.performZoom(on: map)
            }
        }

        private func performZoom(on map: MKMapView) {
            guard !didZoom else { return }
            didZoom = true
            // `UIView.animate` sarmalayıcısı MapKit'in varsayılan ~0.4 sn'lik
            // geçişini uzatır; yok sayılırsa da yakınlaşma yine oynar.
            UIView.animate(withDuration: 0.85, delay: 0, options: [.curveEaseOut]) {
                map.setRegion(self.targetRegion, animated: true)
            }
        }

        func cancelFallback() {
            fallback?.cancel()
            fallback = nil
        }

        func apply(contours: [SeismicImpactData.Contour]?, on map: MKMapView) {
            let signature = Self.signature(of: contours)
            guard signature != installedContourSignature else { return }
            installedContourSignature = signature

            if !overlays.isEmpty {
                map.removeOverlays(overlays)
                overlays = []
            }
            guard let contours, !contours.isEmpty else { return }

            var grouped: [Int: [MKPolyline]] = [:]
            for contour in contours {
                let mmi = Int(contour.mmi.rounded())
                for path in contour.paths where path.coordinates.count >= 2 {
                    var coordinates = path.coordinates
                    grouped[mmi, default: []].append(
                        MKPolyline(coordinates: &coordinates, count: coordinates.count)
                    )
                }
            }
            overlays = grouped.sorted { $0.key < $1.key }.map { mmi, polylines in
                DetailShakeMultiPolyline(mmi: mmi, polylines: polylines, isGlow: false)
            }
            if !overlays.isEmpty { map.addOverlays(overlays, level: .aboveRoads) }
        }

        /// Yer işaretleri ve merkez üssünü kapsayan yerlerin daireleri; imza
        /// değişmedikçe dokunulmaz.
        func apply(places: [NotificationPlace], epicenter: CLLocationCoordinate2D, on map: MKMapView) {
            let signature = places
                .map { "\($0.id):\($0.latitude):\($0.longitude):\($0.radiusKm):\($0.icon.rawValue)" }
                .joined(separator: "|")
            guard signature != installedPlaceSignature else { return }
            installedPlaceSignature = signature
            map.removeAnnotations(map.annotations.compactMap { $0 as? NotificationPlaceAnnotation })
            map.removeOverlays(map.overlays.compactMap { $0 as? NotificationPlaceCircle })
            map.addAnnotations(places.map(NotificationPlaceAnnotation.init))
            let circles = places.filter { $0.covers(epicenter) }.map(NotificationPlaceCircle.init)
            if !circles.isEmpty { map.addOverlays(circles, level: .aboveRoads) }
        }

        private static func signature(of contours: [SeismicImpactData.Contour]?) -> String {
            guard let contours, !contours.isEmpty else { return "" }
            return "\(contours.count)-\(contours.first?.id ?? "")-\(contours.last?.id ?? "")"
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let shake = overlay as? DetailShakeMultiPolyline {
                let renderer = MKMultiPolylineRenderer(multiPolyline: shake)
                renderer.strokeColor = detailMMIColor(shake.mmi)
                renderer.lineWidth = 2.5
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            if let circle = overlay as? NotificationPlaceCircle {
                return circle.makeRenderer()
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let place = annotation as? NotificationPlaceAnnotation {
                let reuseID = "HeaderPlace"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? NotificationPlaceAnnotationView)
                    ?? NotificationPlaceAnnotationView(annotation: place, reuseIdentifier: reuseID)
                view.annotation = place
                view.configure(with: place.place)
                return view
            }
            guard let epicenter = annotation as? DetailEpicenterAnnotation else { return nil }
            let reuseID = "HeaderEpicenter"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? DetailEpicenterAnnotationView)
                ?? DetailEpicenterAnnotationView(annotation: epicenter, reuseIdentifier: reuseID)
            view.configure(with: epicenter.earthquake)
            return view
        }
    }
}

/// İlk gerçek yerleşimini haber veren `MKMapView`.
///
/// `UIViewRepresentable.makeUIView` görünümü ekrana girmeden ve boyutu
/// belirlenmeden önce çağrılır; MapKit'in `mapViewDidFinishRenderingMap`
/// sinyali de çoğu zaman o anda, harita daha 0×0 boyuttayken gelir. O anda
/// çağrılan `setRegion(animated:)` hiçbir şey göstermez — harita sonradan
/// doğrudan hedef çerçevede belirir. Yakınlaşmanın "ilk açılışta bazen hiç
/// oynamamasının" sebebi buydu.
///
/// Bu alt sınıf, harita hem pencereye girip hem de ölçülebilir bir boyut
/// aldığında bir kez haber verir. Animasyonu tetiklemek için doğru an odur.
final class HeaderMapView: MKMapView {
    var onFirstRealLayout: (() -> Void)?
    private var didReport = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !didReport, window != nil, bounds.width > 1, bounds.height > 1 else { return }
        didReport = true
        onFirstRealLayout?()
    }
}
