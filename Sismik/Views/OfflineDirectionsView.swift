import SwiftUI
import CoreLocation
import MapKit

/// Pusula yönü sağlayıcısı.
///
/// `LocationManager`den ayrı tutuldu: manyetometre sürekli açık kalırsa pil
/// tüketir, bu yüzden yalnızca pusula ekranı görünürken çalışır.
@MainActor
@Observable
final class HeadingProvider: NSObject, CLLocationManagerDelegate {
    /// Cihazın baktığı yön (gerçek kuzeye göre derece). Pusula yoksa `nil`.
    private(set) var heading: CLLocationDirection?
    /// Manyetometre güvenilir mi? Negatif doğruluk "bu değer anlamsız"
    /// demektir; kullanıcıya sessizce yanlış yön göstermektense söylemek
    /// gerekiyor.
    private(set) var needsCalibration = false
    private(set) var isAvailable = CLLocationManager.headingAvailable()

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        // 2° eşiği: daha küçük değerler saniyede onlarca güncelleme üretip
        // hiçbir görsel kazanç sağlamıyor — aradaki fark zaten kadranın
        // yumuşatma animasyonuyla kapanıyor.
        manager.headingFilter = 2
    }

    func start() {
        guard CLLocationManager.headingAvailable() else {
            isAvailable = false
            return
        }
        isAvailable = true
        manager.startUpdatingHeading()
    }

    func stop() {
        manager.stopUpdatingHeading()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Kalibrasyon bozuksa `trueHeading` negatif gelir; o durumda manyetik
        // kuzey yine de doğru yönü verir.
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        let accuracy = newHeading.headingAccuracy
        MainActor.assumeIsolated {
            self.needsCalibration = accuracy < 0
            // Doğruluk tamamen geçersizken eski değeri korumak, ekranda
            // donmuş ama makul görünen bir yön bırakır; bu, kullanıcıyı
            // yanlış yöne yürütmekten iyidir.
            guard accuracy >= 0 || self.heading == nil else { return }
            self.heading = value
        }
    }

    /// Sistemin kalibrasyon çarkını yalnızca gerçekten gerektiğinde göster.
    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        MainActor.assumeIsolated { needsCalibration }
    }
}

/// Pusula kadranı.
///
/// Kendi alt görünümü olması bir optimizasyon: yön saniyede birkaç kez
/// değişiyor ve `heading` yalnızca burada okunuyor. Üst ekran (mesafe,
/// adres kartı, düğmeler) bu güncellemelerden hiç etkilenmiyor, yalnızca
/// bu küçük ağaç yeniden çiziliyor.
private struct CompassDial: View {
    /// Hedefin gerçek kuzeye göre açısı. Konum değişmedikçe sabit.
    let bearing: CLLocationDirection?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var headingProvider = HeadingProvider()
    /// Kadranın SÜREKLİ açısı.
    ///
    /// Ham `-heading` değeri 359°'den 1°'ye geçtiğinde 358 derecelik bir fark
    /// üretir ve kadran tam tur geri döner. Burada her adımda en kısa yön
    /// seçilip açı biriktiriliyor; kuzeyin üstünden geçmek artık görünmüyor.
    @State private var dialAngle: Double = 0
    @State private var didAlign = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
                .shadow(color: .black.opacity(0.05), radius: 12, y: 5)

            // Kadranın dönen parçaları tek bir katmanda: çizgiler, kuzey
            // işareti ve hedef oku birlikte döner. Ok, kadranın içinde
            // hedefin mutlak açısıyla duruyor; ikisinin bileşkesi doğru yönü
            // verir ve tek bir animasyon yeter.
            ZStack {
                tickMarks
                northMarker

                if let bearing {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 74, weight: .semibold))
                        .foregroundStyle(Color.brandOrange)
                        .rotationEffect(.degrees(bearing))
                        .shadow(color: Color.brandOrange.opacity(0.28), radius: 10, y: 4)
                }
            }
            .rotationEffect(.degrees(dialAngle))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: dialAngle)

            if bearing == nil {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(L("compass.waitingForLocation"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 30)
            }
        }
        .frame(width: 240, height: 240)
        .overlay(alignment: .bottom) {
            if headingProvider.needsCalibration {
                Label(
                    L("compass.calibrate"),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .offset(y: 16)
            }
        }
        .onAppear { headingProvider.start() }
        .onDisappear { headingProvider.stop() }
        .onChange(of: headingProvider.heading) { _, new in
            guard let new else { return }
            let target = -new
            guard didAlign else {
                // İlk değer animasyonsuz yerleşir; ekran açılırken kadranın
                // rastgele bir açıdan dönerek gelmesi gereksiz.
                dialAngle = target
                didAlign = true
                return
            }
            dialAngle += Self.shortestDelta(from: dialAngle, to: target)
        }
        .accessibilityHidden(true)
    }

    /// İki açı arasındaki en kısa fark, (-180, 180] aralığında.
    static func shortestDelta(from current: Double, to target: Double) -> Double {
        let raw = (target - current).truncatingRemainder(dividingBy: 360)
        return (raw + 540).truncatingRemainder(dividingBy: 360) - 180
    }

    private var tickMarks: some View {
        ForEach(0..<12, id: \.self) { index in
            let isMajor = index.isMultiple(of: 3)
            Capsule()
                .fill(Color.primary.opacity(isMajor ? 0.32 : 0.14))
                .frame(width: isMajor ? 2.5 : 2, height: isMajor ? 14 : 8)
                .offset(y: -104)
                .rotationEffect(.degrees(Double(index) * 30))
        }
    }

    private var northMarker: some View {
        Text(L("compass.north.short"))
            .font(.caption.weight(.black))
            .foregroundStyle(.red.opacity(0.85))
            .offset(y: -84)
    }
}

/// Ağ olmadan yön bulma ekranı.
///
/// Apple Haritalar'ın yol tarifi rota sunucusuna gider; şebeke çöktüğünde
/// çalışmaz — ve bu ekranın en çok gerektiği an tam olarak odur. Burada rota
/// yok: yalnızca GPS ve pusula var, ikisi de tamamen çevrimdışı çalışır.
///
/// Alttan açılan bir kart değil, kendi sayfası: kullanıcı bu ekranı elinde
/// tutarak yürüyecek. Sayfa olarak açılınca kaydırma jesti kazara ekranı
/// kapatmıyor ve pusula tam yüksekliği kullanabiliyor.
struct OfflineDirectionsView: View {
    let name: String
    let address: String?
    let coordinate: CLLocationCoordinate2D

    @Environment(LocationManager.self) private var locationManager
    @State private var copiedField: String?

    private var target: CLLocation {
        CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    private var distanceMeters: CLLocationDistance? {
        locationManager.location.map { $0.distance(from: target) }
    }

    /// Kullanıcıdan hedefe olan gerçek kuzey açısı (büyük daire yönü).
    private var bearing: CLLocationDirection? {
        guard let origin = locationManager.location?.coordinate else { return nil }
        let fromLat = origin.latitude * .pi / 180
        let fromLon = origin.longitude * .pi / 180
        let toLat = coordinate.latitude * .pi / 180
        let toLon = coordinate.longitude * .pi / 180
        let deltaLon = toLon - fromLon
        let y = sin(deltaLon) * cos(toLat)
        let x = cos(fromLat) * sin(toLat) - sin(fromLat) * cos(toLat) * cos(deltaLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    private var coordinateText: String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                CompassDial(bearing: bearing)
                    .frame(maxWidth: .infinity)

                distanceReadout
                detailCard
                actions
                footnote
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
            .sismikContentWidth()
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        // Bu ekran, gezinme çubuğunu gizleyen bir kökten push edilebiliyor;
        // başlık ve geri düğmesi kaybolmasın.
        .toolbar(.visible, for: .navigationBar)
        .onAppear { locationManager.requestLocation() }
    }

    // MARK: - Mesafe

    private var distanceReadout: some View {
        VStack(spacing: 4) {
            if let distanceMeters {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.distanceValue(distanceMeters))
                        .font(.system(size: 44, weight: .black).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(Self.distanceUnit(distanceMeters))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                // Yalnızca metre değiştiğinde animasyon: ham `Double`e
                // bağlansaydı GPS'in her mikro sapması sayacı tetiklerdi.
                .animation(.snappy(duration: 0.3), value: Int(distanceMeters))

                Text(bearing.map { Self.compassName(for: $0) } ?? "—")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandOrange)
            } else {
                Text(L("compass.needsLocation"))
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let bearing else {
            return L("compass.waitingForLocation")
        }
        let direction = Self.compassName(for: bearing)
        guard let distanceMeters else { return direction }
        return "\(Self.distanceText(distanceMeters)), \(direction)"
    }

    // MARK: - Bilgi kartı

    private var detailCard: some View {
        VStack(spacing: 0) {
            if let address, !address.isEmpty {
                copyRow(
                    icon: "mappin.and.ellipse",
                    label: L("compass.address"),
                    value: address
                )
                Divider().padding(.leading, 46)
            }

            copyRow(
                icon: "globe",
                label: L("compass.coordinates"),
                value: coordinateText
            )
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }

    private func copyRow(icon: String, label: String, value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            copiedField = label
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.appAction)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Image(systemName: copiedField == label ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(copiedField == label ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label): \(value)")
        .accessibilityHint(L("compass.tapToCopy"))
    }

    // MARK: - Eylemler

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                openInMaps()
            } label: {
                Label(L("compass.openInMaps"), systemImage: "map.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.sismikPrimary(height: 52))

            ShareLink(item: shareText) {
                Label(L("compass.shareLocation"), systemImage: "square.and.arrow.up")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.button))
            }
            .buttonStyle(.plain)
        }
    }

    private var shareText: String {
        var parts = [name]
        if let address, !address.isEmpty { parts.append(address) }
        parts.append(coordinateText)
        parts.append("https://maps.apple.com/?ll=\(coordinate.latitude),\(coordinate.longitude)")
        return parts.joined(separator: "\n")
    }

    private func openInMaps() {
        let item: MKMapItem
        if #available(iOS 26.0, *) {
            item = MKMapItem(location: target, address: nil)
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        }
        item.name = name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    private var footnote: some View {
        Label {
            Text(L("compass.footnote"))
        } icon: {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 16))
    }

    // MARK: - Biçimlendirme

    /// Sayı ve birim ayrı döner: kadranın ortasında ikisi farklı puntoda
    /// yazılıyor ve rakam `contentTransition(.numericText())` ile
    /// güncelleniyor — birim de sayının parçası olsaydı her adımda tüm metin
    /// yeniden akardı.
    static func distanceValue(_ meters: CLLocationDistance) -> String {
        meters < 1_000
            ? "\(Int(meters.rounded()))"
            : (meters / 1_000).formatted(.number.precision(.fractionLength(1)))
    }

    static func distanceUnit(_ meters: CLLocationDistance) -> String {
        meters < 1_000 ? "m" : "km"
    }

    static func distanceText(_ meters: CLLocationDistance) -> String {
        "\(distanceValue(meters)) \(distanceUnit(meters))"
    }

    /// Açıyı sekiz ana yönden birine yuvarlayıp yerelleştirilmiş ifadeye
    /// çevirir. Yön adı ve onu saran kalıp ("… yönünde" / "to the …") ayrı
    /// anahtarlar değil: bazı dillerde ikisi tek bir çekim hâlinde birleşiyor
    /// ve parçalı çeviri bozuk cümle üretiyordu.
    static func compassName(for bearing: CLLocationDirection) -> String {
        let keys = [
            "compass.dir.n", "compass.dir.ne", "compass.dir.e", "compass.dir.se",
            "compass.dir.s", "compass.dir.sw", "compass.dir.w", "compass.dir.nw"
        ]
        let index = Int(((bearing + 22.5) / 45).rounded(.down)) % 8
        return L(keys[(index + 8) % 8])
    }
}
